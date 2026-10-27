#!/usr/bin/env node
/*
Copyright 2026 The Radius Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

"use strict";

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const LIMITS = { totalMs: 90000, requestMs: 10000, requests: 24, items: 20, bytes: 2 * 1024 * 1024 };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN = /^[a-z0-9_.:/-]{1,256}$/i;
const TIME = /^\d{4}-\d\d-\d\dT[\d:.]+Z$/;
const IMAGE = /^(?:[a-z0-9.-]+(?::[0-9]+)?\/)?[a-z0-9_./-]+(?::[a-zA-Z0-9_.-]+)?(?:@sha256:[a-f0-9]{64})?$/;
const LISTS = [
  ["Microsoft.ContainerInstance/ngroups", "2024-11-01-preview"],
  ["Microsoft.ContainerInstance/containerGroupProfiles", "2024-11-01-preview"],
  ["Microsoft.ContainerInstance/containerGroups", "2024-11-01-preview"],
  ["Microsoft.Network/virtualNetworks", "2024-05-01"],
  ["Microsoft.Network/natGateways", "2024-05-01"],
  ["Microsoft.Network/loadBalancers", "2024-05-01"],
  ["Microsoft.Network/publicIPAddresses", "2024-05-01"],
];

const text = (value, pattern = TOKEN) =>
  typeof value === "string" && value.length <= 2048 && pattern.test(value) ? value : null;
const integer = (value) => Number.isSafeInteger(value) ? value : null;
const object = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};
const array = (value) => Array.isArray(value) ? value.slice(0, LIMITS.items) : [];

function state(value) {
  const v = object(value);
  return {
    state: text(v.state), exitCode: integer(v.exitCode),
    startTime: text(v.startTime, TIME), finishTime: text(v.finishTime, TIME),
  };
}

function instanceView(value) {
  const v = object(value);
  return {
    available: value !== null && typeof value === "object" && !Array.isArray(value),
    state: text(v.state), restartCount: integer(v.restartCount),
    currentState: state(v.currentState), previousState: state(v.previousState),
    events: array(v.events).map((event) => {
      const e = object(event);
      return {
        name: text(e.name), type: text(e.type), count: integer(e.count),
        firstTimestamp: text(e.firstTimestamp, TIME), lastTimestamp: text(e.lastTimestamp, TIME),
      };
    }),
    eventsTruncated: Array.isArray(v.events) && v.events.length > LIMITS.items,
  };
}

function scopedId(value, scope) {
  return typeof value === "string" &&
    value.toLowerCase().startsWith(`${scope.toLowerCase()}/providers/`) &&
    /^\/[a-z0-9_./()-]+$/i.test(value) && value.length <= 2048 &&
    !value.split("/").some((part) => part === "." || part === "..") ? value : null;
}

function resource(value, scope) {
  const v = object(value);
  const p = object(v.properties);
  const containers = (items) => array(items).map((item) => {
    const c = object(item);
    const cp = object(c.properties);
    return { name: text(c.name), image: text(cp.image, IMAGE), instanceView: instanceView(cp.instanceView) };
  });
  return {
    id: scopedId(v.id, scope), type: text(v.type), name: text(v.name), location: text(v.location),
    provisioningState: text(p.provisioningState),
    instanceView: instanceView(p.instanceView),
    containers: containers(p.containers), initContainers: containers(p.initContainers),
    containersTruncated: [p.containers, p.initContainers].some((v) => Array.isArray(v) && v.length > LIMITS.items),
    containerGroupProfileId: scopedId(object(p.containerGroupProfile).id, scope),
    profiles: array(p.containerGroupProfiles).map((item) => {
      const profile = object(item);
      return {
        id: scopedId(object(profile.resource).id, scope), revision: integer(profile.revision),
        subnetIds: array(object(profile.containerGroupProperties).subnetIds)
          .map((subnet) => scopedId(object(subnet).id, scope)),
      };
    }),
    subnets: array(p.subnets).map((item) => {
      const subnet = object(item);
      const sp = object(subnet.properties);
      return {
        id: scopedId(subnet.id, scope), provisioningState: text(sp.provisioningState),
        natGatewayId: scopedId(object(sp.natGateway).id, scope),
      };
    }),
    subnetIds: array(p.subnetIds).map((subnet) => scopedId(object(subnet).id, scope)),
  };
}

function activity(value, scope) {
  const v = object(value);
  return {
    resourceId: scopedId(v.resourceId, scope),
    eventTimestamp: text(v.eventTimestamp, TIME),
    correlationId: text(v.correlationId, UUID), operationId: text(v.operationId, UUID),
    eventDataId: text(v.eventDataId, UUID),
    serviceRequestId: text(object(v.properties).serviceRequestId, UUID),
    operation: text(object(v.operationName).value),
    status: text(object(v.status).value), subStatus: text(object(v.subStatus).value),
  };
}

// Never save CLI stderr: preview API errors can echo a resource body or credentials.
function runAz(args, timeoutMs, command = "az", prefix = []) {
  return new Promise((resolve) => {
    let child;
    let output = [];
    let bytes = 0;
    let finished = false;
    let timer;
    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve(result);
    };
    const stop = (reason) => {
      if (finished) return;
      // Azure CLI runs in its own process group on the Linux CI runners.
      if (process.platform !== "win32" && child.pid) {
        try { process.kill(-child.pid, "SIGKILL"); }
        catch (error) { if (error.code !== "ESRCH") child.kill("SIGKILL"); }
      } else {
        child.kill("SIGKILL");
      }
      finish({ error: reason });
    };
    child = spawn(command, [...prefix, ...args], {
      stdio: ["ignore", "pipe", "ignore"], detached: process.platform !== "win32",
      env: { ...process.env, AZURE_CORE_COLLECT_TELEMETRY: "0" },
    });
    timer = setTimeout(() => stop("request-timeout"), timeoutMs);
    child.on("error", () => finish({ error: "cli-unavailable" }));
    child.stdout.on("data", (chunk) => {
      if (finished) return;
      bytes += chunk.length;
      if (bytes > LIMITS.bytes) stop("response-size-limit");
      else output.push(chunk);
    });
    child.on("close", (code) => {
      if (finished) return;
      if (code !== 0) return finish({ error: "azure-cli-failed", exitCode: integer(code) });
      try { finish({ value: JSON.parse(Buffer.concat(output).toString("utf8")) }); }
      catch { finish({ error: "invalid-json" }); }
      output = [];
    });
  });
}

async function collect({ subscription, group, app, started, save, run = runAz, now = Date.now }) {
  const deadline = now() + LIMITS.totalMs;
  let requests = 0;
  if (!/^[a-z0-9_-]{1,90}$/i.test(group) ||
      !/^[a-z0-9_-]{1,128}$/i.test(app) || !TIME.test(started)) {
    throw new Error("invalid-diagnostic-context");
  }
  // Older base workflows log in to Azure but do not export the subscription
  // to the test step. Read only the selected account ID, never credentials.
  if (subscription === "") {
    requests++;
    const result = await run(["account", "show", "--query", "id", "--only-show-errors", "--output", "json"],
      LIMITS.requestMs);
    if (result.error || typeof result.value !== "string" || !UUID.test(result.value)) {
      throw new Error("azure-subscription-context-unavailable");
    }
    subscription = result.value;
  }
  if (!UUID.test(subscription)) throw new Error("invalid-diagnostic-context");
  const scope = `/subscriptions/${subscription}/resourceGroups/${group}`;
  const report = {
    schemaVersion: 1, app, scope, deploymentStarted: started,
    collectedAt: new Date(now()).toISOString(), limits: LIMITS,
    scopeNote: "Test resource group snapshot; resources are not attributed to an app.",
    omitted: "Free-text messages, detailStatus, raw errors, headers, tags, env, commands, credentials, deployment parameters and outputs.",
    providerLimitations: "The 2024-11-01-preview API has no NGroups child-list or NGroup instanceView. Resource-group containerGroups may not expose managed children. Activity Log records can be delayed; original PUT/poll headers and registry responses are not available through these reads.",
    resources: [], activity: [], collections: [], errors: [], truncations: [],
  };
  save(report);
  async function get(label, url) {
    if (requests >= LIMITS.requests || now() >= deadline) {
      report.errors.push({ operation: label, reason: "collection-budget-exhausted" });
      save(report);
      return null;
    }
    requests++;
    const result = await run(["rest", "--method", "get", "--url", url, "--only-show-errors", "--output", "json"],
      Math.min(LIMITS.requestMs, deadline - now()));
    if (result.error) {
      report.errors.push({ operation: label, reason: result.error, exitCode: result.exitCode ?? null });
      save(report);
      return null;
    }
    if (!result.value || typeof result.value !== "object" || Array.isArray(result.value)) {
      report.errors.push({ operation: label, reason: "invalid-response-shape" });
      save(report);
      return null;
    }
    return result.value;
  }
  function page(label, response) {
    if (response === null) return [];
    if (!Array.isArray(response.value)) {
      report.errors.push({ operation: label, reason: "invalid-list-shape" });
      return [];
    }
    if (response.nextLink || response.value.length > LIMITS.items) report.truncations.push(label);
    report.collections.push({ operation: label, returned: response.value.length, kept: Math.min(response.value.length, LIMITS.items) });
    return array(response.value);
  }
  const groups = [];
  for (const [type, version] of LISTS) {
    const label = `list:${type}`;
    const response = await get(label, `https://management.azure.com${scope}/providers/${type}?api-version=${version}`);
    for (const item of page(label, response)) {
      const id = scopedId(object(item).id, scope);
      // Do not follow provider-supplied URLs or IDs outside this exact collection.
      const prefix = `${scope}/providers/${type}/`;
      if (!id || !id.toLowerCase().startsWith(prefix.toLowerCase()) ||
          id.slice(prefix.length).includes("/")) {
        report.errors.push({ operation: label, reason: "invalid-resource-id" });
        continue;
      }
      report.resources.push(resource(item, scope));
      if (type === "Microsoft.ContainerInstance/containerGroups") groups.push(id);
    }
    save(report);
  }
  // Activity Log data can arrive late. Do not poll or retry the deployment.
  const filter = `eventTimestamp ge '${started}' and resourceGroupName eq '${group}'`;
  const log = await get("activity-log", `https://management.azure.com/subscriptions/${subscription}/providers/microsoft.insights/eventtypes/management/values?api-version=2015-04-01&$filter=${encodeURIComponent(filter)}&$top=20`);
  report.activity = page("activity-log", log).map((v) => activity(v, scope)).filter((v) => v.resourceId);
  save(report);
  // The list API omits some instance-view data; GET each discovered child group.
  for (const id of groups) {
    const detail = await get("container-group-instance-view", `https://management.azure.com${id}?api-version=2024-11-01-preview`);
    if (detail) {
      if (scopedId(detail.id, scope)?.toLowerCase() === id.toLowerCase()) {
        report.resources.push(resource(detail, scope));
      } else {
        report.errors.push({ operation: "container-group-instance-view", reason: "invalid-resource-id" });
      }
    }
    save(report);
  }
  return report;
}

if (require.main === module) {
  const [directory, subscription, group, app, started] = process.argv.slice(2);
  collect({
    subscription, group, app, started,
    save: (report) => fs.writeFileSync(path.join(directory, "azure.json"), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 }),
  }).then((report) => {
    if (report.errors.length || report.truncations.length) {
      console.error("Azure diagnostics incomplete; see azure.json errors and truncations.");
      process.exitCode = 1;
    }
  }).catch(() => {
    console.error("Azure diagnostics failed: invalid context or collector/output error. Raw error withheld.");
    process.exitCode = 1;
  });
}

module.exports = { collect, runAz, resource, activity, LIMITS };
