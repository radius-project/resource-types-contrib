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
    local -a limit=()
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        limit=(timeout --kill-after=5s 30s)
    fi
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace"
    for kind in secrets deployments services; do
        if ! "${limit[@]}" kubectl delete "$kind" -l "radapp.io/application=$app_name" -n "$kubernetes_namespace"; then
            echo "Error: Could not clean up $kind for '$app_name'." >&2
            status=1
        fi
    done
    return "$status"
}

# Accept only structured capacity errors tied to an Azure PostgreSQL server.
# Wrapper codes are not evidence; every leaf failure must be a capacity code.
rtc_has_postgresql_capacity_failure() {
    python3 - "$1" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    transcript = log.read()
decoder = json.JSONDecoder()
server = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.DBforPostgreSQL/flexibleServers/[^/]+$", re.I
)
wrappers = {
    "RecipeDeploymentFailed",
    "ResourceDeploymentFailure",
    "DeploymentFailed",
    "ResourceOperationFailure",
}
codes = []
invalid = False
json_spans = []

def objects(text):
    found = []
    offset = 0
    while (offset := text.find("{", offset)) != -1:
        try:
            start = offset
            value, end = decoder.raw_decode(text, offset)
            found.append((value, start, end))
            offset = end
        except ValueError:
            offset += 1
    return found

def visit(value, target="", failure_context=False):
    global invalid
    if isinstance(value, list):
        for item in value:
            visit(item, target, failure_context)
    elif isinstance(value, dict):
        before = len(codes)
        target = value.get("target", target)
        code = value.get("code")
        status = value.get("status", "")
        is_failure = failure_context or (
            isinstance(status, str) and status.lower() in {"failed", "failure", "error"}
        )
        if code:
            if code in {"SkuNotAvailable", "ServerIsBusy"}:
                if isinstance(target, str) and server.fullmatch(target):
                    codes.append(code)
                else:
                    invalid = True
            elif code not in wrappers:
                invalid = True
        elif is_failure or ("target" in value and "message" in value):
            invalid = True
        if is_failure and not code:
            invalid = True

        children = []
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                children.append((item, is_failure or (code in wrappers and key == "details")))
        embedded = []
        if isinstance(value.get("message"), str):
            for item, start, end in objects(value["message"]):
                embedded.append((item, True))
        for item, child_failure in children + embedded:
            if isinstance(item, (dict, list)):
                visit(item, target, child_failure)
        if code in wrappers and len(codes) == before:
            invalid = True

for root, start, end in objects(transcript):
    json_spans.append((start, end))
    visit(root)

# CLI progress output may contain normal Error-prefixed JSON records, which are
# classified above. A second plain error line is not safe to ignore.
failure_prefix = re.compile(r"^\s*(?:error|fatal|failure|failed):", re.IGNORECASE)
bare_failure = re.compile(
    r"^\s*(?:[A-Za-z_][A-Za-z0-9_.-]*|\([A-Za-z_][A-Za-z0-9_.-]*\))\s*:\s*\S"
    r"|^\s*(?i:unknown|unclassified|unexpected)\b.*\b(?i:error|failure)\b"
)
harmless_progress = re.compile(
    r"\s*(?:Location:\s*[a-z][a-z0-9-]*|Status:\s*(?:Running|Accepted|Succeeded)"
    r"|WARNING: Radius type compatibility is not verified\.)\s*"
)
line_start = 0
for line in transcript.splitlines(keepends=True):
    line_body = line.rstrip("\r\n")
    residual = list(line_body)
    line_end = line_start + len(line_body)
    for start, end in json_spans:
        overlap_start = max(start, line_start)
        overlap_end = min(end, line_end)
        if overlap_start < overlap_end:
            residual[overlap_start - line_start:overlap_end - line_start] = \
                [" "] * (overlap_end - overlap_start)
    residual = "".join(residual)
    if (bare_failure.search(residual) and not harmless_progress.fullmatch(residual)) or (
        failure_prefix.search(residual) and failure_prefix.sub("", residual).strip()
    ):
        invalid = True
    line_start += len(line)

sys.exit(0 if codes and not invalid else 1)
PY
}

# Compare group-wide IDs, not just Radius outputs: a failed recipe can allocate
# a server before it records any output. Never delete an untracked resource here.
rtc_snapshot_azure_resource_ids() {
    local inventory
    local -a subscription_args=()
    [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]] || subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    [[ -n "${AZURE_RESOURCE_GROUP:-}" ]] || {
        echo "Error: Azure cleanup verification requires AZURE_RESOURCE_GROUP." >&2
        return 1
    }
    inventory=$(timeout --kill-after=5s 30s az resource list --resource-group "$AZURE_RESOURCE_GROUP" \
        "${subscription_args[@]}" --output json) || return 1
    jq -er '
        if type == "array" and all(.[]; .id | type == "string" and startswith("/subscriptions/"))
        then map(.id | ascii_downcase) | unique | join("\n")
        else error("invalid Azure resource inventory") end
    ' <<<"$inventory"
}

