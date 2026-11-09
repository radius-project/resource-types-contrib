#!/bin/bash

# ------------------------------------------------------------
# Copyright 2026 The Radius Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------

set -euo pipefail

SOURCE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GENERATOR="$SOURCE_REPO_ROOT/.github/scripts/generate-recipe-pack.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-empty-recipe-pack-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "Output still exists: $1"
}

run_empty() {
    RECIPE_PLATFORM_FILTER=aws bash "$GENERATOR" "$FIXTURE_ROOT" "$PACK_NAME" "$1" >"$TEST_ROOT/output.log" 2>&1 ||
        fail "Valid empty selection failed"
    grep -Fq "No $kind recipes found" "$TEST_ROOT/output.log" || fail "Missing no-recipes message"
}

FIXTURE_ROOT="$TEST_ROOT/source"
mkdir -p "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep" \
    "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/terraform" "$TEST_ROOT/empty"
printf 'param context object\n' >"$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/main.bicep"
printf 'variable "context" {}\n' >"$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/terraform/main.tf"
printf 'keep\n' >"$TEST_ROOT/unrelated.bicep"
printf 'keep\n' >"$TEST_ROOT/literal1-other.bicep"
cd "$TEST_ROOT"

for kind in bicep terraform; do
    PACK_NAME="${kind}recipepack"
    output="$TEST_ROOT/generated $kind.bicep"

    # Generate a real pack, then reuse the same path for an empty selection.
    RECIPE_PLATFORM_FILTER=kubernetes bash "$GENERATOR" "$FIXTURE_ROOT" "$PACK_NAME" "$output"
    grep -Fq "'Radius.Data/widgets': {" "$output" || fail "Missing resource entry"
    grep -Fq "kind: '$kind'" "$output" || fail "Wrong recipe kind"
    if [[ "$kind" == bicep ]]; then
        grep -Fq "source: 'reciperegistry:5000/radius-recipes/data/widgets/kubernetes/bicep/main:latest'" "$output" ||
            fail "Wrong Bicep source"
    else
        grep -Fq "source: 'http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/widgets-kubernetes.zip'" "$output" ||
            fail "Wrong Terraform source"
    fi
    run_empty "$output"
    assert_absent "$output"
    run_empty "$output"
    assert_absent "$output"

    printf 'stale\n' >"$output"
    RECIPE_PLATFORM_FILTER='' bash "$GENERATOR" "$TEST_ROOT/empty" "$PACK_NAME" "$output"
    assert_absent "$output"

    for output in '-leading option.bicep' 'literal[1]*.bicep'; do
        printf 'stale\n' >"$output"
        run_empty "$output"
        assert_absent "$output"
    done
    [[ "$(cat "$TEST_ROOT/unrelated.bicep")" == keep ]] || fail "Unrelated output changed"
    [[ "$(cat "$TEST_ROOT/literal1-other.bicep")" == keep ]] || fail "Output path was expanded as a glob"

    for target in "$TEST_ROOT/unrelated.bicep" "$TEST_ROOT/missing" "$FIXTURE_ROOT"; do
        ln -s "$target" "$TEST_ROOT/link.bicep"
        run_empty "$TEST_ROOT/link.bicep"
        assert_absent "$TEST_ROOT/link.bicep"
    done
    [[ "$(cat "$TEST_ROOT/unrelated.bicep")" == keep ]] || fail "Symlink target changed"
    [[ -f "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/main.bicep" ]] || fail "Directory target changed"

    mkdir -p "$TEST_ROOT/directory.bicep"
    printf 'keep\n' >"$TEST_ROOT/directory.bicep/child"
    if RECIPE_PLATFORM_FILTER=aws bash "$GENERATOR" "$FIXTURE_ROOT" "$PACK_NAME" "$TEST_ROOT/directory.bicep" >"$TEST_ROOT/output.log" 2>&1; then
        fail "Directory cleanup reported success"
    fi
    [[ "$(cat "$TEST_ROOT/directory.bicep/child")" == keep ]] || fail "Directory contents changed"
    grep -Fq "Error: Could not remove stale recipe pack output" "$TEST_ROOT/output.log" ||
        fail "Missing cleanup error"
done

# Inject a failed unlink so this test also works when run as root.
mkdir "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/rm" <<'EOF'
#!/bin/bash
echo "injected unlink failure" >&2
exit 1
EOF
chmod +x "$TEST_ROOT/bin/rm"
printf 'stale\n' >"$TEST_ROOT/failed.bicep"
if PATH="$TEST_ROOT/bin:$PATH" RECIPE_PLATFORM_FILTER=aws \
    bash "$GENERATOR" "$FIXTURE_ROOT" "$PACK_NAME" "$TEST_ROOT/failed.bicep" >"$TEST_ROOT/output.log" 2>&1; then
    fail "Failed cleanup reported success"
fi
[[ "$(cat "$TEST_ROOT/failed.bicep")" == stale ]] || fail "Failed cleanup changed output"
grep -Fq "injected unlink failure" "$TEST_ROOT/output.log" || fail "Missing unlink diagnostic"
grep -Fq "Error: Could not remove stale recipe pack output" "$TEST_ROOT/output.log" || fail "Missing cleanup error"

echo "Empty Recipe Pack generation tests passed"
