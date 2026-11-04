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
const { collect, runAz, resource, activity, LIMITS } = require("../collect-azure-test-diagnostics.js");

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
  assert.equal(calls.length, 9);
  for (const args of calls) {
    assert.deepEqual(args.slice(0, 3), ["rest", "--method", "get"]);
    const url = new URL(args[4]);
    assert.equal(url.origin, "https://management.azure.com");
    if (url.pathname.endsWith("/management/values")) {
      assert.equal(url.searchParams.get("$filter"), `eventTimestamp ge '${started}' and resourceGroupName eq '${group}'`);
      assert.equal(url.searchParams.get("$top"), "20");
    } else {
      assert.ok(url.pathname.startsWith(`${scope}/providers/`));
    }
  }
  assert.equal(report.resources.find((r) => r.id.endsWith("/ng")).provisioningState, "Failed");
  assert.equal(report.resources.find((r) => r.id.endsWith("/vnet")).subnets[0].provisioningState, "Succeeded");
  assert.equal(report.resources.at(-1).containers[0].image, image);
  assert.equal(report.resources.at(-1).containers[0].instanceView.events[0].count, 2);
  assert.equal(report.activity[0].serviceRequestId, subscription);
  assert.equal(report.errors.length, 0);
  assert.ok(snapshots.length > calls.length, "partial evidence must be saved before later calls");
  assert.ok(snapshots.every((s) => !s.includes(secret)));
});

test("allowlists typed leaves; never copies nested objects, free text or credential-bearing image URLs", () => {
  const input = fixture();
  input.name = { secret };
  input.properties.provisioningState = { secret };
  input.properties.containers[0].properties.image = `https://user:${secret}@host/image?token=${secret}`;
  input.properties.instanceView.events[0].name = { secret };
  const safe = resource(input, scope);
  assert.equal(safe.name, null);
  assert.equal(safe.provisioningState, null);
  assert.equal(safe.containers[0].image, null);
  assert.ok(!JSON.stringify(safe).includes(secret));
  assert.ok(!JSON.stringify(activity({ properties: { serviceRequestId: secret }, status: { value: { secret } } }, scope)).includes(secret));
  assert.equal(resource(null, scope).instanceView.available, false);
});

test("records denied/unsupported calls without copying CLI errors and continues", async () => {
  const { report, calls } = await withMock(async () => ({ error: "azure-cli-failed", exitCode: 3 }));
  assert.equal(calls.length, 8);
  assert.equal(report.errors.length, 8);
  assert.deepEqual(report.errors[0], { operation: "list:Microsoft.ContainerInstance/ngroups", reason: "azure-cli-failed", exitCode: 3 });
});

test("records missing data and invalid API shapes explicitly", async () => {
  const empty = await withMock(async () => ({ value: { value: [] } }));
  assert.equal(empty.report.collections.length, 8);
  assert.ok(empty.report.collections.every((c) => c.returned === 0));
  assert.match(empty.report.providerLimitations, /no NGroups child-list/);
  const bad = await withMock(async () => ({ value: { value: { secret } } }));
  assert.equal(bad.report.errors.length, 8);
  assert.ok(bad.report.errors.every((e) => e.reason === "invalid-list-shape"));
  for (const value of [null, false, [], secret]) {
    const malformed = await withMock(async () => ({ value }));
    assert.equal(malformed.report.errors.length, 8);
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
  assert.equal(calls.length, 8);
  assert.equal(report.truncations.length, 8);
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
  assert.equal(calls.length, LIMITS.requests);
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

test("rejects invalid context before calling Azure", async () => {
  await assert.rejects(withMock(() => assert.fail("must not call"), { group: "group' or true" }));
  await assert.rejects(withMock(() => assert.fail("must not call"), { subscription: "not-a-subscription" }));
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
  assert.equal(calls.length, 9);
  assert.equal(report.scope, scope);
  assert.equal(report.errors.length, 0);
});

test("account lookup failure cannot fall back to an unscoped resource request", async () => {
  for (const response of [{ error: "request-timeout" }, { error: "azure-cli-failed", exitCode: 3 },
    { value: { id: subscription, credentials: secret } }, { value: secret }]) {
    let calls = 0;
    await assert.rejects(withMock(async () => { calls++; return response; }, { subscription: "" }));
    assert.equal(calls, 1);
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
