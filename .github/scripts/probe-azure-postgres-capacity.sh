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
# Checks that Azure can create the PostgreSQL flexible server SKU used by the
# azure-aks Recipe Pack test (size 'S' maps to Standard_B1ms, Burstable).
#
# Azure has no API for live regional capacity: the SKU list and quota APIs can
# report a SKU as available while a create still fails with SkuNotAvailable or
# ServerIsBusy. This script creates a probe server, deletes it without waiting,
# and retries only those capacity errors. Other errors fail immediately.
#
# Exit codes: 0 capacity available, 1 other error, 2 no capacity after all
# attempts.
#
# Required environment: AZURE_RESOURCE_GROUP, AZURE_LOCATION
# Optional environment: RTC_POSTGRES_PROBE_ATTEMPTS (default 3),
#                       RTC_POSTGRES_PROBE_WAIT_SECONDS (default 600)
# =============================================================================

set -euo pipefail

resource_group="${AZURE_RESOURCE_GROUP:-}"
location="${AZURE_LOCATION:-}"
attempts="${RTC_POSTGRES_PROBE_ATTEMPTS:-3}"
wait_seconds="${RTC_POSTGRES_PROBE_WAIT_SECONDS:-600}"
sku_name="Standard_B1ms"
tier="Burstable"

if [[ -z "$resource_group" || -z "$location" ]]; then
    echo "Error: AZURE_RESOURCE_GROUP and AZURE_LOCATION must be set." >&2
    exit 1
fi
if [[ ! "$attempts" =~ ^[1-9][0-9]*$ || ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
    echo "Error: probe attempts must be a positive integer and wait seconds a nonnegative integer." >&2
    exit 1
fi

error_file="$(mktemp "${TMPDIR:-/tmp}/rtc-postgres-probe-XXXXXX")"
trap 'rm -f -- "$error_file"' EXIT

for ((attempt = 1; attempt <= attempts; attempt++)); do
    server_name="pgprobe-${GITHUB_RUN_ID:-local}-${attempt}-${RANDOM}"
    server_name="${server_name:0:63}"
    password="Pp1-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"

    echo "==> PostgreSQL capacity probe $attempt/$attempts: $sku_name ($tier) in $location"
    status=0
    az postgres flexible-server create \
        --resource-group "$resource_group" \
        --name "$server_name" \
        --location "$location" \
        --tier "$tier" \
        --sku-name "$sku_name" \
        --storage-size 32 \
        --version 16 \
        --public-access None \
        --admin-user probeadmin \
        --admin-password "$password" \
        --yes \
        --only-show-errors \
        --output none 2>"$error_file" || status=$?

    # A failed create can leave a server in the Failed state. The resource
    # group cleanup removes anything this best-effort delete does not.
    if ! az postgres flexible-server delete \
        --resource-group "$resource_group" \
        --name "$server_name" \
        --yes --no-wait --only-show-errors --output none 2>/dev/null; then
        echo "==> Probe server '$server_name' was not deleted; resource group cleanup will remove it."
    fi

    if [[ "$status" -eq 0 ]]; then
        echo "==> PostgreSQL capacity is available in $location"
        exit 0
    fi

    if ! grep -qE 'SkuNotAvailable|ServerIsBusy' "$error_file"; then
        echo "Error: the PostgreSQL capacity probe failed for a reason other than capacity:" >&2
        cat "$error_file" >&2
        exit 1
    fi

    echo "==> No $sku_name capacity in $location: $(grep -oE 'SkuNotAvailable|ServerIsBusy' "$error_file" | head -n 1)"
    if ((attempt < attempts)); then
        echo "==> Waiting ${wait_seconds}s before the next probe"
        sleep "$wait_seconds"
    fi
done

echo "::error::Azure has no $sku_name ($tier) PostgreSQL capacity in $location after $attempts probes. This is an Azure capacity limit, not a recipe failure." >&2
exit 2
