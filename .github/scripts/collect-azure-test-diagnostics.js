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
const OPERATION_STATE = /^(Accepted|Running|InProgress|Enqueued|Dequeued|Succeeded|Failed|Canceled|Cancelled|Creating|Updating|Deleting)$/i;
const COSMOS_API_VERSION = "2025-04-15";
const COSMOS_OPERATIONS = 4;
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
const SERVICE_LISTS = [
  ["Microsoft.CognitiveServices/accounts", "2025-06-01"],
  ["Microsoft.DocumentDB/databaseAccounts", "2024-11-15"],
  ["Microsoft.DBforPostgreSQL/flexibleServers", "2024-08-01"],
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
  return typeof scope === "string" && typeof value === "string" &&
    value.toLowerCase().startsWith(`${scope.toLowerCase()}/providers/`) &&
    /^\/[a-z0-9_./()-]+$/i.test(value) && value.length <= 2048 &&
    !value.split("/").some((part) => part === "." || part === "..") ? value : null;
}

function radiusId(value) {
  const id = text(value,
    /^\/planes\/(?:radius|kubernetes)\/local\/(?:resourcegroups|namespaces)\/[a-z0-9_()-]+\/providers\/[a-z0-9_.-]+(?:\/[a-z0-9_().-]+){2,}$/i);
  return id && !id.split("/").some((part) => part === "." || part === "..") ? id : null;
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
    provisioningState: text(p.provisioningState) ?? text(v.provisioningState), state: text(p.state),
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
    errorCodes: errorCodes(object(v.properties).statusMessage),
  };
}

function errorCodes(value) {
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { return []; }
  }
  const codes = new Set();
  function visit(item, depth) {
    if (depth > 8 || codes.size >= LIMITS.items) return;
    if (Array.isArray(item)) {
      for (const child of item.slice(0, LIMITS.items)) visit(child, depth + 1);
    } else if (item && typeof item === "object") {
      const code = text(item.code, /^[a-z][a-z0-9_.-]{0,127}$/i);
      if (code) codes.add(code);
      visit(item.error, depth + 1);
      visit(item.details, depth + 1);
    }
  }
  visit(value, 0);
  return [...codes];
}

function requestTarget(value, scope) {
  if (typeof value !== "string") return null;
  let url;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (url.username || url.password) return null;
  const azure = url.hostname === "management.azure.com" && scopedId(url.pathname, scope);
  const cosmos = url.protocol === "https:" && url.port === "" && !url.hash &&
    (value === `https://management.azure.com${url.pathname}` ||
      value.startsWith(`https://management.azure.com${url.pathname}?`)) &&
    cosmosOperation(url.pathname, scope);
  const radius = /^(ucp|dynamic-rp|applications-rp)\.radius-system$/.test(url.hostname) &&
    /^\/(?:apis\/api\.ucp\.dev\/v1alpha3\/)?planes\/radius\/local\/[a-z0-9_./()-]+$/i.test(url.pathname);
  return azure || radius || cosmos ? { host: url.hostname, path: url.pathname } : null;
}

function cosmosOperation(value, scope) {
  const subscription = typeof scope === "string" &&
    /^\/subscriptions\/([a-f0-9-]+)\/resourceGroups\/[a-z0-9_-]+$/i.exec(scope)?.[1];
  if (!subscription || !UUID.test(subscription) || typeof value !== "string") return null;
  const match = /^\/subscriptions\/([a-f0-9-]+)\/providers\/Microsoft\.DocumentDB\/locations\/([a-z0-9-]{1,64})\/operationsStatus\/([a-f0-9-]+)$/i.exec(value);
  return match && match[1].toLowerCase() === subscription.toLowerCase() && UUID.test(match[3])
    ? { location: match[2].toLowerCase(), operationId: match[3] } : null;
}

function operationState(value) {
  const v = object(value);
  return {
    status: text(v.status, OPERATION_STATE),
    provisioningState: text(object(v.properties).provisioningState, OPERATION_STATE),
    errorCodes: errorCodes(v.error),
  };
}

