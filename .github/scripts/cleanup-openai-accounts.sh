#!/bin/bash

# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

fail() { echo "Error: $*; OpenAI capacity release is not confirmed." >&2; exit 1; }

[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == radius-project/resource-types-contrib &&
    "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ &&
    "${AZURE_RESOURCE_GROUP:-}" == "rrttest-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-openai" &&
    "${AZURE_SUBSCRIPTION_ID:-}" =~ ^[a-fA-F0-9-]{36}$ &&
    "${AZURE_LOCATION:-}" =~ ^[a-z0-9]+$ ]] || fail "Invalid CI cleanup scope"
[[ "${1:-}" == true || "${1:-}" == false ]] || fail "Missing resource-group existence result"
group_exists="$1"
mode="${2:-cleanup}"
[[ "$mode" == begin || "$mode" == prepare || "$mode" == record || "$mode" == cleanup ]] ||
    fail "Invalid cleanup operation"
[[ "${RTC_OPENAI_RELEASE_CONFIRMED:-false}" == true || "${RTC_OPENAI_RELEASE_CONFIRMED:-false}" == false ]] ||
    fail "Invalid release confirmation"
group_id="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP"
account_prefix="${group_id,,}/providers/microsoft.cognitiveservices/accounts/"
deleted_prefix="/subscriptions/${AZURE_SUBSCRIPTION_ID,,}/providers/microsoft.cognitiveservices/locations/"

az_read() {
    timeout --kill-after=5s 30s az "$@" --subscription "$AZURE_SUBSCRIPTION_ID" --output json
}

verify_ownership() {
    local group
    group="$(az_read group show --name "$AZURE_RESOURCE_GROUP")" || fail "Cannot read resource-group ownership"
    jq -e --arg id "${group_id,,}" --arg repo "$GITHUB_REPOSITORY" \
        --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" '
        (.id | ascii_downcase) == $id and
        .tags.rtcRepository == $repo and .tags.rtcRunId == $run and
        .tags.rtcRunAttempt == $attempt and .tags.rtcPurpose == "azure-openai-test"
    ' <<<"$group" >/dev/null || fail "Resource-group ownership does not match this run"
    printf '%s\n' "$group"
}

state=""
if [[ "$group_exists" == true ]]; then
    group="$(verify_ownership)"
    state="$(jq -r '.tags.rtcOpenaiCleanup // ""' <<<"$group")"
    if [[ -n "$state" ]]; then
        jq -e '
            type == "object" and (.target | type) == "number" and
            .target >= 0 and (.target | floor) == .target and
            (.recording | type) == "boolean" and (.accounts | type) == "object" and
            ((has("completed") | not) or (.completed | type) == "boolean") and
            ((has("requested") | not) or (.requested | type) == "boolean") and
            all(.accounts | to_entries[];
                (.key | test("^[a-z0-9][a-z0-9_.-]*$")) and (.value | type) == "boolean")
        ' <<<"$state" >/dev/null || fail "Invalid saved OpenAI cleanup state"
    fi
elif [[ "$mode" != cleanup ]]; then
    fail "Cannot record cleanup state without a live owned resource group"
fi

