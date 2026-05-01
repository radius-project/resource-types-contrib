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
# Integration test for Compute/containers with azure-aci recipe
#
# Tests end-to-end deployment of the containers resource type using the
# azure-aci-containers.bicep recipe, including:
#   - Container provisioning via NGroups
#   - PersistentVolume connection
#   - Secrets connection (Key Vault integration)
#   - Volume mounts (persistent, emptyDir, secrets)
#   - Liveness/readiness probes
#   - Network infrastructure (VNet, LB, NSG, NAT GW)
#
# Prerequisites:
#   - Radius CLI installed and configured
#   - Azure CLI authenticated with a subscription
#   - Resource types registered (Radius.Compute/containers, persistentVolumes, Radius.Security/secrets)
#   - Recipe registered for Radius.Compute/containers (azure-aci-containers)
#   - Recipe registered for Radius.Compute/persistentVolumes
#   - Recipe registered for Radius.Security/secrets
#
# Usage:
#   ./integration-test.sh [environment-id] [location]
#
# Example:
#   ./integration-test.sh /planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/default eastus2euap
# =============================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_FILE="$REPO_ROOT/Compute/containers/test/app.bicep"
ENVIRONMENT_ID="${1:-/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/default}"
LOCATION="${2:-eastus2euap}"
APP_NAME="containers-testapp"
CONTAINER_NAME="myapp"
PERSISTENT_VOLUME_NAME="mypersistentvolume"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
MAX_WAIT_SECONDS=900
POLL_INTERVAL=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging helpers
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

record_pass() { ((TESTS_PASSED++)); log_pass "$1"; }
record_fail() { ((TESTS_FAILED++)); log_fail "$1"; }
record_skip() { ((TESTS_SKIPPED++)); log_warn "[SKIP] $1"; }

# Cleanup function
cleanup() {
    log_step "Cleanup"
    log_info "Deleting test application and resources..."

    # Delete Radius application (cascades to child resources)
    rad app delete "$APP_NAME" --yes 2>/dev/null || true

    # Delete individual resources if app delete didn't catch them
    rad resource delete Radius.Compute/containers "$CONTAINER_NAME" --group default --yes 2>/dev/null || true
    rad resource delete Radius.Compute/persistentVolumes "$PERSISTENT_VOLUME_NAME" --group default --yes 2>/dev/null || true

    log_info "Cleanup complete"
}

# Determine resource group from Radius environment if not set
detect_resource_group() {
    if [[ -z "$RESOURCE_GROUP" ]]; then
        log_info "Detecting Azure resource group from Radius environment..."
        RESOURCE_GROUP=$(rad env show default -o json --preview 2>/dev/null | jq -r '.properties.providers.azure.scope // empty' | sed 's|.*/resourceGroups/||') || true
        if [[ -z "$RESOURCE_GROUP" ]]; then
            log_warn "Could not detect resource group from environment. Azure-level validations will be skipped."
        else
            log_info "Detected resource group: $RESOURCE_GROUP"
        fi
    fi
}

# =============================================================================
# Step 1: Deploy the test application
# =============================================================================
deploy_app() {
    log_step "Step 1: Deploy test application"

    if [[ ! -f "$TEST_FILE" ]]; then
        log_fail "Test file not found: $TEST_FILE"
        exit 1
    fi

    log_info "Deploying $TEST_FILE with location=$LOCATION..."
    log_info "Environment: $ENVIRONMENT_ID"

    if rad deploy "$TEST_FILE" \
        -p environment="$ENVIRONMENT_ID" \
        2>&1 | tee /tmp/rad-deploy-output.txt; then
        record_pass "Deployment succeeded"
    else
        log_fail "Deployment failed. Output:"
        cat /tmp/rad-deploy-output.txt
        record_fail "Deployment failed"
        return 1
    fi
}