function recipeSource(value) {
  const image = text(value, IMAGE);
  if (image) return image;
  if (typeof value !== "string" || value.length > 2048 || /[?#]/.test(value)) return null;
  let url;
  try { url = new URL(value); } catch { return null; }
  return (url.protocol === "https:" || url.protocol === "http:") &&
    !url.username && !url.password &&
    text(url.hostname, /^[a-z0-9.-]+$/i) &&
    text(url.pathname, /^\/[a-z0-9_./()-]+$/i) ? value : null;
}

function logRecords(output, scope) {
  const records = [];
  let omitted = 0;
  for (const line of output.split("\n")) {
    if (!line.trim()) continue;
    let v;
    try { v = object(JSON.parse(line)); } catch { omitted++; continue; }
    if (records.length >= LIMITS.items * 100) { omitted++; continue; }
    const message = typeof v.message === "string" ? v.message : "";
    const recipe = /^Deploying recipe: "[a-z0-9._-]+", template: "([^"]+)"$/i.exec(message);
    const httpEvent = [
      ["Start processing HTTP request ", "logical-start"],
      ["Sending HTTP request ", "request-send"],
      ["Received HTTP response headers ", "response-headers"],
      ["End processing HTTP request ", "logical-end"],
    ].find(([prefix]) => message.startsWith(prefix))?.[1] ?? null;
    const resourceId = v.resourceId ?? v.ResourceId ?? v.resourceID;
    records.push({
      timestamp: text(v.timestamp, TIME), severity: text(v.severity),
      traceId: text(v.traceId, /^[a-f0-9]{32}$/i), spanId: text(v.spanId, /^[a-f0-9]{16}$/i),
      resourceId: scopedId(resourceId, scope) ?? radiusId(resourceId),
      operationId: text(v.operationId, UUID),
      operationType: text(v.operationType, /^[a-z0-9_./|()-]{1,256}$/i),
      operationName: text(v.OperationName),
      state: text(v.message, /^(Accepted|Running|Succeeded|Failed|Canceled|Creating|Updating|Deleting)$/),
      version: text(v.version),
      recipeSource: recipeSource(recipe?.[1]),
      httpEvent,
      logger: text(v.scope ?? v.name, /^[a-z0-9_.:/ -]{1,256}$/i),
      request: requestTarget(v.Uri, scope),
      method: text(v.HttpMethod), statusCode: integer(v.StatusCode),
      elapsedMilliseconds: integer(v.ElapsedMilliseconds),
      errorCodes: errorCodes(v.error),
    });
  }
  return { records, omitted };
}

// Never save CLI stderr: preview API errors can echo a resource body or credentials.
function runAz(args, timeoutMs, command = "az", prefix = [], parse = JSON.parse) {
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
      try { finish({ value: parse(Buffer.concat(output).toString("utf8")) }); }
      catch { finish({ error: "invalid-json" }); }
      output = [];
    });
  });
}

