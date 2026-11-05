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
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-azure-postgres-test.sh"

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

# Unrelated tests keep their existing command behavior.
rtc_run_postgresql_test_command() {
    local limit="$1" deadline="$2" remaining
    shift 2
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" != 1 ]]; then
        "$@"
        return
    fi
    if [[ ! "$deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
        echo "Error: Invalid PostgreSQL command deadline." >&2
        return 1
    fi
    remaining=$((deadline - $(date +%s)))
    if ((remaining <= 0)); then
        echo "Error: PostgreSQL command deadline expired before $1." >&2
        return 124
    fi
    if ((limit > remaining)); then limit="$remaining"; fi
    rtc_run_command --timeout "$limit" "$@"
}

# Only delete leftovers labelled for this test app, not shared resources.
rtc_cleanup_kubernetes_resources() {
    local kubernetes_namespace="$1" app_name="$2" deadline="${3:-}" kind status=0
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace"
    for kind in secrets deployments services; do
        if ! rtc_run_postgresql_test_command 30 "$deadline" \
            kubectl delete "$kind" -l "radapp.io/application=$app_name" -n "$kubernetes_namespace"; then
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
    local deadline="${1:-}" inventory
    local -a subscription_args=()
    [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]] || subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    [[ -n "${AZURE_RESOURCE_GROUP:-}" ]] || {
        echo "Error: PostgreSQL cleanup requires AZURE_RESOURCE_GROUP." >&2
        return 1
    }
    inventory=$(rtc_run_postgresql_test_command 30 "$deadline" \
        az resource list --resource-group "$AZURE_RESOURCE_GROUP" \
        "${subscription_args[@]}" --output json) || return 1
    jq -er '
        if type == "array" and all(.[]; .id | type == "string" and startswith("/subscriptions/"))
        then map(.id | ascii_downcase) | unique | join("\n")
        else error("invalid Azure resource inventory") end
    ' <<<"$inventory"
}

rtc_postgresql_group_location() {
    local deadline="$1" location
    local -a subscription_args=()
    [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]] || subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]] ||
        ! location=$(RTC_POSTGRES_CAPACITY_RECOVERY=1 RTC_POSTGRES_TEST_DEADLINE_EPOCH="$deadline" \
            rtc_run_postgresql_test_command 30 "$deadline" az group show \
            --name "$AZURE_RESOURCE_GROUP" "${subscription_args[@]}" --query location --output tsv) ||
        [[ ! "$location" =~ ^[a-z0-9]+$ ]]; then
        echo "Error: Could not establish the fixed region for the PostgreSQL probe." >&2
        return 1
    fi
    printf '%s\n' "$location"
}

# Probe a tuple in the existing group's region, never a caller's location hint.
rtc_probe_azure_postgresql_size() {
    local size="$1" deadline="$2" remaining location cleanup_reserve
    local delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
    cleanup_reserve="$(rtc_postgres_cleanup_reserve_seconds)" || return 1
    if ! rtc_postgres_positive_limit "$delete_timeout" 900; then
        echo "Error: Invalid PostgreSQL probe cleanup reserve or delete timeout." >&2
        return 1
    fi
    location="$(rtc_postgresql_group_location "$deadline")" || return 1
    remaining=$((deadline - $(date +%s)))
    if ((remaining <= 0)); then
        echo "Error: PostgreSQL deadline has expired before the probe." >&2
        return 1
    fi
    if ((remaining > 900)); then remaining=900; fi
    AZURE_LOCATION="$location" RTC_POSTGRES_TEST_SIZE="$size" RTC_POSTGRES_PROBE_ATTEMPTS=1 \
        RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS="$remaining" \
        RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS="$delete_timeout" \
        RTC_POSTGRES_PROBE_CLEANUP_DEADLINE_EPOCH="$((deadline + cleanup_reserve))" \
        rtc_run_command --quiet "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/probe-azure-postgres-capacity.sh"
}

