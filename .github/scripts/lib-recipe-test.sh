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
# `test/app.bicep` against a live Radius environment. Both test-recipe.sh and
# test-recipe-pack-entry.sh consume an already-active Recipe Pack; neither
# registers or unregisters a single recipe.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-recipe-test.sh"
# =============================================================================

if [[ -n "${RTC_LIB_RECIPE_TEST_SOURCED:-}" ]]; then
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
    local kubernetes_namespace="$1" app_name="$2" kind remaining status=0
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace"
    for kind in secrets deployments services configmaps; do
        if ! kubectl delete "$kind" -l "radapp.io/application=$app_name" -n "$kubernetes_namespace"; then
            echo "Error: Could not clean up $kind for '$app_name'." >&2
            status=1
        fi
    done
    if ! remaining=$(kubectl get secrets,deployments,services,configmaps \
        -l "radapp.io/application=$app_name" -n "$kubernetes_namespace" -o json) ||
        ! jq -e '.items | type == "array" and length == 0' <<<"$remaining" >/dev/null; then
        echo "Error: Could not verify Kubernetes cleanup for '$app_name' in '$kubernetes_namespace'." >&2
        status=1
    fi
    return "$status"
}

# Unlike application-filtered listing, typed group-wide listing also works
# when a failed deployment or deletion has left resources without an app record.
rtc_list_test_application_resources() {
    local app_name="$1" workspace_name="$2" catalog types resource_type resources entries inventory='[]'
    if ! catalog=$(rad resource-type list --workspace "$workspace_name" -o json) ||
        ! types=$(jq -r '
            if type != "array" or any(.[]; (.Name | type) != "string") then
                error("Expected resource type catalog")
            else [.[].Name | select((ascii_downcase == "microsoft.resources/deployments" or
                ascii_downcase == "radius.core/environments" or
                ascii_downcase == "radius.core/applications") | not)] | unique | .[]
            end' <<<"$catalog"); then
        echo "Error: Could not enumerate resource types for cleanup." >&2
        return 1
    fi
    while IFS= read -r resource_type; do
        [[ -n "$resource_type" ]] || continue
        if ! resources=$(rad resource list "$resource_type" --preview --workspace "$workspace_name" -o json) ||
            ! entries=$(jq -c --arg app "$app_name" '
                if type != "array" then error("Expected resource list")
                else [.[] |
                    if (.id | type) != "string" or (.id | test("/providers/"; "i") | not) then
                        error("Expected resource ID")
                    else {
                        id: .id,
                        owned: ((.properties.application // "" | ascii_downcase) ==
                            ((.id | ascii_downcase | sub("/providers/.*$"; "")) +
                                "/providers/radius.core/applications/" + ($app | ascii_downcase)))
                    } end]
                end' <<<"$resources"); then
            echo "Error: Could not inventory '$resource_type' for cleanup." >&2
            return 1
        fi
        inventory=$(jq -cn --argjson current "$inventory" --argjson next "$entries" '$current + $next') || return 1
    done <<<"$types"
    printf '%s\n' "$inventory"
}

# Capture actual namespaces before Radius removes the resources that identify
# them. The configured namespace is only a signal that Kubernetes is enabled.
rtc_cleanup_test_application() {
    local app_name="$1" workspace_name="$2" configured_namespace="$3"
    local resources namespaces='' namespace applications before='[]' owned_ids='[]' after status=0
    if before=$(rtc_list_test_application_resources "$app_name" "$workspace_name"); then
        owned_ids=$(jq -c '[.[] | select(.owned) | .id | ascii_downcase]' <<<"$before") || status=1
    else
        status=1
    fi
    if [[ -n "$configured_namespace" ]]; then
        if ! resources=$(kubectl get secrets,deployments,services,configmaps \
            --all-namespaces -l "radapp.io/application=$app_name" -o json) ||
            ! namespaces=$(jq -r --arg app "$app_name" '
                if (.items | type) != "array" then error("Expected Kubernetes resource list")
                else [.items[] |
                    if .metadata.labels["radapp.io/application"] == $app and
                        (.metadata.namespace | type == "string" and length > 0)
                    then .metadata.namespace
                    else error("Expected app-owned resource with a namespace")
                    end] | unique | .[]
                end' <<<"$resources"); then
            echo "Error: Could not discover runtime namespaces for '$app_name'." >&2
            namespaces=''
            status=1
        fi
    fi

    if ! rad app delete "$app_name" --workspace "$workspace_name" --preview --yes; then
        echo "Error: Radius.Core application cleanup failed for '$app_name'." >&2
        status=1
    fi
    if ! applications=$(rad app list --workspace "$workspace_name" --preview -o json) ||
        ! jq -e --arg app "$app_name" '
            (if . == null then [] else . end) |
            type == "array" and all(.[]; (.name | type == "string") and
                (.name | ascii_downcase) != ($app | ascii_downcase))
        ' <<<"$applications" >/dev/null; then
        echo "Error: Could not verify Radius.Core application removal for '$app_name'." >&2
        status=1
    fi
    if ! after=$(rtc_list_test_application_resources "$app_name" "$workspace_name") ||
        ! jq -e --argjson ids "$owned_ids" '
            all(.[]; .owned == false and
                (.id | ascii_downcase as $id | $ids | index($id) == null))
        ' <<<"$after" >/dev/null; then
        echo "Error: Could not verify removal of resources owned by '$app_name'." >&2
        status=1
    fi

    while IFS= read -r namespace; do
        [[ -n "$namespace" ]] || continue
        rtc_cleanup_kubernetes_resources "$namespace" "$app_name" || status=1
    done <<<"$namespaces"
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

# Deploy a Resource Type's test/app.bicep against an already-ready
# environment and run its post-deploy assertion, then clean up. The
# environment must already have an active Recipe Pack covering the type.
#
# On failure, the app and any leftover Kubernetes resources are still cleaned
# up before returning non-zero. Shared Recipe Packs are never removed.
#
# Usage: rtc_deploy_and_assert_test_app <test-file> <resource-type> \
#            <app-name-prefix> <environment-path> <workspace-name> \
#            <kubernetes-namespace> [additional rad deploy arguments...]
rtc_deploy_and_assert_test_app() {
    local test_file="$1" resource_type="$2" app_name_prefix="$3" environment_path="$4" workspace_name="$5" kubernetes_namespace="$6"
    local app_name
    local -a params=()
    shift 6

    app_name="${app_name_prefix}-$(date +%s)"

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

    echo "==> Deploying test application from $test_file"
    if rad deploy "$test_file" --application "$app_name" --workspace "$workspace_name" -e "$environment_path" "${params[@]}" "$@"; then
        echo "==> Test deployment successful"

        if ! rtc_assert_recipe_result "$resource_type" "$app_name" "$workspace_name" "$kubernetes_namespace"; then
            rtc_cleanup_test_application "$app_name" "$workspace_name" "$kubernetes_namespace" ||
                echo "Error: Test app cleanup failed after assertion failure." >&2
            return 1
        fi

        echo "==> Cleaning up test application"
        rtc_cleanup_test_application "$app_name" "$workspace_name" "$kubernetes_namespace"
        return $?
    fi

    echo "==> Test deployment failed"
    rtc_cleanup_test_application "$app_name" "$workspace_name" "$kubernetes_namespace" ||
        echo "Error: Test app cleanup failed after deployment failure." >&2
    return 1
}
