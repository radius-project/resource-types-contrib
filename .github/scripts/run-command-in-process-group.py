#!/usr/bin/env python3
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

"""Run an unbounded command in a process group and forward cancellation."""

import os
import signal
import subprocess
import sys
import time


def main():
    if len(sys.argv) < 2:
        print("Error: expected a command.", file=sys.stderr)
        return 1
    process = None
    interrupted = 0

    def kill_group():
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def forward_signal(signum, _frame):
        nonlocal interrupted
        if interrupted == 0:
            interrupted = signum
        if process is not None:
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    if interrupted:
        return 128 + interrupted
    try:
        process = subprocess.Popen(
            sys.argv[1:], start_new_session=True, stdin=subprocess.DEVNULL,
        )
        if interrupted:
            forward_signal(interrupted, None)
        deadline = time.monotonic() + 2 if interrupted else None
        escalated = False
        while True:
            try:
                status = process.wait(timeout=0.1)
                return 128 + interrupted if interrupted else status if status >= 0 else 128 - status
            except subprocess.TimeoutExpired:
                if interrupted and deadline is None:
                    deadline = time.monotonic() + 2
                if deadline is not None and time.monotonic() >= deadline and not escalated:
                    kill_group()
                    escalated = True
    except OSError as error:
        print(f"Error: could not start command: {error}", file=sys.stderr)
        return 1
    finally:
        kill_group()
        if process is not None:
            process.wait()


if __name__ == "__main__":
    sys.exit(main())
