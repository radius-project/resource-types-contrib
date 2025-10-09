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

set -e

# This script monitors the UCP pod logs to ensure manifests are successfully registered

echo "Waiting for Radius UCP pod to start..."

# Find the pod with container "ucp"
POD_NAME=$(
  kubectl get pods -n radius-system \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
  | grep "ucp" \
  | head -n1 \
  | cut -d" " -f1
)

echo "Found UCP pod: $POD_NAME"

if [ -z "$POD_NAME" ]; then
  echo "No pod with container 'ucp' found in namespace radius-system."
  exit 1
fi

# Poll logs for up to 120 iterations, 5 seconds each (up to 10 minutes total)
for i in {1..120}; do
  logs=$(kubectl logs "$POD_NAME" -n radius-system)

  # Exit on error
  if echo "$logs" | grep -qi "Service initializer terminated with error"; then
    echo "Error found in ucp logs."
    echo "$logs" | grep -i "Service initializer terminated with error"
    exit 1
  fi

  # Check for success
  if echo "$logs" | grep -q "Successfully registered manifests"; then
    echo "Pod is ready."
    break
  fi

  echo "Pod not ready, waiting 5 seconds..."
  sleep 5
done

# Final check to ensure success message was found
if ! echo "$logs" | grep -q "Successfully registered manifests"; then
  echo "Pod not ready after 10 minutes."
  exit 1
fi

echo "✅ Radius UCP pod is ready."