# Retry one untried size only when the shared helper confirms safe cleanup.
rtc_test_azure_postgresql_app() (
    local test_file="$1" environment_path="$2" workspace_name="$3" kubernetes_namespace="$4"
    local size="${RTC_POSTGRES_TEST_SIZE:-S}" deadline="${RTC_POSTGRES_TEST_DEADLINE_EPOCH:-}"
    local test_harness script_dir workspace_root invocation_id
    local interrupted_status=0
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    workspace_root="${GITHUB_WORKSPACE:-$(cd "$script_dir/../.." && pwd)}"
    workspace_root="$(cd "$workspace_root" && pwd)" || return 1
    test_harness=$(mktemp "$workspace_root/.rtc-postgres-test-XXXXXX.bicep") || return 1
    trap 'rm -f -- "$test_harness"' EXIT
    if ! bash "$script_dir/prepare-postgres-test-harness.sh" "$test_file" "$test_harness"; then
        return 1
    fi
    test_file="$test_harness"
    trap 'interrupted_status=130' INT
    trap 'interrupted_status=143' TERM
    ((interrupted_status == 0)) || return "$interrupted_status"
    if ! invocation_id="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"; then
        echo "Error: Could not generate a unique PostgreSQL test application name." >&2
        return 1
    fi
    local status attempt candidate alternate=""
    local size_list
    local -a allowed_sizes
    case "$size" in S|M) ;; *) echo "Error: PostgreSQL test size must be S or M." >&2; return 1 ;; esac
    size_list="$(rtc_postgres_normalize_test_sizes)" || return 1
    IFS=',' read -r -a allowed_sizes <<<"$size_list"
    if [[ ",$size_list," != *",$size,"* ]]; then
        echo "Error: Selected PostgreSQL size $size is excluded by the configured size list." >&2
        return 1
    fi
    if [[ -z "$deadline" ]]; then deadline=$(( $(date +%s) + 1800 )); fi
    if [[ ! "$deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
        echo "Error: Invalid PostgreSQL test deadline." >&2
        return 1
    fi
    if [[ "${RTC_POSTGRES_VERIFIED_SIZE:-}" != "$size" ||
        ! "${RTC_POSTGRES_VERIFIED_LOCATION:-}" =~ ^[a-z0-9]+$ ]]; then
        if ! rtc_probe_azure_postgresql_size "$size" "$deadline"; then
            ((interrupted_status == 0)) || return "$interrupted_status"
            echo "Error: Initial PostgreSQL probe failed; deployment is not allowed." >&2
            return 1
        fi
    else
        local location
        location="$(rtc_postgresql_group_location "$deadline")" || return 1
        if [[ "$location" != "$RTC_POSTGRES_VERIFIED_LOCATION" ]]; then
            echo "Error: Verified PostgreSQL region differs from the existing resource group; deployment is blocked." >&2
            return 1
        fi
    fi
    for attempt in 1 2; do
        ((interrupted_status == 0)) || return "$interrupted_status"
        if ((deadline <= $(date +%s))); then
            echo "Error: PostgreSQL deployment deadline has expired." >&2
            return 1
        fi
        status=0
        RTC_POSTGRES_CAPACITY_RECOVERY=1 RTC_POSTGRES_TEST_DEADLINE_EPOCH="$deadline" \
            rtc_deploy_and_assert_test_app "$test_file" Radius.Data/postgreSqlDatabases \
                "rtcpg-$invocation_id-$size-$attempt" "$environment_path" "$workspace_name" "$kubernetes_namespace" \
                --parameters "postgresSize=$size" || status=$?
        ((interrupted_status == 0)) || return "$interrupted_status"
        if ((status == 0)); then return 0; fi
        if ((status != 42 || attempt == 2)); then
            echo "Error: PostgreSQL deployment failed (size $size, attempt $attempt, status $status)." >&2
            return 1
        fi
        for candidate in "${allowed_sizes[@]}"; do
            if [[ "$candidate" != "$size" ]]; then alternate="$candidate"; break; fi
        done
        if [[ -z "$alternate" ]]; then
            echo "Error: PostgreSQL capacity lost; no alternate size is allowed." >&2
            return 1
        fi
        echo "==> PostgreSQL capacity lost; cleanup confirmed. Probing allowed size $alternate in the same region."
        if ! rtc_probe_azure_postgresql_size "$alternate" "$deadline"; then
            echo "Error: Alternate PostgreSQL probe failed; no deployment retry is allowed." >&2
            return 1
        fi
        size="$alternate"
    done
)

# Best-effort cleanup for fast-fail paths. The request timeout and non-blocking
# delete keep cleanup bounded when the cluster or resource controllers are unhealthy.
rtc_cleanup_kubernetes_resources_bounded() {
    local kubernetes_namespace="$1" app_name="$2" deadline="${3:-}" kind
    if [[ -z "$kubernetes_namespace" ]]; then
        return
    fi

    echo "==> Cleaning up leftover K8s resources for $app_name in $kubernetes_namespace (bounded)"
    for kind in secrets deployments services; do
        rtc_run_postgresql_test_command 30 "$deadline" kubectl delete "$kind" \
            -l "radapp.io/application=$app_name" \
            -n "$kubernetes_namespace" \
            --request-timeout=10s \
            --wait=false ||
            echo "Error: Could not clean up $kind for '$app_name'." >&2
    done
}

rtc_snapshot_azure_management_locks() {
    local deadline="${1:-}"
    local -a subscription_args=()
    if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]]; then
        echo "Error: AZURE_RESOURCE_GROUP is required for the Azure management lock guard." >&2
        return 1
    fi
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    fi

    rtc_run_postgresql_test_command 30 "$deadline" az lock list \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        "${subscription_args[@]}" \
        --query '[].id' \
        --output tsv | sort -u
}

