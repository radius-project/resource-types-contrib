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
# Selects the Azure region for the nightly Azure tests. Recipes create
# resources in the test resource group's region, so the region must be chosen
# before that group is created.
#
# For each candidate in order, run one PostgreSQL capacity probe and select
# the first region with capacity. The probes run in a temporary resource group
# that is deleted on exit. If no candidate has capacity, or a probe fails for
# another reason, select the first candidate: the per-entry probe then reports
# the result, and the other tests still run.
#
# Usage: select-azure-test-location.sh <probe-resource-group> <location>...
# Prints the selected location on stdout. Progress goes to stderr.
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <probe-resource-group> <location>..." >&2
    exit 1
fi

probe_rg="$1"
shift
candidates=("$@")
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
subscription_args=()
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi

if [[ $# -eq 1 ]]; then
    echo "==> One candidate region; no capacity selection needed" >&2
    echo "${candidates[0]}"
    exit 0
fi

cleanup() {
    az group delete "${subscription_args[@]}" --name "$probe_rg" --yes --no-wait --only-show-errors --output none >/dev/null 2>&1 || true
}

# The probe group's own region does not limit the regions it can probe.
if ! az group create "${subscription_args[@]}" --name "$probe_rg" --location "${candidates[0]}" \
    --tags "creationTime=$(date +%s)" --only-show-errors --output none >&2; then
    echo "::warning::Could not create probe resource group '$probe_rg'; using ${candidates[0]}." >&2
    echo "${candidates[0]}"
    exit 0
fi
trap cleanup EXIT

for location in "${candidates[@]}"; do
    status=0
    AZURE_RESOURCE_GROUP="$probe_rg" AZURE_LOCATION="$location" RTC_POSTGRES_PROBE_ATTEMPTS=1 \
        "$script_dir/probe-azure-postgres-capacity.sh" >&2 || status=$?
    case "$status" in
        0)
            echo "==> Selected Azure test region: $location" >&2
            echo "$location"
            exit 0
            ;;
        2)
            echo "::warning::No PostgreSQL capacity in $location; trying the next candidate region." >&2
            ;;
        *)
            echo "::warning::The capacity probe failed for a reason other than capacity; using ${candidates[0]}." >&2
            echo "${candidates[0]}"
            exit 0
            ;;
    esac
done

echo "::warning::No candidate region had PostgreSQL capacity; using ${candidates[0]}." >&2
echo "${candidates[0]}"
