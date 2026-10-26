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

# =============================================================================
# lib-recipe-test.sh
# -----------------------------------------------------------------------------
# Shared deploy/assert/cleanup logic for exercising a Resource Type's
# `test/app.bicep` against a live Radius environment. Originally written
# inline in test-recipe.sh (which tests one `recipes/<platform>/<kind>/`
# folder by registering it as a single recipe first); extracted here so
# test-recipe-pack-entry.sh can reuse the exact same deploy/assert/cleanup
# behavior for a Resource Type whose recipe is supplied by the active pack.
# No single-recipe registration step is needed.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-recipe-test.sh"
# =============================================================================

if [[ -n "${RTC_LIB_RECIPE_TEST_SOURCED:-}" ]]; then
    # shellcheck disable=SC2317 # The function-like sourced-file guard is intentional.
    return 0 2>/dev/null || exit 0
fi
RTC_LIB_RECIPE_TEST_SOURCED=1

rtc_ensure_workspace_context() {
    local workspace_name="$1"
    if ! rad workspace switch "$workspace_name"; then
        echo "Error: Could not switch to workspace '$workspace_name'." >&2
        return 1
    fi
}

# Resolve an environment name to its full resource ID and (if applicable) its
# Kubernetes namespace. Prints "<environment-path>\t<kubernetes-namespace>" on
# success (namespace may be empty); returns non-zero with an error on stderr
# if the environment cannot be found.
rtc_resolve_environment_path() {
    local environment_name="$1" workspace_name="$2" environment_json environment_path kubernetes_namespace
    if ! environment_json=$(rad env show "$environment_name" --workspace "$workspace_name" -o json 2>/dev/null); then
        echo "Error: Environment '$environment_name' was not found in workspace '$workspace_name'." >&2
        return 1
    fi

    environment_path=$(echo "$environment_json" | jq -r 'if type=="object" then (.id // "") elif type=="array" and length>0 then (.[0].id // "") else "" end') || return 1
    if [[ -z "$environment_path" ]]; then
        echo "Error: Could not determine environment id from rad env show output." >&2
        echo "$environment_json" >&2
        return 1
    fi
    kubernetes_namespace=$(echo "$environment_json" | jq -r 'if type=="object" then (.properties.providers.kubernetes.namespace // "") elif type=="array" and length>0 then (.[0].properties.providers.kubernetes.namespace // "") else "" end') || return 1
    echo "$environment_path"$'\t'"$kubernetes_namespace"
}

# Only delete leftovers labelled for this test app, not shared resources.
rtc_cleanup_kubernetes_resources() {
    local kubernetes_namespace="$1" app_name="$2" kind status=0
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace"
    for kind in secrets deployments services; do
        if ! kubectl delete "$kind" -l "radapp.io/application=$app_name" -n "$kubernetes_namespace"; then
            echo "Error: Could not clean up $kind for '$app_name'." >&2
            status=1
        fi
    done
    return "$status"
}

# Best-effort cleanup for fast-fail paths. The request timeout and non-blocking
# delete keep cleanup bounded when the cluster or resource controllers are unhealthy.
rtc_cleanup_kubernetes_resources_bounded() {
    local kubernetes_namespace="$1" app_name="$2" kind
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace (bounded)"
    for kind in secrets deployments services; do
        kubectl delete "$kind" \
            -l "radapp.io/application=$app_name" \
            -n "$kubernetes_namespace" \
            --request-timeout=10s \
            --wait=false ||
            echo "Error: Could not clean up $kind for '$app_name'." >&2
    done
}

rtc_snapshot_azure_management_locks() {
    local -a subscription_args=()
    if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]]; then
        echo "Error: AZURE_RESOURCE_GROUP is required for the Azure management lock guard." >&2
        return 1
    fi
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    fi

    az lock list \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        "${subscription_args[@]}" \
        --query '[].id' \
        --output tsv | sort -u
}

rtc_snapshot_application_azure_lock_inventory() {
    local app_name="$1" workspace_name="$2" resources_json
    if ! resources_json=$(rad resource list \
        --application "$app_name" \
        --workspace "$workspace_name" \
        --output json); then
        echo "Error: Could not inspect the test application's Radius resource inventory." >&2
        return 1
    fi

    jq -r '
        .. | objects | .outputResources? // empty | arrays[]?
        | select(type == "object")
        | .id? // empty
        | select(type == "string")
        | sub("^/planes/azure/azurecloud"; "")
        | select(test("/providers/Microsoft.Authorization/locks/"; "i"))
    ' <<<"$resources_json" | sort -u
}

