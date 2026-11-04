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

# Probe the azure-aks PostgreSQL test tuple; this does not reserve capacity.
# Required: AZURE_RESOURCE_GROUP, AZURE_LOCATION.
# RTC_POSTGRES_TEST_SIZE defaults to S (S or M only).
# Standalone retries: RTC_POSTGRES_PROBE_ATTEMPTS=3 (max 3),
# RTC_POSTGRES_PROBE_WAIT_SECONDS=600 (0..600). Selection uses one attempt.
# Create/delete limits: RTC_POSTGRES_PROBE_{CREATE,DELETE}_TIMEOUT_SECONDS=900
# (1..900 each). Cleanup has its own time reserve.
# Optional RTC_POSTGRES_PROBE_RESULT_FILE receives a credential-free JSON record.
# Exit: 0 available, 1 other/cleanup error, 2 capacity exhausted, 3 create timeout,
# 4 verified unsupported tuple.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$script_dir/lib-azure-postgres-test.sh"

# Keep login notices and mask commands outside captured provider diagnostics.
exec 3>&2
export RTC_AZURE_LOGIN_LOG_FD=3
resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
attempts="${RTC_POSTGRES_PROBE_ATTEMPTS-3}"
wait_seconds="${RTC_POSTGRES_PROBE_WAIT_SECONDS-600}"
create_timeout="${RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS-900}"
delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
cleanup_deadline_epoch="${RTC_POSTGRES_PROBE_CLEANUP_DEADLINE_EPOCH:-}"
rtc_postgres_test_tuple "${RTC_POSTGRES_TEST_SIZE-S}" || exit 1
if [[ -z "$resource_group" || ! "$location" =~ ^[a-z0-9]+$ ]] ||
    ! rtc_postgres_positive_limit "$attempts" 3 ||
    ! rtc_postgres_positive_limit "$create_timeout" 900 ||
    ! rtc_postgres_positive_limit "$delete_timeout" 900 ||
    [[ ! "$wait_seconds" =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((10#$wait_seconds > 600)) ||
    { [[ -n "$cleanup_deadline_epoch" ]] && [[ ! "$cleanup_deadline_epoch" =~ ^[1-9][0-9]{0,10}$ ]]; }; then
    echo "Error: invalid probe environment or time/attempt limit." >&2
    exit 1
fi

subscription_args=()
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-probe-XXXXXX")"
server_name=""
probe_owner=""
create_in_flight=false
create_status=0
outcome="probe_error"
error_code="UnknownError"
cleanup_result="not_required"
create_uncertain=false
first_error_stage=""
first_error_status=""
first_error_code=""
diagnostic_stage=""
diagnostic_status=""
diagnostic_error_code=""
diagnostic_outcome_before_cleanup=""
diagnostic_code_before_cleanup=""

report_uncertain_create() {
    echo "Error: create request timed out or was interrupted for probe server '$server_name' in resource group '$resource_group' (ownership tag rtc-probe-owner=$probe_owner)." >&2
    echo "A current ResourceNotFound response does not rule out later creation. Check this target again and verify its ownership tag before deletion." >&2
}

record_first_error() {
    local stage="$1" status="$2" codes="${3:-none}"
    [[ -n "$codes" ]] || codes="none"
    if [[ -z "$first_error_stage" ]]; then
        first_error_stage="$stage"
        first_error_status="$status"
        first_error_code="$codes"
    fi
}

report_probe_error() {
    local stage="$1" status="$2" codes="${3:-none}"
    [[ -n "$codes" ]] || codes="none"
    codes="${codes//$'\n'/,}"
    record_first_error "$stage" "$status" "$codes"
    diagnostic_stage="$stage"
    diagnostic_status="$status"
    diagnostic_error_code="$codes"
    printf 'Error: probe stage=%s exit_status=%s error_codes=%s\n' "$stage" "$status" "$codes" >&2
}

report_cleanup_failure() {
    local stage="$1" status="$2" codes="${3:-none}" prior_code="${error_code:-none}"
    [[ -n "$codes" ]] || codes="none"
    codes="${codes//$'\n'/,}"
    prior_code="${prior_code//$'\n'/,}"
    diagnostic_stage="$stage"
    diagnostic_status="$status"
    diagnostic_error_code="$codes"
    diagnostic_outcome_before_cleanup="$outcome"
    diagnostic_code_before_cleanup="$prior_code"
    printf 'Error: cleanup stage=%s exit_status=%s error_codes=%s first_error_stage=%s first_error_status=%s first_error_code=%s outcome_before_cleanup=%s error_code_before_cleanup=%s\n' \
        "$stage" "$status" "$codes" "${first_error_stage:-none}" "${first_error_status:-none}" \
        "${first_error_code:-none}" "$outcome" "$prior_code" >&2
}

delete_server() {
    local status=0 remaining cleanup_deadline codes cleanup_limit="$delete_timeout"
    if [[ -n "$cleanup_deadline_epoch" ]]; then
        remaining=$((cleanup_deadline_epoch - $(date +%s)))
        if ((remaining <= 0)); then
            report_cleanup_failure deadline 124
            return 1
        fi
        if ((remaining < cleanup_limit)); then cleanup_limit="$remaining"; fi
    fi
    cleanup_deadline=$((SECONDS + cleanup_limit))
    rtc_run_command --timeout "$cleanup_limit" --quiet --stdout "$work_dir/server" \
        --stderr "$work_dir/show-error" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --only-show-errors --output json || status=$?
    if ((status != 0)); then
        codes="$(rtc_postgres_error_codes "$work_dir/show-error")"
        if ((status != 124 && status != 130 && status != 137 && status != 143)) &&
            [[ "$codes" == "ResourceNotFound" ]]; then
            # Bash 5.2 bare return can restore the failure from before an EXIT trap.
            return 0
        fi
        report_cleanup_failure show "$status" "$codes"
        return 1
    fi
    if [[ -s "$work_dir/show-error" ]]; then
        codes="$(rtc_postgres_error_codes "$work_dir/show-error")"
        report_cleanup_failure show "$status" "$codes"
        return 1
    fi
    if ! jq -e --arg owner "$probe_owner" '.tags["rtc-probe-owner"] == $owner' \
        "$work_dir/server" >/dev/null 2>&1; then
        report_cleanup_failure show "$status" OwnershipUnconfirmed
        echo "Error: ownership of probe server '$server_name' was not confirmed; refusing deletion." >&2
        return 1
    fi
    remaining=$((cleanup_deadline - SECONDS))
    if ((remaining <= 0)); then
        report_cleanup_failure deadline 124
        return 1
    fi
    rtc_run_command --timeout "$remaining" --quiet --stdout /dev/null \
        --stderr "$work_dir/delete-error" az postgres flexible-server delete \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --yes --only-show-errors --output none || status=$?
    codes="$(rtc_postgres_error_codes "$work_dir/delete-error")"
    if ((status != 0)); then
        if ((status == 124 || status == 130 || status == 137 || status == 143)); then
            report_cleanup_failure delete "$status" "$codes"
            return 1
        fi
        if [[ "$codes" != "ResourceNotFound" ]]; then
            report_cleanup_failure delete "$status" "$codes"
            return 1
        fi
    elif [[ -s "$work_dir/delete-error" ]]; then
        report_cleanup_failure delete "$status" "$codes"
        return 1
    fi
    remaining=$((cleanup_deadline - SECONDS))
    if ((remaining <= 0)); then
        report_cleanup_failure deadline 124
        return 1
    fi
    status=0
    rtc_run_command --timeout "$remaining" --quiet --stdout /dev/null \
        --stderr "$work_dir/show-error" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --only-show-errors --output none || status=$?
    codes="$(rtc_postgres_error_codes "$work_dir/show-error")"
    if ((status != 0 && status != 124 && status != 130 && status != 137 && status != 143)) &&
        [[ "$codes" == "ResourceNotFound" ]]; then
        return 0
    fi
    report_cleanup_failure confirm "$status" "$codes"
    return 1
}

# Invoked by the EXIT trap, including after an interrupt.
# shellcheck disable=SC2329
finish() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$create_in_flight" == true ]]; then
        create_uncertain=true
        report_uncertain_create
        outcome="probe_error"; error_code="CreateInterrupted"; status=1
        if [[ -z "$first_error_stage" ]]; then report_probe_error create "$create_status"; fi
    fi
    if [[ -n "$server_name" ]] && ! delete_server; then
        cleanup_result="failed"
        echo "Error: probe server '$server_name' deletion was not confirmed." >&2
        outcome="probe_error"; error_code="CleanupFailed"; status=1
    elif [[ -n "$server_name" && "$create_uncertain" == false ]]; then
        cleanup_result="confirmed"
    fi
    if [[ -n "${RTC_POSTGRES_PROBE_RESULT_FILE:-}" ]]; then
        jq -n --arg outcome "$outcome" --arg errorCode "$error_code" --arg cleanup "$cleanup_result" \
            --arg diagnosticStage "$diagnostic_stage" --arg diagnosticStatus "$diagnostic_status" \
            --arg diagnosticErrorCode "$diagnostic_error_code" \
            --arg outcomeBeforeCleanup "$diagnostic_outcome_before_cleanup" \
            --arg errorCodeBeforeCleanup "$diagnostic_code_before_cleanup" \
            --arg firstErrorStage "$first_error_stage" --arg firstErrorStatus "$first_error_status" \
            --arg firstErrorCode "$first_error_code" '
            {outcome: $outcome, errorCode: $errorCode, cleanup: $cleanup}
            + (if $diagnosticStage == "" then {} else
                {diagnostic: {
                    stage: $diagnosticStage,
                    exitStatus: ($diagnosticStatus | tonumber),
                    errorCode: $diagnosticErrorCode,
                    firstError: (if $firstErrorStage == "" then null else {
                        stage: $firstErrorStage,
                        exitStatus: ($firstErrorStatus | tonumber),
                        errorCode: $firstErrorCode
                    } end),
                    outcomeBeforeCleanup: (if $outcomeBeforeCleanup == "" then null else $outcomeBeforeCleanup end),
                    errorCodeBeforeCleanup: (if $errorCodeBeforeCleanup == "" then null else $errorCodeBeforeCleanup end)
                }}
            end)' >"$RTC_POSTGRES_PROBE_RESULT_FILE" || status=1
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
# shellcheck disable=SC2329
handle_probe_signal() {
    local signal="$1" status codes=""
    if [[ "$signal" == INT ]]; then status=130; else status=143; fi
    if [[ "$create_in_flight" == true ]]; then
        create_status="$status"
        codes="$(rtc_postgres_error_codes "$work_dir/create-error")"
        outcome="probe_error"; error_code="CreateInterrupted"
        report_probe_error create "$status" "$codes"
    fi
    exit "$status"
}
trap finish EXIT
trap 'handle_probe_signal INT' INT
trap 'handle_probe_signal TERM' TERM

# Azure CLI renamed these switches. Read local help, not a cloud capability list.
# Charge the full remaining create/selection budget to this check.
help_started=$SECONDS
help_timeout="$create_timeout"
help_status=0
rtc_run_command --timeout "$help_timeout" --quiet --stdout "$work_dir/create-help" \
    --stderr /dev/null az postgres flexible-server create --help || help_status=$?
help_elapsed=$((SECONDS - help_started))
if ((help_status == 124 || help_status == 137)) && ((help_elapsed >= help_timeout)); then
    outcome="timeout"; error_code="CreateTimeout"
    echo "Error: PostgreSQL probe timed out while reading CLI options." >&2
    exit 3
fi
if ((help_status != 0)); then
    error_code="AzureCliHelpFailed"
    echo "Error: could not read Azure CLI PostgreSQL create options." >&2
    exit 1
fi
if grep -q -- '--zonal-resiliency' "$work_dir/create-help"; then
    ha_option="--zonal-resiliency"
elif grep -q -- '--high-availability' "$work_dir/create-help"; then
    ha_option="--high-availability"
else
    error_code="UnsupportedAzureCli"
    echo "Error: Azure CLI has no supported PostgreSQL HA option." >&2
    exit 1
fi
if grep -q -- '--microsoft-entra-auth' "$work_dir/create-help"; then
    auth_option="--microsoft-entra-auth"
elif grep -q -- '--active-directory-auth' "$work_dir/create-help"; then
    auth_option="--active-directory-auth"
else
    error_code="UnsupportedAzureCli"
    echo "Error: Azure CLI has no supported PostgreSQL Entra authentication option." >&2
    exit 1
fi
first_create_timeout=$((create_timeout - (SECONDS - help_started)))
if ((first_create_timeout <= 0)); then
    outcome="timeout"; error_code="CreateTimeout"
    echo "Error: PostgreSQL probe used its create budget while reading CLI options." >&2
    exit 3
fi
catalog_status=0
rtc_run_command --timeout "$first_create_timeout" --quiet --stdout "$work_dir/catalog" \
    --stderr "$work_dir/catalog-error" az postgres flexible-server list-skus \
    "${subscription_args[@]}" --location "$location" --only-show-errors --output json \
    || catalog_status=$?
if ((catalog_status == 124 || catalog_status == 137)); then
    outcome="timeout"; error_code="CreateTimeout"
    echo "Error: PostgreSQL capability discovery exceeded the create budget." >&2
    exit 3
elif ((catalog_status != 0)) || [[ -s "$work_dir/catalog-error" ]]; then
    error_code="CatalogReadFailed"
    echo "Error: PostgreSQL capability discovery failed; refusing allocation." >&2
    exit 1
fi
error_code="$(rtc_postgres_catalog_result "$work_dir/catalog" "$postgres_tier" "$postgres_sku")"
if [[ -n "$error_code" ]]; then
    echo "Error: PostgreSQL capability check failed: $error_code." >&2
    case "$error_code" in
        UnsupportedVersion|UnsupportedTier|UnsupportedSku|UnsupportedStorage) outcome="unsupported"; exit 4 ;;
        *) exit 1 ;;
    esac
fi
error_code="UnknownError"
for ((attempt = 1; attempt <= attempts; attempt++)); do
    create_deadline=$((SECONDS + create_timeout))
    if ((attempt == 1)); then create_deadline=$((help_started + create_timeout)); fi
    probe_owner="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    candidate_name="pgprobe-$probe_owner"
    limit=$((create_deadline - SECONDS))
    if ((limit <= 0)); then
        outcome="timeout"; error_code="CreateTimeout"
        echo "Error: PostgreSQL probe used its create budget before the absence check." >&2
        exit 3
    fi
    status=0
    rtc_run_command --timeout "$limit" --quiet --stdout /dev/null \
        --stderr "$work_dir/precreate-error" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$candidate_name" \
        --only-show-errors --output json || status=$?
    codes="$(rtc_postgres_error_codes "$work_dir/precreate-error")"
    if ((status == 0)); then
        error_code="ServerAlreadyExists"
        report_probe_error "pre-create read" "$status" "$error_code"
        echo "Error: probe server name '$candidate_name' already exists; refusing creation." >&2
        exit 1
    elif ((status == 124 || status == 137)); then
        outcome="timeout"; error_code="CreateTimeout"
        report_probe_error "pre-create read" "$status" "$codes"
        echo "Error: PostgreSQL probe server absence check timed out." >&2
        exit 3
    elif ((status == 130 || status == 143)) || [[ "$codes" != "ResourceNotFound" ]]; then
        error_code="ServerAbsenceUnknown"
        report_probe_error "pre-create read" "$status" "$codes"
        echo "Error: probe server absence was not confirmed; refusing creation." >&2
        exit 1
    fi
    limit=$((create_deadline - SECONDS))
    if ((limit <= 0)); then
        outcome="timeout"; error_code="CreateTimeout"
        echo "Error: PostgreSQL probe used its create budget during the absence check." >&2
        exit 3
    fi
    server_name="$candidate_name"
    cleanup_result="uncertain"
    password="P$(openssl rand -hex 16)a1!"
    echo "==> PostgreSQL probe $attempt/$attempts: $postgres_sku ($postgres_tier) in $location" >&2
    echo "==> Recovery target: probe server '$server_name' in resource group '$resource_group' (ownership tag rtc-probe-owner=$probe_owner). Verify this tag before any later deletion." >&2
    status=0
    # None enables public networking without a firewall rule. It does not disable
    # TLS. Leave zone unset for automatic placement, as in the pack.
    create_in_flight=true
    rtc_run_command --timeout "$limit" --quiet --stdout /dev/null \
        --stderr "$work_dir/create-error" az postgres flexible-server create \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --location "$location" --tier "$postgres_tier" --sku-name "$postgres_sku" \
        --storage-size 32 --version 16 "$ha_option" Disabled \
        --geo-redundant-backup Disabled "$auth_option" Enabled --password-auth Enabled \
        --public-access None --admin-user probeadmin --admin-password "$password" \
        --tags "rtc-probe-owner=$probe_owner" \
        --yes --only-show-errors --output none || status=$?
    create_status="$status"
    unset password
    codes="$(rtc_postgres_error_codes "$work_dir/create-error")"
    # A child signal can reach Bash before its deferred signal trap runs.
    # Keep the in-flight target so the exit trap reports and cleans it safely.
    if ((status == 130 || status == 143)); then
        outcome="probe_error"; error_code="CreateInterrupted"
        report_probe_error create "$status" "$codes"
        exit 1
    fi
    if ((status == 124 || status == 137)); then
        create_uncertain=true
        report_uncertain_create
    fi
    create_in_flight=false
    if ((status == 0)); then
        outcome="available"; error_code=""
    elif ((status == 124 || status == 137)); then
        outcome="timeout"; error_code="CreateTimeout"
    elif [[ -n "$codes" ]] && ! grep -qvE '^(SkuNotAvailable|ServerIsBusy)$' <<<"$codes"; then
        outcome="capacity_exhausted"; error_code="$codes"
    else
        outcome="probe_error"; error_code="${codes:-UnknownError}"
    fi
    if ((status != 0)); then report_probe_error create "$status" "$codes"; fi
    if ! delete_server; then
        cleanup_result="failed"
        echo "Error: probe server '$server_name' deletion was not confirmed." >&2
        # Do not allocate again after failed cleanup. The caller owns group recovery.
        server_name=""
        outcome="probe_error"; error_code="CleanupFailed"
        exit 1
    fi
    if [[ "$create_uncertain" == false ]]; then cleanup_result="confirmed"; fi
    server_name=""
    if ((status == 0)); then
        outcome="available"; error_code=""
        echo "==> PostgreSQL capacity is available in $location" >&2
        exit 0
    fi
    if ((status == 124 || status == 137)); then
        outcome="timeout"; error_code="CreateTimeout"
        echo "Error: PostgreSQL create exceeded ${create_timeout}s." >&2
        exit 3
    fi
    error_code="${codes:-UnknownError}"
    if [[ -z "$codes" ]] || grep -qvE '^(SkuNotAvailable|ServerIsBusy)$' <<<"$codes"; then
        outcome="probe_error"
        echo "Error: PostgreSQL probe failed: $error_code." >&2
        exit 1
    fi
    outcome="capacity_exhausted"
    echo "==> No $postgres_sku capacity in $location: $error_code" >&2
    if ((attempt < attempts)); then sleep "$wait_seconds"; fi
done
echo "::error::Azure has no $postgres_sku ($postgres_tier) PostgreSQL capacity in $location after $attempts probes. This is an Azure capacity limit, not a recipe failure." >&2
exit 2
