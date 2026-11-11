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

const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { collect, runAz, resource, activity, logRecords, operationState, deploymentErrors, collectionOutcome, LIMITS } = require("../collect-azure-test-diagnostics.js");

const subscription = "11111111-1111-1111-1111-111111111111";
const group = "rrttest-123-1-bicep";
const scope = `/subscriptions/${subscription}/resourceGroups/${group}`;
const started = "2026-10-22T17:00:00Z";
const secret = "DO-NOT-SAVE-this-secret";
const id = (type, name) => `${scope}/providers/${type}/${name}`;
const containerId = id("Microsoft.ContainerInstance/containerGroups", "child");
const image = `public.ecr.aws/docker/library/nginx@sha256:${"a".repeat(64)}`;

function fixture(resourceId = containerId) {
  return {
    id: resourceId, type: "Microsoft.ContainerInstance/containerGroups", name: "child", location: "westus3",
    tags: { secret }, identity: { secret },
    properties: {
      provisioningState: "Failed",
      containers: [{
        name: "web", properties: {
          image, environmentVariables: [{ value: secret, secureValue: secret }],
          command: [secret], imageRegistryCredentials: [{ password: secret }],
          instanceView: {
            currentState: { state: "Waiting", detailStatus: secret },
            events: [{ name: "Failed", type: "Warning", count: 2, message: secret, firstTimestamp: started }],
          },
        },
      }],
      initContainers: [{ name: "init", properties: { image: "busybox:1.37", command: [secret] } }],
      volumes: [{ azureFile: { storageAccountKey: secret } }],
      parameters: { secret }, outputs: { secret }, error: { message: secret },
      instanceView: { state: "Pending", events: [{ name: "Pulling", message: secret }] },
    },
  };
}

async function withMock(run, extra = {}) {
  const snapshots = [];
  const calls = [];
  const report = await collect({
    subscription, group, app: "testapp-123", started,
    save: (value) => snapshots.push(JSON.stringify(value)),
    run: async (args, timeout) => { calls.push(args); return run(args, timeout); },
    runKubernetes: async (args) => ({ value: args[0] === "get"
      ? { items: [{ metadata: { name: "deployment-engine-test" } }] }
      : { records: [], omitted: 0 } }),
    ...extra,
  });
  return { report, calls, snapshots };
}

test("collects preview ACI, images, network state and operation IDs using scoped GETs", async () => {
  const { report, calls, snapshots } = await withMock(async (args) => {
    const url = new URL(args[4]);
    if (url.pathname.endsWith("/containerGroups")) return { value: { value: [fixture()] } };
    if (url.pathname.endsWith("/containerGroups/child")) return { value: fixture() };
    if (url.pathname.endsWith("/ngroups")) {
      return { value: { value: [{
        id: id("Microsoft.ContainerInstance/ngroups", "ng"),
        properties: {
          provisioningState: "Failed",
          containerGroupProfiles: [{ resource: { id: id("Microsoft.ContainerInstance/containerGroupProfiles", "profile") } }],
        },
      }] } };
    }
    if (url.pathname.endsWith("/virtualNetworks")) {
      return { value: { value: [{
        id: id("Microsoft.Network/virtualNetworks", "vnet"),
        properties: {
          provisioningState: "Succeeded",
          subnets: [{ id: id("Microsoft.Network/virtualNetworks", "vnet/subnets/default"), properties: { provisioningState: "Succeeded" } }],
        },
      }] } };
    }
    if (url.pathname.endsWith("/management/values")) {
      return { value: { value: [{
        resourceId: containerId, eventTimestamp: started, correlationId: subscription,
        operationId: subscription, properties: { serviceRequestId: subscription, statusMessage: secret },
        status: { value: "Failed" }, operationName: { value: "Microsoft.ContainerInstance/ngroups/write" },
        claims: { secret }, caller: secret,
      }] } };
    }
    return { value: { value: [] } };
  });
  assert.equal(calls.length, 13);
  for (const args of calls) {
    assert.deepEqual(args.slice(0, 3), ["rest", "--method", "get"]);
    const url = new URL(args[4]);
    assert.equal(url.origin, "https://management.azure.com");
    if (url.pathname.endsWith("/management/values")) {
      assert.equal(url.searchParams.get("$filter"),
        `eventTimestamp ge '${started}' and eventTimestamp le '${report.collectedAt}' and resourceGroupName eq '${group}'`);
      assert.equal(url.searchParams.has("$top"), false);
      assert.equal(url.searchParams.get("$select"),
        "resourceId,eventTimestamp,correlationId,operationId,eventDataId,operationName,status,subStatus,properties");
    } else {
      assert.ok(url.pathname === `${scope}/resources` || url.pathname.startsWith(`${scope}/providers/`));
    }
  }
  assert.equal(report.resources.find((r) => r.id.endsWith("/ng")).provisioningState, "Failed");
  assert.equal(report.resources.find((r) => r.id.endsWith("/vnet")).subnets[0].provisioningState, "Succeeded");
  assert.equal(report.resources.find((r) => r.id === containerId).containers[0].image, image);
  assert.equal(report.resources.find((r) => r.id === containerId).containers[0].instanceView.events[0].count, 2);
  assert.equal(report.activity[0].serviceRequestId, subscription);
  assert.equal(report.errors.length, 0);
  assert.ok(snapshots.length > calls.length, "partial evidence must be saved before later calls");
  assert.ok(snapshots.every((s) => !s.includes(secret)));
});

test("allowlists typed leaves; never copies nested objects, free text or credential-bearing image URLs", () => {
  const input = fixture();
  input.name = { secret };
  input.properties.provisioningState = { secret };
  input.properties.state = { secret };
  input.properties.containers[0].properties.image = `https://user:${secret}@host/image?token=${secret}`;
  input.properties.instanceView.events[0].name = { secret };
  const safe = resource(input, scope);
  assert.equal(safe.name, null);
  assert.equal(safe.provisioningState, null);
  assert.equal(safe.state, null);
  assert.equal(safe.containers[0].image, null);
  assert.ok(!JSON.stringify(safe).includes(secret));
  assert.ok(!JSON.stringify(activity({ properties: { serviceRequestId: secret }, status: { value: { secret } } }, scope)).includes(secret));
  assert.equal(resource(null, scope).instanceView.available, false);
});

