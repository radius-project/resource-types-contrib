// Copyright 2026 The Radius Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const recipes = path.join(root, 'Data/postgreSqlDatabases/recipes');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, ...options });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};

function fixture(platform, callback) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `rtc-postgresql-${platform}-`));
  try {
    const source = path.join(recipes, platform, 'bicep');
    // Snapshots omit secure inputs. Remove the decorator only in this temporary
    // fixture and use dummy credentials; never modify the production template.
    fs.writeFileSync(path.join(dir, 'recipe.bicep'),
      fs.readFileSync(path.join(source, `${platform}-postgresql.bicep`), 'utf8').replace(/^@secure\(\)\r?\n/m, ''));
    if (platform === 'azure') fs.copyFileSync(path.join(source, 'bicepconfig.json'), path.join(dir, 'bicepconfig.json'));
    run(bicep, ['build', path.join(dir, 'recipe.bicep'), '--outfile', path.join(dir, 'recipe.json')]);
    const template = JSON.parse(fs.readFileSync(path.join(dir, 'recipe.json'), 'utf8'));
    const snapshot = (properties = '', configurations = '[]', name = 'pgsql-fixture', scope = {}) => {
      fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './recipe.bicep'
param context = {
  application: { name: 'fixture' }
  environment: { name: 'fixture' }
  runtime: { kubernetes: { namespace: 'fixture' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/fixture/providers/Radius.Data/postgreSqlDatabases/pgsql-fixture'
    name: 'pgsql-fixture'
    type: 'Radius.Data/postgreSqlDatabases'
    properties: {
      username: 'fixture'
      password: 'fixture-only'
      ${properties}
    }
  }
}
${platform === 'azure' ? `${name === null ? '' : `param postgreSqlServerName = '${name}'`}\nparam postgreSqlServerConfigurations = ${configurations}` : ''}
`);
      run(bicep, ['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite',
        '--subscription-id', scope.subscriptionId ?? '00000000-0000-0000-0000-000000000000',
        '--resource-group', scope.resourceGroup ?? 'fixture', '--location', 'westus3']);
      return JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
    };
    callback({ dir, template, snapshot });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('Azure settings retain the AVM contract and merge operator pins without regard to case', () => {
  fixture('azure', ({ template, snapshot }) => {
    assert.equal(template.languageVersion, '2.0', 'Use symbolic references across Radius and Azure scopes');
    assert.equal(template.resources.server.type, 'Microsoft.Resources/deployments');
    assert.equal(template.resources.server.name, "[parameters('postgreSqlServerName')]");
    assert.deepEqual(Object.keys(template.resources), ['server'], 'Settings must not add an SQL runner');
    assert.deepEqual(template.outputs.result.value.resources, ["[reference('server').outputs.resourceId.value]"]);
    assert.equal(template.outputs.result.value.values.host, "[reference('server').outputs.fqdn.value]");
    assert.equal(template.outputs.result.value.values.port, 5432);
    const hasSetting = (resources, name) => resources.some(r =>
      r.type === 'Microsoft.DBforPostgreSQL/flexibleServers/configurations' && r.name.toLowerCase().endsWith(`/${name}`));
    const setting = (resources, name) => {
      const matches = resources.filter(r =>
        r.type === 'Microsoft.DBforPostgreSQL/flexibleServers/configurations' && r.name.toLowerCase().endsWith(`/${name}`));
      assert.equal(matches.length, 1, `Expected one ${name} configuration`);
      return matches[0].properties.value;
    };
    let resources = snapshot();
    assert.equal(setting(resources, 'require_secure_transport'), 'ON');
    assert.equal(hasSetting(resources, 'azure.extensions'), false);
    const server = resources.find(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers');
    assert.equal(server.name, 'pgsql-fixture');
    assert.deepEqual(server.sku, { name: 'Standard_B1ms', tier: 'Burstable' });
    assert.equal(server.properties.version, '16');
    assert.equal(server.properties.storage.storageSizeGB, 32);
    assert.equal(server.properties.network.publicNetworkAccess, 'Enabled');
    assert.equal(resources.some(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers/databases' &&
      r.name.endsWith('/postgres_db')), true);
    resources = snapshot('extensions: []');
    assert.equal(hasSetting(resources, 'azure.extensions'), false, 'An empty list must not clear an existing allow-list');
    resources = snapshot('extensions: null\nserverSettings: null');
    assert.equal(hasSetting(resources, 'azure.extensions'), false);
    assert.equal(setting(resources, 'require_secure_transport'), 'ON');
    resources = snapshot(`extensions: ['pg_trgm', 'btree_gin']
serverSettings: { log_min_duration_statement: '1000' }
tls: 'optional'
size: 'M'`);
    assert.equal(setting(resources, 'azure.extensions'), 'pg_trgm,btree_gin');
    assert.equal(setting(resources, 'log_min_duration_statement'), '1000');
    assert.equal(setting(resources, 'require_secure_transport'), 'OFF');
    assert.deepEqual(resources.find(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers').sku,
      { name: 'Standard_D2ds_v5', tier: 'GeneralPurpose' });
    for (const casing of [name => name, name => name.toUpperCase(), name => name[0].toUpperCase() + name.slice(1)]) {
      resources = snapshot(`extensions: ['vector']
serverSettings: {
  '${casing('azure.extensions')}': 'unsafe-bypass'
  '${casing('require_secure_transport')}': 'OFF'
  '${casing('port')}': '6000'
}`);
      assert.equal(setting(resources, 'azure.extensions'), 'vector');
      assert.equal(setting(resources, 'require_secure_transport'), 'ON');
      assert.equal(hasSetting(resources, 'port'), false);
      resources = snapshot("extensions: ['pg_trgm', 'btree_gin']", `[
  { name: '${casing('azure.extensions')}', source: 'user-override', value: ' VECTOR, PG_TRGM ' }
]`);
      assert.equal(setting(resources, 'azure.extensions'), 'vector,pg_trgm,btree_gin',
        'Nonempty operator and application lists must merge, with case-insensitive duplicates removed');
      const mergedExtensions = resources.find(r =>
        r.type === 'Microsoft.DBforPostgreSQL/flexibleServers/configurations' &&
        r.name.toLowerCase().endsWith('/azure.extensions'));
      assert.ok(mergedExtensions.name.endsWith(`/${casing('azure.extensions')}`),
        'Preserve the operator setting name');
      assert.equal(mergedExtensions.properties.source, 'user-override');
      resources = snapshot(`extensions: ['vector']
tls: 'optional'
serverSettings: { log_min_duration_statement: '1000' }`, `[
  { name: '${casing('azure.extensions')}', source: 'user-override', value: '' }
  { name: '${casing('require_secure_transport')}', source: 'user-override', value: 'ON' }
  { name: '${casing('log_min_duration_statement')}', source: 'user-override', value: '2000' }
  { name: '${casing('port')}', source: 'user-override', value: '6000' }
]`);
      assert.equal(setting(resources, 'azure.extensions'), '', 'Operators can explicitly clear the allow-list');
      assert.equal(setting(resources, 'require_secure_transport'), 'ON');
      assert.equal(setting(resources, 'log_min_duration_statement'), '2000');
      assert.equal(hasSetting(resources, 'port'), false);
    }
    resources = snapshot("serverSettings: { LOG_MIN_DURATION_STATEMENT: '1000' }",
      "[{ name: 'log_min_duration_statement', source: 'user-override', value: '2000' }]");
    assert.equal(setting(resources, 'log_min_duration_statement'), '2000');
    for (const properties of ['', 'extensions: []']) {
      resources = snapshot(properties, "[{ name: 'azure.extensions', source: 'user-override', value: 'VECTOR' }]");
      assert.equal(setting(resources, 'azure.extensions'), 'VECTOR',
        'An absent application list must leave the operator value unchanged');
    }

    const defaultName = (scope = {}) => snapshot('', '[]', null, scope)
      .find(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers').name;
    const first = defaultName();
    assert.match(first, /^pgsql-[a-z0-9]{13}$/);
    assert.equal(defaultName(), first, 'Repeated deployment in the same scope must keep the name');
    assert.notEqual(defaultName({ resourceGroup: 'other-fixture' }), first,
      'The same Radius resource ID in another Azure resource group needs a distinct name');
    assert.notEqual(defaultName({ subscriptionId: '11111111-1111-1111-1111-111111111111' }), first,
      'The same Radius resource ID in another subscription needs a distinct name');
  });
});

test('Kubernetes settings preserve TLS, fixed ports, and first-initialization extensions', () => {
  fixture('kubernetes', ({ dir, template, snapshot }) => {
    const deployment = template.resources.postgresql;
    const container = deployment.properties.spec.template.spec.containers[0];
    assert.equal(template.variables.port, 5432);
    assert.deepEqual(template.variables.protectedSettings, ['port', 'ssl', 'ssl_cert_file', 'ssl_key_file', 'hba_file']);
    assert.ok(template.variables.serverArgs.includes("toLower(lambdaVariables('setting').key)"));
    assert.equal(container.args, "[concat(createArray('postgres'), variables('serverArgs'))]");
    assert.equal(container.ports[0].containerPort, "[variables('port')]");
    assert.equal(template.resources.svc.properties.spec.ports[0].port, "[variables('port')]");
    assert.equal(template.outputs.result.value.values.port, "[variables('port')]");
    assert.ok(template.resources.initSqlConfigMap.properties.data.includes("'00-extensions.sql'"));
    assert.ok(template.resources.initSqlConfigMap.properties.data.includes("'01-init.sql'"),
      'Preserve the existing Bicep initialization script after extensions');
    assert.ok(template.variables.extensionSql.includes('CREATE EXTENSION IF NOT EXISTS'));
    assert.ok(template.variables.extensionSql.includes("replace(lambdaVariables('name'), '\"', '\"\"')"));
    assert.ok(template.outputs.result.value.resources.includes('ConfigMap'));
    assert.deepEqual(container.command.slice(0, 2), ['/bin/sh', '-ec']);
    const exec = container.command[2].split('\n').find(line => line.startsWith('exec docker-entrypoint.sh'));
    assert.ok(exec.includes('postgres "$@" -c port=5432 -c ssl=on'));
    assert.ok(exec.includes('-c hba_file=/tls-runtime/pg_hba.conf'));
    assert.ok(container.command[2].includes('required) plaintext_auth=reject'));
    assert.ok(container.command[2].includes('optional) plaintext_auth=scram-sha-256'));
    fs.writeFileSync(path.join(dir, 'docker-entrypoint.sh'), '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o755 });
    // Model kubelet's single-pass expansion before the shell receives its argv.
    // See kubernetes/third_party/forked/golang/expansion/expand.go.
    const expandKubernetesArgument = argument => argument.replace(/\$\$|\$\(([^)]*)\)/g,
      (reference, name) => reference === '$$' ? '$' : name === 'POSTGRES_DB' ? 'fixture-db' : reference);
    assert.equal(expandKubernetesArgument('$(POSTGRES_DB)'), 'fixture-db');
    assert.equal(expandKubernetesArgument('$$'), '$');
    assert.equal(expandKubernetesArgument('$$(POSTGRES_DB)'), '$(POSTGRES_DB)');
    for (const { value, podValue } of [
      { value: '$(POSTGRES_DB)', podValue: '$$(POSTGRES_DB)' },
      { value: '$$', podValue: '$$$$' },
      {
        value: 'literal $(POSTGRES_DB) $$ $$(POSTGRES_DB) $value; `not a command`',
        podValue: 'literal $$(POSTGRES_DB) $$$$ $$$$(POSTGRES_DB) $$value; `not a command`',
      },
    ]) {
      const literalResources = snapshot(`serverSettings: { application_name: '${value}' }`);
      const pod = literalResources.find(resource => resource.type === 'apps/Deployment@v1')
        .properties.spec.template.spec.containers[0];
      assert.deepEqual(pod.args, ['postgres', '-c', `application_name=${podValue}`],
        'Pod arguments must escape dollars before Kubernetes expansion');
      const processArgs = pod.args.map(expandKubernetesArgument);
      assert.deepEqual(processArgs, ['postgres', '-c', `application_name=${value}`]);
      const forwarded = run('sh', ['-ec', exec, ...processArgs], {
        env: { ...process.env, POSTGRES_DB: 'fixture-db', PATH: `${dir}${path.delimiter}${process.env.PATH}` },
      }).trim().split('\n');
      assert.deepEqual(forwarded, ['postgres', '-c', `application_name=${value}`, '-c', 'port=5432', '-c', 'ssl=on',
        '-c', 'ssl_cert_file=/tls-runtime/server.crt', '-c', 'ssl_key_file=/tls-runtime/server.key',
        '-c', 'hba_file=/tls-runtime/pg_hba.conf']);
    }
    const resources = snapshot(`extensions: ['pg_trgm']
serverSettings: {
  port: '6000'
  PORT: '6001'
  Port: '6002'
  SSL: 'off'
  ssl: 'off'
  sSl: 'off'
  Ssl_Cert_File: '/bypass.crt'
  SSL_KEY_FILE: '/bypass.key'
  Hba_File: '/bypass.conf'
  application_name: 'fixture'
}`);
    const predictedDeployment = resources.find(resource => resource.type === 'apps/Deployment@v1');
    assert.ok(predictedDeployment, JSON.stringify(resources));
    assert.deepEqual(predictedDeployment.properties.spec.template.spec.containers[0].args,
      ['postgres', '-c', 'application_name=fixture']);
    const configMap = resources.find(resource => resource.type === 'core/ConfigMap@v1');
    assert.deepEqual(configMap.properties.data, { '00-extensions.sql': 'CREATE EXTENSION IF NOT EXISTS "pg_trgm";' });
    const volumes = predictedDeployment.properties.spec.template.spec.volumes;
    assert.equal(volumes.find(volume => volume.name === 'init-sql').configMap.name, configMap.properties.metadata.name);
    for (const properties of ['', 'extensions: []\nserverSettings: {}', 'extensions: null\nserverSettings: null']) {
      const defaults = snapshot(properties);
      assert.equal(defaults.some(resource => resource.type === 'core/ConfigMap@v1'), false);
      const container = defaults.find(resource => resource.type === 'apps/Deployment@v1')
        .properties.spec.template.spec.containers[0];
      assert.deepEqual(container.args, ['postgres']);
    }
  });
});
