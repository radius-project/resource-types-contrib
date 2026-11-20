// Copyright 2026 The Radius Authors.
// Licensed under the Apache License, Version 2.0.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin',
  process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const types = {
  stateStores: 'state',
  pubSubBrokers: 'pubsub',
  configurationStores: 'configuration',
  secretStores: 'secretstores',
};
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 180000, ...options });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};
const context = (type, properties) => ({
  application: null,
  environment: { name: 'fixture' },
  runtime: { kubernetes: { namespace: 'fixture' } },
  resource: {
    id: `/planes/radius/local/resourceGroups/fixture/providers/Radius.Dapr/${type}/component`,
    name: 'component',
    type: `Radius.Dapr/${type}`,
    properties: { environment: 'fixture', ...properties },
  },
});
const cases = [
  { name: 'resource_scopes', properties: { scopes: ['backend'] }, expected: ['backend'] },
  { name: 'valid_id_boundaries', properties: { scopes: ['a', 'a'.repeat(63)] }, expected: ['a', 'a'.repeat(63)] },
  { name: 'platform_only', properties: {}, allowed: ['backend', 'worker'], expected: ['backend', 'worker'] },
  { name: 'narrow_platform', properties: { scopes: ['worker'] }, allowed: ['backend', 'worker'], expected: ['worker'] },
  { name: 'framework_fields', properties: { scopes: ['backend'], connections: {}, codeReference: 'fixture', recipe: {}, status: {} }, expected: ['backend'] },
  { name: 'metadata', properties: { scopes: ['backend'], metadata: { plain: { value: '' }, password: { secretKeyRef: { name: 'creds', key: 'password' } } } }, expected: ['backend'] },
  { name: 'omitted_access', properties: {}, error: /Set nonempty scopes/ },
  { name: 'empty_resource', properties: { scopes: [] }, allowed: ['backend'], error: /Set nonempty scopes/ },
  { name: 'broader_resource', properties: { scopes: ['backend', 'outsider'] }, allowed: ['backend'], error: /subset of platform/ },
  { name: 'duplicate_resource', properties: { scopes: ['backend', 'backend'] }, error: /duplicate IDs/ },
  ...['', ' ', '-app', 'app-', 'App', 'a.b', 'a'.repeat(64)].map((id, i) =>
    ({ name: `invalid_id_${i}`, properties: { scopes: [id] }, error: /1 to 63/ })),
  { name: 'duplicate_platform', properties: { scopes: ['backend'] }, allowed: ['backend', 'backend'], error: /duplicate IDs|unique IDs/, variableError: true },
  { name: 'invalid_platform', properties: { scopes: ['backend'] }, allowed: ['bad id'], error: /1 to 63/, variableError: true },
  { name: 'empty_metadata', properties: { scopes: ['backend'], metadata: { password: {} } }, error: /exactly one/ },
  { name: 'both_metadata', properties: { scopes: ['backend'], metadata: { password: { value: 'fixture-only', secretKeyRef: { name: 'creds', key: 'password' } } } }, error: /exactly one/ },
  { name: 'unknown_metadata', properties: { scopes: ['backend'], metadata: { password: { typo: 'fixture-only' } } }, error: /exactly one/ },
  { name: 'blank_secret_name', properties: { scopes: ['backend'], metadata: { password: { secretKeyRef: { name: ' ', key: 'password' } } } }, error: /nonempty name and key/ },
  { name: 'blank_secret_key', properties: { scopes: ['backend'], metadata: { password: { secretKeyRef: { name: 'creds', key: ' ' } } } }, error: /nonempty name and key/ },
  { name: 'missing_secret_key', properties: { scopes: ['backend'], metadata: { password: { secretKeyRef: { name: 'creds' } } } }, error: /nonempty name and key/ },
  { name: 'unknown_secret_field', properties: { scopes: ['backend'], metadata: { password: { secretKeyRef: { name: 'creds', key: 'password', typo: 'fixture-only' } } } }, error: /nonempty name and key/ },
  { name: 'unknown_property', properties: { scopes: ['backend'], scope: ['outsider'] }, error: /Unsupported resource property/ },
  { name: 'wrong_family', properties: { scopes: ['backend'], componentType: 'bindings.http' }, error: /componentType must name/ },
  { name: 'empty_component_type', properties: { scopes: ['backend'], componentType: '' }, error: /componentType must name/ },
  { name: 'blank_version', properties: { scopes: ['backend'], version: ' ' }, error: /version must be nonempty/ },
  { name: 'version_whitespace', properties: { scopes: ['backend'], version: 'v 1' }, error: /version must be nonempty/ },
];

