const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const recipes = path.resolve(__dirname, '../recipes/kubernetes');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};

test('Bicep keeps both credential contracts, queue JSON, and namespace ownership', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-rabbitmq-'));
  try {
    // Snapshot only dummy credentials; secure outputs are omitted by the compiler.
    fs.writeFileSync(path.join(dir, 'recipe.bicep'), fs.readFileSync(
      path.join(recipes, 'bicep/kubernetes-rabbitmq.bicep'), 'utf8').replace('@secure()\n', '').replace('@secure()\r\n', ''));
    const definitionHashes = new Set();
    for (const mode of ['defaults', 'supplied', 'nulls']) {
      const supplied = mode === 'supplied';
      fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './recipe.bicep'
param generatedPassword = 'fixture-password'
param context = {
  application: null
  environment: null
  runtime: { kubernetes: { namespace: 'rabbitmq-fixture' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/rabbitMQ/broker'
    name: 'broker'
    type: 'Radius.Messaging/rabbitMQ'
    properties: {
      ${supplied ? `username: 'user"\\\\\\n$(HOSTNAME)'\nqueue: 'queue"\\\\\\n$(HOSTNAME)'\npassword: '/planes/radius/local/resourceGroups/test/providers/Radius.Security/secrets/existing'` : mode === 'nulls' ? 'username: null\nqueue: null\npassword: null' : ''}
    }
  }
}
`);
      run(bicep, ['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite']);
      const resources = JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
      const resource = type => resources.find(r => r.type === type);
      const config = resource('core/ConfigMap@v1') || resource('core/ConfigMap');
      assert.ok(config, JSON.stringify(resources));
      const definition = JSON.parse(config.properties.data['definitions.json']);
      assert.equal(definition.users[0].name, supplied ? 'user"\\\n$(HOSTNAME)' : 'radius');
      assert.equal(definition.queues[0].name, supplied ? 'queue"\\\n$(HOSTNAME)' : 'jobs');
      assert.equal(definition.users[0].password_hash, '');
      const deployment = resource('apps/Deployment@v1') || resource('apps/Deployment');
      const pod = deployment.properties.spec.template.spec;
      definitionHashes.add(deployment.properties.spec.template.metadata.annotations['radapp.io/definitions-hash']);
      assert.equal(deployment.properties.spec.strategy.type, 'Recreate');
      assert.deepEqual(pod.containers[0].readinessProbe.exec.command, ['rabbitmq-diagnostics', '-q', 'check_running']);
      const secret = resource('core/Secret@v1') || resource('core/Secret');
      assert.equal(Boolean(secret), !supplied);
      assert.equal(pod.initContainers[0].env[0].valueFrom.secretKeyRef.name, supplied ? 'existing' : secret.properties.metadata.name);
      for (const r of resources) assert.equal(r.properties.metadata.namespace, 'rabbitmq-fixture');
      const script = pod.initContainers[0].command[2];
      assert.ok(script.includes('HASH=$$(rabbitmqctl'));
      checkScript(dir, script.replaceAll('$$', '$'), config.properties.data['definitions.json']);
    }
    assert.equal(definitionHashes.size, 2, 'Changed definitions must restart the broker; omitted and null properties use the same defaults');
    assert.ok(!definitionHashes.has(undefined));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function checkScript(dir, script, definitions) {
  const bootstrap = path.join(dir, 'bootstrap.json');
  const output = path.join(dir, 'definitions.json');
  const shellPath = value => value.replaceAll('\\', '/');
  fs.writeFileSync(bootstrap, definitions);
  const executable = script.replace('/etc/rabbitmq/bootstrap/definitions.json', `"${shellPath(bootstrap)}"`)
    .replace('/etc/rabbitmq/definitions/definitions.json', `"${shellPath(output)}"`);
  const scriptFile = path.join(dir, 'init.sh');
  fs.writeFileSync(scriptFile, executable);
  run('shellcheck', ['--shell=sh', scriptFile]);
  // Test the shell boundary without a broker: RabbitMQ returns a base64 hash.
  run('bash', ['-c', `rabbitmqctl() { printf '%s\\n' 'fixture/hash+base64='; }; export -f rabbitmqctl; source "$1"`, 'test', shellPath(scriptFile)],
    { env: { ...process.env, RABBITMQ_PASSWORD: 'fixture-only' } });
  const actual = JSON.parse(fs.readFileSync(output, 'utf8'));
  const expected = JSON.parse(definitions);
  expected.users[0].password_hash = 'fixture/hash+base64=';
  assert.deepEqual(actual, expected);
  fs.rmSync(output);
  const failedHash = spawnSync('bash', ['-c',
    `rabbitmqctl() { return 1; }; export -f rabbitmqctl; source "$1"`, 'test', shellPath(scriptFile)],
  { encoding: 'utf8', env: { ...process.env, RABBITMQ_PASSWORD: 'fixture-only' } });
  assert.notEqual(failedHash.status, 0, 'Hash generation failure must stop initialization');
  assert.equal(fs.existsSync(output), false, 'Do not write a definitions file with an empty password hash');
}

test('Terraform init script preserves serialized names and accepts RabbitMQ hashes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-rabbitmq-shell-'));
  try {
    const source = fs.readFileSync(path.join(recipes, 'terraform/main.tf'), 'utf8');
    const script = source.match(/<<-SCRIPT\r?\n([\s\S]*?)\r?\n\s*SCRIPT/)[1];
    checkScript(dir, script, JSON.stringify({
      users: [{ name: 'user"\\\n$(HOSTNAME)', password_hash: '' }],
      queues: [{ name: 'queue"\\\n$(HOSTNAME)' }],
    }));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
