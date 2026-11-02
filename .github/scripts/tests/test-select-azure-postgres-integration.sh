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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-integration-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALL_LOG="$TEST_ROOT/calls"
export GROUP_STATE="$TEST_ROOT/groups"
export SERVER_STATE="$TEST_ROOT/servers"
export RTC_AZURE_SELECTION_FILE="$TEST_ROOT/selection.json"
: >"$CALL_LOG"
: >"$GROUP_STATE"
: >"$SERVER_STATE"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail

service="${1:-}"
command="${2:-}"
subcommand="${3:-}"
shift 3 || true
if [[ "$service:$command:$subcommand" == postgres:flexible-server:create && "${1:-}" == --help ]]; then
    printf 'PostgreSQL create --zonal-resiliency --microsoft-entra-auth --password-auth\n'
    exit 0
fi
name=""
location=""
sku=""
tier=""
owner=""
query=""
while (($#)); do
    case "$1" in
        --name|--resource-group) name="$2"; shift 2 ;;
        --location) location="$2"; shift 2 ;;
        --sku-name) sku="$2"; shift 2 ;;
        --tier) tier="$2"; shift 2 ;;
        --query) query="$2"; shift 2 ;;
        --tags)
            shift
            while (($#)) && [[ "$1" != --* ]]; do
                [[ "$1" == rtc-probe-owner=* || "$1" == rtcPostgresSelectorOwner=* ]] &&
                    owner="${1#*=}"
                shift
            done
            ;;
        *) shift ;;
    esac
done

case "$service:$command:$subcommand" in
    group:exists:*)
        printf 'group exists %s\n' "$name" >>"$CALL_LOG"
        grep -Fq "$name|" "$GROUP_STATE" && echo true || echo false
        ;;
    group:create:*)
        printf 'group create %s location=%s owner=%s\n' "$name" "$location" "$owner" >>"$CALL_LOG"
        [[ -n "$owner" ]] || exit 1
        printf '%s|%s|%s\n' "$name" "$owner" "$location" >>"$GROUP_STATE"
        ;;
    group:show:*)
        printf 'group show %s\n' "$name" >>"$CALL_LOG"
        group_owner="$(awk -F'|' -v group="$name" '$1 == group { print $2; exit }' "$GROUP_STATE")"
        [[ -n "$group_owner" ]] || exit 1
        if [[ "$query" == tags.rtcPostgresSelectorOwner ]]; then
            echo "$group_owner"
        fi
        ;;
    group:delete:*)
        printf 'group delete %s\n' "$name" >>"$CALL_LOG"
        awk -F'|' -v group="$name" '$1 != group' "$GROUP_STATE" >"$GROUP_STATE.next"
        mv "$GROUP_STATE.next" "$GROUP_STATE"
        ;;
    postgres:flexible-server:list-skus)
        printf 'catalog %s\n' "$location" >>"$CALL_LOG"
        cat <<'JSON'
[
  {
    "supportedServerVersions": [{"name": "16"}],
    "supportedServerEditions": [
      {
        "name": "Burstable",
        "supportedServerSkus": [{"name": "Standard_B1ms"}],
        "supportedStorageEditions": [
          {"name": "P4", "supportedStorageMb": [{"storageSizeMb": 32768}]}
        ]
      },
      {
        "name": "GeneralPurpose",
        "supportedServerSkus": [{"name": "Standard_D2ds_v5"}],
        "supportedStorageEditions": [
          {"name": "P4", "supportedStorageMb": [{"storageSizeMb": 32768}]}
        ]
      }
    ]
  }
]
JSON
        ;;
    postgres:flexible-server:show)
        printf 'server show %s\n' "$name" >>"$CALL_LOG"
        server_line="$(awk -F'|' -v server="$name" '$1 == server { print; exit }' "$SERVER_STATE")"
        if [[ -z "$server_line" ]]; then
            echo '(ResourceNotFound) server is absent' >&2
            exit 1
        fi
        server_owner="$(cut -d'|' -f2 <<<"$server_line")"
        jq -n --arg owner "$server_owner" '{tags:{"rtc-probe-owner":$owner}}'
        ;;
    postgres:flexible-server:delete)
        printf 'server delete %s\n' "$name" >>"$CALL_LOG"
        awk -F'|' -v server="$name" '$1 != server' "$SERVER_STATE" >"$SERVER_STATE.next"
        mv "$SERVER_STATE.next" "$SERVER_STATE"
        ;;
    postgres:flexible-server:create)
        printf 'server create %s region=%s sku=%s tier=%s\n' \
            "$name" "$location" "$sku" "$tier" >>"$CALL_LOG"
        [[ -n "$owner" ]] || exit 1
        printf '%s|%s|%s|%s|%s\n' "$name" "$owner" "$location" "$sku" "$tier" >>"$SERVER_STATE"
        if [[ "$sku" == Standard_B1ms ]]; then
            echo '(SkuNotAvailable) temporary capacity shortage' >&2
            exit 1
        fi
        [[ "$sku" == Standard_D2ds_v5 ]] || exit 1
        ;;
    *)
        printf 'Unexpected Azure CLI call: %s %s %s\n' "$service" "$command" "$subcommand" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/az"