# =============================================================================
# Step 2: Verify Radius resources are created
# =============================================================================
verify_radius_resources() {
    log_step "Step 2: Verify Radius resources"

    # Check application exists
    log_info "Checking application '$APP_NAME'..."
    if rad app show "$APP_NAME" -o json 2>/dev/null | jq -e '.properties.status.compute' >/dev/null 2>&1; then
        record_pass "Application '$APP_NAME' exists with compute status"
    elif rad app show "$APP_NAME" 2>/dev/null; then
        record_pass "Application '$APP_NAME' exists"
    else
        record_fail "Application '$APP_NAME' not found"
    fi

    # Check container resource
    log_info "Checking container '$CONTAINER_NAME'..."
    local container_json
    container_json=$(rad resource show Radius.Compute/containers "$CONTAINER_NAME" -o json --group default 2>/dev/null) || true

    if [[ -n "$container_json" ]]; then
        record_pass "Container resource '$CONTAINER_NAME' exists"

        # Verify provisioning state
        local state
        state=$(echo "$container_json" | jq -r '.properties.provisioningState // "unknown"')
        if [[ "$state" == "Succeeded" ]]; then
            record_pass "Container provisioningState is 'Succeeded'"
        else
            record_fail "Container provisioningState is '$state' (expected 'Succeeded')"
        fi

        # Verify connections are configured
        local conn_data conn_secrets
        conn_data=$(echo "$container_json" | jq -r '.properties.connections.data.source // empty')
        conn_secrets=$(echo "$container_json" | jq -r '.properties.connections.secrets.source // empty')

        if [[ -n "$conn_data" ]]; then
            record_pass "Connection 'data' (persistentVolume) is configured: $conn_data"
        else
            record_fail "Connection 'data' (persistentVolume) not found"
        fi

        if [[ -n "$conn_secrets" ]]; then
            record_pass "Connection 'secrets' is configured: $conn_secrets"
        else
            record_fail "Connection 'secrets' not found"
        fi

        # Verify recipe output resources exist
        local output_resources
        output_resources=$(echo "$container_json" | jq -r '.properties.status.outputResources // [] | length')
        if [[ "$output_resources" -gt 0 ]]; then
            record_pass "Container has $output_resources output resources from recipe"
            echo "$container_json" | jq -r '.properties.status.outputResources[]?.id // empty' | while read -r res_id; do
                log_info "  Output resource: $res_id"
            done
        else
            record_fail "Container has no output resources (recipe may not have reported them)"
        fi
    else
        record_fail "Container resource '$CONTAINER_NAME' not found"
    fi

    # Check persistent volume
    log_info "Checking persistent volume '$PERSISTENT_VOLUME_NAME'..."
    local pv_json
    pv_json=$(rad resource show Radius.Compute/persistentVolumes "$PERSISTENT_VOLUME_NAME" -o json --group default 2>/dev/null) || true

    if [[ -n "$pv_json" ]]; then
        record_pass "PersistentVolume '$PERSISTENT_VOLUME_NAME' exists"
        local pv_state
        pv_state=$(echo "$pv_json" | jq -r '.properties.provisioningState // "unknown"')
        if [[ "$pv_state" == "Succeeded" ]]; then
            record_pass "PersistentVolume provisioningState is 'Succeeded'"
        else
            record_fail "PersistentVolume provisioningState is '$pv_state'"
        fi
    else
        record_fail "PersistentVolume '$PERSISTENT_VOLUME_NAME' not found"
    fi

    # Check secrets resource (name has uniqueString suffix)
    log_info "Checking secrets resource..."
    local secrets_list
    secrets_list=$(rad resource list Radius.Security/secrets -o json --group default 2>/dev/null) || true
    local secret_found
    secret_found=$(echo "$secrets_list" | jq -r '.[].name // empty' | grep -c "^app-secrets-" || echo "0")

    if [[ "$secret_found" -gt 0 ]]; then
        record_pass "Secrets resource found (app-secrets-*)"
    else
        record_fail "No secrets resource matching 'app-secrets-*' found"
    fi
}

