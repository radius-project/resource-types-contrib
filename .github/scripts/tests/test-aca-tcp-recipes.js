const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const source = path.join(root, 'Compute/containers/recipes/azure-aca');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const targetId = '/planes/radius/local/resourceGroups/test/providers/Radius.Compute/containers/workload';
const run = (command, args, options = {}) => spawnSync(command, args, {
  encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, ...options,
});
function succeeds(result) {
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
}
function route(port, name = 'cache', id = `route-${port}`) {
  return {
    id: `/planes/radius/local/resourceGroups/test/providers/Radius.Compute/routes/${id}`,
    type: 'Radius.Compute/routes', apiVersion: '2025-08-01-preview', revision: `revision-${id}`,
    properties: {
      kind: 'TCP',
      rules: [{ matches: [], destinationContainer: { resourceId: targetId, containerName: name, containerPort: port } }],
    },
  };
}
function context() {
  return {
    azure: { resourceGroup: { name: 'test' } },
    resource: {
      id: targetId, name: 'workload', type: 'Radius.Compute/containers',
      properties: {
        replicas: 2,
        connections: { cache: { source: '/cache' }, ignored: { source: '/ignored', disableDefaultEnvVars: true } },
        containers: {
          cache: {
            image: 'redis:7-alpine', command: ['redis-server'], args: ['--port', '6379'],
            ports: { redis: { containerPort: 6379 } },
            env: { CONNECTION_CACHE_HOST: { value: 'explicit' } },
            resources: { requests: { cpu: '0.5', memoryInMib: 1024 } },
          },
          worker: { image: 'nginx:alpine', ports: { worker: { containerPort: 9000 } } },
          setup: { image: 'busybox:1.37', initContainer: true, command: ['sh', '-c'], args: ['echo ready'] },
        },
      },
      connections: {
        cache: { properties: { host: 'generated', port: 6379, status: 'private', recipe: 'internal', resourceProvisioning: 'internal' } },
        ignored: { properties: { host: 'do-not-inject' } },
      },
      incomingReferences: [route(9000, 'worker'), route(6379)],
    },
  };
}
const cases = [];
function valid(name, mutate = () => {}, parameters = {}) {
  const input = context();
  mutate(input);
  cases.push({ name, input, parameters, valid: true });
}
function invalid(name, mutate, parameters = {}) {
  const input = context();
  mutate(input);
  cases.push({ name, input, parameters, valid: false });
}
valid('multiple_routes_and_all_rules', input => {
  input.resource.incomingReferences[1].properties.rules.push(structuredClone(input.resource.incomingReferences[1].properties.rules[0]));
});
valid('six_ports', input => {
  input.resource.properties.containers = {
    cache: { image: 'fixture', ports: Object.fromEntries([1000, 2000, 3000, 4000, 5000, 6000].map(port => [`p${port}`, { containerPort: port }])) },
  };
  input.resource.incomingReferences = [1000, 2000, 3000, 4000, 5000, 6000].map(port => route(port));
});
valid('last_route_deleted', input => { input.resource.incomingReferences = []; }, { containerAppsExposedPorts: { 6379: 16379 } });
valid('ordinary_target_without_routes', input => { delete input.resource.incomingReferences; });
valid('exposed_port_mapping', () => {}, { containerAppsExposedPorts: { 6379: 16379, 9000: 19000 } });
valid('external_target_port80_is_allowed', input => {
  input.resource.properties.containers.cache.ports.web = { containerPort: 80 };
  input.resource.incomingReferences[1].properties.rules[0].destinationContainer.containerPort = 80;
}, { containerAppsExternalIngress: true, containerAppsExposedPorts: { 80: 8080 } });
valid('aliases_of_same_workload_port', input => {
  input.resource.properties.containers.cache.ports.alias = { containerPort: 6379 };
});
valid('several_routes_share_endpoint', input => {
  input.resource.incomingReferences.push(route(6379, 'cache', 'cache-alias'));
});
valid('equivalent_cpu_decimal_strings', input => {
  input.resource.properties.containers.cache.resources.limits = { cpu: '0.50' };
});
valid('secret_connection_disabled', input => {
  input.resource.connections.ignored = { type: 'Radius.Security/secrets', secrets: { password: { source: 'secret', key: 'key' } } };
});
for (const protocol of ['HTTP', 'TLS', 'UDP']) {
  invalid(`reject_${protocol.toLowerCase()}`, input => { input.resource.incomingReferences[0].properties.kind = protocol; });
}
invalid('missing_kind_is_http', input => { delete input.resource.incomingReferences[0].properties.kind; });
invalid('second_rule_has_match', input => {
  const rule = structuredClone(input.resource.incomingReferences[0].properties.rules[0]);
  rule.matches = [{ httpPath: '/' }];
  input.resource.incomingReferences[0].properties.rules.push(rule);
});
invalid('second_rule_has_other_target', input => {
  const rule = structuredClone(input.resource.incomingReferences[0].properties.rules[0]);
  rule.destinationContainer.resourceId = `${targetId}-other`;
  input.resource.incomingReferences[0].properties.rules.push(rule);
});
invalid('one_route_multiple_endpoints', input => {
  input.resource.incomingReferences[0].properties.rules.push(structuredClone(input.resource.incomingReferences[1].properties.rules[0]));
});
invalid('missing_workload', input => { input.resource.incomingReferences[0].properties.rules[0].destinationContainer.containerName = 'missing'; });
invalid('undeclared_port', input => { input.resource.incomingReferences[0].properties.rules[0].destinationContainer.containerPort = 9001; });
invalid('init_container_destination', input => {
  input.resource.properties.containers.setup.ports = { init: { containerPort: 9000 } };
  input.resource.incomingReferences[0].properties.rules[0].destinationContainer.containerName = 'setup';
});
invalid('hostname_condition', input => { input.resource.incomingReferences[0].properties.hostnames = ['example.test']; });
invalid('empty_rules', input => { input.resource.incomingReferences[0].properties.rules = []; });
invalid('foreign_delegate', input => { input.resource.incomingReferences[0].type = 'Radius.Other/routes'; });
invalid('shared_workload_port', input => { input.resource.properties.containers.worker.ports.worker.containerPort = 6379; });
invalid('normalized_name_collision', input => { input.resource.properties.containers.CACHE = structuredClone(input.resource.properties.containers.cache); });
invalid('seventh_port', input => {
  input.resource.properties.containers = { cache: { image: 'fixture', ports: Object.fromEntries([1000, 2000, 3000, 4000, 5000, 6000, 7000].map(port => [`p${port}`, { containerPort: port }])) } };
  input.resource.incomingReferences = [1000, 2000, 3000, 4000, 5000, 6000, 7000].map(port => route(port));
});
invalid('duplicate_exposed_port', () => {}, { containerAppsExposedPorts: { 6379: 10000, 9000: 10000 } });
invalid('reserved_exposed_port', () => {}, { containerAppsExposedPorts: { 6379: 36985 } });
invalid('external_reserved_port', () => {}, { containerAppsExternalIngress: true, containerAppsExposedPorts: { 6379: 443 } });
invalid('fractional_exposed_port', () => {}, { containerAppsExposedPorts: { 6379: 16379.5 } });
invalid('secret_env_reference', input => { input.resource.properties.containers.cache.env.PASSWORD = { valueFrom: { secretKeyRef: { secretName: 'secret', key: 'password' } } }; });
invalid('active_secret_connection', input => { input.resource.connections.cache.secrets = { password: { source: 'secret', key: 'password' } }; });
invalid('unsupported_working_directory', input => { input.resource.properties.containers.cache.workingDir = '/data'; });
invalid('unequal_resource_limits', input => { input.resource.properties.containers.cache.resources.limits = { cpu: '1' }; });
invalid('unsupported_autoscaling', input => { input.resource.properties.autoScaling = { metrics: [] }; });
invalid('memory_requires_more_than_two_decimals', input => { input.resource.properties.containers.cache.resources.requests.memoryInMib = 128; });