async function collect({ subscription, group, app, started, resourceType = "", platform = "azure",
  save, run = runAz, runKubernetes = (args, timeout, parse) => runAz(args, timeout, "kubectl", [], parse),
  now = Date.now }) {
  const deadline = now() + LIMITS.totalMs;
  let requests = 0;
  if (!/^[a-z0-9_-]{1,128}$/i.test(app) || !TIME.test(started)) {
    throw new Error("invalid-diagnostic-context");
  }
  const report = {
    schemaVersion: 1, app, resourceType, platform, scope: null, deploymentStarted: started,
    collectedAt: new Date(now()).toISOString(), limits: LIMITS,
    scopeNote: "Cluster log snapshot and optional Azure test resource group snapshot; records are not attributed to an app.",
    omitted: "Free-text messages, detailStatus, raw errors, headers, URL queries, tags, env, commands, credentials, deployment parameters and outputs.",
    providerLimitations: "The 2024-11-01-preview API has no NGroups child-list or NGroup instanceView. Resource-group containerGroups may not expose managed children. Activity Log records can be delayed; original PUT/poll headers and registry responses are not available through these reads. Cosmos operation reads are later snapshots, not the engine's response. Subscription-scoped operation paths and matching account regions do not prove account or app ownership.",
    resources: [], activity: [], radiusLogs: [], cosmosOperations: [], collections: [], errors: [], truncations: [],
  };
  save(report);
  // Older base workflows log in to Azure but do not export the subscription
  // to the test step. Read only the selected account ID, never credentials.
  if (platform === "azure" && subscription === "" && /^[a-z0-9_-]{1,90}$/i.test(group)) {
    requests++;
    const result = await run(["account", "show", "--query", "id", "--only-show-errors", "--output", "json"],
      LIMITS.requestMs);
    if (result.error || typeof result.value !== "string" || !UUID.test(result.value)) {
      report.errors.push({ operation: "azure-context", reason: "azure-subscription-context-unavailable" });
    } else {
      subscription = result.value;
    }
  }
  const scope = platform === "azure" && UUID.test(subscription) && /^[a-z0-9_-]{1,90}$/i.test(group)
    ? `/subscriptions/${subscription}/resourceGroups/${group}` : null;
  report.scope = scope;
  if (platform === "azure" && !scope && report.errors.length === 0) {
    report.errors.push({ operation: "azure-context", reason: "invalid-or-missing-azure-context" });
  }
  save(report);
  async function kubernetes(label, args, parse = JSON.parse) {
    if (requests >= LIMITS.requests || now() >= deadline) {
      report.errors.push({ operation: label, reason: "collection-budget-exhausted" });
      save(report);
      return null;
    }
    requests++;
    const result = await runKubernetes(args, Math.min(LIMITS.requestMs, deadline - now()), parse);
    if (result.error) {
      report.errors.push({ operation: label, reason: result.error, exitCode: result.exitCode ?? null });
      save(report);
      return null;
    }
    return result.value;
  }
  const pods = await kubernetes("radius-pods", ["get", "pods", "-n", "radius-system", "-o", "json"]);
  if (pods !== null && !Array.isArray(object(pods).items)) {
    report.errors.push({ operation: "radius-pods", reason: "invalid-list-shape" });
    save(report);
  }
  const seen = new Set();
  if (Array.isArray(object(pods).items) && pods.items.length > LIMITS.items) {
    report.truncations.push("radius-pods");
  }
  for (const pod of array(object(pods).items)) {
    const name = object(object(pod).metadata).name;
    const component = typeof name === "string" &&
      /^(deployment-engine|bicep-de|dynamic-rp|applications-rp|ucp)-[a-z0-9-]+$/.exec(name)?.[1];
    if (!component) continue;
    seen.add(component);
    const logs = await kubernetes(`radius-logs:${component}`, [
      "logs", name, "-n", "radius-system", "--all-containers=true",
      `--since-time=${started}`, "--tail=2000", "--limit-bytes=524288",
    ], (output) => logRecords(output, scope));
    const images = array(object(pod.spec).containers).map((container) => text(object(container).image, IMAGE));
    const imageIds = array(object(pod.status).containerStatuses).map((container) => {
      const id = object(container).imageID;
      return typeof id === "string" ? text(id.replace(/^(docker-pullable|containerd|docker):\/\//, ""), IMAGE) : null;
    });
    report.radiusLogs.push({ component, pod: name, images, imageIds, tailOnly: true, ...(logs ?? { records: [], omitted: 0 }) });
    save(report);
  }
  if (pods !== null && seen.size === 0) {
    report.errors.push({ operation: "radius-pods", reason: "no-radius-pods" });
    save(report);
  }
  if (!scope) return report;
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
  function recordResource(value) {
    const next = resource(value, scope);
    const previous = report.resources.find((item) => item.id.toLowerCase() === next.id.toLowerCase());
    if (previous) {
      Object.assign(previous, Object.fromEntries(Object.entries(next).filter(([, value]) => value !== null)));
    } else {
      report.resources.push(next);
    }
  }
  const groups = [];
  const inventory = await get("resource-inventory",
    `https://management.azure.com${scope}/resources?api-version=2021-04-01&$expand=provisioningState`);
  for (const item of page("resource-inventory", inventory)) {
    if (scopedId(object(item).id, scope)) recordResource(item);
  }
  save(report);
  const children = [];
  // These API-specific reads enrich the general inventory; they do not select
  // which applications or failures get logs.
  for (const [type, version] of [...LISTS, ...SERVICE_LISTS]) {
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
      recordResource(item);
      if (type === "Microsoft.ContainerInstance/containerGroups") groups.push(id);
      if (type === "Microsoft.CognitiveServices/accounts") {
        children.push([`${id}/deployments`, version]);
      }
      if (type === "Microsoft.DocumentDB/databaseAccounts") {
        children.push([`${id}/mongodbDatabases`, version]);
      }
    }
    save(report);
  }
  for (const [collection, version] of children) {
    const label = `children:${collection}`;
    const response = await get(label, `https://management.azure.com${collection}?api-version=${version}`);
    for (const item of page(label, response)) {
      const id = scopedId(object(item).id, scope);
      if (!id || !id.toLowerCase().startsWith(`${collection.toLowerCase()}/`) ||
          id.slice(collection.length + 1).includes("/")) {
        report.errors.push({ operation: label, reason: "invalid-resource-id" });
        continue;
      }
      recordResource(item);
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
        recordResource(detail);
      } else {
        report.errors.push({ operation: "container-group-instance-view", reason: "invalid-resource-id" });
      }
    }
    save(report);
  }
  // Only read observed Cosmos status paths in this subscription and an
  // inventoried account region. Never follow a logged query or response URL.
  const candidates = new Map();
  for (const logs of report.radiusLogs) {
    if (!["deployment-engine", "bicep-de"].includes(logs.component)) continue;
    for (const record of logs.records) {
      if (record.method !== "GET" || record.request?.host !== "management.azure.com") continue;
      const target = cosmosOperation(record.request.path, scope);
      if (!target || !record.traceId || !record.timestamp ||
          !Number.isFinite(Date.parse(record.timestamp)) ||
          Date.parse(record.timestamp) < Date.parse(started)) continue;
      const accounts = report.resources.filter((item) =>
        item.type?.toLowerCase() === "microsoft.documentdb/databaseaccounts" &&
        item.location?.toLowerCase().replaceAll(" ", "") === target.location);
      if (!accounts.length) continue;
      const key = record.request.path.toLowerCase();
      const previous = candidates.get(key);
      if (!previous || Date.parse(previous.record.timestamp) <= Date.parse(record.timestamp)) {
        candidates.set(key, { record, target, accounts });
      }
    }
  }
  if (candidates.size > COSMOS_OPERATIONS) report.truncations.push("cosmos-operation-status");
  const latest = [...candidates.values()].sort((a, b) =>
    Date.parse(b.record.timestamp) - Date.parse(a.record.timestamp));
  for (const { record, target, accounts } of latest.slice(0, COSMOS_OPERATIONS)) {
    const response = await get("cosmos-operation-status",
      `https://management.azure.com${record.request.path}?api-version=${COSMOS_API_VERSION}`);
    const snapshot = {
      path: record.request.path, operationId: target.operationId,
      traceId: record.traceId, spanId: record.spanId, observedAt: record.timestamp,
      collectedAt: new Date(now()).toISOString(), apiVersion: COSMOS_API_VERSION,
      candidateAccountIds: accounts.map((item) => item.id),
      attribution: "Subscription and account region only; account/app ownership is not proved.",
      responseAvailable: response !== null,
      ...operationState(response),
    };
    report.cosmosOperations.push(snapshot);
    if (response && ((!snapshot.status && !snapshot.provisioningState) ||
        (response.status !== undefined && !snapshot.status) ||
        (object(response.properties).provisioningState !== undefined && !snapshot.provisioningState))) {
      report.errors.push({ operation: "cosmos-operation-status", reason: "missing-or-unrecognized-operation-state" });
    }
    save(report);
  }
  return report;
}

if (require.main === module) {
  const [directory, subscription, group, app, started, resourceType, platform = "azure"] = process.argv.slice(2);
  const file = platform === "azure" ? "azure.json" : "radius.json";
  collect({
    subscription, group, app, started, resourceType, platform,
    save: (report) => fs.writeFileSync(path.join(directory, file), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 }),
  }).then((report) => {
    if (report.errors.length || report.truncations.length) {
      console.error(`Failure diagnostics incomplete; see ${file} errors and truncations.`);
      process.exitCode = 1;
    }
  }).catch(() => {
    console.error("Failure diagnostics failed: invalid context or collector/output error. Raw error withheld.");
    process.exitCode = 1;
  });
}

module.exports = { collect, runAz, resource, activity, logRecords, operationState, LIMITS };