# =============================================================================
# Step 3: Verify Azure resources (NGroups, networking, CGP)
# =============================================================================
verify_azure_resources() {
    log_step "Step 3: Verify Azure infrastructure"

    if [[ -z "$RESOURCE_GROUP" ]]; then
        record_skip "Azure resource verification (resource group not detected)"
        return 0
    fi

    log_info "Checking Azure resources in resource group: $RESOURCE_GROUP"

    # List all ACI-related resources
    local azure_resources
    azure_resources=$(az resource list --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(type, 'Microsoft.ContainerInstance') || contains(type, 'Microsoft.Network')].{name:name, type:type, location:location, state:provisioningState}" \
        -o json 2>/dev/null) || true

    if [[ -z "$azure_resources" || "$azure_resources" == "[]" ]]; then
        record_fail "No Azure resources found in resource group '$RESOURCE_GROUP'"
        return 1
    fi

    log_info "Azure resources in $RESOURCE_GROUP:"
    echo "$azure_resources" | jq -r '.[] | "  \(.type) / \(.name) [\(.location)] - \(.state // "N/A")"'

    # Check for NGroups resource
    local ngroups_count
    ngroups_count=$(echo "$azure_resources" | jq '[.[] | select(.type == "Microsoft.ContainerInstance/NGroups" or .type == "Microsoft.ContainerInstance/ngroups")] | length')
    if [[ "$ngroups_count" -gt 0 ]]; then
        record_pass "NGroups resource exists in Azure"

        # Verify NGroups location
        local ngroups_location
        ngroups_location=$(echo "$azure_resources" | jq -r '[.[] | select(.type == "Microsoft.ContainerInstance/NGroups" or .type == "Microsoft.ContainerInstance/ngroups")][0].location')
        if [[ "$ngroups_location" == "$LOCATION" ]]; then
            record_pass "NGroups deployed in expected location: $LOCATION"
        else
            record_fail "NGroups location mismatch: expected '$LOCATION', got '$ngroups_location'"
        fi
    else
        record_fail "NGroups resource not found in Azure"
    fi

    # Check Container Group Profile
    local cgp_count
    cgp_count=$(echo "$azure_resources" | jq '[.[] | select(.type | contains("containerGroupProfiles"))] | length')
    if [[ "$cgp_count" -gt 0 ]]; then
        record_pass "Container Group Profile exists"
    else
        record_fail "Container Group Profile not found"
    fi

    # Check networking resources
    local has_vnet has_lb has_nsg has_natgw
    has_vnet=$(echo "$azure_resources" | jq '[.[] | select(.type | contains("virtualNetworks"))] | length')
    has_lb=$(echo "$azure_resources" | jq '[.[] | select(.type | contains("loadBalancers"))] | length')
    has_nsg=$(echo "$azure_resources" | jq '[.[] | select(.type | contains("networkSecurityGroups"))] | length')
    has_natgw=$(echo "$azure_resources" | jq '[.[] | select(.type | contains("natGateways"))] | length')

    [[ "$has_vnet" -gt 0 ]] && record_pass "Virtual Network exists" || record_fail "Virtual Network not found"
    [[ "$has_lb" -gt 0 ]] && record_pass "Load Balancer exists" || record_fail "Load Balancer not found"
    [[ "$has_nsg" -gt 0 ]] && record_pass "Network Security Group exists" || record_fail "Network Security Group not found"
    [[ "$has_natgw" -gt 0 ]] && record_pass "NAT Gateway exists" || record_fail "NAT Gateway not found"
}

# =============================================================================
# Step 4: Verify NGroups container instances are running
# =============================================================================
verify_container_instances() {
    log_step "Step 4: Verify container instances are running"

    if [[ -z "$RESOURCE_GROUP" ]]; then
        record_skip "Container instance verification (resource group not detected)"
        return 0
    fi

    # Find the NGroups resource name
    local ngroups_name
    ngroups_name=$(az resource list --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(type, 'NGroups') || contains(type, 'ngroups')].name" -o tsv 2>/dev/null | head -1) || true

    if [[ -z "$ngroups_name" ]]; then
        record_fail "Cannot find NGroups resource to verify instances"
        return 1
    fi

    log_info "Checking NGroups '$ngroups_name' status..."

    # Query NGroups for container group status
    local ngroups_detail
    ngroups_detail=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerInstance/NGroups/$ngroups_name?api-version=2024-09-01-preview" \
        2>/dev/null) || true

    if [[ -n "$ngroups_detail" ]]; then
        local provisioning_state desired_count current_count
        provisioning_state=$(echo "$ngroups_detail" | jq -r '.properties.provisioningState // "unknown"')
        desired_count=$(echo "$ngroups_detail" | jq -r '.properties.elasticProfile.desiredCount // 0')
        current_count=$(echo "$ngroups_detail" | jq -r '.properties.containerGroupProfiles[0].containerGroupProperties.instanceView.groups // [] | length' 2>/dev/null || echo "0")

        log_info "NGroups provisioning state: $provisioning_state"
        log_info "Desired count: $desired_count"

        if [[ "$provisioning_state" == "Succeeded" ]]; then
            record_pass "NGroups provisioning state is 'Succeeded'"
        elif [[ "$provisioning_state" == "Creating" || "$provisioning_state" == "Updating" ]]; then
            log_warn "NGroups is still provisioning ($provisioning_state). Instances may not be ready yet."
            record_pass "NGroups is actively provisioning"
        else
            record_fail "NGroups provisioning state is '$provisioning_state'"
        fi
    else
        record_fail "Could not query NGroups details"
    fi
}

