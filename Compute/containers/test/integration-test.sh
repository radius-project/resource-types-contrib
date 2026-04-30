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

# =============================================================================
# Integration test for Radius.Compute/containers with connections to
# Radius.Compute/persistentVolumes and Radius.Security/secrets (Key Vault).
#
# This test verifies:
# 1. The container deploys successfully with both connections
# 2. The persistentVolume connection provides valid storage account details
# 3. The secrets connection provides valid Key Vault and UAI details
# 4. The container resource shows successful provisioning with connections
#
# Prerequisites:
# - Radius environment with Azure provider configured
# - Resource types registered: Radius.Compute/containers,
#   Radius.Compute/persistentVolumes, Radius.Security/secrets
# - Recipes registered for all three resource types
#
# Usage: ./integration-test.sh [environment-id]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE="$SCRIPT_DIR/app.bicep"
ENVIRONMENT="${1:-/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/default}"
APP_NAME="integration-test-$(date +%s)"
PASSED=0
FAILED=0
TESTS=()

# --- Helpers ---

log_info() { echo -e "\033[34;1m==>\033[0m $1"; }
log_pass() { echo -e "\033[32;1m  ✓\033[0m $1"; PASSED=$((PASSED + 1)); TESTS+=("PASS: $1"); }
log_fail() { echo -e "\033[31;1m  ✗\033[0m $1"; FAILED=$((FAILED + 1)); TESTS+=("FAIL: $1"); }

cleanup() {
    log_info "Cleaning up test application: $APP_NAME"
    rad app delete "$APP_NAME" --yes 2>/dev/null || true
}

trap cleanup EXIT

assert_not_empty() {
    local value="$1"
    local description="$2"
    if [[ -n "$value" && "$value" != "null" && "$value" != "" ]]; then
        log_pass "$description"
    else
        log_fail "$description (got empty/null value)"
    fi
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$description"
    else
        log_fail "$description (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    if echo "$haystack" | grep -q "$needle"; then
        log_pass "$description"
    else
        log_fail "$description (expected to contain '$needle')"
    fi
}

# --- Test Execution ---

log_info "Starting integration test for container connections"
log_info "Test file: $TEST_FILE"
log_info "Application: $APP_NAME"

# Step 1: Deploy the test application
log_info "Step 1: Deploying test application..."
if ! rad deploy "$TEST_FILE" --application "$APP_NAME" -e "$ENVIRONMENT"; then
    log_fail "Deployment of test application"
    echo ""
    echo "================================================"
    echo "INTEGRATION TEST ABORTED - Deployment failed"
    echo "================================================"
    exit 1
fi
log_pass "Deployment of test application succeeded"

# Step 2: Verify container resource status
log_info "Step 2: Verifying container resource..."
CONTAINER_JSON=$(rad resource show "Radius.Compute/containers" "myapp" -a "$APP_NAME" -o json 2>/dev/null || echo "{}")

CONTAINER_STATE=$(echo "$CONTAINER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('provisioningState',''))" 2>/dev/null || echo "")
assert_equals "$CONTAINER_STATE" "Succeeded" "Container provisioningState is Succeeded"

