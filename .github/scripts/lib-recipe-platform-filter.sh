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

rtc_parse_recipe_platform_filter() {
    local raw="${RECIPE_PLATFORM_FILTER:-}"
    local entry trimmed
    local -a entries=()
    RTC_RECIPE_PLATFORM_FILTERS=()
    if [[ -n "$raw" ]]; then
        IFS=',' read -ra entries <<< "$raw"
        for entry in "${entries[@]}"; do
            trimmed="$(printf '%s' "$entry" | xargs)"
            if [[ -n "$trimmed" ]]; then
                RTC_RECIPE_PLATFORM_FILTERS+=("$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')")
            fi
        done
    fi
}

rtc_matches_recipe_platform() {
    local platform="$1"
    local filter
    if [[ ${#RTC_RECIPE_PLATFORM_FILTERS[@]} -eq 0 ]]; then
        return 0
    fi

    platform="$(printf '%s' "$platform" | tr '[:upper:]' '[:lower:]')"
    for filter in "${RTC_RECIPE_PLATFORM_FILTERS[@]}"; do
        # Match literal prefixes: azure includes azure, azure-aci, and azure-aks.
        if [[ "$platform" == "$filter"* ]]; then
            return 0
        fi
    done
    return 1
}

rtc_is_azure_test_container_dependency() {
    [[ "${RTC_ACI_TEST_SCOPE:-}" == exclude ]] || return 1
    case "/${1#./}" in
        */Compute/containers/recipes/kubernetes/bicep|*/Compute/containers/recipes/kubernetes/bicep/*.bicep)
            rtc_matches_recipe_platform azure
            ;;
        *) return 1 ;;
    esac
}