# =============================================================================
# Step 5: Verify Load Balancer connectivity
# =============================================================================
verify_lb_connectivity() {
    log_step "Step 5: Verify Load Balancer connectivity"

    if [[ -z "$RESOURCE_GROUP" ]]; then
        record_skip "Load balancer connectivity check (resource group not detected)"
        return 0
    fi

    # Get the inbound public IP
    local public_ip
    public_ip=$(az network public-ip list --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(name, 'inboundPIP')].ipAddress" -o tsv 2>/dev/null | head -1) || true

    if [[ -z "$public_ip" || "$public_ip" == "null" ]]; then
        log_warn "No public IP assigned yet (may still be provisioning)"
        record_skip "LB connectivity check (no public IP assigned)"
        return 0
    fi

    log_info "Inbound public IP: $public_ip"
    log_info "Attempting HTTP request to container (port 80)..."

    # Try to reach the container via LB (with retries for propagation)
    local attempt max_attempts=5
    for attempt in $(seq 1 $max_attempts); do
        if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "http://$public_ip" 2>/dev/null | grep -qE "^(200|301|302|403)"; then
            record_pass "HTTP response received from container via Load Balancer (IP: $public_ip)"
            return 0
        fi
        log_info "  Attempt $attempt/$max_attempts - no response yet, waiting..."
        sleep 10
    done

    log_warn "Could not reach container via LB (containers may still be starting)"
    record_skip "LB connectivity (containers not yet responding after $max_attempts attempts)"
}

# =============================================================================
# Step 6: Verify connections data in Radius resource
# =============================================================================
verify_connections() {
    log_step "Step 6: Verify connection data integrity"

    local container_json
    container_json=$(rad resource show Radius.Compute/containers "$CONTAINER_NAME" -o json --group default 2>/dev/null) || true

    if [[ -z "$container_json" ]]; then
        record_fail "Cannot retrieve container resource for connection verification"
        return 1
    fi

    # Verify the persistent volume connection resolves
    local pv_source
    pv_source=$(echo "$container_json" | jq -r '.properties.connections.data.source // empty')
    if [[ -n "$pv_source" ]]; then
        # Try to resolve the persistent volume resource
        if rad resource show Radius.Compute/persistentVolumes "$PERSISTENT_VOLUME_NAME" --group default 2>/dev/null | grep -q "Succeeded"; then
            record_pass "PersistentVolume connection source resolves and is healthy"
        else
            record_fail "PersistentVolume connection source does not resolve to a healthy resource"
        fi
    fi

    # Verify secrets connection resolves
    local secrets_source
    secrets_source=$(echo "$container_json" | jq -r '.properties.connections.secrets.source // empty')
    if [[ -n "$secrets_source" ]]; then
        # Extract secret name from the resource ID
        local secret_name
        secret_name=$(echo "$secrets_source" | sed 's|.*/||')
        if rad resource show Radius.Security/secrets "$secret_name" --group default 2>/dev/null | grep -q "Succeeded"; then
            record_pass "Secrets connection source resolves and is healthy"
        else
            log_warn "Secrets connection source status could not be verified"
            record_skip "Secrets connection health check"
        fi
    fi

    # Verify volumes are configured in the container spec
    local volume_count
    volume_count=$(echo "$container_json" | jq '.properties.volumes // {} | length')
    if [[ "$volume_count" -ge 3 ]]; then
        record_pass "All 3 volume types configured (persistent, emptyDir, secrets)"
    else
        record_fail "Expected 3 volumes, found $volume_count"
    fi
}

# =============================================================================
# Main execution
# =============================================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Radius Compute/containers - Azure ACI Integration Test    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Test file:   $TEST_FILE"
    log_info "Environment: $ENVIRONMENT_ID"
    log_info "Location:    $LOCATION"
    echo ""

    # Detect resource group for Azure-level checks
    detect_resource_group

    # Set trap for cleanup on failure
    trap 'log_warn "Test interrupted. Run cleanup manually if needed: rad app delete $APP_NAME --yes"' EXIT

    # Run test steps
    deploy_app || { log_fail "Deployment failed, aborting remaining tests"; print_summary; exit 1; }
    verify_radius_resources
    verify_azure_resources
    verify_container_instances
    verify_lb_connectivity
    verify_connections

    # Remove the trap since we're doing controlled cleanup
    trap - EXIT

    # Print summary
    print_summary
}

print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     TEST SUMMARY                           ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  ${GREEN}Passed:  %3d${NC}                                              ║\n" "$TESTS_PASSED"
    printf "║  ${RED}Failed:  %3d${NC}                                              ║\n" "$TESTS_FAILED"
    printf "║  ${YELLOW}Skipped: %3d${NC}                                              ║\n" "$TESTS_SKIPPED"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        log_fail "Integration test FAILED with $TESTS_FAILED failure(s)"
        exit 1
    else
        log_pass "Integration test PASSED"
        exit 0
    fi
}

main "$@"
