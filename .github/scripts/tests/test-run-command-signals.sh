#!/usr/bin/env bash
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-azure-postgres-test.sh
source "$SCRIPT_DIR/../lib-azure-postgres-test.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

for phase in prelaunch assignment startup; do
    for sig in INT TERM; do
        for mode in bounded unbounded; do
            (
                marker="$TEST_ROOT/$phase-$sig-$mode"
                delivered=0
                injected=0
                builtin trap 'delivered=$((delivered + 1))' "$sig"
                previous_int="$(builtin trap -p INT)"
                previous_term="$(builtin trap -p TERM)"

                # shellcheck disable=SC2329 # Called by the sourced wrapper.
                trap() {
                    # shellcheck disable=SC2064 # Forward the original trap arguments.
                    builtin trap "$@"
                    if [[ "$phase" == prelaunch && "${1-}" == "rtc_forward_command_signal $sig" && "${2-}" == "$sig" ]]; then
                        injected=1
                        kill -s "$sig" "$BASHPID"
                    fi
                }

                # Hold Python behind a barrier while a real parent-only signal arrives.
                # shellcheck disable=SC2329 # Called by the sourced wrapper.
                python3() {
                    if [[ "$phase" == startup ]]; then
                        : >"$marker-ready"
                        for ((attempt = 0; attempt < 300; attempt++)); do
                            [[ -f "$marker-release" ]] && break
                            sleep 0.01
                        done
                        [[ -f "$marker-release" ]] || return 1
                    fi
                    command python3 "$@"
                }

                # shellcheck disable=SC2329 # Called by the DEBUG trap.
                inject_signal() {
                    if [[ "$injected" == 0 && "$phase" == assignment && "$1" == 'rtc_command_pid=$!' ]]; then
                        injected=1
                        kill -s "$sig" "$BASHPID"
                    fi
                }
                set -o functrace
                builtin trap 'inject_signal "$BASH_COMMAND"' DEBUG
                controller=""
                if [[ "$phase" == startup ]]; then
                    parent="$BASHPID"
                    (
                        for ((attempt = 0; attempt < 300; attempt++)); do
                            [[ -f "$marker-ready" ]] && break
                            sleep 0.01
                        done
                        [[ -f "$marker-ready" ]] || exit 1
                        kill -s "$sig" "$parent"
                        : >"$marker-sent"
                        sleep 0.1
                        : >"$marker-release"
                    ) &
                    controller=$!
                fi
                status=0
                # shellcheck disable=SC2016 # Expanded by the child shell.
                command_args=(bash -c 'printf started >"$1"' _ "$marker")
                if [[ "$phase" == assignment ]]; then
                    # shellcheck disable=SC2016 # Expanded by the child shell.
                    command_args=(bash -c 'sleep 1; printf survived >"$1"' _ "$marker")
                fi
                if [[ "$mode" == bounded ]]; then
                    rtc_run_command --timeout 5 --quiet "${command_args[@]}" || status=$?
                else
                    rtc_run_command --quiet "${command_args[@]}" || status=$?
                fi
                builtin trap - DEBUG
                if [[ -n "$controller" ]]; then
                    wait "$controller"
                    [[ ! -f "$marker-sent" ]] || injected=1
                fi
                if [[ "$sig" == INT ]]; then expected_status=130; else expected_status=143; fi
                if [[ -f "$marker" || "$injected" != 1 || "$delivered" != 1 ||
                    "$status" != "$expected_status" ||
                    "$(builtin trap -p INT)" != "$previous_int" ||
                    "$(builtin trap -p TERM)" != "$previous_term" ]]; then
                    printf 'FAIL: %s %s %s: status=%s injected=%s previous_trap_called=%s\n' \
                        "$phase" "$sig" "$mode" "$status" "$injected" "$delivered" >&2
                    exit 1
                fi
            )
        done
    done
done

rtc_run_command --quiet python3 "$SCRIPT_DIR/../run-command.py" --timeout 5 -- true
rtc_run_command --timeout 5 --quiet python3 "$SCRIPT_DIR/../run-command.py" -- true

echo "Command startup signal tests passed"
