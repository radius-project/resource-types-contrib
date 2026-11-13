// Copyright 2026 The Radius Authors.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../../..');
const recipes = path.join(root, 'Storage/objectStorage/recipes/kubernetes');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const source = fs.readFileSync(path.join(recipes, 'bicep/kubernetes-objectstorage.bicep'), 'utf8').replace(/\r\n/g, '\n');
const terraform = fs.readFileSync(path.join(recipes, 'terraform/main.tf'), 'utf8').replace(/\r\n/g, '\n');
const script = source.match(/var initializeContainer = '''\n([\s\S]*?\n)'''/)[1];
const key = crypto.randomBytes(64).toString('base64');
const account = 'radiusstorage';

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
}

test('Bicep renders named-container initialization, persistent storage, credentials, and cleanup', () => {
  assert.equal(script, terraform.match(/initialize_container = <<-JS\n([\s\S]*?\n)JS/)[1]);
  // Kubernetes expands $(VAR) and $$ in exec args, even without a shell.
  assert.ok(!/\$\(|\$\$/.test(script), 'The probe must survive kubelet argument expansion unchanged');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-objectstorage-'));
  try {
    const recipe = path.join(dir, 'recipe.bicep');
    fs.writeFileSync(recipe, source);
    run(bicep, ['build', recipe, '--outfile', path.join(dir, 'recipe.json')]);
    const template = JSON.parse(fs.readFileSync(path.join(dir, 'recipe.json'), 'utf8'));
    assert.equal(template.parameters.objectStorageAccountKey.type.toLowerCase(), 'securestring');
    assert.equal(template.parameters.objectStorageAccountKey.defaultValue, undefined);
    assert.deepEqual(Object.keys(template.outputs.result.value.values).sort(), ['accountName', 'endpoint']);
    assert.deepEqual(Object.keys(template.outputs.result.value.secrets).sort(), ['accountKey', 'connectionString']);
    assert.equal(template.outputs.result.value.resources.length, 4);

    // Snapshot only dummy credentials, never a production secure parameter.
    fs.writeFileSync(recipe, source.replace(/^@secure\(\)\r?\n/m, ''));
    for (const custom of [false, true]) {
      const params = path.join(dir, 'test.bicepparam');
      fs.writeFileSync(params, `using './recipe.bicep'
param objectStorageAccountKey = '${key}'
param context = {
  runtime: { kubernetes: { namespace: 'storage-test' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/test/providers/Radius.Storage/objectStorage/store'
    name: 'store'
    type: 'Radius.Storage/objectStorage'
    properties: { ${custom ? "containerName: 'app-files'" : ''} }
  }
}
${custom ? "param objectStorageStorageSize = '4Gi'\nparam objectStorageStorageClassName = 'fixture-class'" : ''}
`);
      run(bicep, ['snapshot', params, '--mode', 'Overwrite', '--subscription-id',
        '00000000-0000-0000-0000-000000000000', '--resource-group', 'fixture', '--location', 'westus3']);
      const resources = JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
      assert.equal(resources.length, 4);
      const find = type => resources.find(r => r.type === `${type}@v1`).properties;
      const secret = find('core/Secret');
      assert.equal(Buffer.from(secret.data.accounts, 'base64').toString(), `${account}:${key}`);
      const deployment = find('apps/Deployment');
      assert.equal(deployment.metadata.namespace, 'storage-test');
      assert.equal(deployment.spec.strategy.type, 'Recreate');
      assert.equal(deployment.spec.replicas, 1);
      const container = deployment.spec.template.spec.containers[0];
      assert.deepEqual(container.startupProbe.exec.command, ['node', '-e', script]);
      assert.equal(container.ports[0].name, 'blob');
      assert.equal(container.readinessProbe.tcpSocket.port, 'blob');
      assert.equal(container.livenessProbe.tcpSocket.port, 'blob');
      assert.equal(container.env[1].value, custom ? 'app-files' : 'data');
      assert.equal(container.env[0].valueFrom.secretKeyRef.name, secret.metadata.name);
      assert.equal(JSON.stringify(deployment).includes(key), false);
      const pvc = find('core/PersistentVolumeClaim');
      assert.equal(pvc.spec.resources.requests.storage, custom ? '4Gi' : '1Gi');
      assert.equal(pvc.spec.storageClassName, custom ? 'fixture-class' : undefined);
      assert.equal(deployment.spec.template.spec.volumes[0].persistentVolumeClaim.claimName, pvc.metadata.name);
      const service = find('core/Service');
      assert.equal(service.spec.type, 'ClusterIP');
      assert.deepEqual(service.spec.selector, deployment.spec.selector.matchLabels);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function probe(container = 'app-files', accountKey = key) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', script], {
      env: { ...process.env, AZURITE_ACCOUNTS: `${account}:${accountKey}`, CONTAINER_NAME: container },
    });
    let stderr = '';
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject);
    child.on('exit', code => resolve({ code, stderr }));
  });
}

