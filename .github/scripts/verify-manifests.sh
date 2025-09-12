#!/bin/bash
set -e

# Script: Verify that manifests are registered in the UCP pod
# This script monitors the UCP pod logs to ensure manifests are successfully registered

echo "Verifying manifests are registered..."

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
  logs=$(kubectl logs "$POD_NAME" -n radius-system)

  # Exit on error
  if echo "$logs" | grep -qi "Service initializer terminated with error"; then
    echo "Error found in ucp logs."
    echo "$logs" | grep -i "Service initializer terminated with error"
    exit 1
  fi

  # Check for success
  if echo "$logs" | grep -q "Successfully registered manifests"; then
    echo "Successfully registered manifests - message found."
    break
  fi

  echo "Logs not ready, waiting 30 seconds..."
  sleep 30
done

# Final check to ensure success message was found
if ! echo "$logs" | grep -q "Successfully registered manifests"; then
  echo "Manifests not registered after 10 minutes."
  exit 1
fi

echo "✅ All manifests successfully registered"