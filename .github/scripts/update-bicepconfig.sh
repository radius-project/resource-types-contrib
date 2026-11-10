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

# Merge local extension packages without changing registry references.

echo "Creating bicepconfig.json with published extensions..."

config_tmp="$(mktemp ./bicepconfig.tmp.XXXXXX)"
trap 'rm -f "$config_tmp"' EXIT

if [[ -f bicepconfig.json ]]; then
  base_config="$(cat bicepconfig.json)"
else
  base_config="$(cat << 'EOF'
{
  "extensions": {
    "radius": "br:biceptypes.azurecr.io/radius:latest",
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
EOF
)"
fi

# Find all published .tgz files and add them to bicepconfig.json (safe handling)
tgz_files=()
while IFS= read -r -d '' f; do
  tgz_files+=("$f")
done < <(find . -name "*-extension.tgz" -type f -print0)

if [[ ${#tgz_files[@]} -gt 0 ]]; then
  echo "Found extension files to add to bicepconfig.json:"
  printf '%s\n' "${tgz_files[@]}"

  paths="$(printf '%s\0' "${tgz_files[@]}" | jq -Rs 'split("\u0000") | map(select(length > 0))')"
else
  paths='[]'
  echo "No extension .tgz files found to add to bicepconfig.json"
fi

# New packages use the full schema path. Old basename-only packages remain
# usable, but a rebuilt schema takes precedence over its old package.
jq --argjson paths "$paths" '
  ($paths | map({
    path: .,
    scoped: test("\\.ya?ml-extension\\.tgz$"),
    short: (split("/")[-1] | sub("(\\.yaml|\\.yml)?-extension\\.tgz$"; "")),
    alias: (ltrimstr("./") | sub("-extension\\.tgz$"; "") | gsub("[^A-Za-z0-9_]"; "_"))
  })) as $all |
  ($all | map(select(.scoped or
    (.short as $name | any($all[]; .scoped and .short == $name) | not)))) as $packages |
  ([$packages[] | select(.scoped) | {name: .alias, path: .path}] +
   [$packages | group_by(.short)[] | select(length == 1) | .[0] |
    {name: .short, path: .path}]) as $entries |
  ($entries | group_by(.name) |
    map(select((map(.path) | unique | length) > 1) | .[0].name)) as $conflicts |
  if ($conflicts | length) > 0 then
    error("Conflicting extension alias: " + ($conflicts | join(", ")))
  elif any($packages | group_by(.short)[]; length > 1 and any(.[]; .scoped | not)) then
    error("Duplicate legacy extension basenames; rebuild the schemas to use path-based aliases")
  elif any($entries[]; .name == "radius" or .name == "aws") then
    error("Local extension alias conflicts with radius or aws")
  else
    # Remove only stale local short aliases when the basename becomes ambiguous.
    reduce ($packages | group_by(.short)[] | select(length > 1) | .[0].short) as $name (.;
      if (.extensions[$name] | type) == "string" then
        (.extensions[$name] | split("/")[-1]) as $file |
        if ([$name + "-extension.tgz", $name + ".yaml-extension.tgz",
             $name + ".yml-extension.tgz"] | index($file)) != null
           and (.extensions[$name] | startswith("./")) then
          del(.extensions[$name])
        else . end
      else . end) |
    reduce $entries[] as $entry (.;
      .extensions[$entry.name] = $entry.path)
  end
' <<<"$base_config" >"$config_tmp"
mv "$config_tmp" bicepconfig.json

echo "Successfully updated bicepconfig.json with extensions"
echo "Final bicepconfig.json content:"
cat bicepconfig.json