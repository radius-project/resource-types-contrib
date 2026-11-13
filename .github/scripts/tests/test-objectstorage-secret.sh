#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-objectstorage-secret-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/repo/Storage/objectStorage/test" "$TEST_ROOT/repo/.github/scripts" "$TEST_ROOT/bin"
cp "$REPO_ROOT/Storage/objectStorage/test/test-kubernetes.sh" "$TEST_ROOT/repo/Storage/objectStorage/test/"
export TEST_CALLS="$TEST_ROOT/calls"
export TEST_MANIFEST="$TEST_ROOT/manifest"
cat >"$TEST_ROOT/repo/.github/scripts/lib-recipe-test.sh" <<'EOF'
rtc_ensure_workspace_context() { printf 'workspace %s\n' "$*" >>"$TEST_CALLS"; }
rtc_resolve_environment_path() { printf '/test/environment\t%s\n' "${TEST_NAMESPACE-fixture}"; }
rtc_deploy_and_assert_test_app() {
    printf 'deploy %s\n' "$*" >>"$TEST_CALLS"
    return "${TEST_DEPLOY_STATUS:-0}"
}
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$TEST_CALLS"
if [[ "$1" == create ]]; then
    cat >"$TEST_MANIFEST"
    exit "${TEST_CREATE_STATUS:-0}"
fi
if [[ "$1" == delete ]]; then
    exit "${TEST_DELETE_STATUS:-0}"
fi
exit 1
EOF
chmod +x "$TEST_ROOT/bin/kubectl"
export PATH="$TEST_ROOT/bin:$PATH"
helper="$TEST_ROOT/repo/Storage/objectStorage/test/test-kubernetes.sh"

bash "$helper" isolated-workspace isolated-environment >"$TEST_ROOT/output" 2>&1
python3 - "$TEST_MANIFEST" "$TEST_CALLS" "$TEST_ROOT/output" <<'PY'
import base64
import json
import re
import sys

with open(sys.argv[1]) as source:
    secret = json.load(source)
with open(sys.argv[2]) as source:
    calls = source.read()
with open(sys.argv[3]) as source:
    output = source.read()
assert secret["metadata"]["namespace"] == "fixture"
name = secret["metadata"]["name"]
assert re.fullmatch(r"store-[a-f0-9]{16}-blob-credentials", name)
key = base64.b64decode(secret["data"]["accountKey"], validate=True).decode("ascii")
assert len(base64.b64decode(key, validate=True)) == 64
assert key not in calls and key not in output
assert "kubectl create --namespace fixture --request-timeout=30s -f - -o name" in calls
assert "objectStorageResourceName=" + name.removesuffix("-blob-credentials") in calls
assert "kubectl delete secret " + name + " --namespace fixture" in calls
assert "isolated-workspace" in calls and "/test/environment" in calls
assert "--all" not in calls and "recipeParameters" not in calls
PY

: >"$TEST_CALLS"
if TEST_DEPLOY_STATUS=7 bash "$helper" >"$TEST_ROOT/output" 2>&1; then
    echo "Error: Deployment failure was hidden." >&2
    exit 1
else
    [[ "$?" == 7 ]]
fi
grep -q '^kubectl delete secret store-' "$TEST_CALLS"

: >"$TEST_CALLS"
if TEST_CREATE_STATUS=1 bash "$helper" >"$TEST_ROOT/output" 2>&1; then
    echo "Error: Secret create failure was hidden." >&2
    exit 1
fi
if grep -Eq '^deploy |^kubectl delete ' "$TEST_CALLS"; then
    echo "Error: Failed create must not deploy or delete an unowned Secret." >&2
    exit 1
fi

: >"$TEST_CALLS"
if TEST_DELETE_STATUS=1 bash "$helper" >"$TEST_ROOT/output" 2>&1; then
    echo "Error: Secret cleanup failure was hidden." >&2
    exit 1
fi
grep -q 'Error: Could not remove test credentials Secret' "$TEST_ROOT/output"

: >"$TEST_CALLS"
if TEST_NAMESPACE='' bash "$helper" >"$TEST_ROOT/output" 2>&1; then
    echo "Error: Missing namespace must fail." >&2
    exit 1
fi
if grep -q '^kubectl ' "$TEST_CALLS"; then
    echo "Error: Missing namespace must not reach Kubernetes." >&2
    exit 1
fi
echo "Object storage Secret setup and cleanup tests passed"
