#!/bin/bash

# ------------------------------------------------------------
# Copyright 2025 The Radius Authors.
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
SYNC_SCRIPT="${REPO_ROOT}/.github/scripts/compute-radius-sync-payload.sh"
VERSION_SCRIPT="${REPO_ROOT}/.github/scripts/release/next-version.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-release-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local want="$1" got="$2" message="$3"
    [[ "$got" == "$want" ]] || fail "$message: got '$got', want '$want'"
}

output_value() {
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" | tail -n1
}

create_repo() {
    local repo="$1" category="$2"
    git init -q "$repo"
    git -C "$repo" config user.name "Release Test"
    git -C "$repo" config user.email "release-test@example.com"
    mkdir -p "$repo/$category/widgets"
    cat >"$repo/$category/widgets/widget.yaml" <<EOF
namespace: Radius.${category}
types:
  widgets:
    apiVersions:
      '2025-01-01-preview':
        schema: {}
EOF
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add ${category} manifest"
}

test_deleted_namespace() {
    local repo="$TEST_ROOT/deleted" output="$TEST_ROOT/deleted.out" before after
    create_repo "$repo" "Security"
    before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" rm -q Security/widgets/widget.yaml
    git -C "$repo" commit -q -m "delete Security manifest"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "1" "$(output_value "$output" namespace_count)" "deleted namespace count"
    assert_eq "Radius.Security" "$(output_value "$output" affected)" "deleted namespace"
}

test_renamed_namespace() {
    local repo="$TEST_ROOT/renamed" output="$TEST_ROOT/renamed.out" before after
    create_repo "$repo" "Data"
    before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" mv Data Compute
    sed -i 's/Radius\.Data/Radius.Compute/' "$repo/Compute/widgets/widget.yaml"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "rename Data namespace to Compute"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "2" "$(output_value "$output" namespace_count)" "renamed namespace count"
    assert_eq "Radius.Data,Radius.Compute" "$(output_value "$output" affected)" "renamed namespaces"
}

test_prerelease_labels() {
    local repo="$TEST_ROOT/prerelease" label
    create_repo "$repo" "Data"

    REPO_ROOT="$repo" NAMESPACE=Radius.Data BUMP=minor PRERELEASE_LABEL=rc.1 \
        bash "$VERSION_SCRIPT" >/dev/null 2>&1 || fail "valid prerelease label rc.1 was rejected"

    for label in rc..1 rc.01 01 .rc rc.; do
        if REPO_ROOT="$repo" NAMESPACE=Radius.Data BUMP=minor PRERELEASE_LABEL="$label" \
            bash "$VERSION_SCRIPT" >/dev/null 2>&1; then
            fail "invalid prerelease label '$label' was accepted"
        fi
    done
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
test_deleted_namespace
test_renamed_namespace
test_prerelease_labels
echo "Release automation tests passed"