function blobRequest(method, requestPath, body = '') {
  const date = new Date().toUTCString();
  const contentType = body ? 'application/octet-stream' : '';
  const headers = { 'x-ms-date': date, 'x-ms-version': '2021-12-02' };
  if (method === 'PUT') headers['x-ms-blob-type'] = 'BlockBlob';
  const canonicalHeaders = Object.keys(headers).sort().map(name => `${name}:${headers[name]}\n`).join('');
  const message = [method, '', '', body ? Buffer.byteLength(body) : '', '', contentType,
    '', '', '', '', '', ''].join('\n') + '\n' + canonicalHeaders + `/${account}${requestPath}`;
  headers.Authorization = `SharedKey ${account}:${crypto.createHmac('sha256', Buffer.from(key, 'base64')).update(message).digest('base64')}`;
  headers['Content-Length'] = Buffer.byteLength(body);
  if (contentType) headers['Content-Type'] = contentType;
  return new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port: 10000, method, path: requestPath, headers }, response => {
      let data = '';
      response.on('data', chunk => { data += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, data }));
    });
    request.setTimeout(3000, () => request.destroy(new Error('Blob test timeout')));
    request.on('error', reject);
    request.end(body);
  });
}

test('Azurite creates the named container, rejects bad credentials, and retains blobs after restart', {
  skip: !process.env.AZURITE_CLI && 'Set AZURITE_CLI to Azurite 3.35.0 dist/src/blob/main.js for the service test',
  timeout: 60000,
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-azurite-'));
  let server;
  let logs = '';
  async function start() {
    server = spawn(process.execPath, [process.env.AZURITE_CLI, '--blobHost', '127.0.0.1',
      '--location', dir, '--disableProductStyleUrl', '--disableTelemetry', '--silent'], {
      env: { ...process.env, AZURITE_ACCOUNTS: `${account}:${key}` },
    });
    server.on('error', error => { logs += error.message; });
    server.stdout.on('data', data => { logs += data; });
    server.stderr.on('data', data => { logs += data; });
    for (let attempt = 0; attempt < 50; attempt++) {
      if (server.exitCode !== null) assert.fail(`Azurite exited: ${logs}`);
      const result = await probe();
      if (result.code === 0) return;
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    assert.fail(`Azurite did not become ready: ${logs}`);
  }
  async function stop() {
    if (server && server.exitCode === null) {
      const exited = once(server, 'exit');
      // On Windows SIGTERM is a hard kill. Let Azurite flush metadata first.
      server.kill('SIGTERM');
      await exited;
    }
  }
  try {
    await start();
    assert.equal((await probe()).code, 0, 'Existing container must be idempotent');
    const path = `/${account}/app-files/fixture.txt`;
    assert.equal((await blobRequest('PUT', path, 'persistent blob')).status, 201);
    assert.deepEqual(await blobRequest('GET', path), { status: 200, data: 'persistent blob' });
    const badKey = await probe('app-files', crypto.randomBytes(64).toString('base64'));
    assert.equal(badKey.code, 1);
    assert.match(badKey.stderr, /HTTP 403/);
    assert.equal(badKey.stderr.includes(key), false);
    assert.equal((await probe('app-files', 'invalid-key')).code, 1);
    for (const name of ['bad--name', 'ab', 'BadName', 'a;touch-file']) {
      assert.equal((await probe(name)).code, 1);
    }
    // LokiJS saves container/blob metadata every five seconds.
    await new Promise(resolve => setTimeout(resolve, 6000));
    await stop();
    await start();
    assert.deepEqual(await blobRequest('GET', path), { status: 200, data: 'persistent blob' });
  } finally {
    await stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
