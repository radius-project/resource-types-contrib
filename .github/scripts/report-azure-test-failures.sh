#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

failures=0
for result in "$@"; do
    [[ "$result" == *:* ]] || {
        echo "Error: invalid Azure test outcome '$result'." >&2
        exit 1
    }
    name="${result%%:*}"
    outcome="${result#*:}"
    if [[ -z "$name" || -z "$outcome" ]]; then
        echo "Error: invalid Azure test outcome '$result'." >&2
        exit 1
    fi
    if [[ "$outcome" != success ]]; then
        echo "::error::$name finished with outcome '$outcome'"
        failures=1
    fi
done
exit "$failures"