# Retry one untried size only when the shared helper confirms safe cleanup.
rtc_test_azure_postgresql_app() (
    local test_file="$1" environment_path="$2" workspace_name="$3" kubernetes_namespace="$4"
    local size="${RTC_POSTGRES_TEST_SIZE:-S}" deadline="${RTC_POSTGRES_TEST_DEADLINE_EPOCH:-}"
    local remaining status attempt test_harness script_dir
    case "$size" in S|M) ;; *) echo "Error: PostgreSQL test size must be S or M." >&2; return 1 ;; esac
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    # Keep Bicep configuration and relative file paths tied to the source.
    test_harness=$(mktemp "$(dirname "$test_file")/rtc-postgres-test-XXXXXX.bicep") || return 1
    trap 'rm -f -- "$test_harness"' EXIT
    if ! bash "$script_dir/prepare-postgres-test-harness.sh" "$test_file" "$test_harness"; then
        return 1
    fi
    test_file="$test_harness"
    if [[ -z "$deadline" ]]; then deadline=$(( $(date +%s) + 1800 )); fi
    if [[ ! "$deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
        echo "Error: Invalid PostgreSQL test deadline." >&2
        return 1
    fi
    for attempt in 1 2; do
        if ((deadline <= $(date +%s))); then
            echo "Error: PostgreSQL deployment deadline has expired." >&2
            return 1
        fi
        status=0
        RTC_POSTGRES_CAPACITY_RECOVERY=1 RTC_POSTGRES_TEST_DEADLINE_EPOCH="$deadline" \
            rtc_deploy_and_assert_test_app "$test_file" Radius.Data/postgreSqlDatabases \
                "recipepacktest-pg-$size-$attempt" "$environment_path" "$workspace_name" "$kubernetes_namespace" \
                --parameters "postgresSize=$size" || status=$?
        if ((status == 0)); then return 0; fi
        if ((status != 42 || attempt == 2)); then
            echo "Error: PostgreSQL deployment failed (size $size, attempt $attempt, status $status)." >&2
            return 1
        fi
        if [[ "$size" == S ]]; then size=M; else size=S; fi
        echo "==> PostgreSQL capacity lost; cleanup confirmed. Retrying size $size in the same region."
    done
)

# Best-effort cleanup for fast-fail paths. The request timeout and non-blocking
# delete keep cleanup bounded when the cluster or resource controllers are unhealthy.
rtc_cleanup_kubernetes_resources_bounded() {
    local kubernetes_namespace="$1" app_name="$2" kind status=0
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace (bounded)"
    for kind in secrets deployments services; do
        if ! kubectl delete "$kind" \
            -l "radapp.io/application=$app_name" \
            -n "$kubernetes_namespace" \
            --request-timeout=10s \
            --wait=false; then
            echo "Error: Could not clean up $kind for '$app_name'." >&2
            status=1
        fi
    done
    return "$status"
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

rtc_save_azure_lock_diagnostics() {
    local locks_before="$1" locks_after="$2" inventory_locks="$3" app_name="$4"
    local root="${RTC_AZURE_DIAGNOSTICS_DIR:-}" directory
    if [[ "${GITHUB_ACTIONS:-}" == true && -z "${RTC_AZURE_DIAGNOSTICS_DIR+x}" ]]; then
        root="radius-pod-logs/azure-test-diagnostics"
    fi
    [[ -n "$root" ]] || return 0
    if ! mkdir -p "$root" || ! directory=$(mktemp -d "$root/lock-failure-XXXXXXXX"); then
        echo "Error: Could not create Azure lock diagnostic directory." >&2
        return 1
    fi
    # Save only the IDs, never the raw Radius inventory or recipe secrets.
    if ! jq -n --arg app "$app_name" --arg before "$locks_before" \
        --arg after "$locks_after" --arg inventory "$inventory_locks" '
        def ids: split("\n") | map(select(length > 0));
        {app: $app, azureLocksBefore: ($before | ids),
         azureLocksAfter: ($after | ids), radiusLockInventory: ($inventory | ids)}
    ' >"$directory/locks.json"; then
        echo "Error: Could not save Azure lock diagnostics." >&2
        return 1
    fi
    echo "==> Saved Azure lock inventory evidence to $directory/locks.json"
}

rtc_delete_owned_new_azure_management_locks() {
    local locks_before="$1" inventory_locks="$2" app_name="$3" locks_after lock_id delete_output status=0
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
        echo "Error: Unexpected Radius output resource: $lock_id" >&2
        echo "Error: Check Deployment Engine skipped-resource inventory; this is not evidence of a missing locks/delete permission." >&2
        status=1
    done < <(printf '%s\n' "$inventory_locks" | sed '/^$/d' | sort -u)

    if [[ "$status" -ne 0 ]]; then
        rtc_save_azure_lock_diagnostics "$locks_before" "$locks_after" "$inventory_locks" "$app_name" ||
            echo "Error: Azure lock diagnostic collection failed." >&2
    fi
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
# For secret stores, it creates the least-privilege access that the
# Radius.Dapr/secretStores README requires: `get` on the allowed test secret
# only, bound to the default ServiceAccount of the test containers.
rtc_assert_dapr_result() {
    local resource_type="$1" app_name="$2" kubernetes_namespace="$3" redis_deployment status=0
    local secret_reader="dapr-secret-reader-$app_name"
    if [[ -z "$kubernetes_namespace" ]]; then
        echo "Error: Dapr runtime assertion requires the environment Kubernetes namespace." >&2
        return 1
    fi
    if [[ "$resource_type" == Radius.Dapr/secretStores ]]; then
        if ! kubectl create role "$secret_reader" -n "$kubernetes_namespace" \
                --verb=get --resource=secrets --resource-name=dapr-allowed-secret ||
           ! kubectl create rolebinding "$secret_reader" -n "$kubernetes_namespace" \
                --role="$secret_reader" --serviceaccount="$kubernetes_namespace:default"; then
            echo "Error: Could not give the Dapr test client read access to the allowed secret." >&2
            rtc_delete_dapr_secret_reader "$kubernetes_namespace" "$secret_reader"
            return 1
        fi
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
        status=1
    fi
    if [[ "$resource_type" == Radius.Dapr/secretStores ]]; then
        rtc_delete_dapr_secret_reader "$kubernetes_namespace" "$secret_reader"
    fi
    [[ "$status" -eq 0 ]] && echo "==> Dapr runtime checks passed for $resource_type"
    return "$status"
}

rtc_delete_dapr_secret_reader() {
    local kubernetes_namespace="$1" secret_reader="$2"
    kubectl delete rolebinding,role "$secret_reader" -n "$kubernetes_namespace" --ignore-not-found ||
        echo "Warning: Could not delete Role and RoleBinding $secret_reader." >&2
}

# Resource-Type-specific post-deploy assertion dispatcher. A no-op (success)
# for every Resource Type without a dedicated assertion above -- for those,
# `rad deploy` succeeding (the test app's own readiness probes/waits included)
# is the test.
rtc_assert_recipe_result() {
    local resource_type="$1" app_name="$2" workspace_name="$3"
    case "$resource_type" in
        Radius.Data/mySqlDatabases|Radius.Data/redisCaches)
            local kubernetes_namespace="${4:-}"
            local client_resource=mysqlclient
            [[ "$resource_type" != Radius.Data/redisCaches ]] || client_resource=democontainer
            if [[ -z "$kubernetes_namespace" ]]; then
                echo "Error: $resource_type readiness assertion requires the environment Kubernetes namespace." >&2
                return 1
            fi
            # Wait for the client probe, not just a successful resource deployment.
            if ! kubectl wait deployment \
                -n "$kubernetes_namespace" \
                -l "radapp.io/application=$app_name,radapp.io/resource=$client_resource" \
                --for=condition=Available --timeout=180s; then
                echo "Error: $resource_type client readiness assertion failed." >&2
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

# CLI progress text can surround JSON errors; inspect each decoded object separately.
rtc_deployment_retry_reason() {
    python3 - "$1" "${2:-transient}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    transcript = log.read()
decoder = json.JSONDecoder()
quota_only = sys.argv[2] == "aci-quota"
aci_group = re.compile(
    r"/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.ContainerInstance/ngroups/[^/]+", re.I
)
provider_reset = re.compile(
    r'Failed to install provider\s+'
    r'Error while installing [\w./-]+ v[\w.+-]+:\s+'
    r'releases\.hashicorp\.com:\s+Get\s+'
    r'"https://releases\.hashicorp\.com/terraform-provider-[^"\s]+\.zip":\s+'
    r'read tcp [^\n]+: read: connection reset by peer\s*'
)
failure_prefix = re.compile(r"^\s*(?:error|fatal|failure|failed):", re.IGNORECASE | re.MULTILINE)
bare_failure = re.compile(
    r"^\s*(?:[A-Za-z_][A-Za-z0-9_.-]*|\([A-Za-z_][A-Za-z0-9_.-]*\))\s*:\s*\S"
    r"|^\s*(?i:unknown|unclassified|unexpected)\b.*\b(?i:error|failure)\b"
)
harmless_progress = re.compile(
    r"\s*(?:Location:\s*[a-z][a-z0-9-]*|Status:\s*(?:Running|Accepted|Succeeded)"
    r"|WARNING: Radius type compatibility is not verified\.)\s*"
)
harmless_quota_metadata = re.compile(r"TraceId: [0-9a-fA-F]{32}")
wrappers = {"DeploymentFailed", "RecipeDeploymentFailed", "ResourceDeploymentFailure", "ResourceOperationFailure"}
reasons = []
invalid = False

def objects(text):
    offset = 0
    while (offset := text.find("{", offset)) != -1:
        try:
            start = offset
            value, offset = decoder.raw_decode(text, offset)
            yield value, start, offset
        except ValueError:
            offset += 1

def is_provider_reset(message):
    preamble, marker, failure = message.partition("terraform init failure: exit status 1")
    if not marker:
        return False
    for line in preamble.splitlines():
        if (bare_failure.search(line) and not harmless_progress.fullmatch(line)) or (
            failure_prefix.search(line) and failure_prefix.sub("", line).strip()
        ):
            return False
    diagnostics = re.split(r'(?mi)^\s*Error:\s*', failure)
    return (
        not diagnostics[0].strip() and len(diagnostics) >= 2
        and all(provider_reset.fullmatch(item) for item in diagnostics[1:])
    )

def visit(value, failure_context=False, resource_target=""):
    global invalid
    if isinstance(value, list):
        for item in value:
            visit(item, failure_context, resource_target)
    elif isinstance(value, dict):
        before = len(reasons)
        code = value.get("code")
        message = value.get("message")
        target = value.get("target")
        if isinstance(target, str) and target.startswith("/"):
            resource_target = target
        status = value.get("status", "")
        is_failure = failure_context or (
            isinstance(status, str) and status.lower() in {"failed", "failure", "error"}
        )
        if code:
            if quota_only and code == "AzureContainerInstance/ContainerGroupQuotaReached":
                if aci_group.fullmatch(resource_target) and status not in {"Succeeded", "Running", "Accepted"}:
                    reasons.append("Azure Container Instance regional core quota reached")
                else:
                    invalid = True
            elif not quota_only and code == "AzureContainerInstance/ContainerGroupTransitioning":
                if (
                    re.fullmatch(
                        r"/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
                        r"Microsoft\.ContainerInstance/ngroups/[^/]+",
                        resource_target,
                        re.I,
                    )
                    and isinstance(message, str)
                    and '"ErrorCode": "AzureContainerInstance/ContainerGroupTransitioning"' in message
                    and "still transitioning, please retry later." in message
                ):
                    reasons.append("Azure Container Instance group is still transitioning")
                else:
                    invalid = True
            elif code not in wrappers:
                invalid = True
            elif not quota_only and code == "RecipeDeploymentFailed" and isinstance(message, str) and is_provider_reset(message):
                reasons.append("Terraform provider download connection reset")
            elif (
                code == "ResourceDeploymentFailure"
                and not quota_only
                and isinstance(message, str) and "Connection reset by peer" in message
                and isinstance(target, str)
                and re.match(r'/subscriptions/[^"]*/providers/Microsoft\.', target)
            ):
                reasons.append("Azure deployment connection reset")
        elif (
            quota_only
            and value.get("ErrorCode") == "AzureContainerInstance/ContainerGroupQuotaReached"
            and aci_group.fullmatch(resource_target)
            and isinstance(value.get("SampleErrorMessage"), str)
            and status not in {"Succeeded", "Running", "Accepted"}
        ):
            reasons.append("Azure Container Instance regional core quota reached")
        elif (
            not quota_only
            and value.get("ErrorCode") == "AzureContainerInstance/ContainerGroupTransitioning"
            and re.fullmatch(
                r"/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
                r"Microsoft\.ContainerInstance/ngroups/[^/]+",
                resource_target,
                re.I,
            )
            and isinstance(value.get("SampleErrorMessage"), str)
            and "still transitioning, please retry later." in value["SampleErrorMessage"]
        ):
            reasons.append("Azure Container Instance group is still transitioning")
        elif is_failure or (
            "message" in value and status not in {"Succeeded", "Running", "Accepted"}
        ):
            invalid = True
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                visit(
                    item,
                    is_failure or (code in wrappers and key in {"details", "error"}),
                    resource_target,
                )
        if isinstance(message, str):
            for item, _, _ in objects(message):
                visit(item, True, resource_target)
        if code in wrappers and len(reasons) == before:
            invalid = True
    elif failure_context:
        invalid = True

records = list(objects(transcript))
if not records:
    if not quota_only and is_provider_reset(transcript):
        reasons.append("Terraform provider download connection reset")
else:
    residual = list(transcript)
    for root, start, end in records:
        visit(root)
        residual[start:end] = ["\n" if char == "\n" else " " for char in transcript[start:end]]
    for line in "".join(residual).splitlines():
        if (bare_failure.search(line) and not (
            harmless_progress.fullmatch(line)
            or (quota_only and harmless_quota_metadata.fullmatch(line))
        )) or (
            failure_prefix.search(line) and failure_prefix.sub("", line).strip()
        ):
            invalid = True

if reasons and not invalid:
    print("; ".join(dict.fromkeys(reasons)))
    sys.exit(0)
sys.exit(1)
PY
}

rtc_save_deployment_error() {
    local transcript="$1" directory script_dir
    local diagnostics_root="${RTC_TEST_DIAGNOSTICS_DIR-${RTC_AZURE_DIAGNOSTICS_DIR:-}}"
    if [[ "${RTC_TEST_PLATFORM:-}" != azure || -z "$diagnostics_root" ]]; then
        return 0
    fi
    if ! command -v node >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        echo "Error: Deployment error capture requires Node.js and GNU timeout." >&2
        return 1
    fi
    if ! mkdir -p "$diagnostics_root" ||
       ! directory=$(mktemp -d "$diagnostics_root/deployment-error-XXXXXXXX"); then
        echo "Error: Could not create deployment error diagnostic directory." >&2
        return 1
    fi
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! timeout --kill-after=5s 5s node "$script_dir/collect-azure-test-diagnostics.js" \
        --deployment-error "$transcript" "$directory" "${AZURE_SUBSCRIPTION_ID:-}" "${AZURE_RESOURCE_GROUP:-}" \
        "${RTC_TEST_DIAGNOSTIC_APP:-}" "${RTC_TEST_DIAGNOSTIC_STARTED:-}"; then
        echo "Error: Deployment error capture incomplete; deployment status and cleanup are unchanged." >&2
        return 1
    fi
}

# Retry confirmed download or Azure transport failures without deleting partially
# deployed resources. Terraform init fails before apply; keep deployment arguments.
rtc_deploy_with_retry() (
    local deploy_log retry_reason attempt=1 max_attempts=3
    local -a pipeline_status
    deploy_log=$(mktemp "${TMPDIR:-/tmp}/rtc-deploy-XXXXXX") || return 1
    trap 'rm -f "$deploy_log"' EXIT
    set -o pipefail

    while true; do
        if rad deploy "$@" 2>&1 | tee "$deploy_log"; then
            return 0
        else
            pipeline_status=("${PIPESTATUS[@]}")
        fi

        rtc_save_deployment_error "$deploy_log" ||
            echo "Error: Could not save filtered deployment error evidence; continuing failure handling." >&2
        if [[ "${pipeline_status[1]}" -ne 0 ]]; then
            return 1
        fi
        # Only the classifier can return the quota recovery sentinel.
        if [[ "${RTC_ACI_QUOTA_RECOVERY:-0}" == 1 &&
              "${pipeline_status[0]}" != 124 && "${pipeline_status[0]}" != 137 ]] &&
            rtc_deployment_retry_reason "$deploy_log" aci-quota >/dev/null; then
            return 43
        fi
        if [[ "$attempt" -ge "$max_attempts" ]] ||
            ! retry_reason=$(rtc_deployment_retry_reason "$deploy_log"); then
            if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 &&
                  "${pipeline_status[0]}" != 124 && "${pipeline_status[0]}" != 137 ]]; then
                if rtc_has_postgresql_capacity_failure "$deploy_log"; then return 42; fi
                return 1
            fi
            if [[ "${RTC_ACI_QUOTA_RECOVERY:-0}" == 1 ]]; then return 1; fi
            return "${pipeline_status[0]}"
        fi

        echo "==> $retry_reason; retrying in $((attempt * 10)) seconds (attempt $((attempt + 1))/$max_attempts)"
        sleep "$((attempt * 10))" || return 1
        attempt=$((attempt + 1))
    done
)

rtc_collect_test_diagnostics() {
    local resource_type="$1" app_name="$2" started="$3" directory status script_dir dependency
    local diagnostics_root="${RTC_TEST_DIAGNOSTICS_DIR-${RTC_AZURE_DIAGNOSTICS_DIR:-}}"
    if [[ -z "$diagnostics_root" ]]; then
        return 0
    fi
    if ! mkdir -p "$diagnostics_root" ||
       ! directory=$(mktemp -d "$diagnostics_root/failure-XXXXXXXX"); then
        echo "Error: Could not create failure diagnostic directory." >&2
        return 1
    fi
    for dependency in node timeout; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "Error: Failure diagnostics require $dependency." | tee "$directory/collector-status.txt" >&2
            return 1
        fi
    done
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "==> Collecting failure diagnostics"
    if timeout --kill-after=5s 100s node "$script_dir/collect-azure-test-diagnostics.js" \
        "$directory" "${AZURE_SUBSCRIPTION_ID:-}" "${AZURE_RESOURCE_GROUP:-}" "$app_name" "$started" "$resource_type" "${RTC_TEST_PLATFORM:-kubernetes}"; then
        echo "Failure diagnostic collection completed." >"$directory/collector-status.txt"
    else
        status=$?
        echo "Error: Failure diagnostics incomplete (collector exit $status); test failure and cleanup are unchanged." |
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
# Usage: rtc_deploy_and_assert_test_app_once <test-file> <resource-type> \
#            <app-name-prefix> <environment-path> <workspace-name> \
#            <kubernetes-namespace> [additional rad deploy arguments...]
rtc_deploy_and_assert_test_app_once() {
    local test_file="$1" resource_type="$2" app_name_prefix="$3" environment_path="$4" workspace_name="$5" kubernetes_namespace="$6"
    local app_name started locks_before="" inventory_locks="" deploy_status=0 azure_before="" azure_after=""
    local step_remaining="" step_deadline="${RTC_AZURE_TEST_STEP_DEADLINE_EPOCH:-}" step_reserve=360
    local diagnostics_collected=0
    local -a params=() deploy_timeout=() cleanup_timeout=()
    local -a deploy_command=(rtc_deploy_with_retry)
    shift 6

    app_name="${app_name_prefix}-$(date +%s)"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        # Preserve the twelve-minute deletion budget plus diagnostics and verification.
        step_reserve=1080
    fi

    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ||
          ( "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure &&
            ( -n "$step_deadline" || "$resource_type" == Radius.Compute/containers ) ) ]]; then
        if ! command -v timeout >/dev/null 2>&1; then
            echo "Error: Azure test deadlines require GNU timeout." >&2
            rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                echo "Error: Diagnostic collection failed before deployment." >&2
            return 1
        fi
    fi

    if [[ "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure && -n "$step_deadline" ]]; then
        if [[ ! "$step_deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
            echo "Error: Invalid Azure test step deadline." >&2
            return 1
        fi
        step_remaining=$((step_deadline - $(date +%s) - step_reserve))
        if ((step_remaining <= 0)); then
            echo "Error: Azure test step budget exhausted before deployment; collecting diagnostics." >&2
            rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                echo "Error: Diagnostic collection failed before deployment." >&2
            return 1
        fi
    fi

    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 || "${RTC_ACI_QUOTA_RECOVERY:-0}" == 1 ]]; then
        app_name+="-$RANDOM"
        if ! azure_before=$(rtc_snapshot_azure_resource_ids); then
            echo "Error: Could not snapshot Azure resources before capacity recovery deployment." >&2
            return 1
        fi
        if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
            cleanup_timeout=(timeout --kill-after=5s 12m)
        else
            cleanup_timeout=(timeout --kill-after=5s 3m)
        fi
    elif [[ "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure ]] &&
        rtc_is_aci_test_target "$resource_type"; then
        deploy_timeout=(timeout --kill-after=5s 15m)
        # shellcheck disable=SC2016 # Expanded by the child shell.
        deploy_command=("${deploy_timeout[@]}" bash -c \
            'source "$1"; shift; rtc_deploy_with_retry "$@"' \
            bash "${BASH_SOURCE[0]}")
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
    if [[ "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure && -n "$step_deadline" ]]; then
        step_remaining=$((step_deadline - $(date +%s) - step_reserve))
        if ((step_remaining <= 0)); then
            echo "Error: Azure test step budget exhausted before deployment; collecting diagnostics." >&2
            rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                echo "Error: Diagnostic collection failed before deployment." >&2
            return 1
        fi
    fi
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        local deadline="${RTC_POSTGRES_TEST_DEADLINE_EPOCH:-}" remaining
        if [[ ! "$deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
            echo "Error: Invalid PostgreSQL test deadline." >&2
            return 1
        fi
        remaining=$((deadline - $(date +%s)))
        if ((remaining <= 0)); then
            echo "Error: PostgreSQL deployment deadline expired before allocation." >&2
            return 1
        fi
        if ((remaining > 900)); then remaining=900; fi
        deploy_timeout=(timeout --kill-after=5s "${remaining}s")
        # shellcheck disable=SC2016 # Expanded by the child shell.
        deploy_command=("${deploy_timeout[@]}" bash -c \
            'source "$1"; shift; rtc_deploy_with_retry "$@"' \
            bash "${BASH_SOURCE[0]}")
    fi
    if [[ -n "$step_remaining" ]]; then
        if rtc_is_aci_test_target "$resource_type" && ((step_remaining > 900)); then
            step_remaining=900
        fi
        if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]] && ((step_remaining > remaining)); then
            step_remaining="$remaining"
        fi
        deploy_timeout=(timeout --kill-after=5s "${step_remaining}s")
        # shellcheck disable=SC2016 # Expanded by the child shell.
        deploy_command=("${deploy_timeout[@]}" bash -c \
            'source "$1"; shift; rtc_deploy_with_retry "$@"' \
            bash "${BASH_SOURCE[0]}")
    fi
    if RTC_TEST_DIAGNOSTIC_APP="$app_name" RTC_TEST_DIAGNOSTIC_STARTED="$started" \
        "${deploy_command[@]}" "$test_file" --application "$app_name" --workspace "$workspace_name" -e "$environment_path" "${params[@]}" "$@"; then
        echo "==> Test deployment successful"

        local assertion_remaining="" assertion_status=0
        local -a assertion_command=(rtc_assert_recipe_result)
        if [[ -n "$step_remaining" ]]; then
            assertion_remaining=$((step_deadline - $(date +%s) - step_reserve))
            if ((assertion_remaining <= 0)); then
                echo "Error: Azure test step budget exhausted before assertions; collecting diagnostics." >&2
                deploy_status=1
            else
                # shellcheck disable=SC2016 # Expanded by the child shell.
                assertion_command=(timeout --kill-after=5s "${assertion_remaining}s" bash -c \
                    'source "$1"; shift; rtc_assert_recipe_result "$@"' \
                    bash "${BASH_SOURCE[0]}")
            fi
        fi
        if [[ "$deploy_status" == 0 ]]; then
            "${assertion_command[@]}" "$resource_type" "$app_name" "$workspace_name" "$kubernetes_namespace" || assertion_status=$?
            if [[ "$assertion_status" -ne 0 ]]; then
                deploy_status=1
                if [[ -n "$assertion_remaining" && ( "$assertion_status" == 124 || "$assertion_status" == 137 ) ]]; then
                    echo "Error: Azure test assertions exceeded the step budget; collecting diagnostics." >&2
                fi
            fi
        fi
    else
        deploy_status=$?
        echo "==> Test deployment failed"
        if [[ -n "${deploy_timeout[*]:-}" && ( "$deploy_status" == 124 || "$deploy_status" == 137 ) ]]; then
            if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
                echo "Error: PostgreSQL test deployment exceeded its time limit." >&2
            elif [[ -n "$step_remaining" ]]; then
                echo "Error: Azure test deployment exceeded its time limit; collecting diagnostics before the step deadline." >&2
            else
                echo "Error: Azure ACI-dependent test deployment exceeded its 15-minute limit." >&2
            fi
        fi
        if [[ "$deploy_status" != 42 && "$deploy_status" != 43 ]]; then deploy_status=1; fi
    fi

    if [[ "$deploy_status" -ne 0 ]]; then
        if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" != 1 &&
              ( -n "$step_remaining" || -n "${deploy_timeout[*]:-}" ) ]]; then
            cleanup_timeout=(timeout --kill-after=5s 3m)
        fi
        rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
            echo "Error: Diagnostic collection failed; continuing cleanup." >&2
        diagnostics_collected=1
    fi

    if [[ "${RTC_AZURE_LOCK_GUARD:-0}" == "1" ]]; then
        if ! inventory_locks=$(rtc_snapshot_application_azure_lock_inventory "$app_name" "$workspace_name"); then
            echo "Error: Continuing with bounded Radius application deletion without lock ownership data." >&2
            inventory_locks=""
            deploy_status=1
            cleanup_timeout=(timeout --kill-after=5s 3m)
            if [[ "$diagnostics_collected" == 0 ]]; then
                rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                    echo "Error: Diagnostic collection failed after lock inventory failure; continuing cleanup." >&2
                diagnostics_collected=1
            fi
        fi
        if ! rtc_delete_owned_new_azure_management_locks "$locks_before" "$inventory_locks" "$app_name"; then
            echo "Error: Skipping Radius application deletion because Azure lock cleanup or Radius lock inventory validation failed." >&2
            if [[ "$deploy_status" == 0 ]]; then
                rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                    echo "Error: Diagnostic collection failed after lock cleanup failure." >&2
            fi
            rtc_cleanup_kubernetes_resources_bounded "$kubernetes_namespace" "$app_name"
            return 1
        fi
    fi

    echo "==> Cleaning up test application"
    local cleanup_status=0
    if [[ "${RTC_ACI_QUOTA_RECOVERY:-0}" == 1 && -n "$step_deadline" ]]; then
        local cleanup_remaining=$((step_deadline - $(date +%s)))
        if ((cleanup_remaining > 720)); then cleanup_remaining=720; fi
        if ((cleanup_remaining <= 0)); then cleanup_remaining=1; fi
        cleanup_timeout=(timeout --kill-after=5s "${cleanup_remaining}s")
    fi
    if ! ${cleanup_timeout[@]+"${cleanup_timeout[@]}"} rad app delete "$app_name" --workspace "$workspace_name" --yes; then
        cleanup_status=1
        if [[ "$deploy_status" == 0 ]]; then
            rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                echo "Error: Diagnostic collection failed after application cleanup failure." >&2
            diagnostics_collected=1
        fi
    fi
    if [[ -n "$step_remaining" && "$deploy_status" -ne 0 && "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" != 1 ]]; then
        rtc_cleanup_kubernetes_resources_bounded "$kubernetes_namespace" "$app_name" || cleanup_status=1
    else
        rtc_cleanup_kubernetes_resources "$kubernetes_namespace" "$app_name" || cleanup_status=1
    fi
    if [[ "$cleanup_status" -ne 0 ]]; then
        echo "Error: Test app cleanup failed." >&2
        if [[ "$diagnostics_collected" == 0 ]]; then
            rtc_collect_test_diagnostics "$resource_type" "$app_name" "$started" ||
                echo "Error: Diagnostic collection failed after cleanup failure." >&2
        fi
        return 1
    fi
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 || "${RTC_ACI_QUOTA_RECOVERY:-0}" == 1 ]]; then
        if ! azure_after=$(rtc_snapshot_azure_resource_ids) ||
            [[ -n "$(comm -13 <(printf '%s\n' "$azure_before" | sed '/^$/d') \
                <(printf '%s\n' "$azure_after" | sed '/^$/d'))" ]]; then
            echo "Error: Azure resource deletion was not confirmed; capacity recovery is blocked." >&2
            return 1
        fi
    fi
    if [[ "$deploy_status" -ne 0 ]]; then
        return "$deploy_status"
    fi
    return "$cleanup_status"
}

rtc_is_aci_test_target() {
    [[ "$1" == Radius.Compute/containers || "$1" == Radius.AI/models ]]
}

rtc_test_azure_aci_app() (
    local deadline="$RTC_AZURE_TEST_STEP_DEADLINE_EPOCH" status attempt
    local -a test_args=("$@")
    for attempt in 1 2; do
        test_args[2]="$3-quota-$attempt"
        status=0
        rtc_deploy_and_assert_test_app_once "${test_args[@]}" || status=$?
        if ((status == 0)); then return 0; fi
        if ((status != 43)); then return 1; fi
        if ((attempt == 2 || deadline - $(date +%s) <= 420)); then
            echo "Error: ACI quota recovery exhausted; deployment was not validated." >&2
            return 1
        fi
        echo "==> ACI quota reached; resource deletion confirmed. Waiting 60 seconds before attempt 2/2."
        sleep 60 || return 1
    done
)

rtc_deploy_and_assert_test_app() {
    if [[ "${GITHUB_ACTIONS:-}" != true || "${RTC_TEST_PLATFORM:-}" != azure ]] ||
        ! rtc_is_aci_test_target "$2"; then
        rtc_deploy_and_assert_test_app_once "$@"
        return $?
    fi

    local deadline=$(( $(date +%s) + 1200 )) inherited="${RTC_AZURE_TEST_STEP_DEADLINE_EPOCH:-}"
    if [[ -n "$inherited" ]]; then
        if [[ ! "$inherited" =~ ^[1-9][0-9]{0,10}$ ]]; then
            echo "Error: Invalid Azure test step deadline." >&2
            return 1
        fi
        if ((inherited < deadline)); then deadline="$inherited"; fi
    fi
    local remaining=$((deadline - $(date +%s))) status
    if ((remaining <= 360)); then
        echo "Error: Insufficient Azure test budget for ACI deployment and cleanup." >&2
        return 1
    fi
    # shellcheck disable=SC2016 # Expanded by the child shell.
    if RTC_ACI_QUOTA_RECOVERY=1 RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$deadline" \
        timeout --kill-after=5s "${remaining}s" bash -c \
        'source "$1"; shift; rtc_test_azure_aci_app "$@"' bash "${BASH_SOURCE[0]}" "$@"; then
        return 0
    else
        status=$?
        if [[ "$status" == 124 || "$status" == 137 ]]; then
            echo "Error: ACI test deadline expired; deployment and cleanup were not validated." >&2
        fi
        return 1
    fi
}
