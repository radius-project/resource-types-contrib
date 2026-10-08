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

# Merge the canonical extensions and published .tgz files into bicepconfig.json.

echo "Updating bicepconfig.json with published extensions..."

if [[ ! -f bicepconfig.json ]]; then
  printf '{}\n' > bicepconfig.json
fi

config_tmp=$(mktemp ./bicepconfig.XXXXXX)
trap 'rm -f "$config_tmp"' EXIT

# Only migrate the legacy Radius/AWS defaults; keep custom references and tags.
jq '
  def migrate($name):
    "br:biceptypes.azurecr.io/\($name):" as $legacy
    | "br:ghcr.io/radius-project/bicep-types-\($name):" as $canonical
    | if . == null then $canonical + "edge"
      elif type == "string" then
        if startswith($legacy) then
          ltrimstr($legacy) as $tag
          | $canonical + (if $tag == "latest" then "edge" else $tag end)
        else . end
      else . end;
  .experimentalFeaturesEnabled.ociEnabled = true
  | .extensions.radius |= migrate("radius")
  | .extensions.aws |= migrate("aws")
' bicepconfig.json > "$config_tmp"
mv "$config_tmp" bicepconfig.json

# Find all published .tgz files and add them to bicepconfig.json (safe handling)
tgz_files=()
while IFS= read -r -d '' f; do
  tgz_files+=("$f")
done < <(find . -name "*-extension.tgz" -type f -print0)

if [[ ${#tgz_files[@]} -gt 0 ]]; then
  echo "Found extension files to add to bicepconfig.json:"
  printf '%s\n' "${tgz_files[@]}"

  for tgz_file in "${tgz_files[@]}"; do
    # Extract resource name from filename (e.g., "./containers-extension.tgz" -> "containers")
    filename=$(basename "$tgz_file")
    resource_name=${filename%-extension.tgz}

    echo "Adding extension '$resource_name' with file '$tgz_file' to bicepconfig.json..."

    # Update bicepconfig.json using jq
    jq --arg name "$resource_name" --arg path "$tgz_file" \
      '.extensions[$name] = $path' bicepconfig.json > "$config_tmp"
    mv "$config_tmp" bicepconfig.json
  done

  echo "✅ Successfully created bicepconfig.json with extensions"
else
  echo "No extension .tgz files found to add to bicepconfig.json"
fi

echo "Final bicepconfig.json content:"
cat bicepconfig.json