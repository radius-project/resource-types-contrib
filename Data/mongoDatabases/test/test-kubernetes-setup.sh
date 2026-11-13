#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mongo-setup-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALLS="$TEST_ROOT/calls" SECRET_INPUT="$TEST_ROOT/secret.json"
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
grep -qx 'kubectl delete secret mongo-abcdef123456-mongodb-credentials -n mongo-test --ignore-not-found' "$CALLS"
password="$(printf '%064d' 7)"
if grep -Fq "$password" "$CALLS" "$TEST_ROOT/output"; then
    echo "Error: Test password leaked into command arguments or logs." >&2
    exit 1
fi

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

mkdir -p "$TEST_ROOT/repo/Data/mongoDatabases/recipes/kubernetes/bicep"
touch "$TEST_ROOT/repo/Data/mongoDatabases/recipes/kubernetes/bicep/main.bicep"
RECIPE_PLATFORM_FILTER=kubernetes bash "$SCRIPT_DIR/../../../.github/scripts/generate-recipe-pack.sh" \
    "$TEST_ROOT/repo" biceprecipepack "$TEST_ROOT/pack.bicep" >/dev/null
if grep -q 'mongoPassword\|newGuid' "$TEST_ROOT/pack.bicep"; then
    echo "Error: Generated packs must not create or store MongoDB passwords." >&2
    exit 1
fi
echo "MongoDB credential setup tests passed"