output="$(
    PATH="$TEST_ROOT/bin:$PATH" \
    RTC_AZURE_SELECTION_FILE="$RTC_AZURE_SELECTION_FILE" \
    RTC_AZURE_TEST_REGIONS=westus3,centralus,northcentralus,southcentralus \
    RTC_POSTGRES_TEST_SIZES=S,M \
    RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=90 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=20 \
    RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=20 \
    RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=20 \
    bash "$REPO_ROOT/.github/scripts/select-azure-test-location.sh" \
        rtc-integration-probe
)" || {
    echo "$output" >&2
    cat "$CALL_LOG" >&2
    exit 1
}

jq -e '
    .version == 1 and .status == "selected" and .location == "westus3" and
    .postgres == {size:"M",skuName:"Standard_D2ds_v5",tier:"GeneralPurpose"} and
    (.attempts | length == 5) and
    ([.attempts[0:4][] | [.region,.size,.skuName,.tier,.outcome]] ==
        [["westus3","S","Standard_B1ms","Burstable","capacity_exhausted"],
         ["centralus","S","Standard_B1ms","Burstable","capacity_exhausted"],
         ["northcentralus","S","Standard_B1ms","Burstable","capacity_exhausted"],
         ["southcentralus","S","Standard_B1ms","Burstable","capacity_exhausted"]]) and
    (.attempts[4] | [.region,.size,.skuName,.tier,.outcome]) ==
        ["westus3","M","Standard_D2ds_v5","GeneralPurpose","available"]
' "$RTC_AZURE_SELECTION_FILE" >/dev/null || {
    cat "$RTC_AZURE_SELECTION_FILE" >&2
    echo "Selector and probe result contract did not match the expected S-to-M fallback." >&2
    exit 1
}

for region in westus3 centralus northcentralus southcentralus; do
    grep -Eq "^server create pgprobe-[a-f0-9]{32} region=$region sku=Standard_B1ms tier=Burstable$" \
        "$CALL_LOG" || {
            cat "$CALL_LOG" >&2
            echo "Missing S capacity probe in $region." >&2
            exit 1
        }
done
grep -Eq '^server create pgprobe-[a-f0-9]{32} region=westus3 sku=Standard_D2ds_v5 tier=GeneralPurpose$' \
    "$CALL_LOG" || {
    cat "$CALL_LOG" >&2
    echo "Missing successful M deployment in the selected region." >&2
    exit 1
}

[[ "$(grep -c '^server create ' "$CALL_LOG")" == 5 ]] || {
    cat "$CALL_LOG" >&2
    echo "Expected four S probes and one M probe." >&2
    exit 1
}
[[ "$(grep -c '^server delete ' "$CALL_LOG")" == 5 ]] || {
    cat "$CALL_LOG" >&2
    echo "Every partial or successful PostgreSQL probe must be deleted." >&2
    exit 1
}
[[ "$(grep -c '^group create ' "$CALL_LOG")" == 1 &&
    "$(grep -c '^group delete ' "$CALL_LOG")" == 1 ]] || {
    cat "$CALL_LOG" >&2
    echo "The owned temporary resource group must be created and deleted exactly once." >&2
    exit 1
}
[[ ! -s "$GROUP_STATE" && ! -s "$SERVER_STATE" ]] || {
    cat "$GROUP_STATE" "$SERVER_STATE" >&2
    echo "Azure resource state remains after selector cleanup." >&2
    exit 1
}
! grep -q 'password' "$CALL_LOG" || {
    echo "Test log must not include PostgreSQL credentials." >&2
    exit 1
}
echo "Selector and PostgreSQL probe integration test passed"
