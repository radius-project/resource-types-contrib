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
# Exit: 0 available, 1 other/cleanup error, 2 capacity exhausted, 3 create timeout.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$script_dir/lib-azure-postgres-test.sh"

resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
attempts="${RTC_POSTGRES_PROBE_ATTEMPTS-3}"
wait_seconds="${RTC_POSTGRES_PROBE_WAIT_SECONDS-600}"
create_timeout="${RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS-900}"
delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
rtc_postgres_test_tuple "${RTC_POSTGRES_TEST_SIZE-S}" || exit 1
if [[ -z "$resource_group" || ! "$location" =~ ^[a-z0-9]+$ ]] ||
    ! rtc_postgres_positive_limit "$attempts" 3 ||
    ! rtc_postgres_positive_limit "$create_timeout" 900 ||
    ! rtc_postgres_positive_limit "$delete_timeout" 900 ||
    [[ ! "$wait_seconds" =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((10#$wait_seconds > 600)); then
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
outcome="probe_error"
error_code="UnknownError"

report_uncertain_create() {
    echo "Error: create request timed out or was interrupted for probe server '$server_name' in resource group '$resource_group' (ownership tag rtc-probe-owner=$probe_owner)." >&2
    echo "A current ResourceNotFound response does not rule out later creation. Check this target again and verify its ownership tag before deletion." >&2
}

delete_server() {
    local status=0 remaining cleanup_deadline codes
    cleanup_deadline=$((SECONDS + delete_timeout))
    timeout --signal=KILL "$delete_timeout" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --only-show-errors --output json >"$work_dir/server" 2>"$work_dir/show-error" || status=$?
    if ((status != 0)); then
        codes="$(rtc_postgres_error_codes "$work_dir/show-error")"
        ((status != 124 && status != 137)) && [[ "$codes" == "ResourceNotFound" ]]
        return
    fi
    if ! jq -e --arg owner "$probe_owner" '.tags["rtc-probe-owner"] == $owner' \
        "$work_dir/server" >/dev/null 2>&1; then
        echo "Error: ownership of probe server '$server_name' was not confirmed; refusing deletion." >&2
        return 1
    fi
    remaining=$((cleanup_deadline - SECONDS))
    ((remaining > 0)) || return 1
    timeout --signal=KILL "$remaining" az postgres flexible-server delete \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --yes --only-show-errors --output none > /dev/null 2>"$work_dir/delete-error" || status=$?
    if ((status != 0)); then
        codes="$(rtc_postgres_error_codes "$work_dir/delete-error")"
        [[ "$codes" == "ResourceNotFound" ]] || return 1
    fi
    remaining=$((cleanup_deadline - SECONDS))
    ((remaining > 0)) || return 1
    status=0
    timeout --signal=KILL "$remaining" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --only-show-errors --output none > /dev/null 2>"$work_dir/show-error" || status=$?
    codes="$(rtc_postgres_error_codes "$work_dir/show-error")"
    ((status != 0 && status != 124 && status != 137)) && [[ "$codes" == "ResourceNotFound" ]]
}

# Invoked by the EXIT trap, including after an interrupt.
# shellcheck disable=SC2329
finish() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$create_in_flight" == true ]]; then
        report_uncertain_create
        outcome="probe_error"; error_code="CreateInterrupted"; status=1
    fi
    if [[ -n "$server_name" ]] && ! delete_server; then
        echo "Error: probe server '$server_name' deletion was not confirmed." >&2
        outcome="probe_error"; error_code="CleanupFailed"; status=1
    fi
    if [[ -n "${RTC_POSTGRES_PROBE_RESULT_FILE:-}" ]]; then
        jq -n --arg outcome "$outcome" --arg errorCode "$error_code" \
            '{outcome: $outcome, errorCode: $errorCode}' >"$RTC_POSTGRES_PROBE_RESULT_FILE" || status=1
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

# Azure CLI renamed these switches. Read local help, not a cloud capability list.
# Charge the full remaining create/selection budget to this check.
help_started=$SECONDS
help_timeout="$create_timeout"
help_status=0
timeout --signal=KILL "$help_timeout" az postgres flexible-server create --help \
    >"$work_dir/create-help" 2>/dev/null || help_status=$?
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
    timeout --signal=KILL "$limit" az postgres flexible-server show \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$candidate_name" \
        --only-show-errors --output json >/dev/null 2>"$work_dir/precreate-error" || status=$?
    codes="$(rtc_postgres_error_codes "$work_dir/precreate-error")"
    if ((status == 0)); then
        error_code="ServerAlreadyExists"
        echo "Error: probe server name '$candidate_name' already exists; refusing creation." >&2
        exit 1
    elif ((status == 124 || status == 137)); then
        outcome="timeout"; error_code="CreateTimeout"
        echo "Error: PostgreSQL probe server absence check timed out." >&2
        exit 3
    elif [[ "$codes" != "ResourceNotFound" ]]; then
        error_code="ServerAbsenceUnknown"
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
    password="P$(openssl rand -hex 16)a1!"
    echo "==> PostgreSQL probe $attempt/$attempts: $postgres_sku ($postgres_tier) in $location" >&2
    echo "==> Recovery target: probe server '$server_name' in resource group '$resource_group' (ownership tag rtc-probe-owner=$probe_owner). Verify this tag before any later deletion." >&2
    status=0
    # None enables public networking without a firewall rule. It does not disable
    # TLS. Leave zone unset for automatic placement, as in the pack.
    create_in_flight=true
    timeout --signal=KILL "$limit" az postgres flexible-server create \
        "${subscription_args[@]}" --resource-group "$resource_group" --name "$server_name" \
        --location "$location" --tier "$postgres_tier" --sku-name "$postgres_sku" \
        --storage-size 32 --version 16 "$ha_option" Disabled \
        --geo-redundant-backup Disabled "$auth_option" Enabled --password-auth Enabled \
        --public-access None --admin-user probeadmin --admin-password "$password" \
        --tags "rtc-probe-owner=$probe_owner" \
        --yes --only-show-errors --output none > /dev/null 2>"$work_dir/create-error" || status=$?
    unset password
    if ((status == 124 || status == 137)); then
        report_uncertain_create
    fi
    create_in_flight=false
    codes="$(rtc_postgres_error_codes "$work_dir/create-error")"
    if ! delete_server; then
        echo "Error: probe server '$server_name' deletion was not confirmed." >&2
        # Do not allocate again after failed cleanup. The caller owns group recovery.
        server_name=""
        outcome="probe_error"; error_code="CleanupFailed"
        exit 1
    fi
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
