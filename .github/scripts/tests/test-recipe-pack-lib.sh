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

# Unit tests for lib-recipe-packs.sh. Builds a small fixture repo with two
# packs (one "kubernetes"-style pack with only repo-owned entries, one
# "azure-aks"-style pack with a mix of repo-owned and direct-module entries)
# and asserts the discovery helpers return exactly what the fixture implies,
# with no dependency on the real repo content.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-pack-lib-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"

# --- Resource types -----------------------------------------------------
# Data/widgets: has a test app and a kubernetes recipe folder -> repo-owned,
# never a gap for either pack.
mkdir -p "$FIXTURE_ROOT/Data/widgets/test" "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep"
touch "$FIXTURE_ROOT/Data/widgets/test/app.bicep" "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/main.bicep"

# Data/gadgets: has a test app but NO recipes/ folder at all -> direct-module
# gap wherever its pack entry uses a non-repo source.
mkdir -p "$FIXTURE_ROOT/Data/gadgets/test"
touch "$FIXTURE_ROOT/Data/gadgets/test/app.bicep"

# Data/untested: no test app at all -> never a gap, nothing to deploy.
mkdir -p "$FIXTURE_ROOT/Data/untested"

# --- Recipe packs --------------------------------------------------------
mkdir -p "$FIXTURE_ROOT/recipe-packs/kubernetes" "$FIXTURE_ROOT/recipe-packs/azure-aks"

cat >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" <<'EOF'
resource kubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'kubernetes'
  properties: {
    recipes: {
      'Radius.Data/widgets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/widgets:latest'
      }
    }
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
resource azureAksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {
      'Radius.Data/widgets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/widgets:latest'
      }
      'Radius.Data/gadgets': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/gadget-module:1.0.0'
        parameters: {
          nested: {
            source: 'user-override'
          }
        }
      }
      'Radius.Data/untested': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/untested-module:1.0.0'
      }
    }
  }
}
EOF

run_in_fixture() {
    (
        RTC_REPO_ROOT="$FIXTURE_ROOT"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
        cd "$FIXTURE_ROOT"
        # shellcheck source=/dev/null
        source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
        "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$expected" == "$actual" ]] || fail "$label: expected [$expected] got [$actual]"
}

# rtc_list_recipe_packs discovers both fixture packs.
actual="$(run_in_fixture rtc_list_recipe_packs | sort | tr '\n' ',')"
assert_eq "azure-aks,kubernetes," "$actual" "rtc_list_recipe_packs"

# rtc_recipe_pack_platform_group maps both fixture packs correctly, and
# rejects an unknown pack id with a non-zero exit instead of silently
# returning nothing.
actual="$(run_in_fixture rtc_recipe_pack_platform_group kubernetes)"
assert_eq "kubernetes" "$actual" "platform group for kubernetes"
actual="$(run_in_fixture rtc_recipe_pack_platform_group azure-aks)"
assert_eq "azure" "$actual" "platform group for azure-aks"
if run_in_fixture rtc_recipe_pack_platform_group not-a-real-pack >/dev/null 2>&1; then
    fail "rtc_recipe_pack_platform_group should fail for an unmapped pack id"
fi

# rtc_recipe_packs_for_platform_group filters correctly.
actual="$(run_in_fixture rtc_recipe_packs_for_platform_group azure | tr '\n' ',')"
assert_eq "azure-aks," "$actual" "packs for azure"
actual="$(run_in_fixture rtc_recipe_packs_for_platform_group kubernetes | tr '\n' ',')"
assert_eq "kubernetes," "$actual" "packs for kubernetes"

# rtc_list_platform_groups returns the distinct, sorted set.
actual="$(run_in_fixture rtc_list_platform_groups | tr '\n' ',')"
assert_eq "azure,kubernetes," "$actual" "list of platform groups"

# rtc_recipe_pack_entries extracts type/source pairs, ignoring the nested
# "source: 'user-override'" line inside Data/gadgets' parameters.
expected="Radius.Data/widgets	ghcr.io/radius-project/kube-recipes/widgets:latest|Radius.Data/gadgets	mcr.microsoft.com/bicep/avm/res/some/gadget-module:1.0.0|Radius.Data/untested	mcr.microsoft.com/bicep/avm/res/some/untested-module:1.0.0|"
actual="$(run_in_fixture rtc_recipe_pack_entries "$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" | tr '\n' '|')"
assert_eq "$expected" "$actual" "rtc_recipe_pack_entries for azure-aks"

# rtc_list_direct_module_types: kubernetes pack has zero gaps (its only entry
# is repo-owned); azure-aks pack flags only Data/gadgets (Data/widgets is
# repo-owned, Data/untested has no test app to deploy).
actual="$(run_in_fixture rtc_list_direct_module_types kubernetes | tr '\n' ',')"
assert_eq "" "$actual" "direct-module gaps for kubernetes"
actual="$(run_in_fixture rtc_list_direct_module_types azure-aks | tr '\n' ',')"
assert_eq "Data/gadgets," "$actual" "direct-module gaps for azure-aks"

mkdir -p "$FIXTURE_ROOT/recipe-packs/aaa-unmapped"
touch "$FIXTURE_ROOT/recipe-packs/aaa-unmapped/main.bicep"
if run_in_fixture rtc_list_platform_groups >/dev/null 2>&1; then
    fail "platform discovery must propagate unmapped pack errors"
fi
if run_in_fixture rtc_recipe_packs_for_platform_group azure >/dev/null 2>&1; then
    fail "filtered discovery must propagate unmapped pack errors"
fi
rm "$FIXTURE_ROOT/recipe-packs/aaa-unmapped/main.bicep"

touch "$FIXTURE_ROOT/recipe-packs/azure-aks/second.bicep"
if run_in_fixture rtc_list_direct_module_types azure-aks >/dev/null 2>&1; then
    fail "direct-module discovery must propagate ambiguous template errors"
fi

echo "Recipe pack library test passed"