rtc_report_azure_lock_failure() {
    local lock_id="$1" detail="${2:-}" affected_resource
    affected_resource="${lock_id%/providers/Microsoft.Authorization/locks/*}"
    echo "Error: New Azure management lock could not be deleted: $lock_id" >&2
    echo "Error: Affected Azure resource: $affected_resource" >&2
    echo "Error: Grant the test identity Microsoft.Authorization/locks/delete on the affected resource, then retry." >&2
    if [[ -n "$detail" ]]; then
        echo "Error: Azure CLI output: $detail" >&2
    fi
}

rtc_delete_owned_new_azure_management_locks() {
    local locks_before="$1" inventory_locks="$2" locks_after lock_id delete_output status=0
    local -a subscription_args=()
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    fi
    if ! locks_after=$(rtc_snapshot_azure_management_locks); then
        echo "Error: Could not inspect Azure management locks after the Recipe Pack entry test." >&2
        return 1
    fi

    while IFS= read -r lock_id; do
        [[ -z "$lock_id" ]] && continue
        if ! grep -Fxiq -- "$lock_id" <<<"$inventory_locks"; then
            echo "==> Ignoring new Azure management lock outside the test application: $lock_id"
            continue
        fi
        if delete_output=$(az lock delete --ids "$lock_id" "${subscription_args[@]}" 2>&1); then
            echo "==> Deleted Azure management lock created by the Recipe Pack entry: $lock_id"
            continue
        fi

        if grep -qiE 'AuthorizationFailed|does not have authorization|Microsoft\.Authorization/locks/delete' <<<"$delete_output"; then
            rtc_report_azure_lock_failure "$lock_id"
        else
            rtc_report_azure_lock_failure "$lock_id" "$delete_output"
        fi
        status=1
    done < <(
        comm -13 \
            <(printf '%s\n' "$locks_before" | sed '/^$/d' | sort -u) \
            <(printf '%s\n' "$locks_after" | sed '/^$/d' | sort -u)
    )

    while IFS= read -r lock_id; do
        [[ -z "$lock_id" ]] && continue
        if grep -Fxiq -- "$lock_id" <<<"$locks_before" ||
            grep -Fxiq -- "$lock_id" <<<"$locks_after"; then
            continue
        fi
        echo "Error: Radius recorded an Azure management lock that Azure did not list." >&2
        rtc_report_azure_lock_failure "$lock_id"
        status=1
    done < <(printf '%s\n' "$inventory_locks" | sed '/^$/d' | sort -u)

    return "$status"
}

# Radius.Compute/containers-specific assertion: the shared test app deploys
# two containers resources that must each publish their own host, proving
# they are not accidentally sharing the same underlying infrastructure.
rtc_assert_containers_result() {
    local app_name="$1" workspace_name="$2" app_host peer_host
    app_host=$(rad resource show "Radius.Compute/containers" myApp \
        --application "$app_name" \
        --workspace "$workspace_name" \
        --output json | jq -r '.properties.hosts.orderProcessor // ""') || return 1
    peer_host=$(rad resource show "Radius.Compute/containers" no-connections-app \
        --application "$app_name" \
        --workspace "$workspace_name" \
        --output json | jq -r '.properties.hosts.simple // ""') || return 1

    if [[ -z "$app_host" || -z "$peer_host" || "$app_host" == "$peer_host" ]]; then
        echo "Error: Each containers resource must publish a distinct host (myApp: '$app_host', no-connections-app: '$peer_host')."
        return 1
    fi

    echo "==> Containers hosts validated"
}

# Radius.Data/postgreSqlDatabases-specific assertion: the shared test app's
# deployed resource must expose host/port/database and never leak secrets.
rtc_assert_postgresql_result() {
    local app_name="$1" workspace_name="$2" resource_json
    if ! resource_json=$(rad resource show "Radius.Data/postgreSqlDatabases" postgresql \
        --application "$app_name" \
        --workspace "$workspace_name" \
        --output json); then
        echo "Error: Could not read the deployed PostgreSQL resource."
        return 1
    fi

    if ! jq -e '
        (.properties.host | type == "string" and length > 0) and
        (.properties.port | type == "number") and
        (.properties.database == "appdb") and
        (.properties | has("secrets") | not)
    ' <<<"$resource_json" >/dev/null; then
        echo "Error: PostgreSQL result must expose host, port, and database without secrets."
        return 1
    fi

    echo "==> PostgreSQL result properties validated"
}

