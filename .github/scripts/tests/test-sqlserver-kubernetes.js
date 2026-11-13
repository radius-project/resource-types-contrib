const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, writeFileSync, readFileSync, rmSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '../../..');
const recipe = path.join(root, 'Data/sqlServerDatabases/recipes/kubernetes');
const bootstrap = readFileSync(path.join(recipe, 'terraform/bootstrap.sh'), 'utf8').replace(/\r\n/g, '\n');
const bashPath = value => process.platform === 'win32'
  ? value.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`).replaceAll('\\', '/')
  : value;

function runBootstrap({ consent = 'Y', failSetup = false, failLogin = false } = {}) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sqlserver-bootstrap-'));
  const shellDir = bashPath(dir);
  try {
    const sqlcmd = path.join(dir, 'sqlcmd');
    const server = path.join(dir, 'sqlservr');
    writeFileSync(sqlcmd, `#!/bin/bash
set -eu
printf '%s\\n' "$@" >> "$FIXTURE_DIR/args"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -U && "$2" != sa && "$FAIL_LOGIN" == true ]]; then exit 1; fi
  if [[ "$1" == -i ]]; then
    cp "$2" "$FIXTURE_DIR/setup.sql"
    [[ "$FAIL_SETUP" != true ]]
    exit
  fi
  shift
done
`, { mode: 0o755 });
    writeFileSync(server, '#!/bin/bash\nsleep 1\n', { mode: 0o755 });
    writeFileSync(path.join(dir, 'bootstrap.sh'), bootstrap
      .replace('/opt/mssql-tools18/bin/sqlcmd', `"${shellDir}/sqlcmd"`)
      .replace('/opt/mssql/bin/sqlservr', `"${shellDir}/sqlservr"`));
    const result = spawnSync('bash', [bashPath(path.join(dir, 'bootstrap.sh'))], {
      encoding: 'utf8',
      timeout: 15000,
      env: {
        ...process.env,
        ACCEPT_EULA: consent,
        RADIUS_DATABASE: "db]'; DROP DATABASE master;--$(UNCHANGED)",
        RADIUS_USERNAME: "admin]';--",
        MSSQL_SA_PASSWORD: "Fixture-only'$(UNCHANGED)42!",
        FIXTURE_DIR: shellDir,
        FAIL_SETUP: String(failSetup),
        FAIL_LOGIN: String(failLogin),
      },
    });
    if (result.error) throw result.error;
    const read = name => {
      try { return readFileSync(path.join(dir, name), 'utf8'); }
      catch (error) { if (error.code === 'ENOENT') return ''; throw error; }
    };
    return { ...result, sql: read('setup.sql'), args: read('args') };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('bootstrap creates the requested database and administrator, with escaped literals', () => {
  const result = runBootstrap();
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.sql.includes("N'db]''; DROP DATABASE master;--$(UNCHANGED)'"));
  assert.ok(result.sql.includes("N'admin]'';--'"));
  assert.ok(result.sql.includes("N'Fixture-only''$(UNCHANGED)42!'"));
  assert.match(result.sql, /IF DB_ID\(@database\) IS NULL/);
  assert.match(result.sql, /CREATE DATABASE ' \+ QUOTENAME\(@database\)/);
  assert.match(result.sql, /IF SUSER_ID\(@username\) IS NULL/);
  assert.match(result.sql, /CREATE LOGIN/);
  assert.match(result.sql, /ALTER LOGIN/);
  assert.match(result.sql, /ALTER SERVER ROLE sysadmin ADD MEMBER/);
  assert.match(result.sql, /LOWER\(@username\) <> N'sa'/);
  assert.match(result.args, /-x\n-b\n/);
  assert.ok(result.args.includes("-U\nadmin]';--\n-d\ndb]'; DROP DATABASE master;--$(UNCHANGED)\n"));
  assert.ok(!result.args.includes("Fixture-only"));
  assert.ok(!result.stdout.includes("Fixture-only"));
  assert.ok(!result.stderr.includes("Fixture-only"));
});

test('bootstrap rejects missing license consent before starting SQL Server', () => {
  const result = runBootstrap({ consent: '' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /license terms/);
  assert.equal(result.args, '');
});

test('database setup failure is fatal and does not print SQL containing credentials', () => {
  const result = runBootstrap({ failSetup: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /database\/login setup failed/);
  assert.ok(!result.stderr.includes("Fixture-only"));
  assert.ok(!result.stdout.includes("administrator login are ready"));
});

test('bootstrap fails when the requested login cannot query the requested database', () => {
  const result = runBootstrap({ failLogin: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /requested SQL Server login cannot query/);
  assert.ok(!result.stdout.includes("administrator login are ready"));
});

test('compiled Bicep uses the shared bootstrap and the same database readiness contract', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sqlserver-bicep-'));
  let template;
  try {
    const bicep = process.env.BICEP_CLI || path.join(os.homedir(), '.rad/bin', process.platform === 'win32' ? 'bicep.exe' : 'bicep');
    const output = path.join(dir, 'recipe.json');
    const result = spawnSync(bicep, ['build', path.join(recipe, 'bicep/kubernetes-sqlserver.bicep'), '--outfile', output], {
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    template = JSON.parse(readFileSync(output, 'utf8'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  assert.ok(Object.values(template.variables).some(value => value === bootstrap));
  assert.equal(template.variables.bootstrap, "[replace(variables('$fxv#0'), '$', '$$')]");
  assert.deepEqual(template.parameters.sqlServerAcceptEula.allowedValues, ['Y']);
  assert.ok(!Object.hasOwn(template.parameters.sqlServerAcceptEula, 'defaultValue'));
  const server = template.resources.server.properties.spec;
  assert.equal(server.replicas, 1);
  assert.equal(server.strategy.type, 'Recreate');
  const pod = server.template.spec;
  assert.equal(pod.nodeSelector['kubernetes.io/arch'], 'amd64');
  assert.equal(pod.securityContext.fsGroup, 10001);
  const container = pod.containers[0];
  assert.equal(container.command[2], "[variables('bootstrap')]");
  assert.match(template.variables.readiness, /-U "\$RADIUS_USERNAME" -d "\$RADIUS_DATABASE"/);
  assert.equal(container.readinessProbe.exec.command[2], "[variables('readiness')]");
  assert.equal(template.resources.service.properties.spec.ports[0].targetPort, 'sqlserver');
  assert.equal(container.ports[0].containerPort, 1433);
  assert.equal(template.outputs.result.value.resources.length, 4);
  assert.equal(template.outputs.result.value.values.port, 1433);
  assert.ok(!Object.hasOwn(template.outputs.result.value, 'secrets'));
});
