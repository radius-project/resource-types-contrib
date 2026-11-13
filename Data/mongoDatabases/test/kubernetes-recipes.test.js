const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const source = path.resolve(__dirname, '../recipes/kubernetes/bicep/kubernetes-mongodb.bicep');
const terraform = fs.readFileSync(path.resolve(__dirname, '../recipes/kubernetes/terraform/main.tf'), 'utf8');
const terraformProbe = JSON.parse(terraform.match(/probe\s*=\s*("(?:\\.|[^"\\])*")/)[1]);
const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin',
  process.platform === 'win32' ? 'bicep.exe' : 'bicep');

function run(args) {
  const result = spawnSync(bicep, args, { encoding: 'utf8' });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
}

test('Bicep renders authenticated MongoDB with persistent data in the context namespace', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtc-mongodb-'));
  try {
    // Use dummy credentials in snapshots; keep the production parameter secure.
    const text = fs.readFileSync(source, 'utf8');
    fs.writeFileSync(path.join(dir, 'recipe.bicep'), text.replace('@secure()\n', '').replace('@secure()\r\n', ''));
    run(['build', source, '--outfile', path.join(dir, 'production.json')]);
    const template = JSON.parse(fs.readFileSync(path.join(dir, 'production.json'), 'utf8'));
    assert.equal(template.parameters.mongoPassword.type, 'securestring');
    assert.equal(template.parameters.mongoPassword.defaultValue, undefined,
      'A newGuid default would break access to an existing data volume on redeploy');
    assert.equal(template.parameters.mongoPassword.minLength, 16);
    assert.equal(template.outputs.result.value.resources.length, 4);
    assert.deepEqual(Object.keys(template.outputs.result.value.values).sort(), ['database', 'endpoint']);
    assert.deepEqual(Object.keys(template.outputs.result.value.secrets), ['connectionString']);
    assert.ok(template.outputs.result.value.secrets.connectionString.includes("uriComponent(parameters('mongoPassword'))"));

    for (const database of [undefined, 'orders-v2', null]) {
      fs.writeFileSync(path.join(dir, 'fixture.bicepparam'), `using './recipe.bicep'
param mongoPassword = 'fixture @:/?#[]%&+ password'
param context = {
  ${database === 'orders-v2' ? '' : 'application: null\nenvironment: null'}
  runtime: { kubernetes: { namespace: 'mongo-test' } }
  resource: {
    id: '/planes/radius/local/resourceGroups/test/providers/Radius.Data/mongoDatabases/mongo'
    name: 'mongo'
    type: 'Radius.Data/mongoDatabases'
    properties: { ${database === undefined ? '' : `database: ${database === null ? 'null' : `'${database}'`}`} }
  }
}
`);
      run(['snapshot', path.join(dir, 'fixture.bicepparam'), '--mode', 'Overwrite']);
      const resources = JSON.parse(fs.readFileSync(path.join(dir, 'fixture.snapshot.json'), 'utf8'))
        .predictedResources.map(resource => ({ ...resource.properties, resourceType: resource.type }));
      assert.equal(resources.length, 4);
      for (const resource of resources) {
        assert.equal(resource.metadata.namespace, 'mongo-test');
      }
      const deployment = resources.find(r => r.resourceType === 'apps/Deployment@v1');
      const secret = resources.find(r => r.resourceType === 'core/Secret@v1');
      const pvc = resources.find(r => r.resourceType === 'core/PersistentVolumeClaim@v1');
      const service = resources.find(r => r.resourceType === 'core/Service@v1');
      assert.equal(secret.stringData.password, 'fixture @:/?#[]%&+ password');
      assert.equal(deployment.spec.strategy.type, 'Recreate');
      assert.equal(deployment.spec.replicas, 1);
      const pod = deployment.spec.template.spec;
      const container = pod.containers[0];
      assert.equal(pod.automountServiceAccountToken, false);
      assert.equal(container.env.find(e => e.name === 'MONGO_INITDB_DATABASE').value, database ?? 'mongo_db');
      assert.deepEqual(container.env.find(e => e.name === 'MONGO_INITDB_ROOT_PASSWORD').valueFrom,
        { secretKeyRef: { name: secret.metadata.name, key: 'password' } });
      assert.equal(pod.volumes[0].persistentVolumeClaim.claimName, pvc.metadata.name);
      assert.equal(container.volumeMounts[0].mountPath, '/data/db');
      assert.equal(pvc.spec.resources.requests.storage, '1Gi');
      assert.equal(service.spec.type, 'ClusterIP');
      assert.deepEqual(service.spec.selector, deployment.spec.selector.matchLabels);
      for (const probe of [container.startupProbe, container.readinessProbe]) {
        const command = probe.exec.command;
        assert.deepEqual(command.slice(0, 3), ['mongosh', '--quiet', '--eval']);
        assert.equal(command[3], terraformProbe, 'Both recipes must test the same authentication behavior');
        // Execute the actual probe against a shell model: a bad password must
        // fail, even though MongoDB allows an unauthenticated ping.
        for (const authenticated of [true, false]) {
          let exit;
          const admin = { auth: () => ({ ok: authenticated ? 1 : 0 }), runCommand: () => ({ ok: 1 }) };
          const stop = {};
          try {
            new Function('db', 'process', 'quit', command[3])(
              { getSiblingDB: name => { assert.equal(name, 'admin'); return admin; } },
              { env: { MONGO_INITDB_ROOT_USERNAME: 'radius', MONGO_INITDB_ROOT_PASSWORD: 'fixture' } },
              code => { exit = code; throw stop; });
          } catch (error) {
            if (error !== stop) throw error;
          }
          assert.equal(exit, authenticated ? 0 : 1);
        }
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