test("expands inventory state and merges provider details by resource ID", async () => {
  const other = id("Microsoft.Storage/storageAccounts", "storage");
  const { report } = await withMock(async (args) => {
    const url = new URL(args[4]);
    if (url.pathname.endsWith("/resources")) {
      assert.equal(url.searchParams.get("$expand"), "provisioningState");
      return { value: { value: [
        { id: containerId, name: "child", type: "Microsoft.ContainerInstance/containerGroups", provisioningState: "Creating" },
        { id: other, provisioningState: "Succeeded" },
      ] } };
    }
    if (url.pathname.endsWith("/containerGroups")) {
      return { value: { value: [{ id: containerId.toUpperCase(), properties: { provisioningState: "Succeeded" } }] } };
    }
    if (url.pathname.toLowerCase().endsWith("/containergroups/child")) return { value: fixture() };
    return { value: { value: [] } };
  });
  assert.equal(report.resources.length, 2);
  const container = report.resources.find((r) => r.id.toLowerCase() === containerId.toLowerCase());
  assert.equal(container.name, "child");
  assert.equal(container.provisioningState, "Failed");
  assert.equal(container.containers[0].image, image);
  assert.equal(report.resources.find((r) => r.id === other).provisioningState, "Succeeded");
  assert.equal(resource({ provisioningState: { secret } }, scope).provisioningState, null);
});

test("caps discovered pod replicas and reports truncation", async () => {
  const podCalls = [];
  const { report } = await withMock(() => assert.fail("must not call Azure"), {
    platform: "kubernetes",
    runKubernetes: async (args) => {
      podCalls.push(args);
      return { value: args[0] === "get"
        ? { items: Array.from({ length: LIMITS.items + 5 }, (_, i) => ({ metadata: { name: `dynamic-rp-${i}` } })) }
        : { records: [], omitted: 0 } };
    },
  });
  assert.equal(report.radiusLogs.length, LIMITS.items);
  assert.equal(podCalls.filter((args) => args[0] === "logs").length, LIMITS.items);
  assert.ok(report.truncations.includes("radius-pods"));
});

test("non-container failures collect account, model, MongoDB and PostgreSQL state", async () => {
  const account = id("Microsoft.CognitiveServices/accounts", "openai");
  const mongo = id("Microsoft.DocumentDB/databaseAccounts", "mongo");
  const postgres = id("Microsoft.DBforPostgreSQL/flexibleServers", "postgres");
  const { report, calls } = await withMock(async (args) => {
    const url = new URL(args[4]);
    if (url.pathname.endsWith("/accounts")) {
      return { value: { value: [{ id: account, properties: { provisioningState: "Creating", secret } }] } };
    }
    if (url.pathname.endsWith("/databaseAccounts")) return { value: { value: [{ id: mongo }] } };
    if (url.pathname.endsWith("/accounts/openai/deployments")) {
      return { value: { value: [{ id: `${account}/deployments/chat`, properties: { provisioningState: "Failed" } }] } };
    }
    if (url.pathname.endsWith("/mongodbDatabases")) {
      return { value: { value: [{ id: `${mongo}/mongodbDatabases/test`, properties: { provisioningState: "Creating" } }] } };
    }
    if (url.pathname.endsWith("/flexibleServers")) {
      return { value: { value: [{ id: postgres, properties: { state: "Ready", secret } }] } };
    }
    return { value: { value: [] } };
  }, { resourceType: "Radius.AI/models" });
  assert.equal(calls.length, 14);
  assert.equal(report.resourceType, "Radius.AI/models");
  assert.equal(report.resources.find((r) => r.id === account).provisioningState, "Creating");
  assert.equal(report.resources.find((r) => r.id.endsWith("/deployments/chat")).provisioningState, "Failed");
  assert.equal(report.resources.find((r) => r.id === postgres).state, "Ready");
  assert.equal(report.resources.find((r) => r.id === postgres).provisioningState, null);
  assert.ok(calls.some((args) => args[4].includes("/flexibleServers?")));
  assert.ok(!JSON.stringify(report).includes(secret));
});

test("saves filtered Radius request records before Azure reads, without bodies or URL queries", async () => {
  const order = [];
  const request = `${scope}/providers/Microsoft.CognitiveServices/accounts/openai/deployments/chat`;
  const raw = JSON.stringify({
    timestamp: started, severity: "info", scope: "System.Net.Http.HttpClient",
    traceId: "a".repeat(32), spanId: "b".repeat(16),
    Uri: `https://management.azure.com${request}?api-version=2025-06-01&token=${secret}`,
    HttpMethod: "PUT", StatusCode: 409, message: secret, body: { secret }, headers: { secret },
    error: { code: "RequestConflict", message: secret },
  });
  const { report } = await withMock(async () => {
    order.push("azure");
    return { value: { value: [] } };
  }, {
    runKubernetes: async (args, timeout, parse) => {
      order.push(args[0]);
      assert.ok(timeout <= LIMITS.requestMs);
      if (args[0] === "get") return { value: { items: [
        { metadata: { name: "deployment-engine-abc" },
          spec: { containers: [{ image: "ghcr.io/azure-octo/deployment-engine:edge" }, { image: `https://user:${secret}@host` }] },
          status: { containerStatuses: [{ imageID: `docker-pullable://ghcr.io/azure-octo/deployment-engine@sha256:${"a".repeat(64)}` }] } },
        { metadata: { name: "unrelated-pod" } },
        { metadata: { name: "deployment-engine-def" } },
      ] } };
      assert.ok(args.includes(`--since-time=${started}`));
      assert.ok(args.includes("--limit-bytes=524288"));
      return { value: parse(`${raw}\n${secret}\n`) };
    },
  });
  assert.deepEqual(order.slice(0, 4), ["get", "logs", "logs", "azure"]);
  assert.equal(report.radiusLogs.length, 2);
  const logs = report.radiusLogs[0];
  assert.equal(logs.omitted, 1);
  assert.deepEqual(logs.records[0].request, { host: "management.azure.com", path: request });
  assert.equal(logs.records[0].method, "PUT");
  assert.equal(logs.records[0].statusCode, 409);
  assert.deepEqual(logs.records[0].errorCodes, ["RequestConflict"]);
  assert.equal(logs.images[1], null);
  assert.equal(logs.imageIds[0], `ghcr.io/azure-octo/deployment-engine@sha256:${"a".repeat(64)}`);
  assert.equal(logs.tailOnly, true);
  assert.ok(!JSON.stringify(report).includes(secret));
  for (const uri of [`https://evil.invalid${request}`, `https://management.azure.com${request.replace(group, "other")}`,
    `https://user:password@management.azure.com${request}`]) {
    assert.equal(logRecords(JSON.stringify({ Uri: uri }), scope).records[0].request, null);
  }
});

