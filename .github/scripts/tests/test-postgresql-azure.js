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
const recipe = path.join(root, 'Data/postgreSqlDatabases/recipes/azure/bicep');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');

test('Azure PostgreSQL settings, precedence, and initialization', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-postgresql-azure-'));
  try {
    // Snapshot evaluation hides secure parameters. Use only dummy inputs in a
    // temporary copy without this decorator; never change the shipped recipe.
    fs.writeFileSync(path.join(dir, 'recipe.bicep'),
      fs.readFileSync(path.join(recipe, 'azure-postgresql.bicep'), 'utf8').replace(/^@secure\(\)\r?\n/m, ''));
    fs.copyFileSync(path.join(recipe, 'initialize-database.sh'), path.join(dir, 'initialize-database.sh'));
    fs.copyFileSync(path.join(recipe, 'bicepconfig.json'), path.join(dir, 'bicepconfig.json'));
    const build = spawnSync(bicep, ['build', path.join(dir, 'recipe.bicep'), '--outfile', path.join(dir, 'recipe.json')],
      { encoding: 'utf8' });
    assert.equal(build.status, 0, `${build.error || ''}\n${build.stdout}\n${build.stderr}`);
    const template = JSON.parse(fs.readFileSync(path.join(dir, 'recipe.json'), 'utf8'));
    assert.equal(template.languageVersion, '2.0', 'Use symbolic references across Radius and Azure scopes');
    const deployment = template.resources.server;
    assert.equal(deployment.type, 'Microsoft.Resources/deployments');
    assert.equal(deployment.name, "[parameters('name')]", 'Nested deployments must use the unique server name');
    const deploymentReference = "reference('server')";
    const initialize = template.resources.initialize;
    const host = initialize.properties.environmentVariables.find(v => v.name === 'PGHOST').value;
    assert.equal(host, `[${deploymentReference}.outputs.fqdn.value]`, 'Use the actual AVM hostname');
    assert.deepEqual(initialize.dependsOn, ['server'], 'Wait for all AVM configuration before SQL');
    assert.ok(template.outputs.result.value.resources.includes(`${deploymentReference}.outputs.resourceId.value`),
      'Cleanup must use the actual AVM resource ID');
    assert.equal(template.outputs.result.value.values.host, host, 'Connections must use the same AVM hostname');
    assert.ok(!JSON.stringify({ initialize: initialize.properties, result: template.outputs.result })
      .includes("resourceId('Microsoft.Resources/deployments'"), 'Do not resolve nested deployments in the Azure scope');
    const snapshot = (properties = '', configurations = '[]', serverName = 'pgsql-fixture') => {
      const params = path.join(dir, 'test.bicepparam');
      fs.writeFileSync(params, `using './recipe.bicep'
param name = '${serverName}'
param context = { resource: { properties: {
  username: 'fixture'
  password: 'fixture-only'
  ${properties}
} } }
param configurations = ${configurations}
`);
      const result = spawnSync(bicep, ['snapshot', params, '--mode', 'Overwrite',
        '--subscription-id', '00000000-0000-0000-0000-000000000000',
        '--resource-group', 'fixture', '--location', 'westus3'],
      { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
      assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
      return JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
    };
    const setting = (resources, name) => {
      const matches = resources.filter(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers/configurations' && r.name.endsWith(`/${name}`));
      assert.equal(matches.length, 1, `Expected one ${name} configuration`);
      return matches[0].properties.value;
    };
    let resources = snapshot();
    assert.equal(setting(resources, 'require_secure_transport'), 'ON');
    assert.equal(setting(resources, 'azure.extensions'), '');
    for (const serverName of ['pgsql-first', 'pgsql-second']) {
      const serverResources = snapshot("initSql: 'SELECT 1;'", '[]', serverName);
      assert.equal(serverResources.find(r => r.type === 'Microsoft.DBforPostgreSQL/flexibleServers').name, serverName);
      assert.equal(serverResources.find(r => r.type === 'Microsoft.Resources/deploymentScripts').name, `${serverName}-init`);
    }
    assert.equal(resources.some(r => r.type === 'Microsoft.Resources/deploymentScripts'), false);

    resources = snapshot(`extensions: ['pg_trgm', 'vector']
serverSettings: { log_min_duration_statement: '1000' }
tls: 'optional'
initSql: 'CREATE SCHEMA IF NOT EXISTS app;'`);
    assert.equal(setting(resources, 'azure.extensions'), 'pg_trgm,vector');
    assert.equal(setting(resources, 'log_min_duration_statement'), '1000');
    assert.equal(setting(resources, 'require_secure_transport'), 'OFF');
    const script = resources.find(r => r.type === 'Microsoft.Resources/deploymentScripts');
    assert.ok(script, 'initSql must create a deployment script');
    assert.equal(script.properties.cleanupPreference, 'Always');
    assert.equal(script.properties.environmentVariables.find(v => v.name === 'PGPASSWORD').secureValue, 'fixture-only');
    assert.equal(script.properties.environmentVariables.find(v => v.name === 'INIT_SQL').secureValue, 'CREATE SCHEMA IF NOT EXISTS app;');
    assert.equal(script.properties.environmentVariables.find(v => v.name === 'PGSSLMODE').value, 'require');
    assert.ok(script.properties.scriptContent.includes('--set=ON_ERROR_STOP=1'));

    resources = snapshot(`extensions: ['vector']
serverSettings: {
  log_min_duration_statement: '1000'
  'azure.extensions': 'unsafe-bypass'
  require_secure_transport: 'OFF'
}`, `[
  { name: 'log_min_duration_statement', source: 'user-override', value: '2000' }
  { name: 'require_secure_transport', source: 'user-override', value: 'ON' }
  { name: 'azure.extensions', source: 'user-override', value: 'pg_trgm' }
]`);
    assert.equal(setting(resources, 'log_min_duration_statement'), '2000');
    assert.equal(setting(resources, 'require_secure_transport'), 'ON');
    assert.equal(setting(resources, 'azure.extensions'), 'pg_trgm');

    resources = snapshot(`serverSettings: {
  'azure.extensions': 'unsafe-bypass'
  require_secure_transport: 'OFF'
}`);
    assert.equal(setting(resources, 'require_secure_transport'), 'ON');
    assert.equal(setting(resources, 'azure.extensions'), '');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