save_state() {
    local response confirmed
    ((${#state} <= 256)) || fail "OpenAI cleanup state exceeds the Azure tag value limit"
    if response="$(timeout --kill-after=5s 30s az tag update --resource-id "$group_id" \
        --operation Merge --tags "rtcOpenaiCleanup=$state" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --output json)" &&
        jq -e --arg state "$state" '.properties.tags.rtcOpenaiCleanup == $state' <<<"$response" >/dev/null; then
        return
    fi
    if [[ "$mode" == prepare ]]; then
        echo "Warning: Pending request tag response was unclear; checking saved ownership and state" >&2
        confirmed="$(verify_ownership)"
        jq -e --arg state "$state" '.tags.rtcOpenaiCleanup == $state' <<<"$confirmed" >/dev/null ||
            fail "Pending request state was not confirmed"
        echo "Pending request state confirmed by readback"
        return
    fi
    fail "Cannot save and confirm OpenAI cleanup state before continuing"
}

inventory() {
    local data
    if [[ "$1" == active ]]; then
        if [[ "$group_exists" == false ]]; then echo '[]'; return; fi
        data="$(az_read cognitiveservices account list --resource-group "$AZURE_RESOURCE_GROUP")" ||
            fail "Cannot list active accounts"
    else
        data="$(az_read cognitiveservices account list-deleted)" || fail "Cannot list deleted accounts"
    fi
    jq -ce --arg prefix "$account_prefix" --arg deletedPrefix "$deleted_prefix" \
        --arg group "${AZURE_RESOURCE_GROUP,,}" --arg location "$AZURE_LOCATION" --arg mode "$1" '
        if type != "array" then error("account list must be an array") else . end |
        if all(.[]; (.id | type) == "string" and (.kind | type) == "string" and
            (.kind | length) > 0 and
            (.id | ascii_downcase | test("^/subscriptions/[^/]+/(resourcegroups/[^/]+/providers/microsoft\\.cognitiveservices/accounts/[^/]+|providers/microsoft\\.cognitiveservices/locations/[^/]+/resourcegroups/[^/]+/deletedaccounts/[^/]+)$")))
        then . else error("account identity is missing") end |
        if $mode == "active" and any(.[]; (.id | ascii_downcase | startswith($prefix) | not))
        then error("active account outside the resource group") else . end |
        [.[] | select(
            (.id | ascii_downcase | startswith($prefix)) or
            ($mode == "deleted" and (.id | ascii_downcase | startswith($deletedPrefix)) and
                (.id | ascii_downcase | split("/")[7:9]) == ["resourcegroups", $group])
        ) | select(.kind == "OpenAI")] |
        if all(.[]; (.name | type) == "string" and
            (.name | test("^[a-zA-Z0-9][a-zA-Z0-9_.-]*$")) and
            .location == $location and
            ((.id | ascii_downcase) == ($prefix + (.name | ascii_downcase)) or
                ($mode == "deleted" and (.id | ascii_downcase) ==
                    ($deletedPrefix + $location + "/resourcegroups/" + $group +
                        "/deletedaccounts/" + (.name | ascii_downcase)))))
        then map({name:(.name | ascii_downcase)})
        else error("unexpected scoped OpenAI account identity or location") end
    ' <<<"$data" || fail "Invalid $1 account inventory"
}

usage() {
    local data
    data="$(az_read cognitiveservices usage list --location "$AZURE_LOCATION")" ||
        fail "Cannot read OpenAI account quota"
    jq -ce '
        if type != "array" then error("usage list must be an array") else . end |
        [.[] | select(.name.value == "OpenAI.S0.AccountCount")] |
        if length == 1 and (.[0].currentValue | type) == "number" and
            (.[0].limit | type) == "number" and .[0].currentValue >= 0 and .[0].limit > 0 and
            (.[0].currentValue | floor) == .[0].currentValue and (.[0].limit | floor) == .[0].limit
        then .[0] else error("missing or invalid OpenAI account quota") end
    ' <<<"$data" || fail "Invalid OpenAI account quota"
}

empty_run_settled() {
    local deployments resources current active_now deleted_now
    [[ "$(jq '.completed // false' <<<"$state")" == true ]] || return 1
    deployments="$(az_read deployment group list --resource-group "$AZURE_RESOURCE_GROUP")" ||
        fail "Cannot verify deployment completion for an empty OpenAI run"
    resources="$(az_read resource list --resource-group "$AZURE_RESOURCE_GROUP" --expand provisioningState)" ||
        fail "Cannot verify resource completion for an empty OpenAI run"
    printf '%s\n%s\n' "$deployments" "$resources" |
        jq -es --arg prefix "${group_id,,}/providers/" '
        def terminal: type == "string" and
            (ascii_downcase | IN("succeeded", "failed", "canceled", "cancelled", "deleted"));
        .[0] as $deployments | .[1] as $resources |
        length == 2 and
        ($deployments | type) == "array" and ($resources | type) == "array" and
        all($deployments[]; .properties.provisioningState | terminal) and
        all($resources[];
            (.id | type) == "string" and (.id | ascii_downcase | startswith($prefix)) and
            (.id | ascii_downcase | contains("/providers/microsoft.cognitiveservices/accounts/") | not) and
            ((.properties.provisioningState // .provisioningState) | terminal))
    ' >/dev/null || return 1
    current="$(usage)"
    jq -en --argjson current "$current" --argjson state "$state" \
        '$current.currentValue <= $state.target' >/dev/null || return 1
    active_now="$(inventory active)"
    deleted_now="$(inventory deleted)"
    [[ "$active_now" == '[]' && "$deleted_now" == '[]' ]]
}

active="$(inventory active)"
deleted="$(inventory deleted)"
expected="$(jq -cn --argjson active "$active" --argjson deleted "$deleted" \
    '[$active[], $deleted[]] | map(.name) | unique')"
count="$(jq 'length' <<<"$expected")"
if [[ "$group_exists" == false && "$count" != 0 ]]; then
    fail "Deleted accounts remain but the resource group's ownership evidence is absent; operator review required"
fi
if [[ "${RTC_OPENAI_RELEASE_CONFIRMED:-false}" == true ]]; then
    [[ "$mode" == cleanup && "$group_exists" == false ]] ||
        fail "A confirmed release still has a resource group"
    echo "Previously released OpenAI group and deleted accounts remain absent; quota may now serve another worker"
    exit 0
fi

saved_state="$state"
if [[ "$mode" == begin ]]; then
    [[ -z "$state" && "$count" == 0 ]] || fail "OpenAI test must start with an empty, unrecorded owned group"
    before="$(usage)"
    state="$(jq -c '{target:.currentValue,accounts:{},recording:false}' <<<"$before")"
    save_state
    jq -e '.currentValue < .limit' <<<"$before" >/dev/null ||
        fail "No regional OpenAI.S0.AccountCount slot is free; model deployment was not submitted"
    exit 0
elif [[ "$mode" == prepare ]]; then
    [[ -n "$state" ]] || fail "Cannot deploy without saved OpenAI cleanup state"
    [[ "$(jq '.requested // false' <<<"$state")" == false &&
        "$(jq '.recording' <<<"$state")" == false &&
        "$(jq '.accounts | length' <<<"$state")" == 0 && "$count" == 0 ]] ||
        fail "Only one OpenAI model request is allowed per owned test group"
    state="$(jq -c '.completed = false | .recording = true | .requested = true' <<<"$state")"
    save_state
    exit 0
elif [[ "$mode" == record ]]; then
    [[ -n "$state" ]] ||
        fail "Cannot record deployed OpenAI account identities; retain the app for cleanup"
    [[ "${3:-unknown}" == completed || "${3:-unknown}" == unknown ]] ||
        fail "Invalid deployment completion result"
    if [[ "${3:-unknown}" == completed ]]; then
        state="$(jq -c '.completed = true' <<<"$state")"
    fi
    if [[ "$count" == 0 && "$(jq '.accounts | length' <<<"$state")" == 0 ]]; then
        if [[ "${3:-unknown}" == completed ]]; then
            state="$(jq -c '.recording = true' <<<"$state")"
            save_state
        fi
        empty_run_settled ||
            fail "Empty OpenAI inventory is not settled; retain the app for cleanup"
        state="$(jq -c '.recording = false' <<<"$state")"
    fi
elif [[ -z "$state" ]]; then
    target=0
    if [[ "$count" != 0 ]]; then
        before="$(usage)"
        target="$(jq --argjson count "$count" '.currentValue - $count' <<<"$before")"
    fi
    (( target >= 0 )) || fail "Quota usage is lower than the owned account inventory; operator review required"
    state="$(jq -cn --argjson target "$target" '{target:$target,accounts:{},recording:false}')"
fi

state="$(jq -c --argjson names "$expected" '
    reduce $names[] as $name (.;
        if .accounts | has($name) then . else .accounts[$name] = false end) |
    if ($names | length) > 0 then .recording = false else . end
' <<<"$state")"
if [[ "$group_exists" == true && "$state" != "$saved_state" ]]; then
    save_state
fi
if [[ "$mode" == record ]]; then exit 0; fi
target="$(jq '.target' <<<"$state")"
expected="$(jq -c '.accounts | keys' <<<"$state")"

# Keep the tagged group until all tombstones are purged so fallback cleanup can
# establish ownership even if this runner stops between account deletion and purge.
deleting='[]'
purged="$(jq -c '[.accounts | to_entries[] | select(.value) | .key]' <<<"$state")"
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
    active="$(inventory active)"
    deleted="$(inventory deleted)"
    observed="$(jq -cn --argjson active "$active" --argjson deleted "$deleted" \
        '[$active[], $deleted[]] | map(.name) | unique')"
    new="$(jq -cn --argjson observed "$observed" --argjson expected "$expected" '$observed - $expected')"
    if [[ "$new" != '[]' ]]; then
        [[ "$(jq '.recording' <<<"$state")" == true ]] ||
            fail "Account inventory changed outside the cleanup snapshot"
        verify_ownership >/dev/null
        state="$(jq -c --argjson names "$new" '
            reduce $names[] as $name (.; .accounts[$name] = false) |
            .recording = false
        ' <<<"$state")"
        save_state
        expected="$(jq -c '.accounts | keys' <<<"$state")"
    elif [[ "$observed" != '[]' && "$(jq '.recording' <<<"$state")" == true ]]; then
        verify_ownership >/dev/null
        state="$(jq -c '.recording = false' <<<"$state")"
        save_state
    fi
    while IFS= read -r name; do
        verify_ownership >/dev/null
        echo "Deleting owned OpenAI account '$name' in '$AZURE_RESOURCE_GROUP'"
        timeout --kill-after=5s 60s az cognitiveservices account delete \
            --name "$name" --resource-group "$AZURE_RESOURCE_GROUP" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output none ||
            fail "OpenAI account deletion failed or timed out"
        deleting="$(jq -c --arg name "$name" '. + [$name]' <<<"$deleting")"
    done < <(jq -r --argjson deleting "$deleting" '[.[].name] - $deleting | .[]' <<<"$active")
    while IFS= read -r name; do
        verify_ownership >/dev/null
        echo "Purging owned soft-deleted OpenAI account '$name' in '$AZURE_RESOURCE_GROUP'"
        timeout --kill-after=5s 60s az cognitiveservices account purge \
            --name "$name" --resource-group "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output none ||
            fail "OpenAI account purge failed or timed out (check deletedAccounts/delete permission)"
        purged="$(jq -c --arg name "$name" '. + [$name]' <<<"$purged")"
        state="$(jq -c --arg name "$name" '.accounts[$name] = true' <<<"$state")"
        save_state
    done < <(jq -r --argjson purged "$purged" '[.[].name] - $purged | .[]' <<<"$deleted")
    if [[ "$(jq '.recording' <<<"$state")" == true && "$expected" == '[]' &&
        "$active" == '[]' && "$deleted" == '[]' ]] && empty_run_settled; then
        state="$(jq -c '.recording = false' <<<"$state")"
        save_state
    fi
    if [[ "$expected" == '[]' && "$active" == '[]' && "$deleted" == '[]' &&
        "$(jq '.recording' <<<"$state")" == false ]]; then
        echo "No OpenAI accounts belonged to this run; regional quota is unchanged by this cleanup"
        exit 0
    fi
    current="$(usage)"
    if [[ "$(jq 'length' <<<"$active")" == 0 && "$(jq 'length' <<<"$deleted")" == 0 ]] &&
        jq -en --argjson expected "$expected" --argjson purged "$purged" \
            --argjson current "$current" --argjson target "$target" '
            ($expected - $purged | length) == 0 and
            $current.currentValue <= $target and $current.currentValue < $current.limit
        ' >/dev/null && [[ "$(jq '.recording' <<<"$state")" == false ]]; then
        echo "Owned OpenAI accounts are absent and regional OpenAI.S0.AccountCount capacity is available"
        exit 0
    fi
    sleep 15
done
fail "Timed out waiting for account purge and OpenAI.S0.AccountCount quota recovery"