test("records HTTP phases and exact recipe references without free-text messages", () => {
  const source = "mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0";
  const { records } = logRecords([
    JSON.stringify({ message: `Sending HTTP request PUT https://example.invalid/?password=${secret}` }),
    JSON.stringify({ message: `Deploying recipe: "default", template: "${source}"` }),
    JSON.stringify({ message: "Succeeded" }),
    JSON.stringify({ resourceID: "/planes/radius/local/resourcegroups/default/providers/Radius.Data/widgets/test" }),
  ].join("\n"), scope);
  assert.equal(records[0].httpEvent, "request-send");
  assert.equal(records[1].recipeSource, source);
  assert.equal(records[2].state, "Succeeded");
  assert.equal(records[3].resourceId, "/planes/radius/local/resourcegroups/default/providers/Radius.Data/widgets/test");
  assert.ok(!JSON.stringify(records).includes(secret));
});

const operationPath = `/subscriptions/${subscription}/providers/Microsoft.DocumentDB/locations/centralus/operationsStatus/${subscription}`;
const mongoId = id("Microsoft.DocumentDB/databaseAccounts", "mongo");
const mongoAccount = {
  id: mongoId, type: "Microsoft.DocumentDB/databaseAccounts", location: "centralus",
  properties: { provisioningState: "Succeeded", connectionStrings: [secret], keys: { secret } },
};
function pollLog(uri = `https://management.azure.com${operationPath}?api-version=old&token=${secret}`, extra = {}) {
  return JSON.stringify({
    timestamp: started, traceId: "a".repeat(32), spanId: "b".repeat(16),
    Uri: uri, HttpMethod: "GET", StatusCode: 200, body: { secret }, headers: { Authorization: secret },
    ...extra,
  });
}
async function withCosmos({ logs = pollLog(), account = mongoAccount, response = {
  value: { status: "Succeeded", properties: { provisioningState: "Succeeded", secret }, connectionStrings: [secret] },
}, ...extra } = {}) {
  return withMock(async (args) => {
    const url = new URL(args[4]);
    if (url.pathname.endsWith("/databaseAccounts")) return { value: { value: account ? [account] : [] } };
    if (/\/operationsStatus\//i.test(url.pathname)) return response;
    return { value: { value: [] } };
  }, {
    runKubernetes: async (args, _timeout, parse) => ({ value: args[0] === "get"
      ? { items: [{ metadata: { name: "bicep-de-test" } }] } : parse(logs) }),
    ...extra,
  });
}

test("snapshots observed Cosmos operation state once without treating HTTP 200 as completion", async () => {
  for (const status of ["InProgress", "Enqueued", "Dequeued", "Succeeded", "Failed", "Canceled"]) {
    const { report, calls, snapshots } = await withCosmos({
      logs: `${pollLog()}\n${pollLog(undefined, { timestamp: "2026-10-22T17:01:00Z" })}\n${pollLog()}`,
      response: { value: { status, properties: { provisioningState: "Succeeded", secret },
        error: { code: "OperationFailed", message: secret, details: [{ code: "RequestConflict", message: secret }] },
        connectionStrings: [secret], primaryMasterKey: secret, headers: { Authorization: secret },
      } },
    });
    const reads = calls.filter((args) => args[4].includes("/operationsStatus/"));
    assert.equal(reads.length, 1);
    assert.equal(reads[0][4], `https://management.azure.com${operationPath}?api-version=2025-04-15`);
    const op = report.cosmosOperations[0];
    assert.equal(op.status, status);
    assert.equal(op.provisioningState, "Succeeded");
    assert.equal(op.operationId, subscription);
    assert.equal(op.traceId, "a".repeat(32));
    assert.equal(op.spanId, "b".repeat(16));
    assert.equal(op.observedAt, "2026-10-22T17:01:00Z");
    assert.equal(op.responseAvailable, true);
    assert.deepEqual(op.candidateAccountIds, [mongoId]);
    assert.match(op.attribution, /ownership is not proved/);
    assert.deepEqual(op.errorCodes, ["OperationFailed", "RequestConflict"]);
    assert.ok(snapshots.every((s) => !s.includes(secret)));
    assert.ok(!JSON.stringify(report).includes("api-version=old"));
    assert.equal(report.errors.length, 0);
  }
});

test("Cosmos log paths reject other subscriptions, providers, hosts and unsafe URL shapes", () => {
  assert.deepEqual(logRecords(pollLog(), scope).records[0].request,
    { host: "management.azure.com", path: operationPath });
  const valid = `https://management.azure.com${operationPath}`;
  for (const uri of [
    valid.replace(subscription, "22222222-2222-2222-2222-222222222222"),
    valid.replace("Microsoft.DocumentDB", "Microsoft.Storage"),
    valid.replace("operationsStatus", "listKeys"),
    valid.replace("management.azure.com", "evil.invalid"),
    valid.replace("https:", "http:"),
    valid.replace("management.azure.com", `user:${secret}@management.azure.com`),
    valid.replace("management.azure.com", "management.azure.com:8443"),
    valid.replace("/operationsStatus/", "/extra/../operationsStatus/"),
    valid.replace("/operationsStatus/", "/%2e%2e/operationsStatus/"),
    valid.replace("/operationsStatus/", "\\operationsStatus\\"),
    `${valid}/child`, `${valid}#${secret}`, `${valid.slice(0, -36)}not-a-uuid`,
  ]) {
    assert.equal(logRecords(pollLog(uri), scope).records[0].request, null, uri);
  }
  assert.equal(logRecords(pollLog(), null).records[0].request, null);
});

test("Cosmos reads require engine GET traces since deployment and a scoped account in the same region", async () => {
  for (const options of [
    { account: null },
    { account: { ...mongoAccount, id: mongoId.replace(group, "other-group") } },
    { account: { ...mongoAccount, location: "westus3" } },
    { logs: pollLog(undefined, { HttpMethod: "PUT" }) },
    { logs: pollLog(undefined, { traceId: null }) },
    { logs: pollLog(undefined, { timestamp: "2026-10-22T16:59:59Z" }) },
    { logs: pollLog(undefined, { timestamp: "2026-99-22T17:00:00Z" }) },
    { logs: pollLog(undefined, { timestamp: null }) },
    { runKubernetes: async (args, _timeout, parse) => ({ value: args[0] === "get"
      ? { items: [{ metadata: { name: "ucp-test" } }] } : parse(pollLog()) }) },
  ]) {
    const { report, calls } = await withCosmos(options);
    assert.equal(report.cosmosOperations.length, 0);
    assert.ok(calls.every((args) => !args[4].includes("/operationsStatus/")));
  }
});

test("Cosmos unavailable and unknown states remain explicit, never inferred from account success", async () => {
  for (const response of [
    { error: "azure-cli-failed", exitCode: 3 },
    { error: "request-timeout" },
    { value: { status: secret, properties: { provisioningState: { secret } } } },
    { value: { status: { secret }, properties: { provisioningState: secret } } },
    { value: {} },
  ]) {
    const { report, snapshots } = await withCosmos({ response });
    assert.equal(report.cosmosOperations[0].status, null);
    assert.equal(report.cosmosOperations[0].provisioningState, null);
    assert.equal(report.cosmosOperations[0].responseAvailable, !response.error);
    assert.ok(report.errors.some((e) => e.operation === "cosmos-operation-status"));
    assert.ok(snapshots.every((s) => !s.includes(secret)));
  }
  for (const value of [null, [], secret]) {
    assert.deepEqual(operationState(value), { status: null, provisioningState: null, errorCodes: [] });
  }
});

test("Cosmos snapshots cap unique operations and use the existing request and time budgets", async () => {
  const logs = Array.from({ length: 6 }, (_, i) => pollLog(
    `https://management.azure.com${operationPath.slice(0, -1)}${i}`,
    { timestamp: `2026-10-22T17:0${i}:00Z` },
  )).join("\n");
  const capped = await withCosmos({ logs });
  assert.equal(capped.report.cosmosOperations.length, 4);
  assert.equal(capped.report.cosmosOperations[0].observedAt, "2026-10-22T17:05:00Z");
  assert.ok(capped.report.truncations.includes("cosmos-operation-status"));
  let clock = 0;
  const spent = await withCosmos({ now: () => clock, run: async (args) => {
    if (args[4].includes("/databaseAccounts?")) return { value: { value: [mongoAccount] } };
    if (args[4].includes("/management/values?")) clock = LIMITS.totalMs + 1;
    assert.ok(!args[4].includes("/operationsStatus/"));
    return { value: { value: [] } };
  } });
  assert.equal(spent.report.cosmosOperations[0].responseAvailable, false);
  assert.ok(spent.report.errors.some((e) => e.operation === "cosmos-operation-status" &&
    e.reason === "collection-budget-exhausted"));
  const requestLimited = await withCosmos({ run: async (args) => {
    const url = new URL(args[4]);
    if (url.pathname.endsWith("/containerGroups")) {
      return { value: { value: Array.from({ length: LIMITS.items }, (_, i) => fixture(`${containerId}${i}`)) } };
    }
    if (url.pathname.endsWith("/databaseAccounts")) return { value: { value: [mongoAccount] } };
    assert.ok(!url.pathname.includes("/operationsStatus/"), "no request after the shared limit");
    return { value: { value: [] } };
  } });
  assert.equal(requestLimited.report.cosmosOperations[0].responseAvailable, false);
  assert.ok(requestLimited.report.errors.some((e) => e.operation === "cosmos-operation-status" &&
    e.reason === "collection-budget-exhausted"));
});

test("preserves native Radius IDs without Azure context and rejects unsafe paths", () => {
  for (const resourceId of [
    "/planes/radius/local/resourceGroups/default/providers/Radius.AI/models/testmodel",
    "/planes/kubernetes/local/namespaces/default/providers/core/Secret/test",
  ]) {
    for (const key of ["resourceId", "ResourceId", "resourceID"]) {
      assert.equal(logRecords(JSON.stringify({ [key]: resourceId }), null).records[0].resourceId, resourceId);
    }
  }
  for (const resourceId of [
    "/planes/radius/local/resourceGroups/default/providers/Radius.AI/models/../test",
    "/planes/radius/local/resourceGroups/default/providers/Radius.AI/models/test?token=hidden",
    "/planes/radius/local/resourceGroups/default/providers/Radius.AI/models/test#hidden",
    "/planes/radius/local/resourceGroups/default/unrelated/path",
    "/planes/other/local/resourceGroups/default/providers/Radius.AI/models/test",
    { secret },
    "x".repeat(2049),
  ]) {
    assert.equal(logRecords(JSON.stringify({ resourceId }), null).records[0].resourceId, null);
  }
});

test("preserves HTTP Terraform recipe sources without credentials, queries or fragments", () => {
  const source = (value) => logRecords(JSON.stringify({
    message: `Deploying recipe: "default", template: "${value}"`,
  }), scope).records[0].recipeSource;
  for (const value of [
    "http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/secrets-azure.zip",
    "https://modules.example.invalid:8443/recipes/secrets-azure.zip",
  ]) {
    assert.equal(source(value), value);
  }
  for (const value of [
    `https://user:${secret}@modules.example.invalid/recipe.zip`,
    `https://modules.example.invalid/recipe.zip?token=${secret}`,
    `https://modules.example.invalid/recipe.zip#${secret}`,
    "https://modules.example.invalid/recipe.zip?",
    "https://modules.example.invalid/recipe.zip#",
    "https://modules.example.invalid/recipe with spaces.zip",
    "file:///recipe.zip",
    "ftp://modules.example.invalid/recipe.zip",
    "https://modules.example.invalid/" + "a".repeat(2048),
  ]) {
    assert.equal(source(value), null);
  }
});

test("preserves bounded logger names with spaces without accepting free text", () => {
  for (const key of ["scope", "name"]) {
    for (const value of ["applications.core.Applications.Core async worker", "ucp async worker"]) {
      assert.equal(logRecords(JSON.stringify({ [key]: value }), scope).records[0].logger, value);
    }
    for (const value of [{ secret }, "a".repeat(257), "worker\nhidden", "worker?token=hidden"]) {
      assert.equal(logRecords(JSON.stringify({ [key]: value }), scope).records[0].logger, null);
    }
  }
});

test("pod log failures are explicit and cannot block Azure evidence", async () => {
  const { report, calls } = await withMock(async () => ({ value: { value: [] } }), {
    runKubernetes: async () => ({ error: "cli-unavailable" }),
  });
  assert.equal(calls.length, 12);
  assert.deepEqual(report.errors[0], { operation: "radius-pods", reason: "cli-unavailable", exitCode: null });
});

test("Activity Log saves structured error codes but discards provider messages", () => {
  const safe = activity({
    resourceId: containerId,
    properties: { statusMessage: JSON.stringify({ error: {
      code: "DeploymentFailed", message: secret, details: [{ code: "RequestConflict", message: secret }],
    } }) },
  }, scope);
  assert.deepEqual(safe.errorCodes, ["DeploymentFailed", "RequestConflict"]);
  assert.ok(!JSON.stringify(safe).includes(secret));
});

function activityEvent(index, status = "Started", code = null, resourceId = containerId) {
  return {
    resourceId, eventTimestamp: new Date(Date.parse(started) + index * 1000).toISOString(),
    eventDataId: `00000000-0000-0000-0000-${String(index).padStart(12, "0")}`,
    correlationId: subscription, operationId: subscription,
    operationName: { value: "Microsoft.ContainerInstance/containerGroups/delete", localizedValue: secret },
    status: { value: status }, caller: secret, claims: { secret },
    properties: {
      serviceRequestId: subscription,
      statusMessage: JSON.stringify({ error: { code, message: secret } }),
    },
  };
}

test("Activity Log retains distinct failures and recent context beyond the item limit", async () => {
  const events = [
    ...Array.from({ length: LIMITS.items + 5 }, (_, i) => activityEvent(100 - i)),
    activityEvent(4, "Failed", "PublicIPAddressCannotBeDeleted"),
    activityEvent(3, "Failed", "PublicIPAddressCannotBeDeleted"),
    activityEvent(2, "Canceled"),
    activityEvent(1, "Succeeded"),
    activityEvent(0, "Failed", "AnotherConflict"),
    activityEvent(200, "Failed", "ForeignFailure", containerId.replace(group, "other")),
  ];
  const { report, calls, snapshots } = await withMock(async (args) => ({
    value: { value: args[4].includes("/management/values?") ? events : [] },
  }));
  assert.equal(calls.length, 12, "retention must not add requests");
  assert.deepEqual(report.activity, [
    ...events.slice(0, 15), ...events.slice(25, 30),
  ].map((event) => activity(event, scope)));
  assert.deepEqual(report.collections.at(-1), { operation: "activity-log", returned: 31, kept: 20 });
  assert.deepEqual(report.errors, []);
  assert.deepEqual(report.truncations, ["activity-log"]);
  assert.deepEqual(collectionOutcome(report, "azure.json"), {
    exitCode: 1,
    message: "Failure diagnostics truncated; reads succeeded but evidence is incomplete. See azure.json truncations.",
  });
  assert.ok(snapshots.every((snapshot) => !snapshot.includes(secret)));
  assert.ok(!JSON.stringify(report).includes("ForeignFailure"));
});

test("Activity Log keeps distinct failures before excess failures or routine progress", async () => {
  const events = [
    ...Array.from({ length: LIMITS.items + 5 }, (_, i) => activityEvent(100 - i, "Failed", "RepeatedConflict")),
    activityEvent(3, "Failed", "DistinctConflict"),
    activityEvent(2, "Cancelled"),
    activityEvent(1, "Succeeded"),
  ];
  const { report } = await withMock(async (args) => ({
    value: { value: args[4].includes("/management/values?") ? events : [] },
  }));
  assert.deepEqual(report.activity, [
    ...events.slice(0, 17), ...events.slice(25),
  ].map((event) => activity(event, scope)));
  assert.deepEqual(report.truncations, ["activity-log"]);
});

test("more than 20 distinct failures keep the newest failures, not routine progress", async () => {
  const failures = Array.from({ length: LIMITS.items + 5 }, (_, i) =>
    activityEvent(i, "Failed", `Conflict${i}`));
  const { report } = await withMock(async (args) => ({
    value: { value: args[4].includes("/management/values?")
      ? [activityEvent(100), ...failures] : [] },
  }));
  assert.deepEqual(report.activity, failures.slice(5).reverse().map((event) => activity(event, scope)));
  assert.deepEqual(report.collections.at(-1), { operation: "activity-log", returned: 26, kept: 20 });
  assert.deepEqual(report.errors, []);
  assert.deepEqual(report.truncations, ["activity-log"]);
  assert.equal(collectionOutcome(report, "azure.json").exitCode, 1);
});

test("Activity Log next pages remain explicit, unfollowed truncation even below the item limit", async () => {
  const { report, calls, snapshots } = await withMock(async (args) => ({
    value: args[4].includes("/management/values?")
      ? { value: [activityEvent(1)], nextLink: `https://evil.invalid/${secret}` }
      : { value: [] },
  }));
  assert.equal(calls.length, 12);
  assert.deepEqual(report.activity, [activity(activityEvent(1), scope)]);
  assert.deepEqual(report.collections.at(-1), { operation: "activity-log", returned: 1, kept: 1 });
  assert.deepEqual(report.errors, []);
  assert.deepEqual(report.truncations, ["activity-log"]);
  assert.equal(collectionOutcome(report, "azure.json").exitCode, 1);
  assert.ok(snapshots.every((snapshot) => !snapshot.includes(secret)));
});

test("exact item limit is not truncation; failed reads still take precedence over truncation", async () => {
  const events = Array.from({ length: LIMITS.items }, (_, i) => activityEvent(LIMITS.items - i));
  const success = await withMock(async (args) => ({
    value: { value: args[4].includes("/management/values?") ? events : [] },
  }));
  assert.deepEqual(success.report.activity, events.map((event) => activity(event, scope)));
  assert.deepEqual(success.report.truncations, []);
  assert.deepEqual(collectionOutcome(success.report, "azure.json"), { exitCode: 0, message: null });
  for (const result of [{ error: "azure-cli-failed", exitCode: 3 }, { error: "request-timeout" },
    { error: "response-size-limit" }, { value: { value: {} } }]) {
    const { report } = await withMock(async (args) =>
      args[4].includes("/management/values?") ? result : { value: { value: [] } });
    assert.deepEqual(report.activity, []);
    assert.deepEqual(report.truncations, []);
    assert.equal(report.errors.length, 1);
    assert.equal(report.errors[0].operation, "activity-log");
    if (result.error) {
      assert.equal(report.errors[0].reason, result.error);
      assert.equal(report.errors[0].exitCode, result.exitCode ?? null);
    } else {
      assert.equal(report.errors[0].reason, "invalid-list-shape");
    }
    report.truncations.push("resource-inventory");
    assert.deepEqual(collectionOutcome(report, "azure.json"), {
      exitCode: 1, message: "Failure diagnostics incomplete; see azure.json errors and truncations.",
    });
  }
});

const registryCode = "AzureContainerInstance/RegistryErrorResponse";
const nGroupId = id("Microsoft.ContainerInstance/ngroups", "ngroups-test");
const aciTargets = [
  "4114cc1a-89b4-4c63-ac08-97e82f0fa1e8",
  "caf77f84-473e-4273-afd4-4ddbb77639a0",
  "e6e62358-13ba-4923-8480-233a17ff432b",
];
function registryFailure(target = nGroupId) {
  let error = {
    code: "ResourceDeploymentFailure", target, message: secret,
    details: [{ code: registryCode, target: aciTargets.join(", "), message: secret }],
  };
  for (const code of ["DeploymentFailed", "RecipeDeploymentFailed", "ResourceDeploymentFailure", "DeploymentFailed"]) {
    error = { code, message: secret, details: [error] };
  }
  return { error, parameters: { secret }, headers: { secret } };
}

test("qualified ACI codes survive nested Radius errors in logs and Activity Log", () => {
  const failure = registryFailure();
  for (const codes of [
    activity({ properties: { statusMessage: JSON.stringify(failure) } }, scope).errorCodes,
    logRecords(JSON.stringify(failure), scope).records[0].errorCodes,
  ]) {
    assert.ok(codes.includes(registryCode));
    assert.ok(!JSON.stringify(codes).includes(secret));
  }
  for (const code of ["AzureContainerInstance/RegistryErrorResponse?token=hidden", "a".repeat(129),
    "AzureContainerInstance//RegistryErrorResponse", { secret }]) {
    assert.deepEqual(logRecords(JSON.stringify({ error: { code } }), scope).records[0].errorCodes, []);
  }
  failure.error.code = "a".repeat(129);
  assert.ok(logRecords(JSON.stringify(failure), scope).records[0].errorCodes.includes(registryCode));
});

test("captures the retained CLI error shape and trace ID without messages or duplicate targets", () => {
  const failure = registryFailure();
  failure.error.message = `${secret} { "quoted": "}\\\\{" }`;
  failure.error.details.push(failure.error.details[0]);
  const transcript = `Deployment failed:\r\n${JSON.stringify(failure, null, 2)}\r\nTraceId:  ${"a".repeat(32)}\r\n${secret}\n`;
  const report = deploymentErrors(transcript, scope);
  assert.deepEqual(report, {
    errors: [{ code: registryCode, resourceId: nGroupId, errorTargets: aciTargets }],
    traceIds: ["a".repeat(32)], truncated: false,
  });
  assert.ok(!JSON.stringify(report).includes(secret));
});

test("deployment capture rejects foreign resources and accepts only UUID error targets", () => {
  for (const target of [
    nGroupId.replace(group, "other-group"), nGroupId.replace(subscription, aciTargets[0]),
    containerId, `${scope}/providers/other/type/providers/Microsoft.ContainerInstance/ngroups/test`,
    `${nGroupId}/../test`, `${nGroupId}?token=${secret}`,
  ]) {
    assert.deepEqual(deploymentErrors(JSON.stringify(registryFailure(target)), scope).errors, []);
  }
  const report = deploymentErrors(JSON.stringify({
    error: { code: "ResourceDeploymentFailure", target: nGroupId, details: [
      { code: registryCode, target: `${aciTargets[0].toUpperCase()}, ${secret}, ${aciTargets[0]}`, message: secret },
      { code: "DifferentFailure", target: aciTargets[1] },
    ] },
  }), scope);
  assert.deepEqual(report.errors[0].errorTargets, [aciTargets[0]]);
  assert.ok(!JSON.stringify(report).includes(secret));
  assert.deepEqual(deploymentErrors(`${secret}\nTraceId: ${secret}\n{incomplete`, scope), {
    errors: [], traceIds: [], truncated: true,
  });
});

test("deployment capture reports record, depth, and target bounds", () => {
  const targets = Array.from({ length: LIMITS.items + 1 }, (_, i) =>
    `00000000-0000-0000-0000-${String(i).padStart(12, "0")}`);
  const report = deploymentErrors(JSON.stringify({
    code: registryCode, target: nGroupId, details: [{
      code: registryCode, target: targets.join(", "),
    }],
  }), scope);
  assert.equal(report.errors[0].errorTargets.length, LIMITS.items);
  assert.equal(report.truncated, true);
  assert.equal(deploymentErrors("{}\n".repeat(LIMITS.items), scope).truncated, false);
  assert.equal(deploymentErrors("{}\n".repeat(LIMITS.items + 1), scope).truncated, true);
  assert.equal(deploymentErrors("{not-json}\n", scope).truncated, true);
  const manyResources = deploymentErrors(JSON.stringify({ details: targets.map((_, i) => ({
    code: registryCode, target: `${nGroupId}-${i}`,
  })) }), scope);
  assert.equal(manyResources.errors.length, LIMITS.items);
  assert.equal(manyResources.truncated, true);
  let deep = registryFailure();
  for (let i = 0; i < 17; i++) deep = { error: deep };
  assert.equal(deploymentErrors(JSON.stringify(deep), scope).truncated, true);
});

test("deployment capture CLI saves only filtered evidence, bounds input, and reports I/O/context errors", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "rtc-deployment-errors-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const transcript = path.join(directory, "raw.txt");
  const output = path.join(directory, "deployment-error.json");
  const execute = (args = []) => spawnSync(process.execPath, [
    path.join(__dirname, "../collect-azure-test-diagnostics.js"), "--deployment-error",
    transcript, directory, subscription, group, "testapp-123", started, ...args,
  ], { encoding: "utf8", timeout: 5000 });
  fs.writeFileSync(transcript, JSON.stringify(registryFailure()));
  const success = execute();
  assert.equal(success.status, 0, success.stderr);
  const report = JSON.parse(fs.readFileSync(output, "utf8"));
  assert.equal(report.app, "testapp-123");
  assert.equal(report.scope, scope);
  assert.equal(report.deploymentStarted, started);
  assert.deepEqual(report.errors[0].errorTargets, aciTargets);
  assert.equal(report.transcriptTruncated, false);
  assert.ok(!fs.readFileSync(output, "utf8").includes(secret));
  if (process.platform !== "win32") assert.equal(fs.statSync(output).mode & 0o777, 0o600);
  fs.writeFileSync(transcript, " ".repeat(LIMITS.bytes + 1) + JSON.stringify(registryFailure()));
  assert.equal(execute().status, 0);
  assert.equal(JSON.parse(fs.readFileSync(output, "utf8")).transcriptTruncated, true);
  fs.unlinkSync(transcript);
  const failure = execute();
  assert.equal(failure.status, 1);
  assert.match(failure.stderr, /capture failed/);
  assert.ok(!failure.stderr.includes(directory));
  const badContext = spawnSync(process.execPath, [
    path.join(__dirname, "../collect-azure-test-diagnostics.js"), "--deployment-error",
    secret, directory, subscription, `group'${secret}`, "testapp-123", started,
  ], { encoding: "utf8", timeout: 5000 });
  assert.equal(badContext.status, 1);
  assert.ok(!badContext.stderr.includes(secret));
  const missingContext = spawnSync(process.execPath, [
    path.join(__dirname, "../collect-azure-test-diagnostics.js"), "--deployment-error",
    transcript, directory, "", group, "testapp-123", started,
  ], { encoding: "utf8", timeout: 5000 });
  assert.equal(missingContext.status, 1);
  assert.match(missingContext.stderr, /invalid context/);
});

