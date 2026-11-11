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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-discovery-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo with spaces"
SCRIPTS="$FIXTURE_ROOT/.github/scripts"
export TYPE_DIR="$FIXTURE_ROOT/Data/caches"
BICEP_DIR="$TYPE_DIR/recipes/kubernetes/bicep"
TERRAFORM_DIR="$TYPE_DIR/recipes/kubernetes/terraform"
EMPTY_ROOT="$TEST_ROOT/empty"
OUTPUT="$TEST_ROOT/pack.bicep"
export CALL_LOG="$TEST_ROOT/calls"
export REAL_FIND
REAL_FIND="$(command -v find)"
export FAIL_SCAN="" SCAN_OUTPUT="partial"
FAILURES=0
CHECKS=0

mkdir -p "$SCRIPTS" "$BICEP_DIR" "$TERRAFORM_DIR" "$EMPTY_ROOT" "$TEST_ROOT/bin"
for script in list-recipe-folders list-resource-type-folders generate-recipe-pack test-all-recipes build-all; do
    cp "$REPO_ROOT/.github/scripts/$script.sh" "$SCRIPTS/"
    chmod +x "$SCRIPTS/$script.sh"
done
if [[ -f "$REPO_ROOT/.github/scripts/lib-recipe-platform-filter.sh" ]]; then
    cp "$REPO_ROOT/.github/scripts/lib-recipe-platform-filter.sh" "$SCRIPTS/"
fi
printf 'namespace: Radius.Data\ntypes:\n  caches: {}\n' >"$TYPE_DIR/caches.yaml"
printf 'output result object = {}\n' >"$BICEP_DIR/cache recipe.bicep"
printf 'output "result" { value = {} }\n' >"$TERRAFORM_DIR/main.tf"

cat >"$TEST_ROOT/bin/make" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >>"$CALL_LOG"
EOF
cat >"$SCRIPTS/test-recipe.sh" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >>"$CALL_LOG"
EOF

# Keep real find output so a producer can fail after returning valid paths.
cat >"$TEST_ROOT/bin/find" <<'EOF'
#!/bin/bash
set -euo pipefail
scan=""
case "$*" in
    *"-path "*"*.bicep"*) scan="recipe-bicep" ;;
    *"-path "*"terraform/main.tf"*) scan="recipe-terraform" ;;
    *"-name *.yaml"*) scan="resource" ;;
esac
if [[ "$1" == "$TYPE_DIR/recipes" ]]; then
    case "$*" in
        *"-type f"*) scan="build-bicep" ;;
        *"-type d"*) scan="build-terraform" ;;
    esac
fi
if [[ -n "$FAIL_SCAN" && "$scan" == "$FAIL_SCAN" ]]; then
    if [[ "$SCAN_OUTPUT" == "partial" ]]; then
        "$REAL_FIND" "$@"
    fi
    # EOF can arrive before the producer exits. The caller must wait for it.
    exec 1>&-
    sleep 0.02
    echo "injected $scan scan failure" >&2
    exit 37
fi
exec "$REAL_FIND" "$@"
EOF
chmod +x "$TEST_ROOT/bin/"* "$SCRIPTS/test-recipe.sh"

fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

run_script() {
    : >"$CALL_LOG"
    (
        cd "$FIXTURE_ROOT"
        export PATH="$TEST_ROOT/bin:$PATH"
        unset RECIPE_PLATFORM_FILTER
        bash "$SCRIPTS/$1.sh" "${@:2}"
    ) >"$TEST_ROOT/stdout" 2>"$TEST_ROOT/stderr"
}

expect_failure() {
    local diagnostic="$1"
    shift
    CHECKS=$((CHECKS + 1))
    if run_script "$@"; then
        fail "$*: expected a nonzero exit"
    fi
    grep -Fq "$diagnostic" "$TEST_ROOT/stderr" ||
        fail "$*: missing diagnostic: $diagnostic"
}

expect_success() {
    CHECKS=$((CHECKS + 1))
    if ! run_script "$@"; then
        cat "$TEST_ROOT/stderr" >&2
        fail "$*: expected success"
    fi
}

expect_no_calls() {
    [[ ! -s "$CALL_LOG" ]] || fail "discovery failure or empty root must not start builds/tests"
}

for script in list-recipe-folders list-resource-type-folders generate-recipe-pack test-all-recipes build-all; do
    expect_failure "does not exist" "$script" "$TEST_ROOT/missing"
    expect_no_calls
done
expect_failure "Unsupported recipe type" list-recipe-folders "$FIXTURE_ROOT" invalid
expect_failure "Unsupported recipe type" test-all-recipes "$FIXTURE_ROOT" default invalid
expect_no_calls

# Both listing scripts must propagate failed scans through all their callers.
for SCAN_OUTPUT in empty partial; do
    for kind in bicep terraform; do
        FAIL_SCAN="recipe-$kind"
        expect_failure "injected $FAIL_SCAN scan failure" list-recipe-folders "$FIXTURE_ROOT" "$kind"
        expect_failure "injected $FAIL_SCAN scan failure" list-recipe-folders "$FIXTURE_ROOT" all
        printf 'existing output\n' >"$OUTPUT"
        expect_failure "injected $FAIL_SCAN scan failure" generate-recipe-pack "$FIXTURE_ROOT" "${kind}recipepack" "$OUTPUT"
        [[ "$(cat "$OUTPUT")" == "existing output" ]] || fail "failed discovery must not replace the pack"
        expect_failure "injected $FAIL_SCAN scan failure" test-all-recipes "$FIXTURE_ROOT" default "$kind"
        expect_no_calls
        expect_failure "injected $FAIL_SCAN scan failure" test-all-recipes "$FIXTURE_ROOT" default all
        expect_no_calls
    done
    FAIL_SCAN="resource"
    expect_failure "injected resource scan failure" list-resource-type-folders "$FIXTURE_ROOT"
    expect_failure "injected resource scan failure" build-all "$FIXTURE_ROOT"
    expect_no_calls

    for kind in bicep terraform; do
        FAIL_SCAN="build-$kind"
        expect_failure "injected $FAIL_SCAN scan failure" build-all "$FIXTURE_ROOT"
    done
