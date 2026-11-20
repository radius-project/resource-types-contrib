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

# Runs Data/mySqlDatabases/test/assert-recipe-result.sh on copies of the AWS
# MySQL Recipe and the aws-eks pack with new required Recipe parameters. A
# parameter that the pack passes must not fail the contract test, whatever its
# type, and one that the pack doesn't pass must. Needs the Bicep CLI that the
# rad CLI installs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mysql-recipe-contract-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

RECIPE=Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep
PACK=recipe-packs/aws-eks/aws-eks.bicep

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Copies the files the contract test reads, adds the Recipe parameter
# declarations and pack parameter lines from stdin (separated by a `---`
# line), runs the contract test, and prints its output.
run_contract_test() {
    local dir="$TEST_ROOT/$1" input recipe_params pack_params
    rm -rf "$dir"
    mkdir -p "$dir/Data" "$dir/recipe-packs" "$dir/.github"
    cp -R "$REPO_ROOT/Data/mySqlDatabases" "$dir/Data/"
    cp -R "$REPO_ROOT/recipe-packs/aws-eks" "$dir/recipe-packs/"
    cp -R "$REPO_ROOT/.github/scripts" "$dir/.github/"
    input="$(cat)"
    recipe_params="$(sed '/^---$/,$d' <<<"$input")"
    pack_params="$(sed '1,/^---$/d' <<<"$input")"
    RECIPE_PARAMS="$recipe_params" PACK_PARAMS="$pack_params" python3 - "$dir/$RECIPE" "$dir/$PACK" <<'PY' || return 1
import os, sys
recipe_path, pack_path = sys.argv[1:]
def insert_after(path, anchor, text):
    source = open(path).read()
    assert source.count(anchor) == 1, f'{anchor!r} must appear once in {path}'
    open(path, 'w').write(source.replace(anchor, anchor + text))
insert_after(recipe_path, 'param subnetIds string\n', '\n' + os.environ['RECIPE_PARAMS'] + '\n')
if os.environ['PACK_PARAMS']:
    insert_after(pack_path, '          subnetIds: subnetIds\n', os.environ['PACK_PARAMS'] + '\n')
PY
    "$dir/Data/mySqlDatabases/test/assert-recipe-result.sh" 2>&1
}

expect_pass() {
    local label="$1" output
    output="$(run_contract_test "$label")" || fail "$label: the contract test should pass: $output"
}

expect_fail() {
    local label="$1" message="$2" output
    if output="$(run_contract_test "$label")"; then
        fail "$label: the contract test should fail"
    fi
    [[ "$output" == *"$message"* ]] || fail "$label: expected '$message' in: $output"
}

expect_pass required-object <<'EOF'
param extra object
---
          extra: {
            a: 'b'
          }
EOF

expect_pass required-string <<'EOF'
param extra string
---
          extra: 'value'
EOF

# The placeholders must satisfy the parameter's decorators, and a string
# value must survive Bicep quoting.
expect_pass required-other-types <<'EOF'
@minValue(20)
param size int
param enabled bool
param zones array
@secure()
param token string
@secure()
param settings object
@allowed(['it\'s \${x} \\', 'b'])
param mode string
@minLength(5)
param label string
@allowed(['line1\nline2', 'fallback'])
param note string
@allowed(['a', 'b'])
@minLength(1)
param tiers array
---
          size: 30
          enabled: true
          zones: ['a']
          token: 'secret'
          settings: {}
          mode: 'b'
          label: 'abcde'
          note: 'fallback'
          tiers: ['b']
EOF

expect_fail required-object-not-passed 'Radius.Data/mySqlDatabases in the pack passes ["eksClusterName","subnetIds"]' <<'EOF'
param extra object
---
EOF

# The test can't choose a value for an object with a declared shape, so it
# must say what to do instead of failing in Bicep.
expect_fail required-typed-object 'Add a sample value for the Recipe parameter extra' <<'EOF'
param extra { name: string }
---
          extra: { name: 'x' }
EOF

expect_fail required-discriminated-object 'Add a sample value for the Recipe parameter extra' <<'EOF'
@discriminator('kind')
type extraType = { kind: 'a', name: string } | { kind: 'b' }
param extra extraType
---
          extra: { kind: 'b' }
EOF

expect_fail required-typed-array 'Add a sample value for the Recipe parameter extra' <<'EOF'
@minLength(1)
param extra string[]
---
          extra: ['x']
EOF

echo "MySQL Recipe contract test tests passed"