test("records denied/unsupported calls without copying CLI errors and continues", async () => {
  const { report, calls } = await withMock(async () => ({ error: "azure-cli-failed", exitCode: 3 }));
  assert.equal(calls.length, 12);
  assert.equal(report.errors.length, 12);
  assert.deepEqual(report.errors[0], { operation: "resource-inventory", reason: "azure-cli-failed", exitCode: 3 });
});

test("records missing data and invalid API shapes explicitly", async () => {
  const empty = await withMock(async () => ({ value: { value: [] } }));
  assert.equal(empty.report.collections.length, 12);
  assert.ok(empty.report.collections.every((c) => c.returned === 0));
  assert.match(empty.report.providerLimitations, /no NGroups child-list/);
  const bad = await withMock(async () => ({ value: { value: { secret } } }));
  assert.equal(bad.report.errors.length, 12);
  assert.ok(bad.report.errors.every((e) => e.reason === "invalid-list-shape"));
  for (const value of [null, false, [], secret]) {
    const malformed = await withMock(async () => ({ value }));
    assert.equal(malformed.report.errors.length, 12);
    assert.ok(malformed.report.errors.every((e) => e.reason === "invalid-response-shape"));
  }
});

test("never follows nextLink or cross-group, wrong-type or traversal resource IDs", async () => {
  const { calls, report } = await withMock(async () => ({
    value: { value: [
      { id: containerId.replace(group, "other-group") },
      { id: `${scope}/providers/Microsoft.ContainerInstance/containerGroups/../child` },
      { id: "https://example.invalid/credentials" },
    ], nextLink: `https://example.invalid/${secret}` },
  }));
  assert.equal(calls.length, 12);
  assert.equal(report.truncations.length, 12);
  assert.equal(report.resources.length, 0);
  assert.ok(!JSON.stringify(report).includes(secret));
});

