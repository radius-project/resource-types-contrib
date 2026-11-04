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

"""Bound a command and its process group, including inherited output handles."""

import os
import signal
import subprocess
import sys

from command_launch import CommandLaunch


def main():
    if len(sys.argv) < 3 or not sys.argv[1].isdigit() or int(sys.argv[1]) <= 0:
        print("Error: expected a positive timeout and a command.", file=sys.stderr)
        return 1
    process = None
    interrupted = 0
    launch = CommandLaunch()

    def kill_group():
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def interrupt(signum, _frame):
        nonlocal interrupted
        interrupted = signum
        launch.cancel()
        if process is None:
            return
        kill_group()
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        # A background shell can ignore SIGINT before Python installs handlers.
        signal_fd = os.environ.pop("RTC_COMMAND_SIGNAL_FD", None)
        if signal_fd is not None:
            with os.fdopen(int(signal_fd), encoding="ascii") as pending:
                pending_signal = pending.read().strip()
            if pending_signal:
                return 128 + {"INT": signal.SIGINT, "TERM": signal.SIGTERM}[pending_signal]
        if interrupted:
            return 128 + interrupted
        pass_fds = ()
        login_log_fd = os.environ.get("RTC_AZURE_LOGIN_LOG_FD")
        if login_log_fd is not None:
            if not login_log_fd.isdigit():
                print("Error: invalid Azure login log descriptor.", file=sys.stderr)
                return 1
            pass_fds = (int(login_log_fd),)
        process = launch.start(sys.argv[2:], pass_fds=pass_fds)
        if interrupted:
            return 128 + interrupted
        launch.release()
        try:
            status = process.wait(timeout=int(sys.argv[1]))
            return status if status >= 0 else 128 - status
        except subprocess.TimeoutExpired:
            return 124
    except OSError as error:
        print(f"Error: could not start bounded command: {error}", file=sys.stderr)
        return 1
    finally:
        launch.close()
        kill_group()
        if process is not None:
            process.wait()


if __name__ == "__main__":
    sys.exit(main())
