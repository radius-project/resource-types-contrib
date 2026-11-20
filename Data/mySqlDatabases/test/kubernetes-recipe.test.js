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

const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad', 'bin',
  process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const recipe = path.resolve(__dirname, '../recipes/kubernetes/bicep/kubernetes-mysql.bicep');

function run(args) {
  const result = spawnSync(bicep, args, { encoding: 'utf8' });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
}

for (const fixture of [
  { name: 'defaults', properties: '', image: '8.4', tls: 'ON', database: 'mysql_db' },
  { name: 'required', properties: "version: '8.0'\ntls: 'required'", image: '8.0', tls: 'ON', database: 'mysql_db' },
  { name: 'optional', properties: "version: '5.7'\ntls: 'optional'\ndatabase: 'appdb'", image: '5.7', tls: 'OFF', database: 'appdb' },
  { name: 'null', properties: 'version: null\ntls: null\ndatabase: null', image: '8.4', tls: 'ON', database: 'mysql_db' },
]) {
  test(`Kubernetes Bicep MySQL ${fixture.name}: startup, credentials, namespace, and result`, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-mysql-'));
    try {
      fs.copyFileSync(recipe, path.join(dir, 'recipe.bicep'));
      fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './recipe.bicep'
param context = {
  runtime: { kubernetes: { namespace: 'mysql-fixture' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/test/providers/Radius.Data/mySqlDatabases/mysql'
    name: 'mysql'
    type: 'Radius.Data/mySqlDatabases'
    properties: {
      username: 'fixture'
      password: 'fixture-only'
      port: 6000
      ${fixture.properties}
    }
  }
}
`);
      run(['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite',
        '--subscription-id', '00000000-0000-0000-0000-000000000000',
        '--resource-group', 'fixture', '--location', 'westus3']);
      const snapshot = JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8'));
      const resources = snapshot.predictedResources;
      assert.equal(resources.length, 3);
      const deployment = resources.find(r => r.type === 'apps/Deployment@v1');
      const service = resources.find(r => r.type === 'core/Service@v1');
      const secret = resources.find(r => r.type === 'core/Secret@v1');
      const container = deployment.properties.spec.template.spec.containers[0];
      assert.equal(container.image, `mysql:${fixture.image}`);
      assert.deepEqual(container.args, [`--require-secure-transport=${fixture.tls}`]);
      assert.equal(container.command, undefined, 'Keep the image entrypoint for initialization and certificates');
      assert.deepEqual(secret.properties.stringData, { USERNAME: 'fixture', PASSWORD: 'fixture-only' });
      for (const [name, key] of [['MYSQL_USER', 'USERNAME'], ['MYSQL_PASSWORD', 'PASSWORD']]) {
        assert.deepEqual(container.env.find(e => e.name === name), {
          name, valueFrom: { secretKeyRef: { name: 'mysql-credentials', key } },
        });
      }
      assert.equal(container.env.find(e => e.name === 'MYSQL_DATABASE').value, fixture.database);
      assert.equal(container.env.find(e => e.name === 'MYSQL_RANDOM_ROOT_PASSWORD').value, 'yes');
      assert.equal(container.ports[0].containerPort, 3306);
      assert.equal(service.properties.spec.ports[0].port, 3306);
      assert.equal(service.properties.spec.type, 'ClusterIP');
      assert.deepEqual(deployment.properties.spec.selector.matchLabels, service.properties.spec.selector);
      assert.equal(deployment.properties.spec.template.metadata.labels['radapp.io/resource'], 'mysql');
      for (const resource of resources) {
        assert.equal(resource.properties.metadata.namespace, 'mysql-fixture');
        assert.equal(resource.properties.metadata.labels['radapp.io/application'], '');
      }
      assert.deepEqual(snapshot.outputs.result, {
        resources: [
          '/planes/kubernetes/local/namespaces/mysql-fixture/providers/core/Secret/mysql-credentials',
          '/planes/kubernetes/local/namespaces/mysql-fixture/providers/core/Service/mysql',
          '/planes/kubernetes/local/namespaces/mysql-fixture/providers/apps/Deployment/mysql',
        ],
        values: { host: 'mysql.mysql-fixture.svc.cluster.local', port: 3306, database: fixture.database },
      });
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