test("caps request count, pages and nested items", async () => {
  const { report, calls } = await withMock(async (args) => {
    if (args[4].includes("/containerGroups?")) {
      return { value: { value: Array.from({ length: 30 }, (_, i) => fixture(`${containerId}${i}`)) } };
    }
    if (args[4].includes("/containerGroups/")) return { value: fixture(args[4].split("?")[0].replace("https://management.azure.com", "")) };
    return { value: { value: [] } };
  });
  assert.equal(calls.length, LIMITS.requests - 2);
  assert.ok(report.errors.some((e) => e.reason === "collection-budget-exhausted"));
  assert.ok(report.truncations.includes("list:Microsoft.ContainerInstance/containerGroups"));
  const input = fixture();
  input.properties.containers = Array(50).fill(input.properties.containers[0]);
  assert.equal(resource(input, scope).containers.length, LIMITS.items);
  assert.equal(resource(input, scope).containersTruncated, true);
});

test("stops all new requests when the total time budget is spent", async () => {
  let clock = 0;
  const { report, calls } = await withMock(async (_args, timeout) => {
    assert.equal(timeout, LIMITS.requestMs);
    clock = LIMITS.totalMs + 1;
    return { error: "request-timeout" };
  }, { now: () => clock });
  assert.equal(calls.length, 1);
  assert.equal(report.errors[1].reason, "collection-budget-exhausted");
});

