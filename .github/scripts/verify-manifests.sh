#!/bin/bash
set -e

# Script: Verify that manifests are registered in the UCP pod
# This script monitors the UCP pod logs to ensure manifests are successfully registered

echo "Verifying manifests are registered..."

rm -f registermanifest_logs.txt

# Find the pod with container "ucp"
POD_NAME=$(
  kubectl get pods -n radius-system \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
  | grep "ucp" \
  | head -n1 \
  | cut -d" " -f1
)

echo "Found ucp pod: $POD_NAME"

if [ -z "$POD_NAME" ]; then
  echo "No pod with container 'ucp' found in namespace radius-system."
  exit 1
fi

# Poll logs for up to 20 iterations, 30 seconds each (up to 10 minutes total)
for i in {1..20}; do
  kubectl logs "$POD_NAME" -n radius-system | tee registermanifest_logs.txt > /dev/null

  # Exit on error
  if grep -qi "Service initializer terminated with error" registermanifest_logs.txt; then
    echo "Error found in ucp logs."
    grep -i "Service initializer terminated with error" registermanifest_logs.txt
    exit 1
  fi

  # Check for success
  if grep -q "Successfully registered manifests" registermanifest_logs.txt; then
    echo "Successfully registered manifests - message found."
    break
  fi

  echo "Logs not ready, waiting 30 seconds..."
  sleep 30
done

# Final check to ensure success message was found
if ! grep -q "Successfully registered manifests" registermanifest_logs.txt; then
  echo "Manifests not registered after 10 minutes."
  exit 1
fi

echo "✅ All manifests successfully registered"