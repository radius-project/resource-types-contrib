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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-bicepconfig-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

update() {
    "$REPO_ROOT/.github/scripts/update-bicepconfig.sh" >update.log 2>&1 || {
        cat update.log >&2
        return 1
    }
}

assert_config() {
    jq -e "$1" bicepconfig.json >/dev/null || {
        echo "FAIL: $1" >&2
        cat bicepconfig.json >&2
        exit 1
    }
}

cd "$TEST_ROOT"
update
assert_config '
  . == {
    experimentalFeaturesEnabled: {ociEnabled: true},
    extensions: {
      radius: "br:ghcr.io/radius-project/bicep-types-radius:edge",
      aws: "br:ghcr.io/radius-project/bicep-types-aws:edge"
    }
  }'
cp bicepconfig.json expected.json
update
cmp expected.json bicepconfig.json

# Exercise release channels and exact version pins, not just development defaults.
for tag in latest stable 0.61 0.61.1 0.61.1-rc1; do
    jq -n --arg tag "$tag" '{
      extensions: {
        radius: ("br:biceptypes.azurecr.io/radius:" + $tag),
        aws: ("br:biceptypes.azurecr.io/aws:" + $tag)
      }
    }' >bicepconfig.json
    update
    expected_tag="$tag"
    [[ "$tag" != latest ]] || expected_tag=edge
    assert_config "
      .extensions.radius == \"br:ghcr.io/radius-project/bicep-types-radius:$expected_tag\"
      and .extensions.aws == \"br:ghcr.io/radius-project/bicep-types-aws:$expected_tag\"
      and .experimentalFeaturesEnabled.ociEnabled == true"
done

cat >bicepconfig.json <<'EOF'
{
  "experimentalFeaturesEnabled": {"ociEnabled": false, "extensibility": true},
  "analyzers": {"core": {"enabled": false}},
  "cloud": {"currentProfile": "AzureCloud"},
  "moduleAliases": {"br": {"recipes": {"registry": "recipes.azurecr.io"}}},
  "extensions": {
    "radius": "./custom-radius.tgz",
    "aws": "br:custom.azurecr.io/aws:latest",
    "az": "builtin:",
    "test": "br:biceptypes.azurecr.io/test:latest",
    "other": "br:biceptypes.azurecr.io/radius:latest",
    "containers": "./old-extension.tgz"
  }
}
EOF
mkdir -p "path with spaces"
touch "path with spaces/containers-extension.tgz"
jq '.experimentalFeaturesEnabled.ociEnabled = true
    | .extensions.containers = "./path with spaces/containers-extension.tgz"' \
    bicepconfig.json >expected.json
update
diff -u <(jq -S . expected.json) <(jq -S . bicepconfig.json)
cp bicepconfig.json expected.json
update
cmp expected.json bicepconfig.json

# Already migrated refs, including GHCR latest, must not be reinterpreted.
cat >bicepconfig.json <<'EOF'
{
  "extensions": {
    "radius": "br:ghcr.io/radius-project/bicep-types-radius:0.61",
    "aws": "br:ghcr.io/radius-project/bicep-types-aws:latest"
  }
}
EOF
update
assert_config '
  .extensions.radius == "br:ghcr.io/radius-project/bicep-types-radius:0.61"
  and .extensions.aws == "br:ghcr.io/radius-project/bicep-types-aws:latest"'

printf '{"extensions":{"radius":"./custom-radius.tgz"}}\n' >bicepconfig.json
update
assert_config '
  .extensions.radius == "./custom-radius.tgz"
  and .extensions.aws == "br:ghcr.io/radius-project/bicep-types-aws:edge"'

printf 'invalid JSON\n' >bicepconfig.json
cp bicepconfig.json expected.json
if "$REPO_ROOT/.github/scripts/update-bicepconfig.sh" >update.log 2>&1; then
    echo "FAIL: invalid JSON was accepted" >&2
    exit 1
fi
grep -q 'parse error' update.log
cmp expected.json bicepconfig.json
if compgen -G 'bicepconfig.??????' >/dev/null; then
    echo "FAIL: temporary config was not cleaned up" >&2
    exit 1
fi

echo "Bicep configuration tests passed"