rtc_snapshot_application_azure_lock_inventory() {
    local app_name="$1" workspace_name="$2" deadline="${3:-}" resources_json
    if ! resources_json=$(rtc_run_postgresql_test_command 30 "$deadline" rad resource list \
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
    local locks_before="$1" inventory_locks="$2" app_name="$3" deadline="${4:-}"
    local locks_after lock_id delete_output status=0
    local -a subscription_args=()
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
    fi
    if ! locks_after=$(rtc_snapshot_azure_management_locks "$deadline"); then
        echo "Error: Could not inspect Azure management locks after the Recipe Pack entry test." >&2
        return 1
    fi

    while IFS= read -r lock_id; do
        [[ -z "$lock_id" ]] && continue
        if ! grep -Fxiq -- "$lock_id" <<<"$inventory_locks"; then
            echo "==> Ignoring new Azure management lock outside the test application: $lock_id"
            continue
        fi
        if delete_output=$(rtc_run_postgresql_test_command 30 "$deadline" \
            az lock delete --ids "$lock_id" "${subscription_args[@]}" 2>&1); then
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
    local app_name="$1" workspace_name="$2" deadline="${3:-}" resource_json
    if ! resource_json=$(rtc_run_postgresql_test_command 30 "$deadline" \
        rad resource show "Radius.Data/postgreSqlDatabases" postgresql \
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
    local resource_type="$1" app_name="$2" workspace_name="$3" deadline="${5:-}"
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
            rtc_assert_postgresql_result "$app_name" "$workspace_name" "$deadline"
            ;;
        *)
            return 0
            ;;
    esac
}

# CLI progress text can surround JSON errors; inspect each decoded object separately.
rtc_deployment_retry_reason() {
    python3 - "$1" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    transcript = log.read()
decoder = json.JSONDecoder()
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

def visit(value, failure_context=False):
    global invalid
    if isinstance(value, list):
        for item in value:
            visit(item, failure_context)
    elif isinstance(value, dict):
        before = len(reasons)
        code = value.get("code")
        message = value.get("message")
        target = value.get("target")
        status = value.get("status", "")
        is_failure = failure_context or (
            isinstance(status, str) and status.lower() in {"failed", "failure", "error"}
        )
        if code:
            if code not in wrappers:
                invalid = True
            elif code == "RecipeDeploymentFailed" and isinstance(message, str) and is_provider_reset(message):
                reasons.append("Terraform provider download connection reset")
            elif (
                code == "ResourceDeploymentFailure"
                and isinstance(message, str) and "Connection reset by peer" in message
                and isinstance(target, str)
                and re.match(r'/subscriptions/[^"]*/providers/Microsoft\.', target)
            ):
                reasons.append("Azure deployment connection reset")
        elif is_failure or (
            "message" in value and status not in {"Succeeded", "Running", "Accepted"}
        ):
            invalid = True
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                visit(item, is_failure or (code in wrappers and key in {"details", "error"}))
        if isinstance(message, str):
            for item, _, _ in objects(message):
                visit(item, True)
        if code in wrappers and len(reasons) == before:
            invalid = True
    elif failure_context:
        invalid = True

records = list(objects(transcript))
if not records:
    if is_provider_reset(transcript):
        reasons.append("Terraform provider download connection reset")
else:
    residual = list(transcript)
    for root, start, end in records:
        visit(root)
        residual[start:end] = ["\n" if char == "\n" else " " for char in transcript[start:end]]
    for line in "".join(residual).splitlines():
        if (bare_failure.search(line) and not harmless_progress.fullmatch(line)) or (
            failure_prefix.search(line) and failure_prefix.sub("", line).strip()
        ):
            invalid = True

if reasons and not invalid:
    print("; ".join(dict.fromkeys(reasons)))
    sys.exit(0)
sys.exit(1)
PY
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

        if [[ "${pipeline_status[1]}" -ne 0 ]]; then
            return 1
        fi
        if [[ "$attempt" -ge "$max_attempts" ]] ||
            ! retry_reason=$(rtc_deployment_retry_reason "$deploy_log"); then
            if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 &&
                  "${pipeline_status[0]}" != 124 && "${pipeline_status[0]}" != 137 ]]; then
                if rtc_has_postgresql_capacity_failure "$deploy_log"; then return 42; fi
                return 1
            fi
            return "${pipeline_status[0]}"
        fi

        echo "==> $retry_reason; retrying in $((attempt * 10)) seconds (attempt $((attempt + 1))/$max_attempts)"
        sleep "$((attempt * 10))" || return 1
        attempt=$((attempt + 1))
    done
)

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
    local app_name started locks_before="" inventory_locks="" deploy_status=0 azure_before="" azure_after=""
    local postgres_work_deadline="" postgres_cleanup_deadline="" postgres_cleanup_reserve
    local -a params=() deploy_timeout=() cleanup_timeout=()
    local -a deploy_command=(rtc_deploy_with_retry)
    shift 6

    app_name="${app_name_prefix}-$(date +%s)"

    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        postgres_cleanup_reserve="$(rtc_postgres_cleanup_reserve_seconds)" || return 1
        postgres_work_deadline="${RTC_POSTGRES_TEST_DEADLINE_EPOCH:-}"
        if [[ ! "$postgres_work_deadline" =~ ^[1-9][0-9]{0,10}$ ]]; then
            echo "Error: Invalid PostgreSQL test deadline." >&2
            return 1
        fi
        postgres_cleanup_deadline=$((postgres_work_deadline + postgres_cleanup_reserve))
        app_name+="-$RANDOM"
        if ! azure_before=$(rtc_snapshot_azure_resource_ids "$postgres_work_deadline"); then
            echo "Error: Could not snapshot Azure resources before PostgreSQL deployment." >&2
            return 1
        fi
        cleanup_timeout=(rtc_run_postgresql_test_command 720 "$postgres_cleanup_deadline")
    elif [[ "${GITHUB_ACTIONS:-}" == true && "${RTC_TEST_PLATFORM:-}" == azure &&
          "$resource_type" == Radius.Compute/containers ]]; then
        if ! command -v timeout >/dev/null 2>&1; then
            echo "Error: Azure container CI tests require GNU timeout." >&2
            return 1
        fi
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
        if ! locks_before=$(rtc_snapshot_azure_management_locks "$postgres_work_deadline"); then
            echo "Error: Could not inspect Azure management locks before the Recipe Pack entry test." >&2
            return 1
        fi
    fi

    echo "==> Deploying test application from $test_file"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        local remaining
        remaining=$((postgres_work_deadline - $(date +%s)))
        if ((remaining <= 0)); then
            echo "Error: PostgreSQL deployment deadline expired before allocation." >&2
            return 1
        fi
        if ((remaining > 900)); then remaining=900; fi
        deploy_timeout=(rtc_run_postgresql_test_command "$remaining" "$postgres_work_deadline")
        # shellcheck disable=SC2016 # Expanded by the child shell.
        deploy_command=("${deploy_timeout[@]}" bash -c \
            'source "$1"; shift; rtc_deploy_with_retry "$@"' \
            bash "${BASH_SOURCE[0]}")
    fi
    if "${deploy_command[@]}" "$test_file" --application "$app_name" --workspace "$workspace_name" -e "$environment_path" "${params[@]}" "$@"; then
        echo "==> Test deployment successful"

        if ! rtc_assert_recipe_result "$resource_type" "$app_name" "$workspace_name" \
            "$kubernetes_namespace" "$postgres_work_deadline"; then
            deploy_status=1
        fi
    else
        deploy_status=$?
        echo "==> Test deployment failed"
        if [[ -n "${deploy_timeout[*]:-}" && ( "$deploy_status" == 124 || "$deploy_status" == 137 ) ]]; then
            if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
                echo "Error: PostgreSQL test deployment exceeded its time limit." >&2
            else
                echo "Error: Azure container test deployment exceeded its 15-minute limit." >&2
            fi
        fi
        if [[ "$deploy_status" != 42 && "$deploy_status" != 130 && "$deploy_status" != 143 ]]; then
            deploy_status=1
        fi
    fi

    if [[ "$deploy_status" -ne 0 ]]; then
        if [[ -n "${deploy_timeout[*]:-}" && "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" != 1 ]]; then
            cleanup_timeout=(timeout --kill-after=5s 3m)
        fi
        rtc_collect_azure_test_diagnostics "$resource_type" "$app_name" "$started" ||
            echo "Error: Azure diagnostic collection failed; continuing cleanup." >&2
    fi

    if [[ "${RTC_AZURE_LOCK_GUARD:-0}" == "1" ]]; then
        if ! inventory_locks=$(rtc_snapshot_application_azure_lock_inventory \
            "$app_name" "$workspace_name" "$postgres_cleanup_deadline"); then
            echo "Error: Continuing with bounded Radius application deletion without lock ownership data." >&2
            inventory_locks=""
            if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then deploy_status=1; fi
        fi
        if ! rtc_delete_owned_new_azure_management_locks \
            "$locks_before" "$inventory_locks" "$app_name" "$postgres_cleanup_deadline"; then
            echo "Error: Skipping Radius application deletion because Azure lock cleanup or Radius lock inventory validation failed." >&2
            rtc_cleanup_kubernetes_resources_bounded \
                "$kubernetes_namespace" "$app_name" "$postgres_cleanup_deadline"
            return 1
        fi
    fi

    echo "==> Cleaning up test application"
    local cleanup_status=0
    ${cleanup_timeout[@]+"${cleanup_timeout[@]}"} rad app delete "$app_name" --workspace "$workspace_name" --yes || cleanup_status=1
    rtc_cleanup_kubernetes_resources \
        "$kubernetes_namespace" "$app_name" "$postgres_cleanup_deadline" || cleanup_status=1
    if [[ "$cleanup_status" -ne 0 ]]; then
        echo "Error: Test app cleanup failed." >&2
        return 1
    fi
    if [[ "${RTC_POSTGRES_CAPACITY_RECOVERY:-0}" == 1 ]]; then
        if ! azure_after=$(rtc_snapshot_azure_resource_ids "$postgres_cleanup_deadline") ||
            [[ -n "$(comm -13 <(printf '%s\n' "$azure_before" | sed '/^$/d') \
                <(printf '%s\n' "$azure_after" | sed '/^$/d'))" ]]; then
            echo "Error: PostgreSQL Azure resource deletion was not confirmed; recovery is blocked." >&2
            return 1
        fi
    fi
    if [[ "$deploy_status" -ne 0 ]]; then
        return "$deploy_status"
    fi
    return "$cleanup_status"
}