# Dapr test apps run clients that become ready only after they use the
# component through the Dapr sidecar. The configuration API is read-only, so
# this function first writes the expected value to the Recipe-owned Redis.
rtc_assert_dapr_result() {
    local resource_type="$1" app_name="$2" kubernetes_namespace="$3" redis_deployment
    if [[ -z "$kubernetes_namespace" ]]; then
        echo "Error: Dapr runtime assertion requires the environment Kubernetes namespace." >&2
        return 1
    fi
    if [[ "$resource_type" == Radius.Dapr/configurationStores ]]; then
        local redis_selector="radapp.io/application=$app_name,radapp.io/resource-type=Radius.Dapr-configurationStores"
        if ! kubectl wait deployment -n "$kubernetes_namespace" -l "$redis_selector" \
                --for=condition=Available --timeout=180s; then
            echo "Error: Dapr configuration store Redis is not available." >&2
            return 1
        fi
        redis_deployment="$(kubectl get deployment -n "$kubernetes_namespace" -l "$redis_selector" \
            -o jsonpath='{.items[0].metadata.name}')" || return 1
        if [[ -z "$redis_deployment" ]] ||
           ! kubectl exec -n "$kubernetes_namespace" "deployment/$redis_deployment" -- \
                redis-cli SET radius-test-key 'dapr-config-ok||1'; then
            echo "Error: Could not write the Dapr configuration test value." >&2
            return 1
        fi
    fi
    if ! kubectl wait deployment -n "$kubernetes_namespace" -l "radapp.io/application=$app_name" \
            --for=condition=Available --timeout=300s; then
        echo "Error: Dapr runtime assertion failed for $resource_type." >&2
        kubectl logs -n "$kubernetes_namespace" -l "radapp.io/application=$app_name" \
            --all-containers --tail=50 --prefix >&2 || true
        return 1
    fi
    echo "==> Dapr runtime checks passed for $resource_type"
}