done
FAIL_SCAN=""

# A listing command can fail independently of find, including after output.
for listing in list-recipe-folders list-resource-type-folders; do
    cat >"$SCRIPTS/$listing.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$TYPE_DIR/recipes/kubernetes/bicep"
echo "injected listing failure" >&2
exit 37
EOF
    if [[ "$listing" == "list-recipe-folders" ]]; then
        expect_failure "injected listing failure" generate-recipe-pack "$FIXTURE_ROOT" biceprecipepack "$OUTPUT"
        expect_failure "injected listing failure" test-all-recipes "$FIXTURE_ROOT"
    else
        expect_failure "injected listing failure" build-all "$FIXTURE_ROOT"
    fi
    expect_no_calls
    cp "$REPO_ROOT/.github/scripts/$listing.sh" "$SCRIPTS/$listing.sh"
    chmod +x "$SCRIPTS/$listing.sh"
done

# A readable directory with no matches is not a discovery error.
for script in list-resource-type-folders build-all; do
    expect_success "$script" "$EMPTY_ROOT"
    expect_no_calls
done
for kind in all bicep terraform; do
    expect_success list-recipe-folders "$EMPTY_ROOT" "$kind"
    [[ ! -s "$TEST_ROOT/stdout" ]] || fail "empty recipe listing must have no paths"
    expect_success test-all-recipes "$EMPTY_ROOT" default "$kind"
    expect_no_calls
done
for kind in bicep terraform; do
    expect_success generate-recipe-pack "$EMPTY_ROOT" "${kind}recipepack" "$OUTPUT"
    expect_no_calls
done
mkdir -p "$EMPTY_ROOT/Data/caches/recipes"
cp "$TYPE_DIR/caches.yaml" "$EMPTY_ROOT/Data/caches/caches.yaml"
expect_success build-all "$EMPTY_ROOT"
printf '%s\0' -s build-resource-type "TYPE_FOLDER=$EMPTY_ROOT/Data/caches" >"$TEST_ROOT/expected"
diff -u "$TEST_ROOT/expected" "$CALL_LOG" || fail "empty nested scans must only build the resource type"

# Exact comparisons detect path splitting and spurious empty entries.
expect_success list-resource-type-folders "$FIXTURE_ROOT"
diff -u <(printf '%s\n' "$TYPE_DIR") "$TEST_ROOT/stdout" || fail "resource type listing"
for kind in all bicep terraform; do
    expect_success list-recipe-folders "$FIXTURE_ROOT" "$kind"
    case "$kind" in
        all) expected="$(printf '%s\n' "$BICEP_DIR" "$TERRAFORM_DIR")" ;;
        bicep) expected="$BICEP_DIR" ;;
        terraform) expected="$TERRAFORM_DIR" ;;
    esac
    diff -u <(printf '%s\n' "$expected") "$TEST_ROOT/stdout" || fail "$kind recipe listing"
    expect_success test-all-recipes "$FIXTURE_ROOT" fixture-env "$kind"
    case "$kind" in
        all) printf '%s\0' "$BICEP_DIR" fixture-env "$TERRAFORM_DIR" fixture-env ;;
        bicep) printf '%s\0' "$BICEP_DIR" fixture-env ;;
        terraform) printf '%s\0' "$TERRAFORM_DIR" fixture-env ;;
    esac >"$TEST_ROOT/expected"
    diff -u "$TEST_ROOT/expected" "$CALL_LOG" || fail "$kind test paths"
done
for kind in bicep terraform; do
    expect_success generate-recipe-pack "$FIXTURE_ROOT" "${kind}recipepack" "$OUTPUT"
    grep -Fq "'Radius.Data/caches': {" "$OUTPUT" || fail "missing pack resource type"
    grep -Fq "kind: '$kind'" "$OUTPUT" || fail "incorrect pack kind"
done
expect_success build-all "$FIXTURE_ROOT"
printf '%s\0' \
    -s build-resource-type "TYPE_FOLDER=$TYPE_DIR" \
    -s build-bicep-recipe "RECIPE_PATH=$BICEP_DIR/cache recipe.bicep" \
    -s build-terraform-recipe "RECIPE_PATH=$TERRAFORM_DIR" >"$TEST_ROOT/expected"
diff -u "$TEST_ROOT/expected" "$CALL_LOG" || fail "build paths"

# Nested scans must retain NUL delimiters, including newlines in filenames.
mv "$BICEP_DIR/cache recipe.bicep" "$BICEP_DIR/"$'cache\nrecipe.bicep'
expect_success build-all "$FIXTURE_ROOT"
printf '%s\0' \
    -s build-resource-type "TYPE_FOLDER=$TYPE_DIR" \
    -s build-bicep-recipe "RECIPE_PATH=$BICEP_DIR/"$'cache\nrecipe.bicep' \
    -s build-terraform-recipe "RECIPE_PATH=$TERRAFORM_DIR" >"$TEST_ROOT/expected"
diff -u "$TEST_ROOT/expected" "$CALL_LOG" || fail "NUL-delimited build paths"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "$FAILURES assertion(s) failed across $CHECKS discovery checks" >&2
    exit 1
fi
echo "Recipe discovery tests passed ($CHECKS checks)"