for (const [type, family] of Object.entries(types)) {
  const recipePath = path.join(root, 'Dapr', type, 'recipes/kubernetes');
  const typeCases = [
    ...cases,
    { name: 'first_apply', properties: { scopes: ['backend'] }, expected: ['backend'], command: 'apply' },
    { name: 'reapply', properties: { scopes: ['backend'] }, expected: ['backend'], command: 'apply' },
    { name: 'component_type_whitespace', properties: { scopes: ['backend'], componentType: `${family}.custom type` }, error: /componentType must name/ },
    { name: 'custom', properties: { scopes: ['backend'], componentType: `${family}.custom`, metadata: { endpoint: { value: 'external.fixture' } } }, expected: ['backend'], custom: true },
    ...(type === 'secretStores' ? [
      { name: 'unsupported_auth', properties: { scopes: ['backend'], auth: { secretStore: 'secrets' } }, error: /Unsupported resource property/ },
    ] : [
      { name: 'auth', properties: { scopes: ['backend'], auth: { secretStore: 'secrets' } }, expected: ['backend'], auth: true },
      { name: 'unknown_auth', properties: { scopes: ['backend'], auth: { typo: 'secrets' } }, error: /auth supports only/ },
      { name: 'empty_auth', properties: { scopes: ['backend'], auth: { secretStore: '' } }, error: /auth supports only/ },
    ]),
  ];

  test(`Bicep ${type}: access, malformed inputs, outputs, and stable identities`, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), `rtc-dapr-${type}-`));
    try {
      fs.copyFileSync(path.join(recipePath, 'bicep', `kubernetes-dapr-${type.toLowerCase()}.bicep`),
        path.join(dir, 'recipe.bicep'));
      run(bicep, ['build', path.join(dir, 'recipe.bicep'), '--outfile', path.join(dir, 'recipe.json')]);
      const template = JSON.parse(fs.readFileSync(path.join(dir, 'recipe.json'), 'utf8'));
      assert.deepEqual(Object.keys(template.outputs.result.value.values), ['componentName', 'version']);
      // Every created resource must evaluate the guard, including the default Redis.
      for (const resource of Object.values(template.resources)) {
        assert.equal(resource.properties.metadata.labels, "[variables('labels')]");
      }
      assert.equal(template.variables.labels['radapp.io/resource'], "[variables('resourceName')]");
      assert.match(template.variables.resourceName, /fail\(/);
      const snapshot = entry => {
        const json = JSON.stringify(context(type, entry.properties)).replaceAll("'", "\\'");
        fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './recipe.bicep'
param context = json('${json}')
param daprAllowedAppIds = json('${JSON.stringify(entry.allowed || [])}')
`);
        const result = spawnSync(bicep, ['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite'],
          { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 30000 });
        assert.ifError(result.error);
        if (entry.error) {
          assert.notEqual(result.status, 0, entry.name);
          assert.match(`${result.stdout}\n${result.stderr}`, entry.error, entry.name);
          assert.ok(!`${result.stdout}\n${result.stderr}`.includes('fixture-only'), 'Do not log metadata values');
          return;
        }
        assert.equal(result.status, 0, `${entry.name}\n${result.stdout}\n${result.stderr}`);
        return JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
      };
      for (const entry of typeCases.filter(entry => !entry.command)) {
        const resources = snapshot(entry);
        if (!resources) continue;
        const component = resources.filter(resource => resource.type.startsWith('dapr.io/Component'));
        assert.equal(component.length, 1, `${entry.name}: ${JSON.stringify(resources)}`);
        assert.deepEqual(component[0].properties.scopes, entry.expected, entry.name);
        assert.equal(component[0].properties.spec.scopes, undefined);
        assert.equal(component[0].properties.metadata.name, 'component');
        assert.deepEqual(component[0].properties.auth, entry.auth ? { secretStore: 'secrets' } : undefined);
        assert.equal(resources.length, entry.custom || type === 'secretStores' ? 1 : 3);
      }
      assert.deepEqual(snapshot(typeCases[0]), snapshot(typeCases[0]),
        'Repeated unchanged input must predict the same components and backing resources');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    }
  });

  test(`Terraform ${type}: access and malformed inputs with a mock provider`, t => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), `rtc-dapr-tf-${type}-`));
    t.after(() => fs.promises.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
    for (const file of ['main.tf', 'var.tf']) {
      fs.copyFileSync(path.join(recipePath, 'terraform', file), path.join(dir, file));
    }
    fs.mkdirSync(path.join(dir, 'tests'));
    const testCase = entry => `run "${entry.name}" {
  command = ${entry.command || 'plan'}
  variables {
    context = jsondecode(${JSON.stringify(JSON.stringify(context(type, entry.properties)))})
    daprAllowedAppIds = ${JSON.stringify(entry.allowed || [])}
  }
  ${entry.error ? `expect_failures = [${entry.variableError ? 'var.daprAllowedAppIds' : 'terraform_data.validate_inputs'}]` : `
  assert {
    condition = kubernetes_manifest.dapr_component.manifest.scopes == tolist(${JSON.stringify(entry.expected)})
    error_message = "The Component must use the effective root scopes."
  }
  assert {
    condition = length(output.result.resources) == ${entry.custom || type === 'secretStores' ? 1 : 3} && !contains(keys(output.result.values), "componentType")
    error_message = "Track only managed resources; outputs must not switch default provisioning mode."
  }
  assert {
    condition = kubernetes_manifest.dapr_component.manifest.metadata.name == "component"
    error_message = "Preserve component identity and consumer bindings."
  }`}
}`;
    fs.writeFileSync(path.join(dir, 'tests', 'inputs.tftest.hcl'),
      `mock_provider "kubernetes" {}\n${typeCases.map(testCase).join('\n')}\n`);
    run('terraform', [`-chdir=${dir}`, 'init', '-backend=false', '-input=false', '-no-color']);
    run('terraform', [`-chdir=${dir}`, 'validate', '-no-color']);
    run('terraform', [`-chdir=${dir}`, 'test', '-no-color']);
  });
}
