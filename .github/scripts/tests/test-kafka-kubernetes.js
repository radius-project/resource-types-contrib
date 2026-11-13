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
const recipes = path.join(root, 'Messaging/kafka/recipes/kubernetes');
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};

test('Bicep snapshots preserve persistence, topic startup and advertised endpoints', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-kafka-bicep-'));
  try {
    for (const file of ['kubernetes-kafka.bicep', 'create-topic.sh']) {
      fs.copyFileSync(path.join(recipes, 'bicep', file), path.join(dir, file));
    }
    run(bicep, ['build', path.join(dir, 'kubernetes-kafka.bicep'), '--outfile', path.join(dir, 'recipe.json')]);
    const template = JSON.parse(fs.readFileSync(path.join(dir, 'recipe.json'), 'utf8'));
    assert.deepEqual(Object.keys(template.outputs.result.value.values), ['host']);
    assert.deepEqual(Object.keys(template.outputs.result.value.secrets), ['connectionString']);
    assert.equal(template.outputs.result.value.resources.length, 3);
    for (const [topic, expected] of [['', 'events'], ["topic: null", 'events'], ["topic: 'order.events-1'", 'order.events-1']]) {
      fs.writeFileSync(path.join(dir, 'test.bicepparam'), `using './kubernetes-kafka.bicep'
param context = {
  runtime: { kubernetes: { namespace: 'kafka-test' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/kafka/broker'
    name: 'broker'
    type: 'Radius.Messaging/kafka'
    properties: { ${topic} }
  }
}
`);
      run(bicep, ['snapshot', path.join(dir, 'test.bicepparam'), '--mode', 'Overwrite',
        '--subscription-id', '00000000-0000-0000-0000-000000000000', '--resource-group', 'test', '--location', 'westus3']);
      const resources = JSON.parse(fs.readFileSync(path.join(dir, 'test.snapshot.json'), 'utf8')).predictedResources;
      const broker = resources.find(r => r.type === 'apps/Deployment@v1').properties;
      const service = resources.find(r => r.type === 'core/Service@v1').properties;
      const pvc = resources.find(r => r.type === 'core/PersistentVolumeClaim@v1').properties;
      const container = broker.spec.template.spec.containers[0];
      const env = Object.fromEntries(container.env.map(e => [e.name, e.value]));
      assert.equal(env.RADIUS_KAFKA_TOPIC, expected);
      assert.equal(env.KAFKA_ADVERTISED_LISTENERS, 'PLAINTEXT://broker.kafka-test.svc.cluster.local:9092,INTERNAL://127.0.0.1:19092');
      assert.ok(env.KAFKA_LISTENERS.split(',').includes('INTERNAL://127.0.0.1:19092'),
        'The startup client must get loopback metadata before Kubernetes publishes the Pod IP');
      assert.equal(env.KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, 'CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,INTERNAL:PLAINTEXT');
      assert.equal(env.KAFKA_INTER_BROKER_LISTENER_NAME, 'INTERNAL');
      assert.equal(env.KAFKA_CONTROLLER_QUORUM_VOTERS, '1@localhost:9093');
      assert.equal(broker.spec.strategy.type, 'Recreate');
      assert.equal(broker.spec.replicas, 1);
      assert.equal(broker.spec.template.spec.volumes[0].persistentVolumeClaim.claimName, 'broker-data');
      assert.equal(pvc.spec.resources.requests.storage, '1Gi');
      assert.equal(service.spec.publishNotReadyAddresses ?? false, false, 'Expose the broker only after topic readiness');
      assert.deepEqual(service.spec.ports, [{ name: 'kafka', port: 9092, targetPort: 'kafka' }],
        'Do not expose the loopback or controller listener');
      assert.equal(container.lifecycle.postStart.exec.command[2], fs.readFileSync(path.join(recipes, 'bicep/create-topic.sh'), 'utf8'));
      assert.ok(container.readinessProbe.exec.command[2].includes('--describe --topic "$RADIUS_KAFKA_TOPIC"'));
      assert.ok(container.readinessProbe.exec.command[2].includes('--bootstrap-server 127.0.0.1:19092'),
        'Readiness must not depend on its own Service endpoint');
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('topic hook retries startup, creates idempotently and propagates errors', () => {
  const source = fs.readFileSync(path.join(recipes, 'bicep/create-topic.sh'), 'utf8');
  assert.equal(source, fs.readFileSync(path.join(recipes, 'terraform/create-topic.sh'), 'utf8'), 'Both publication bundles must carry the same hook');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-kafka-hook-'));
  try {
    // Stub only the external Kafka CLI and sleep; run the actual hook in Bash.
    fs.writeFileSync(path.join(dir, 'hook.sh'), `kafka_cli() {
  if [[ "$1" != --bootstrap-server || "$2" != 127.0.0.1:19092 ]]; then
    echo "Error: startup must not need Service metadata before Kubernetes publishes the Pod IP." >&2
    return 1
  fi
  if [[ " $* " == *" --list "* ]]; then
    calls=$((calls + 1))
    [[ "$MODE" != unavailable && "$calls" -gt 1 ]]
  else
    printf '%s\\n' "$@"
    [[ "$MODE" != create-failed ]]
  fi
}
sleep() { :; }
calls=0
${source.replaceAll('/opt/kafka/bin/kafka-topics.sh', 'kafka_cli')}
`);
    const execute = (topic, mode = 'ok') => spawnSync('bash', ['hook.sh'], {
      cwd: dir, encoding: 'utf8', env: { ...process.env, RADIUS_KAFKA_TOPIC: topic, MODE: mode }
    });
    const created = execute('order.events-1');
    assert.equal(created.status, 0, created.stderr);
    assert.deepEqual(created.stdout.trim().split(/\r?\n/), [
      '--bootstrap-server', '127.0.0.1:19092', '--create', '--if-not-exists',
      '--topic', 'order.events-1', '--partitions', '1', '--replication-factor', '1'
    ]);
    assert.notEqual(execute('events', 'create-failed').status, 0);
    const unavailable = execute('events', 'unavailable');
    assert.notEqual(unavailable.status, 0);
    assert.match(unavailable.stderr, /did not become available/);
    for (const invalid of ['', '.', '..', '__consumer_offsets', 'a'.repeat(250), 'bad topic', '$(touch injected)', 'bad;topic']) {
      const result = execute(invalid);
      assert.notEqual(result.status, 0, `Reject ${JSON.stringify(invalid)}`);
      assert.match(result.stderr, /non-internal Kafka topic name/);
      assert.equal(result.stdout, '');
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