test("invalid Azure context cannot block Radius logs or cause an unscoped Azure read", async () => {
  for (const context of [{ group: "group' or true" }, { subscription: "not-a-subscription" },
    { group: "", subscription: "" }]) {
    const { report, calls } = await withMock(() => assert.fail("must not call Azure"), context);
    assert.equal(calls.length, 0);
    assert.equal(report.radiusLogs.length, 1);
    assert.equal(report.errors[0].reason, "invalid-or-missing-azure-context");
  }
});

test("every resource type and non-Azure platform gets Radius logs without Azure credentials", async () => {
  for (const platform of ["kubernetes", "aws", ""]) {
    for (const resourceType of ["Radius.Data/widgets", "Radius.Security/secrets", "workflow"]) {
      const { report, calls } = await withMock(() => assert.fail("must not call Azure"), {
        subscription: "", group: "", platform, resourceType,
      });
      assert.equal(calls.length, 0);
      assert.equal(report.radiusLogs.length, 1);
      assert.equal(report.scope, null);
      assert.equal(report.errors.length, 0);
    }
  }
});

test("Azure log and inventory collection has no resource-type allowlist", async () => {
  for (const resourceType of ["Radius.Compute/containers", "Radius.Data/futureType", "workflow"]) {
    const { report, calls } = await withMock(async () => ({ value: { value: [] } }), { resourceType });
    assert.equal(report.radiusLogs.length, 1);
    assert.equal(calls.length, 12);
    assert.ok(report.collections.some((item) => item.operation === "resource-inventory"));
    assert.equal(report.errors.length, 0);
  }
});