# Verify container has connections defined
CONTAINER_CONNECTIONS=$(echo "$CONTAINER_JSON" | python3 -c "
import sys,json
props = json.load(sys.stdin).get('properties',{})
conns = props.get('connections',{})
print(','.join(sorted(conns.keys())))
" 2>/dev/null || echo "")
assert_contains "$CONTAINER_CONNECTIONS" "data" "Container has 'data' connection (persistentVolume)"
assert_contains "$CONTAINER_CONNECTIONS" "secrets" "Container has 'secrets' connection (Key Vault)"

# Step 3: Verify persistent volume resource and its computed values
log_info "Step 3: Verifying persistentVolume connection..."
PV_JSON=$(rad resource show "Radius.Compute/persistentVolumes" "mypersistentvolume" -a "$APP_NAME" -o json 2>/dev/null || echo "{}")

PV_STATE=$(echo "$PV_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('provisioningState',''))" 2>/dev/null || echo "")
assert_equals "$PV_STATE" "Succeeded" "PersistentVolume provisioningState is Succeeded"

PV_SHARE_NAME=$(echo "$PV_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('shareName',''))" 2>/dev/null || echo "")
assert_not_empty "$PV_SHARE_NAME" "PersistentVolume has shareName in computedValues"

PV_STORAGE_ACCOUNT=$(echo "$PV_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('storageAccountName',''))" 2>/dev/null || echo "")
assert_not_empty "$PV_STORAGE_ACCOUNT" "PersistentVolume has storageAccountName in computedValues"

PV_PROVIDER=$(echo "$PV_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('provider',''))" 2>/dev/null || echo "")
assert_equals "$PV_PROVIDER" "azureFile" "PersistentVolume provider is 'azureFile'"

# Verify storage account key exists in secrets
PV_HAS_KEY=$(echo "$PV_JSON" | python3 -c "
import sys,json
secrets = json.load(sys.stdin).get('properties',{}).get('status',{}).get('secrets',{})
print('yes' if secrets.get('storageAccountKey',{}).get('Value','') else 'no')
" 2>/dev/null || echo "no")
assert_equals "$PV_HAS_KEY" "yes" "PersistentVolume has storageAccountKey secret"

# Verify Azure storage account actually exists (use subscription from Radius env provider)
log_info "  Checking Azure storage account exists..."
ENV_JSON=$(rad env show -o json 2>/dev/null)
AZURE_SCOPE=$(echo "$ENV_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('providers',{}).get('azure',{}).get('scope',''))" 2>/dev/null || echo "")
SUBSCRIPTION=$(echo "$AZURE_SCOPE" | cut -d'/' -f3)
RESOURCE_GROUP=$(echo "$AZURE_SCOPE" | cut -d'/' -f5)
if az storage account show --name "$PV_STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then
    log_pass "Azure Storage Account '$PV_STORAGE_ACCOUNT' exists and is provisioned"
else
    log_fail "Azure Storage Account '$PV_STORAGE_ACCOUNT' not found or not provisioned"
fi

# Step 4: Verify secrets resource and Key Vault connection
log_info "Step 4: Verifying secrets (Key Vault) connection..."

# Get the secrets resource name (query all secrets, not scoped to app)
SECRETS_NAME=$(rad resource list "Radius.Security/secrets" -o json 2>/dev/null | python3 -c "
import sys,json
resources = json.load(sys.stdin)
names = sorted([r.get('name','') for r in resources if 'app-secrets' in r.get('name','')], reverse=True)
print(names[0] if names else '')
" 2>/dev/null || echo "")

if [[ -z "$SECRETS_NAME" ]]; then
    log_fail "Could not find secrets resource in application"
else
    SECRETS_JSON=$(rad resource show "Radius.Security/secrets" "$SECRETS_NAME" -o json 2>/dev/null || echo "{}")

    SECRETS_STATE=$(echo "$SECRETS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('provisioningState',''))" 2>/dev/null || echo "")
    assert_equals "$SECRETS_STATE" "Succeeded" "Secrets provisioningState is Succeeded"

    # Verify Key Vault URI is in computed values
    KV_URI=$(echo "$SECRETS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('keyVaultUri',''))" 2>/dev/null || echo "")
    assert_not_empty "$KV_URI" "Secrets has keyVaultUri in computedValues"

    # Verify UAI client ID is in computed values
    UAI_CLIENT_ID=$(echo "$SECRETS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('userAssignedIdentityClientId',''))" 2>/dev/null || echo "")
    assert_not_empty "$UAI_CLIENT_ID" "Secrets has userAssignedIdentityClientId in computedValues"

    # Verify UAI resource ID is in computed values
    UAI_ID=$(echo "$SECRETS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('properties',{}).get('status',{}).get('computedValues',{}).get('userAssignedIdentityId',''))" 2>/dev/null || echo "")
    assert_not_empty "$UAI_ID" "Secrets has userAssignedIdentityId in computedValues"

    # Verify Key Vault exists in Azure
    if [[ -n "$KV_URI" && "$KV_URI" != "null" ]]; then
        KV_NAME=$(echo "$KV_URI" | sed -E 's|https://([^.]+)\.vault\.azure\.net/?|\1|')
        log_info "  Checking Azure Key Vault '$KV_NAME' exists..."
        if az keyvault show --name "$KV_NAME" --subscription "$SUBSCRIPTION" --query "properties.provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then
            log_pass "Azure Key Vault '$KV_NAME' exists and is provisioned"
        else
            log_fail "Azure Key Vault '$KV_NAME' not found or not provisioned"
        fi
    fi
fi

# Step 5: Verify the container's recipe output resources are tracked
log_info "Step 5: Verifying container recipe output resources..."
CONTAINER_OUTPUT_RESOURCES=$(echo "$CONTAINER_JSON" | python3 -c "
import sys,json
outputs = json.load(sys.stdin).get('properties',{}).get('status',{}).get('outputResources',[])
print(len(outputs))
" 2>/dev/null || echo "0")

if [[ "$CONTAINER_OUTPUT_RESOURCES" -gt 0 ]]; then
    log_pass "Container has $CONTAINER_OUTPUT_RESOURCES output resources tracked"
else
    log_fail "Container has no output resources tracked"
fi

# --- Summary ---
echo ""
echo "================================================"
echo "INTEGRATION TEST SUMMARY"
echo "================================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""
for test in "${TESTS[@]}"; do
    echo "  $test"
done
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "RESULT: FAILED"
    exit 1
else
    echo "RESULT: PASSED"
    exit 0
fi