# Resource-Type-specific post-deploy assertion dispatcher. A no-op (success)
# for every Resource Type without a dedicated assertion above -- for those,
# `rad deploy` succeeding (the test app's own readiness probes/waits included)
# is the test.
rtc_assert_recipe_result() {
    local resource_type="$1" app_name="$2" workspace_name="$3"
    case "$resource_type" in
        Radius.Data/mySqlDatabases)
            local kubernetes_namespace="${4:-}"
            if [[ -z "$kubernetes_namespace" ]]; then
                echo "Error: MySQL readiness assertion requires the environment Kubernetes namespace." >&2
                return 1
            fi
            # The direct-module client probe checks the actual server setting.
            if ! kubectl wait deployment \
                -n "$kubernetes_namespace" \
                -l "radapp.io/application=$app_name,radapp.io/resource=mysqlclient" \
                --for=condition=Available --timeout=180s; then
                echo "Error: MySQL client readiness assertion failed." >&2
                return 1
            fi
            ;;
        Radius.Dapr/*)
            rtc_assert_dapr_result "$resource_type" "$app_name" "${4:-}"
            ;;
        Radius.Compute/containers)
            rtc_assert_containers_result "$app_name" "$workspace_name"
            ;;
        Radius.Data/postgreSqlDatabases)
            rtc_assert_postgresql_result "$app_name" "$workspace_name"
            ;;
        *)
            return 0
            ;;
    esac
}

rtc_collect_azure_test_diagnostics() {
    local resource_type="$1" app_name="$2" started="$3" directory status script_dir dependency
    local diagnostics_root="${RTC_AZURE_DIAGNOSTICS_DIR:-}"
    if [[ "${RTC_TEST_PLATFORM:-}" != azure || "$resource_type" != Radius.Compute/containers ||
          -z "$diagnostics_root" ]]; then
        return 0
    fi
    if ! mkdir -p "$diagnostics_root" ||
       ! directory=$(mktemp -d "$diagnostics_root/failure-XXXXXXXX"); then
        echo "Error: Could not create Azure diagnostic directory." >&2
        return 1
    fi
    for dependency in node timeout az; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "Error: Azure diagnostics require $dependency." | tee "$directory/collector-status.txt" >&2
            return 1
        fi
    done
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "==> Collecting Azure failure diagnostics before test app cleanup"
    if timeout --kill-after=5s 100s node "$script_dir/collect-azure-test-diagnostics.js" \
        "$directory" "${AZURE_SUBSCRIPTION_ID:-}" "${AZURE_RESOURCE_GROUP:-}" "$app_name" "$started"; then
        echo "Azure diagnostic collection completed." >"$directory/collector-status.txt"
    else
        status=$?
        echo "Error: Azure diagnostics incomplete (collector exit $status); test failure and cleanup are unchanged." |
            tee "$directory/collector-status.txt" >&2
        return "$status"
    fi
}

# Deploy a Resource Type's test/app.bicep against an already-ready
# environment and run its post-deploy assertion, then clean up. The
# environment must already be able to satisfy the type (either a
# single recipe registered on it, or an active Recipe Pack that covers it) --
# this function does no recipe registration of its own.
#
# On failure, the app and any leftover Kubernetes resources are still cleaned
# up before returning non-zero; the caller is responsible for anything
# specific to how the recipe got onto the environment (e.g. unregistering a
# single recipe) since that varies by caller.
#
# Usage: rtc_deploy_and_assert_test_app <test-file> <resource-type> \
#            <app-name-prefix> <environment-path> <workspace-name> \
#            <kubernetes-namespace> [additional rad deploy arguments...]
rtc_deploy_and_assert_test_app() {
    local test_file="$1" resource_type="$2" app_name_prefix="$3" environment_path="$4" workspace_name="$5" kubernetes_namespace="$6"
    local app_name started locks_before="" inventory_locks="" deploy_status=0
    local -a params=() deploy_timeout=() cleanup_timeout=()
    shift 6

    app_name="${app_name_prefix}-$(date +%s)"

    if [[ "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure &&
          "$resource_type" == Radius.Compute/containers ]]; then
        if ! command -v timeout >/dev/null 2>&1; then
            echo "Error: Azure container CI tests require GNU timeout." >&2
            return 1
        fi
        deploy_timeout=(timeout --kill-after=5s 15m)
    fi

    if ! grep -qE '^param applicationName string' "$test_file"; then
        echo "Error: Test template must declare an applicationName parameter for cleanup." >&2
        return 1
    fi

    if grep -q 'param password' "$test_file" 2>/dev/null; then
        local generated_password
        if ! generated_password=$(openssl rand -hex 16); then
            echo "Error: Could not generate the test password." >&2
            return 1
        fi
        # SQL Server requires multiple character classes, not just hex digits.
        generated_password="Aa1!${generated_password}"
        params=(--parameters "password=$generated_password")
        echo "==> Detected 'password' parameter in test template, auto-generating value"
    fi
    params+=(--parameters "applicationName=$app_name")

    if [[ "${RTC_AZURE_LOCK_GUARD:-0}" == "1" ]]; then
        if ! locks_before=$(rtc_snapshot_azure_management_locks); then
            echo "Error: Could not inspect Azure management locks before the Recipe Pack entry test." >&2
            return 1
        fi
    fi

    echo "==> Deploying test application from $test_file"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ${deploy_timeout[@]+"${deploy_timeout[@]}"} rad deploy "$test_file" --application "$app_name" --workspace "$workspace_name" -e "$environment_path" "${params[@]}" "$@"; then
        echo "==> Test deployment successful"

        if ! rtc_assert_recipe_result "$resource_type" "$app_name" "$workspace_name" "$kubernetes_namespace"; then
            deploy_status=1
        fi
    else
        deploy_status=$?
        echo "==> Test deployment failed"
        if [[ -n "${deploy_timeout[*]:-}" && ( "$deploy_status" == 124 || "$deploy_status" == 137 ) ]]; then
            echo "Error: Azure container test deployment exceeded its 15-minute limit." >&2
        fi
        deploy_status=1
    fi

    if [[ "$deploy_status" -ne 0 ]]; then
        if [[ -n "${deploy_timeout[*]:-}" ]]; then
            cleanup_timeout=(timeout --kill-after=5s 3m)
        fi
        rtc_collect_azure_test_diagnostics "$resource_type" "$app_name" "$started" ||
            echo "Error: Azure diagnostic collection failed; continuing cleanup." >&2
    fi

    if [[ "${RTC_AZURE_LOCK_GUARD:-0}" == "1" ]]; then
        if ! inventory_locks=$(rtc_snapshot_application_azure_lock_inventory "$app_name" "$workspace_name"); then
            echo "Error: Continuing with bounded Radius application deletion without lock ownership data." >&2
            inventory_locks=""
        fi
        if ! rtc_delete_owned_new_azure_management_locks "$locks_before" "$inventory_locks"; then
            echo "Error: Skipping Radius application deletion because a test-owned Azure management lock remains." >&2
            rtc_cleanup_kubernetes_resources_bounded "$kubernetes_namespace" "$app_name"
            return 1
        fi
    fi

    echo "==> Cleaning up test application"
    local cleanup_status=0
    ${cleanup_timeout[@]+"${cleanup_timeout[@]}"} rad app delete "$app_name" --workspace "$workspace_name" --yes || cleanup_status=1
    rtc_cleanup_kubernetes_resources "$kubernetes_namespace" "$app_name" || cleanup_status=1
    if [[ "$cleanup_status" -ne 0 ]]; then
        echo "Error: Test app cleanup failed." >&2
    fi
    if [[ "$deploy_status" -ne 0 ]]; then
        return "$deploy_status"
    fi
    return "$cleanup_status"
}
