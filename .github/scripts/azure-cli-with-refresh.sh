#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
set +x

# Install after azure/login. All later CLI calls, including child processes,
# use the same renewal path. Radius pods use their own workload identity.
if [[ "${1:-}" == --install ]]; then
    : "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${GITHUB_PATH:?}"
    : "${AZURE_CLIENT_ID:?}" "${AZURE_TENANT_ID:?}" "${AZURE_SUBSCRIPTION_ID:?}"
    : "${ACTIONS_ID_TOKEN_REQUEST_URL:?}" "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?}"
    cli="$(command -v az)"
    directory="$RUNNER_TEMP/rtc-azure-cli"
    mkdir -p "$directory"
    cp "${BASH_SOURCE[0]}" "$directory/az"
    chmod +x "$directory/az"
    {
        echo "RTC_AZURE_CLI=$cli"
        echo "RTC_AZURE_LOGIN_STAMP=$directory/login-stamp"
        echo "AZURE_CLIENT_ID=$AZURE_CLIENT_ID"
        echo "AZURE_TENANT_ID=$AZURE_TENANT_ID"
        echo "AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID"
    } >>"$GITHUB_ENV"
    echo "$directory" >>"$GITHUB_PATH"
    exit 0
fi

: "${RTC_AZURE_CLI:?}" "${RTC_AZURE_LOGIN_STAMP:?}"
case "${1:-} ${2:-}" in
    logout\ *|"account clear")
        exec "$RTC_AZURE_CLI" "$@"
        ;;
esac
: "${AZURE_CLIENT_ID:?}" "${AZURE_TENANT_ID:?}" "${AZURE_SUBSCRIPTION_ID:?}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?}" "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?}"

# Renew on demand, not in a background process that can race with CLI reads.
exec 9>"$RTC_AZURE_LOGIN_STAMP.lock"
flock -x 9
now="$(date +%s)"
last=0
if [[ -f "$RTC_AZURE_LOGIN_STAMP" ]]; then
    if ! read -r last <"$RTC_AZURE_LOGIN_STAMP"; then
        echo "Error: Could not read Azure login timestamp." >&2
        exit 1
    fi
fi
if [[ ! "$last" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid Azure login timestamp." >&2
    exit 1
fi
# GitHub's assertion lasts five minutes. A fresh login also renews the Azure
# access token, so the CLI never has to exchange the expired old assertion.
if ((now - last >= 240 || now < last)); then
    echo "==> Renewing Azure CLI login with a fresh GitHub OIDC assertion" >&2
    separator='&'
    [[ "$ACTIONS_ID_TOKEN_REQUEST_URL" == *\?* ]] || separator='?'
    if ! response="$(curl --fail --silent --show-error --max-time 30 \
        -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=api%3A%2F%2FAzureADTokenExchange")"; then
        echo "Error: Could not request a fresh GitHub OIDC assertion." >&2
        exit 1
    fi
    if ! token="$(jq -er '.value | select(type == "string" and length > 0)' <<<"$response")"; then
        echo "Error: GitHub returned no OIDC assertion." >&2
        exit 1
    fi
    echo "::add-mask::$token" >&2
    "$RTC_AZURE_CLI" login --service-principal \
        --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
        --federated-token "$token" --only-show-errors --output none
    unset token response
    "$RTC_AZURE_CLI" account set --subscription "$AZURE_SUBSCRIPTION_ID"
    date +%s >"$RTC_AZURE_LOGIN_STAMP"
fi
flock -u 9
exec 9>&-
exec "$RTC_AZURE_CLI" "$@"
