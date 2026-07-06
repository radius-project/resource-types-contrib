#!/bin/bash

# ------------------------------------------------------------
# Copyright 2025 The Radius Authors.
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
# list-default-resource-types.sh
# -----------------------------------------------------------------------------
# Print the resource types that ship as defaults in Radius, one per line, in the
# "<namespace>/<typeName>" format (e.g. "Radius.Data/mySqlDatabases").
#
# These types are already registered by a stock Radius install and their Bicep
# types are bundled in the unified "radius" extension, so the test workflow does
# not need to create them or publish a standalone extension for them.
#
# The list is sourced from the Radius repo's deploy/manifest/defaults.yaml
# (defaultRegistration entries). The result is cached for the lifetime of the
# CI run so repeated invocations do not re-download the file.
#
# Configuration (environment variables):
#   DEFAULT_RESOURCE_TYPES  Space/newline separated list that overrides the
#                           fetched list entirely (useful for offline/testing).
#   DEFAULTS_YAML_URL       Override the source URL for defaults.yaml.
#
# On network failure with no cache available, prints nothing and exits 0 so that
# callers fall back to the previous behavior (build/publish everything).
# =============================================================================

set -euo pipefail

DEFAULTS_YAML_URL="${DEFAULTS_YAML_URL:-https://raw.githubusercontent.com/radius-project/radius/main/deploy/manifest/defaults.yaml}"
CACHE_FILE="${TMPDIR:-/tmp}/radius-default-resource-types.cache"

# Explicit override wins and is not cached.
if [[ -n "${DEFAULT_RESOURCE_TYPES:-}" ]]; then
    printf '%s\n' $DEFAULT_RESOURCE_TYPES | sed '/^[[:space:]]*$/d'
    exit 0
fi

# Reuse the cached list within the same CI run.
if [[ -s "$CACHE_FILE" ]]; then
    cat "$CACHE_FILE"
    exit 0
fi

# Fetch and parse the defaultRegistration entries. Every default entry is of the
# form "Radius.<Namespace>/<typeName>", so a targeted grep is sufficient and is
# resilient to comments or additional sections in the file.
fetched=""
if fetched="$(curl -fsSL "$DEFAULTS_YAML_URL" 2>/dev/null)"; then
    parsed="$(printf '%s\n' "$fetched" | grep -oE 'Radius\.[A-Za-z0-9]+/[A-Za-z0-9]+' | sort -u || true)"
    if [[ -n "$parsed" ]]; then
        printf '%s\n' "$parsed" > "$CACHE_FILE"
        printf '%s\n' "$parsed"
        exit 0
    fi
    echo "Warning: no defaultRegistration entries found in $DEFAULTS_YAML_URL" >&2
else
    echo "Warning: failed to fetch defaults.yaml from $DEFAULTS_YAML_URL; treating no resource types as defaults" >&2
fi

exit 0
