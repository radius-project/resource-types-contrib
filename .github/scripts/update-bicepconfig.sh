#!/bin/bash
set -e

# This script creates a fresh bicepconfig.json with all published .tgz files

echo "Creating bicepconfig.json with published extensions..."

# Create base bicepconfig.json with required experimental features
cat > bicepconfig.json << 'EOF'
{
  "extensions": {
    "radius": "br:biceptypes.azurecr.io/radius:latest",
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
EOF

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

  echo "✅ Successfully created bicepconfig.json with extensions"
else
  echo "No extension .tgz files found to add to bicepconfig.json"
fi

echo "Final bicepconfig.json content:"
cat bicepconfig.json