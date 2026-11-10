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
const { spawnSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { homedir } = require("node:os");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../../..");
const recipePath = path.join(root, "AI/models/recipes/azure/bicep/azure-openai.bicep");
const bicep = process.env.BICEP ?? path.join(homedir(), ".rad/bin", process.platform === "win32" ? "bicep.exe" : "bicep");
const compiled = spawnSync(bicep, ["build", "--stdout", recipePath], { encoding: "utf8" });
assert.equal(compiled.status, 0, compiled.error?.message ?? compiled.stderr);
const template = JSON.parse(compiled.stdout);
const account = template.resources.account;
const model = template.resources.modelDeployment;

test("model provisioning waits for the account module and both key outputs", () => {
  assert.equal(account.type, "Microsoft.Resources/deployments");
  assert.deepEqual(account.properties.parameters.deployments.value, [],
    "putting models back inside the account module allows its listKeys outputs to race them");
  assert.equal(account.properties.parameters.disableLocalAuth.value, false);
  assert.deepEqual(model.dependsOn, ["account"],
    "the child PUT must wait for module completion, not just account creation");
  assert.equal(model.type, "Microsoft.CognitiveServices/accounts/deployments");

  const outputs = account.properties.template.outputs;
  for (const key of ["primaryKey", "secondaryKey"]) {
    assert.equal(outputs[key].type.toLowerCase(), "securestring");
    assert.match(outputs[key].value, /listKeys\('cognitiveService', '2025-06-01'\)/);
  }
  const outer = { ...template, resources: { modelDeployment: model } };
  assert.doesNotMatch(JSON.stringify(outer), /listKeys\(/i,
    "the outer recipe must reuse stored outputs, not read account keys during the child PUT");
});

test("account identity and model settings match the previous direct-module recipe", () => {
  const params = account.properties.parameters;
  assert.equal(params.name.value, "[parameters('openAIAccountName')]");
  assert.equal(params.customSubDomainName.value, params.name.value);
  assert.equal(params.kind.value, "OpenAI");
  assert.equal(params.sku.value, "S0");
  assert.equal(params.publicNetworkAccess.value, "Enabled");
  assert.equal(params.enableTelemetry.value, false);
  assert.deepEqual(params.lock.value, { kind: "None" });
  assert.equal(model.apiVersion, "2025-06-01");
  assert.equal(model.name, "[format('{0}/chat', parameters('openAIAccountName'))]");
  assert.deepEqual(model.sku, { name: "GlobalStandard", capacity: 1 });
  assert.deepEqual(model.properties.model, {
    format: "OpenAI",
    name: "[coalesce(tryGet(parameters('context').resource.properties, 'model'), 'gpt-5-mini')]",
    version: "2025-08-07",
  });
  assert.match(readFileSync(recipePath, "utf8"), /account:0\.15\.0'/);
});

test("the result keeps the endpoint, secure API key, and both cleanup resource IDs", () => {
  assert.deepEqual(Object.keys(template.outputs), ["result"]);
  const result = template.outputs.result;
  assert.equal(result.type.toLowerCase(), "secureobject");
  assert.deepEqual(result.value.values, { endpoint: "[reference('account').outputs.endpoint.value]" });
  assert.deepEqual(result.value.secrets, {
    apiKey: `[listOutputsWithSecureValues('account', '${account.apiVersion}').primaryKey]`,
  });
  assert.equal(result.value.resources.length, 2);
  assert.equal(result.value.resources[0], "[reference('account').outputs.resourceId.value]");
  assert.match(result.value.resources[1], /resourceId\('Microsoft\.CognitiveServices\/accounts\/deployments'/);
  assert.match(result.value.resources[1], /parameters\('openAIAccountName'\)/);
});

test("the Azure pack preserves the account name and uses the published recipe result", () => {
  const pack = readFileSync(path.join(root, "recipe-packs/azure-aks/azure-aks.bicep"), "utf8");
  const entry = pack.match(/'Radius\.AI\/models': \{([\s\S]*?)\n      \}/)?.[1];
  assert.ok(entry, "the Azure AKS pack must contain Radius.AI/models");
  assert.match(entry, /source: 'ghcr\.io\/radius-project\/azure-recipes\/models:latest'/);
  assert.match(entry, /openAIAccountName: 'oai-\{\{context\.azure\.resourceNameHash\}\}'/);
  assert.doesNotMatch(entry, /outputs:/, "a direct-module output mapping would bypass result.secrets");

  const publisher = readFileSync(path.join(root, ".github/workflows/publish-bicep-recipes.yaml"), "utf8");
  assert.ok(publisher.includes(
    "REGISTRY=ghcr.io/radius-project/azure-recipes ./.github/scripts/publish-bicep-recipe.sh models AI/models/recipes/azure/bicep/azure-openai.bicep",
  ), "the new source must be published with the other repository recipes");
});
