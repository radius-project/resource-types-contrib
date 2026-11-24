#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mongo-setup-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALLS="$TEST_ROOT/calls" SECRET_INPUT="$TEST_ROOT/secret.json" PROBE_INPUT="$TEST_ROOT/probe.js"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
printf 'rad %s\n' "$*" >>"$CALLS"
if [[ "$1 $2" == "env show" ]]; then
    echo '{"id":"/planes/radius/local/resourcegroups/test/providers/Radius.Core/environments/test","properties":{"providers":{"kubernetes":{"namespace":"mongo-test"}}}}'
elif [[ "$1" == deploy && "${FAIL_DEPLOY:-0}" == 1 ]]; then
    exit 1
fi
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
if [[ "$1" == create ]]; then
    cat >"$SECRET_INPUT"
    [[ "${FAIL_CREATE:-0}" != 1 ]]
elif [[ "$1" == wait ]]; then
    [[ "${FAIL_READY:-0}" != 1 ]]
elif [[ "$1 $2" == "get deployment" ]]; then
    echo '{"items":[{"metadata":{"name":"democontainer"}}]}'
elif [[ "$1" == exec ]]; then
    while [[ "$1" != -- ]]; do shift; done
    shift
    [[ "$1 $2" == "node -e" ]] || exit 1
    printf '%s' "$3" >"$PROBE_INPUT"
    [[ "${FAIL_PROBE:-0}" != 1 ]]
fi
EOF
cat >"$TEST_ROOT/bin/openssl" <<'EOF'
#!/bin/bash
if [[ "$*" == "rand -hex 6" ]]; then
    echo abcdef123456
elif [[ "$*" == "rand -hex 32" ]]; then
    printf '%064d\n' 7
else
    exit 1
fi
EOF
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"

run_setup() {
    : >"$CALLS"
    bash "$SCRIPT_DIR/test-kubernetes.sh" fixture test >"$TEST_ROOT/output" 2>&1
}

run_setup
jq -e '.metadata.name == "mongo-abcdef123456-mongodb-credentials" and .metadata.namespace == "mongo-test" and (.stringData.password | length) == 64' "$SECRET_INPUT" >/dev/null
grep -q 'mongoResourceName=mongo-abcdef123456' "$CALLS"
grep -q 'rad deploy .*mongoDatabases/test/app.bicep ' "$CALLS"
if grep -q '/test/kubernetes/app.bicep' "$CALLS"; then
    echo "Error: MongoDB test must reuse the shared app." >&2
    exit 1
fi
grep -q '^kubectl wait deployment .*radapp.io/resource=democontainer .*--timeout=180s' "$CALLS"
grep -q '^kubectl exec .*deployment/democontainer -c demo -- node -e ' "$CALLS"
grep -qx 'kubectl delete secret mongo-abcdef123456-mongodb-credentials -n mongo-test --ignore-not-found' "$CALLS"
password="$(printf '%064d' 7)"
if grep -Fq "$password" "$CALLS" "$TEST_ROOT/output"; then
    echo "Error: Test password leaked into command arguments or logs." >&2
    exit 1
fi

node - "$PROBE_INPUT" <<'EOF'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
(async () => {
    for (const failure of [undefined, 'authentication', 'read']) {
        const fixturePassword = 'fixture-password-never-in-logs';
        const uri = `mongodb://radius:${fixturePassword}@mongo/mongo_db?authSource=admin`;
        const process = { env: { MONGODB_CONNECTIONSTRING: uri }, exitCode: 0 };
        const logs = [];
        let closed = false;
        let written = false;
        class MongoClient {
            constructor(connection, options) {
                assert.equal(connection, uri);
                assert.equal(options.serverSelectionTimeoutMS, 10000);
            }
            async connect() {
                if (failure === 'authentication') throw new Error(fixturePassword);
            }
            db(name) {
                assert.equal(name, 'mongo_db');
                return {
                    collection(name) {
                        assert.equal(name, 'radius_recipe_test');
                        return {
                            async updateOne(filter, update, options) {
                                assert.deepEqual(filter, {_id: 'connection'});
                                assert.deepEqual(update, {$set: {value: 'ok'}});
                                assert.deepEqual(options, {upsert: true});
                                written = true;
                            },
                            async findOne(filter) {
                                assert.deepEqual(filter, {_id: 'connection'});
                                assert.equal(written, true);
                                return failure === 'read' ? null : {value: 'ok'};
                            }
                        };
                    }
                };
            }
            async close() { closed = true; }
        }
        await new Function('require', 'process', 'console', `return ${source.trimStart()}`)(
            name => { assert.equal(name, 'mongodb'); return {MongoClient}; },
            process, {error: message => logs.push(message)});
        assert.equal(process.exitCode, failure ? 1 : 0);
        assert.equal(closed, true);
        assert.equal(logs.some(message => message.includes(fixturePassword)), false);
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
EOF

if FAIL_CREATE=1 run_setup; then
    echo "Error: Failed credential creation reported success." >&2
    exit 1
fi
if grep -q '^kubectl delete secret ' "$CALLS"; then
    echo "Error: Failed creation must not delete an existing Secret." >&2
    exit 1
fi

if FAIL_DEPLOY=1 run_setup; then
    echo "Error: Failed application deployment reported success." >&2
    exit 1
fi
grep -qx 'kubectl delete secret mongo-abcdef123456-mongodb-credentials -n mongo-test --ignore-not-found' "$CALLS"

if FAIL_READY=1 run_setup; then
    echo "Error: Unavailable demo client reported success." >&2
    exit 1
fi
if grep -q '^kubectl exec ' "$CALLS"; then
    echo "Error: An unavailable demo client must not run a database check." >&2
    exit 1
fi
grep -qx 'kubectl delete secret mongo-abcdef123456-mongodb-credentials -n mongo-test --ignore-not-found' "$CALLS"

if FAIL_PROBE=1 run_setup; then
    echo "Error: Failed database write/read reported success." >&2
    exit 1
fi
grep -qx 'kubectl delete secret mongo-abcdef123456-mongodb-credentials -n mongo-test --ignore-not-found' "$CALLS"
grep -q '^rad app delete ' "$CALLS"

mkdir -p "$TEST_ROOT/repo/Data/mongoDatabases/recipes/kubernetes/bicep"
touch "$TEST_ROOT/repo/Data/mongoDatabases/recipes/kubernetes/bicep/main.bicep"
RECIPE_PLATFORM_FILTER=kubernetes bash "$SCRIPT_DIR/../../../.github/scripts/generate-recipe-pack.sh" \
    "$TEST_ROOT/repo" biceprecipepack "$TEST_ROOT/pack.bicep" >/dev/null
if grep -q 'mongoPassword\|newGuid' "$TEST_ROOT/pack.bicep"; then
    echo "Error: Generated packs must not create or store MongoDB passwords." >&2
    exit 1
fi
echo "MongoDB credential setup tests passed"
