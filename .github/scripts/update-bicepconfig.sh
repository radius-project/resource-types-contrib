#!/bin/bash
set -e

# Script: Update bicepconfig.json with published extensions
# This script finds all published .tgz files and adds them to bicepconfig.json

echo "Updating bicepconfig.json with published extensions..."

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
      '.extensions[$name] = $path' bicepconfig.json > bicepconfig.tmp && \
      mv bicepconfig.tmp bicepconfig.json
  done

  echo "✅ Successfully updated bicepconfig.json with extensions"
else
  echo "No extension .tgz files found to add to bicepconfig.json"
fi

echo "Final bicepconfig.json content:"
cat bicepconfig.json