test("older base workflows can use the selected Azure account without listing other subscriptions", async () => {
  const { report, calls } = await withMock(async (args, timeout) => {
    assert.equal(timeout, LIMITS.requestMs);
    if (args[0] === "account") {
      assert.deepEqual(args, ["account", "show", "--query", "id", "--only-show-errors", "--output", "json"]);
      return { value: subscription };
    }
    assert.ok(args[4].includes(`/subscriptions/${subscription}/`));
    return { value: { value: [] } };
  }, { subscription: "" });
  assert.equal(calls.length, 13);
  assert.equal(report.scope, scope);
  assert.equal(report.errors.length, 0);
});

test("account lookup failure cannot fall back to an unscoped resource request", async () => {
  for (const response of [{ error: "request-timeout" }, { error: "azure-cli-failed", exitCode: 3 },
    { value: { id: subscription, credentials: secret } }, { value: secret }]) {
    let calls = 0;
    const { report } = await withMock(async () => { calls++; return response; }, { subscription: "" });
    assert.equal(calls, 1);
    assert.equal(report.radiusLogs.length, 1);
    assert.equal(report.errors[0].reason, "azure-subscription-context-unavailable");
  }
});

test("account lookup consumes the same collection time budget", async () => {
  let clock = 0;
  const { report, calls } = await withMock(async () => {
    clock = LIMITS.totalMs + 1;
    return { value: subscription };
  }, { subscription: "", now: () => clock });
  assert.equal(calls.length, 1);
  assert.ok(report.errors.every((e) => e.reason === "collection-budget-exhausted"));
});

test("real CLI runner handles success, API failure, missing CLI and malformed JSON without stderr leakage", async () => {
  const execute = (script) => runAz([], 2000, process.execPath, ["-e", script]);
  assert.deepEqual(await execute('console.log(JSON.stringify({value:[]}))'), { value: { value: [] } });
  assert.deepEqual(await execute(`console.error("${secret}"); process.exit(3)`), { error: "azure-cli-failed", exitCode: 3 });
  assert.deepEqual(await execute(`console.log("${secret}")`), { error: "invalid-json" });
  assert.deepEqual(await runAz([], 2000, "rtc-missing-azure-cli"), { error: "cli-unavailable" });
});

test("real CLI runner enforces timeout and response byte limit", async () => {
  const start = Date.now();
  assert.deepEqual(await runAz([], 100, process.execPath, ["-e", "setInterval(() => {}, 1000)"]), { error: "request-timeout" });
  assert.ok(Date.now() - start < 5000);
  assert.deepEqual(await runAz([], 2000, process.execPath, ["-e", `process.stdout.write("x".repeat(${LIMITS.bytes + 1}))`]),
    { error: "response-size-limit" });
});
