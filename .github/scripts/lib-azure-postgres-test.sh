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

# Approved test tuples. L is excluded because the pack maps it to the M SKU.
# These variables are return values for callers that source this file.
# shellcheck disable=SC2034
rtc_postgres_test_tuple() {
    case "$1" in
        S) postgres_sku="Standard_B1ms"; postgres_tier="Burstable" ;;
        M) postgres_sku="Standard_D2ds_v5"; postgres_tier="GeneralPurpose" ;;
        *) echo "Error: PostgreSQL test size must be S or M." >&2; return 1 ;;
    esac
}

rtc_postgres_test_settings() {
    printf '%s\n' '{"version":"16","storageSizeGB":32,"highAvailability":"Disabled","geoRedundantBackup":"Disabled","availabilityZone":-1,"publicNetworkAccess":"Enabled","activeDirectoryAuth":"Enabled","passwordAuth":"Enabled"}'
}

# Fail closed when a release overlay changes the tuple or required features.
rtc_validate_postgres_test_pack() {
    local pack="$1" entry small_sku small_tier setting
    entry="$(sed -n "/'Radius.Data\/postgreSqlDatabases': {/,/'Radius.Data\/sqlServerDatabases': {/p" "$pack")" || return 1
    rtc_postgres_test_tuple S
    small_sku="$postgres_sku"; small_tier="$postgres_tier"
    rtc_postgres_test_tuple M
    if ! grep -Fq "skuName: '{{context.resource.properties.size == \"S\" ? \"$small_sku\" : \"$postgres_sku\"}}'" <<<"$entry" ||
        ! grep -Fq "tier: '{{context.resource.properties.size == \"S\" ? \"$small_tier\" : \"$postgres_tier\"}}'" <<<"$entry"; then
        echo "Error: PostgreSQL selection policy differs from the pack SKU or tier mapping: $pack" >&2
        return 1
    fi
    for setting in "version: '16'" "availabilityZone: -1" "highAvailability: 'Disabled'" \
        "geoRedundantBackup: 'Disabled'" "storageSizeGB: 32" "publicNetworkAccess: 'Enabled'" \
        "activeDirectoryAuth: 'Enabled'" "passwordAuth: 'Enabled'"; do
        if ! grep -Fq "$setting" <<<"$entry"; then
            echo "Error: PostgreSQL selection policy differs from pack setting $setting: $pack" >&2
            return 1
        fi
    done
}

rtc_postgres_positive_limit() {
    local value="$1" maximum="$2"
    [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$value <= maximum))
}

rtc_postgres_normalize_test_sizes() {
    local size_list="${RTC_POSTGRES_TEST_SIZES-S,M}" size
    local -a sizes=() normalized=()
    if [[ ! "$size_list" =~ ^[SM](,[SM])*$ || ${#size_list} -gt 63 ]]; then
        echo "Error: Invalid PostgreSQL test size list." >&2
        return 1
    fi
    IFS=',' read -r -a sizes <<<"$size_list"
    for size in "${sizes[@]}"; do
        if [[ ! " ${normalized[*]} " == *" $size "* ]]; then
            normalized+=("$size")
        fi
    done
    (IFS=','; printf '%s\n' "${normalized[*]}")
}

rtc_postgres_cleanup_reserve_seconds() {
    local value="${RTC_POSTGRES_CLEANUP_RESERVE_SECONDS-900}"
    if ! rtc_postgres_positive_limit "$value" 900; then
        echo "Error: Invalid PostgreSQL cleanup reserve." >&2
        return 1
    fi
    printf '%s\n' "$value"
}

rtc_forward_command_signal() {
    local signal="$1"
    rtc_command_signal="$signal"
    printf '%s\n' "$signal" >"$rtc_command_signal_file"
    if [[ -n "${rtc_command_pid:-}" ]]; then
        kill -s "$signal" "$rtc_command_pid" 2>/dev/null || true
    fi
}

rtc_run_command() {
    local timeout="" quiet=false stdout_file="" stderr_file="" output_file
    local previous_int previous_term status=0 signal="" script_dir rtc_command_stderr_fd
    local -a supervisor_args=()
    while (($#)); do
        case "$1" in
            --timeout)
                (($# >= 2)) || { echo "Error: --timeout requires a limit." >&2; return 1; }
                timeout="$2"
                shift 2
                ;;
            --quiet)
                quiet=true
                shift
                ;;
            --stdout)
                (($# >= 2)) || { echo "Error: --stdout requires a file." >&2; return 1; }
                stdout_file="$2"
                shift 2
                ;;
            --stderr)
                (($# >= 2)) || { echo "Error: --stderr requires a file." >&2; return 1; }
                stderr_file="$2"
                shift 2
                ;;
            *) break ;;
        esac
    done
    if (($# == 0)) || { [[ -n "$timeout" ]] && ! rtc_postgres_positive_limit "$timeout" 999999; }; then
        echo "Error: bounded command requires a command and a positive time limit." >&2
        return 1
    fi
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    previous_int="$(trap -p INT)"
    previous_term="$(trap -p TERM)"
    local rtc_command_pid="" rtc_command_signal="" rtc_command_signal_file rtc_command_signal_fd
    if [[ -n "$stdout_file" ]]; then
        output_file="$stdout_file"
    else
        output_file="$(mktemp "${TMPDIR:-/tmp}/rtc-command-XXXXXX")" || return 1
    fi
    rtc_command_signal_file="$(mktemp "${TMPDIR:-/tmp}/rtc-command-signal-XXXXXX")" || {
        [[ -n "$stdout_file" ]] || rm -f -- "$output_file"
        return 1
    }
    if ! exec {rtc_command_signal_fd}<"$rtc_command_signal_file"; then
        rm -f -- "$rtc_command_signal_file"
        [[ -n "$stdout_file" ]] || rm -f -- "$output_file"
        return 1
    fi
    trap 'rtc_forward_command_signal INT' INT
    trap 'rtc_forward_command_signal TERM' TERM
    if [[ -z "$rtc_command_signal" ]]; then
        [[ -z "$timeout" ]] || supervisor_args=(--timeout "$timeout")
        if [[ -n "$stderr_file" ]]; then
            exec {rtc_command_stderr_fd}>"$stderr_file"
        else
            exec {rtc_command_stderr_fd}>&2
        fi
        RTC_COMMAND_SIGNAL_FD="$rtc_command_signal_fd" \
            python3 "$script_dir/run-command.py" "${supervisor_args[@]}" -- "$@" \
            >"$output_file" 2>&"$rtc_command_stderr_fd" &
        rtc_command_pid=$!
        if [[ -n "$rtc_command_signal" ]]; then
            rtc_forward_command_signal "$rtc_command_signal"
        fi
        if wait "$rtc_command_pid"; then status=0; else status=$?; fi
    fi
    if [[ -n "$rtc_command_signal" && -n "$rtc_command_pid" ]]; then
        while kill -0 "$rtc_command_pid" 2>/dev/null; do
            wait "$rtc_command_pid" 2>/dev/null || true
        done
    fi
    rtc_command_pid=""
    RTC_COMMAND_OUTPUT="$(<"$output_file")"
    if [[ "$quiet" != true ]]; then cat -- "$output_file"; fi
    [[ -n "$stdout_file" ]] || rm -f -- "$output_file"
    if [[ -n "$previous_int" ]]; then eval "$previous_int"; else trap - INT; fi
    if [[ -n "$previous_term" ]]; then eval "$previous_term"; else trap - TERM; fi
    signal="$rtc_command_signal"
    if [[ -n "${rtc_command_stderr_fd:-}" ]]; then exec {rtc_command_stderr_fd}>&-; fi
    exec {rtc_command_signal_fd}<&-
    rm -f -- "$rtc_command_signal_file"
    if [[ -n "$signal" ]]; then
        if [[ "$signal" == INT ]]; then status=130; else status=143; fi
        kill -s "$signal" "$BASHPID" 2>/dev/null || true
    fi
    return "$status"
}

rtc_postgres_catalog_result() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

def available(item):
    status = item.get("status")
    return (
        not item.get("reason") and item.get("restricted") in (None, False)
        and (status is None or isinstance(status, str) and status.lower() in {"available", "enabled", "supported"})
    )

def objects(parent, key):
    items = parent[key]
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(key)
    return items

def named(items):
    if not all(isinstance(item.get("name"), str) for item in items):
        raise ValueError("name")
    return items

def classify(catalog, tier, sku):
    if not isinstance(catalog, list) or not all(isinstance(item, dict) for item in catalog):
        return "InvalidCatalog"
    if not catalog:
        return "RegionRestricted"
    if any(not available(item) for item in catalog):
        return "RegionRestricted"
    for root in catalog:
        if "supportedFeatures" in root:
            for feature in named(objects(root, "supportedFeatures")):
                if feature["name"] == "OfferRestricted":
                    if feature.get("status") == "Enabled":
                        return "RegionRestricted"
                    if feature.get("status") != "Disabled":
                        return "InvalidCatalog"
        versions = named(objects(root, "supportedServerVersions"))
        editions = named(objects(root, "supportedServerEditions"))
        if not versions and not editions:
            return "RegionRestricted"
        for edition in editions:
            named(objects(edition, "supportedServerSkus"))
            for storage in named(objects(edition, "supportedStorageEditions")):
                for size in objects(storage, "supportedStorageMb"):
                    if type(size.get("storageSizeMb")) is not int:
                        raise ValueError("storageSizeMb")
    roots = [root for root in catalog if any(
        item["name"] == "16" and available(item) for item in root["supportedServerVersions"]
    )]
    if not roots:
        return "UnsupportedVersion"
    editions = [edition for root in roots for edition in root["supportedServerEditions"]
                if edition["name"] == tier and available(edition)]
    if not editions:
        return "UnsupportedTier"
    editions = [edition for edition in editions if any(
        item["name"] == sku and available(item) for item in edition["supportedServerSkus"]
    )]
    if not editions:
        return "UnsupportedSku"
    if not any(
        size["storageSizeMb"] == 32768 and available(size)
        for edition in editions for storage in edition["supportedStorageEditions"]
        if available(storage) for size in storage["supportedStorageMb"]
    ):
        return "UnsupportedStorage"
    return ""

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        result = classify(json.load(source), sys.argv[2], sys.argv[3])
except (ValueError, KeyError, TypeError):
    result = "InvalidCatalog"
print(result)
PY
}

# Read Azure CLI codes, not words in an error message. Reject mixed failures.
rtc_postgres_error_codes() {
    python3 - "$1" <<'PY'
import json
import re
import sys

def safe_code(value):
    return (
        value
        if isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", value)
        else "UnknownError"
    )

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    text = log.read()
decoder = json.JSONDecoder()
codes = set()

def visit(value):
    if isinstance(value, list):
        for item in value:
            visit(item)
    elif isinstance(value, dict):
        code = value.get("code")
        children = [value[key] for key in ("error", "details", "innererror") if key in value]
        if code is not None:
            codes.add(safe_code(code))
        elif not children or "message" in value:
            codes.add("UnknownError")
        for child in children:
            visit(child)
    else:
        codes.add("UnknownError")

while text.strip():
    text = re.sub(r"^(?:error|fatal|failure|failed):\s*", "", text.lstrip(), count=1, flags=re.I)
    if text.startswith(("{", "[")):
        try:
            value, end = decoder.raw_decode(text)
            visit(value)
            text = text[end:]
            continue
        except ValueError:
            pass
    line, _, text = text.partition("\n")
    match = re.fullmatch(r"\(([A-Za-z][A-Za-z0-9]*)\)(?:[ \t]+(.*))?", line.strip())
    codes.add(safe_code(match[1]) if match else "UnknownError")
    if match:
        envelope = re.match(
            r"Code:[ \t]*([A-Za-z][A-Za-z0-9]*)[ \t]*\r?\n"
            r"Message:[ \t]*([^\r\n]*)\r?(?:\n|$)", text
        )
        if (envelope and envelope[1] == match[1]
                and envelope[2].strip() == (match[2] or "").strip()):
            text = text[envelope.end():]

print("\n".join(sorted(codes)))
PY
}