function literal(value) {
  if (value === null) return 'null';
  if (typeof value === 'string') return `'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'`;
  if (Array.isArray(value)) return `[${value.map(literal).join(', ')}]`;
  if (typeof value === 'object') return `{ ${Object.entries(value).map(([key, item]) => `${/^[A-Za-z_]\w*$/.test(key) ? key : literal(key)}: ${literal(item)}`).join(', ')} }`;
  if (typeof value === 'number' && !Number.isInteger(value)) return `json('${value}')`;
  return String(value);
}

test('Bicep snapshots process every route and remove only contributed ingress', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-aca-bicep-'));
  try {
    fs.writeFileSync(path.join(dir, 'recipe.bicep'), fs.readFileSync(path.join(source, 'bicep/azure-aca-containers.bicep'), 'utf8').replace(/^@secure\(\)\r?\n/m, ''));
    succeeds(run(bicep, ['build', path.join(dir, 'recipe.bicep'), '--outfile', path.join(dir, 'recipe.json')]));
    let appName;
    for (const fixture of cases) {
      fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './recipe.bicep'
param context = ${literal(fixture.input)}
param containerAppsEnvironmentName = 'existing'
param containerAppsLocation = 'westus3'
${Object.entries(fixture.parameters).map(([key, value]) => `param ${key} = ${literal(value)}`).join('\n')}
`);
      const result = run(bicep, ['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite',
        '--subscription-id', '00000000-0000-0000-0000-000000000000', '--resource-group', 'test', '--location', 'westus3']);
      if (!fixture.valid) {
        assert.notEqual(result.status, 0, `${fixture.name} unexpectedly succeeded`);
        const expectedError = fixture.name === 'fractional_exposed_port'
          ? /function 'int'.*provided value is of type 'Float'/i
          : /ACA TCP recipe/;
        assert.match(`${result.stdout}\n${result.stderr}`, expectedError, fixture.name);
        continue;
      }
      succeeds(result);
      const snapshot = JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8'));
      const app = snapshot.predictedResources.find(resource => resource.type === 'Microsoft.App/containerApps');
      assert.equal(snapshot.predictedResources.length, 1);
      appName ??= app.name;
      assert.equal(app.name, appName, 'route changes must preserve target identity');
      assert.equal(app.properties.template.scale.minReplicas, 2);
      assert.equal(app.properties.template.scale.maxReplicas, 2);
      if (fixture.name !== 'six_ports') {
        const cache = app.properties.template.containers.find(container => container.name === 'cache');
        assert.equal(cache.image, 'redis:7-alpine');
        assert.deepEqual(cache.args, ['--port', '6379']);
        assert.equal(cache.resources.cpu, 0.5);
        assert.equal(Number.parseFloat(cache.resources.memory), 1);
        assert.match(cache.resources.memory, /^\d+(?:\.\d{1,2})?Gi$/, 'ACA accepts no more than two decimal places');
        assert.deepEqual(cache.env, [
          { name: 'CONNECTION_CACHE_HOST', value: 'explicit' },
          { name: 'CONNECTION_CACHE_PORT', value: '6379' },
        ]);
        assert.equal(app.properties.template.initContainers[0].name, 'setup');
      }
      if (fixture.name === 'last_route_deleted' || fixture.name === 'ordinary_target_without_routes') {
        assert.equal(app.properties.configuration.ingress, null);
      } else {
        const ingress = app.properties.configuration.ingress;
        const ports = [ingress.targetPort, ...ingress.additionalPortMappings.map(mapping => mapping.targetPort)];
        const expectedPorts = [...new Set(fixture.input.resource.incomingReferences.flatMap(route => route.properties.rules.map(rule => rule.destinationContainer.containerPort)))].sort((left, right) => left - right);
        assert.deepEqual(ports, expectedPorts);
        assert.equal(ingress.exposedPort, fixture.parameters.containerAppsExposedPorts?.[ports[0]] ?? ports[0]);
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Terraform mocked plans enforce the same rules and return exact delegate revisions', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-aca-terraform-'));
  try {
    for (const name of ['main.tf', 'var.tf']) fs.copyFileSync(path.join(source, 'terraform', name), path.join(dir, name));
    const hcl = `mock_provider "azurerm" {
  mock_data "azurerm_container_app_environment" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/managedEnvironments/existing", location = "westus3" }
  }
  mock_data "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test" }
  }
}
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/containerApps/fixture"
      output = { properties = { configuration = { ingress = { fqdn = "fixture.azurecontainerapps.io" } } } }
    }
    override_during = plan
  }
}
${cases.map(fixture => `run "${fixture.name}" {
  command = plan
  variables {
    context = jsondecode(${JSON.stringify(JSON.stringify(fixture.input))})
    containerAppsEnvironmentName = "existing"
    ${Object.entries(fixture.parameters).map(([key, value]) => `${key} = jsondecode(${JSON.stringify(JSON.stringify(value))})`).join('\n')}
  }
  ${fixture.valid ? `assert {
    condition = length(output.result.delegatedOutputs) == ${fixture.input.resource.incomingReferences?.length ?? 0}
    error_message = "Must return one result per incoming member."
  }
  ${fixture.input.resource.incomingReferences?.length ? `assert {
    condition = alltrue([for index, member in output.result.delegatedOutputs : member.id == var.context.resource.incomingReferences[index].id && member.revision == var.context.resource.incomingReferences[index].revision && member.values.listener.protocol == "TCP" && member.values.listener.port == lookup(var.containerAppsExposedPorts, tostring(min([for rule in var.context.resource.incomingReferences[index].properties.rules : rule.destinationContainer.containerPort]...)), min([for rule in var.context.resource.incomingReferences[index].properties.rules : rule.destinationContainer.containerPort]...)) && member.values.listener.hostname == (var.containerAppsExternalIngress ? "fixture.azurecontainerapps.io" : azapi_resource.workload.name)])
    error_message = "Preserve delegate IDs/revisions and return the actual exposed listener port/host."
  }` : `assert {
    condition = azapi_resource.workload.body.properties.configuration.ingress == null && length(output.result.values.hosts) == 0
    error_message = "Empty contributions must clear ingress/hosts without deleting workloads."
  }`}
  assert {
    condition = length(azapi_resource.workload.body.properties.template.containers) == ${Object.values(fixture.input.resource.properties.containers).filter(container => !container.initContainer).length} && azapi_resource.workload.body.properties.template.scale.minReplicas == 2
    error_message = "Preserve the target workload and replica count."
  }
  assert {
    condition = length(output.result.resources) == 1 && output.result.resources[0] == azapi_resource.workload.id
    error_message = "Only the target must return the native Container App inventory."
  }` : 'expect_failures = [azapi_resource.workload]'}
}`).join('\n')}
`;
    fs.writeFileSync(path.join(dir, 'recipe.tftest.hcl'), hcl);
    succeeds(run('terraform', [`-chdir=${dir}`, 'init', '-backend=false', '-input=false', '-no-color']));
    succeeds(run('terraform', [`-chdir=${dir}`, 'test', '-no-color']));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
