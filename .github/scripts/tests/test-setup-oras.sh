#!/bin/bash

# Copyright 2026 The Radius Authors.
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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-oras-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALLS="$TEST_ROOT/calls"

cat >"$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
case "$1" in
    create)
        [[ $# == 2 ]]
        [[ "$2" == "ghcr.io/oras-project/oras@sha256:0087224dd0decc354b5b0689068fbbc40cd5dc3dbf65fcb3868dfbd363dc790b" ]]
        if [[ "$SCENARIO" == unavailable || "$SCENARIO" == integrity ]]; then
            echo "ORAS image download or digest verification failed" >&2
            exit 1
        fi
        echo oras-test-container
        ;;
    cp)
        [[ $# == 3 && "$2" == "oras-test-container:/bin/oras" ]]
        if [[ "$SCENARIO" == copy ]]; then
            echo "ORAS copy failed" >&2
            exit 1
        fi
        cat >"$3" <<'BIN'
#!/bin/bash
set -euo pipefail
[[ "$*" == version ]]
if [[ "$SCENARIO" == executable ]]; then
    echo "ORAS executable failed" >&2
    exit 1
fi
if [[ "$SCENARIO" == version ]]; then
    echo "Version:        1.3.4"
elif [[ "$SCENARIO" == metadata ]]; then
    echo "Version:        1.2.0+unreleased"
else
    echo "Version:        1.2.0"
    echo "Git commit:     dcef719e208a9b226b15bc6512ad729a7dd93270"
fi
BIN
        ;;
    rm)
        [[ $# == 2 && "$2" == oras-test-container ]]
        if [[ "$SCENARIO" == cleanup ]]; then
            echo "ORAS container cleanup failed" >&2
            exit 1
        fi
        ;;
    *) echo "Unexpected Docker command: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TEST_ROOT/bin/oras" <<'EOF'
#!/bin/bash
echo "Must not use an existing ORAS executable" >&2
exit 1
EOF
cat >"$TEST_ROOT/bin/wc" <<'EOF'
#!/bin/bash
set -euo pipefail
count="$(command -p wc "$@")"
printf '%8s\n' "$count"
EOF
chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/oras" "$TEST_ROOT/bin/wc"
export PATH="$TEST_ROOT/bin:$PATH"

for SCENARIO in success unavailable integrity copy executable version metadata cleanup path; do
    export SCENARIO
    export RUNNER_TEMP="$TEST_ROOT/$SCENARIO"
    export GITHUB_PATH="$RUNNER_TEMP/github-path"
    mkdir -p "$RUNNER_TEMP"
    : >"$CALLS"
    if [[ "$SCENARIO" == path ]]; then
        mkdir "$GITHUB_PATH"
    else
        : >"$GITHUB_PATH"
    fi
    status=0
    bash "$REPO_ROOT/.github/scripts/setup-oras.sh" >"$RUNNER_TEMP/output" 2>&1 || status=$?
    if [[ "$SCENARIO" == success ]]; then
        [[ "$status" == 0 ]]
        [[ "$(wc -l <"$GITHUB_PATH")" -eq 1 ]]
        install_dir="$(cat "$GITHUB_PATH")"
        [[ "$install_dir" == "$RUNNER_TEMP"/rtc-oras-* ]]
        [[ -x "$install_dir/oras" ]]
        "$install_dir/oras" version | grep -Eq '^Version:[[:space:]]+1\.2\.0$'
        grep -Fxq 'rm oras-test-container' "$CALLS"
    else
        [[ "$status" != 0 ]]
        [[ -s "$RUNNER_TEMP/output" ]]
        if [[ "$SCENARIO" != path ]]; then
            [[ ! -s "$GITHUB_PATH" ]]
        fi
        [[ -z "$(find "$RUNNER_TEMP" -name oras -print)" ]]
        if [[ "$SCENARIO" == unavailable || "$SCENARIO" == integrity ]]; then
            [[ "$(wc -l <"$CALLS")" -eq 1 ]]
        else
            grep -Fxq 'rm oras-test-container' "$CALLS"
        fi
    fi
    echo "ORAS setup $SCENARIO test passed"
done

for variable in RUNNER_TEMP GITHUB_PATH; do
    : >"$CALLS"
    if env -u "$variable" bash "$REPO_ROOT/.github/scripts/setup-oras.sh" >"$TEST_ROOT/missing-env" 2>&1; then
        echo "Setup must fail when $variable is absent" >&2
        exit 1
    fi
    [[ ! -s "$CALLS" ]]
    grep -Fq "$variable is required" "$TEST_ROOT/missing-env"
done

count=0
for workflow in nightly-recipe-pack-tests release-candidate-recipe-pack-tests validate-resource-types validate-azure-recipes; do
    file="$REPO_ROOT/.github/workflows/$workflow.yaml"
    if grep -Fq 'oras-project/setup-oras@' "$file"; then
        echo "Recipe validation must use the shared ORAS setup action: $workflow" >&2
        exit 1
    fi
    uses="$(grep -Fc 'uses: ./.github/actions/setup-oras' "$file")"
    case "$workflow" in
        nightly-recipe-pack-tests | release-candidate-recipe-pack-tests) [[ "$uses" == 2 ]] ;;
        *) [[ "$uses" == 1 ]] ;;
    esac
    count=$((count + uses))
done
[[ "$count" == 6 ]]
grep -Fq "run: bash \"\$GITHUB_ACTION_PATH/../../scripts/setup-oras.sh\"" "$REPO_ROOT/.github/actions/setup-oras/action.yaml"
grep -Fq 'run: make test-oras-setup' "$REPO_ROOT/.github/workflows/validate-resource-types.yaml"
echo "ORAS setup workflow tests passed"
