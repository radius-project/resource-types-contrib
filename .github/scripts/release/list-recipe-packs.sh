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
# list-recipe-packs.sh
# -----------------------------------------------------------------------------
# Print the releasable recipe packs (directory names under recipe-packs/), one per
# line. Each is versioned and released independently by
# release-recipe-pack.yaml under the `recipe-pack/<pack>/vX.Y.Z` tag series.
#
# Usage:
#   ./.github/scripts/release/list-recipe-packs.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

rtc_list_recipe_packs
