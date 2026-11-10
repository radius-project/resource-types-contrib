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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-extensions-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE="$TEST_ROOT/repo with spaces"
mkdir -p "$FIXTURE/.github/scripts" "$TEST_ROOT/bin"
cp "$REPO_ROOT/.github/scripts/"{build-resource-type,update-bicepconfig}.sh "$FIXTURE/.github/scripts/"
export RAD_CALLS="$TEST_ROOT/rad-calls"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$RAD_CALLS"
if [[ "${RAD_FAIL:-}" == "$1 $2" ]]; then
    exit 1
fi
if [[ "$1 $2" == "bicep publish-extension" ]]; then
    [[ "$3" == "-f" && "$5" == "--target" ]]
    cp "$4" "$6"
fi
EOF
chmod +x "$TEST_ROOT/bin/rad"
export PATH="$TEST_ROOT/bin:$PATH"
cd "$FIXTURE"

make_schema() {
    local path="$1" namespace="$2"
    mkdir -p "$(dirname "$path")"
    printf 'namespace: %s\ntypes: {}\n' "$namespace" >"$path"
}

build() {
    bash .github/scripts/build-resource-type.sh "$1" >"$TEST_ROOT/build.log"
}

update() {
    bash .github/scripts/update-bicepconfig.sh >"$TEST_ROOT/config.log" 2>&1
}

assert_config() {
    jq -e "$1" bicepconfig.json >/dev/null
}

update
assert_config '.extensions.radius == "br:biceptypes.azurecr.io/radius:latest"
    and .extensions.aws == "br:biceptypes.azurecr.io/aws:latest"
    and (.extensions | length) == 2'

make_schema Data/shared/shared.yaml Radius.Data
make_schema Messaging/shared/shared.yaml Radius.Messaging
build Data/shared
build "$FIXTURE/Messaging/shared"
cmp Data/shared/shared.yaml Data/shared/shared.yaml-extension.tgz
cmp Messaging/shared/shared.yaml Messaging/shared/shared.yaml-extension.tgz
[[ "$(grep -c '^bicep publish-extension ' "$RAD_CALLS")" == 2 ]]
update
assert_config '.extensions.Data_shared_shared_yaml == "./Data/shared/shared.yaml-extension.tgz"
    and .extensions.Messaging_shared_shared_yaml == "./Messaging/shared/shared.yaml-extension.tgz"
    and (.extensions | has("shared") | not)'

# Same category, distinct folders, and both accepted schema suffixes.
make_schema Data/second/shared.yml Radius.Data
make_schema Data/second/shared.yaml Radius.Data
build Data/second
cmp Data/second/shared.yml Data/second/shared.yml-extension.tgz
cmp Data/second/shared.yaml Data/second/shared.yaml-extension.tgz
update
assert_config '.extensions.Data_second_shared_yml == "./Data/second/shared.yml-extension.tgz"
    and .extensions.Data_second_shared_yaml == "./Data/second/shared.yaml-extension.tgz"'

# Retain legacy aliases until rebuilt, then prefer the new package.
printf 'legacy\n' >containers-extension.tgz
cat >bicepconfig.json <<'EOF'
{
  "extensions": {
    "radius": "br:example.test/radius:custom",
    "aws": "br:example.test/aws:custom",
    "containers": "./containers-extension.tgz",
    "custom": "br:example.test/custom:v1",
    "shared": "./shared-extension.tgz"
  },
  "analyzers": {"core": {"enabled": false}}
}
EOF
printf 'stale\n' >shared-extension.tgz
update
assert_config '.extensions.containers == "./containers-extension.tgz"
    and (.extensions | has("shared") | not)
    and .extensions.radius == "br:example.test/radius:custom"
    and .extensions.aws == "br:example.test/aws:custom"
    and .extensions.custom == "br:example.test/custom:v1"
    and .analyzers.core.enabled == false'
make_schema Compute/containers/containers.yaml Radius.Compute
build Compute/containers
update
assert_config '.extensions.containers == "./Compute/containers/containers.yaml-extension.tgz"
    and .extensions.Compute_containers_containers_yaml == .extensions.containers'
cp bicepconfig.json "$TEST_ROOT/expected.json"
update
cmp "$TEST_ROOT/expected.json" bicepconfig.json

# A previously unique local alias must not select one of two new packages.
make_schema Data/unique/unique.yaml Radius.Data
build Data/unique
update
assert_config '.extensions.unique == "./Data/unique/unique.yaml-extension.tgz"'
make_schema Messaging/unique/unique.yaml Radius.Messaging
build Messaging/unique
update
assert_config '(.extensions | has("unique") | not)
    and .extensions.Data_unique_unique_yaml != .extensions.Messaging_unique_unique_yaml'

# An explicit remote alias is not a stale generated local reference.
jq '.extensions.shared = "br:example.test/shared:v1"' bicepconfig.json >config.tmp
mv config.tmp bicepconfig.json
update
assert_config '.extensions.shared == "br:example.test/shared:v1"'

# Normalized aliases can collide; fail without replacing the config.
make_schema Data/a-b/item.yaml Radius.Data
make_schema Data/a_b/item.yaml Radius.Data
build Data/a-b
build Data/a_b
cp bicepconfig.json "$TEST_ROOT/expected.json"
if update; then
    echo "Expected alias collision to fail" >&2
    exit 1
fi
grep -q 'Conflicting extension alias' "$TEST_ROOT/config.log"
cmp "$TEST_ROOT/expected.json" bicepconfig.json
rm Data/a-b/item.yaml-extension.tgz Data/a_b/item.yaml-extension.tgz

# Legacy packages with no distinct source identity must not be chosen at random.
mkdir -p old-one old-two
printf 'one\n' >old-one/legacy-extension.tgz
printf 'two\n' >old-two/legacy-extension.tgz
if update; then
    echo "Expected duplicate legacy packages to fail" >&2
    exit 1
fi
grep -q 'Duplicate legacy extension basenames' "$TEST_ROOT/config.log"
cmp "$TEST_ROOT/expected.json" bicepconfig.json
rm old-one/legacy-extension.tgz old-two/legacy-extension.tgz

# Short aliases must not overwrite path-based aliases or the base extensions.
for name in Data_shared_shared_yaml radius aws; do
    printf 'conflict\n' >"$name-extension.tgz"
    if update; then
        echo "Expected alias conflict for $name to fail" >&2
        exit 1
    fi
    grep -Eq 'Conflicting extension alias|Local extension alias conflicts' "$TEST_ROOT/config.log"
    cmp "$TEST_ROOT/expected.json" bicepconfig.json
    rm "$name-extension.tgz"
done

# Both Radius failures must propagate instead of reporting a successful build.
for operation in 'resource-type create' 'bicep publish-extension'; do
    if RAD_FAIL="$operation" build Data/shared; then
        echo "Expected $operation failure to stop the build" >&2
        exit 1
    fi
done

# Invalid JSON must fail and leave the input unchanged.
printf 'invalid JSON\n' >bicepconfig.json
cp bicepconfig.json "$TEST_ROOT/expected.json"
if update; then
    echo "Expected invalid config to fail" >&2
    exit 1
fi
cmp "$TEST_ROOT/expected.json" bicepconfig.json
[[ -z "$(find . -name 'bicepconfig.tmp*' -print)" ]]

echo "Resource type extension tests passed"
