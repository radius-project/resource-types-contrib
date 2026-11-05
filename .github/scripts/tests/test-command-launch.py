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

"""Exercise command launch cancellation and pending-signal validation."""

import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch


script_dir = Path(__file__).resolve().parents[1]
helper_path = script_dir / "run-command.py"
spec = importlib.util.spec_from_file_location("helper", helper_path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

for bounded in (False, True):
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_int = signal.getsignal(signal.SIGINT)
        previous_term = signal.getsignal(signal.SIGTERM)
        previous_argv = sys.argv
        real_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "started"
            command = [
                sys.executable, "-c",
                "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(10)",
                str(marker),
            ]

            def cancel_before_spawn(*args, **kwargs):
                os.kill(os.getpid(), signum)
                process = real_popen(*args, **kwargs)
                deadline = time.monotonic() + 2
                while process.poll() is None and not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                return process

            try:
                sys.argv = [str(helper_path)] + (
                    ["--timeout", "5", "--"] if bounded else ["--"]
                ) + command
                with patch.object(subprocess, "Popen", cancel_before_spawn):
                    status = helper.main()
                assert status == 128 + signum, (bounded, signum, status)
                assert not marker.exists(), (bounded, signum, "target started")
            finally:
                sys.argv = previous_argv
                signal.signal(signal.SIGINT, previous_int)
                signal.signal(signal.SIGTERM, previous_term)

with tempfile.TemporaryFile() as pending:
    pending.write(b"INVALID\n")
    pending.seek(0)
    environment = os.environ.copy()
    environment["RTC_COMMAND_SIGNAL_FD"] = str(pending.fileno())
    result = subprocess.run(
        [sys.executable, helper_path, "--", "true"],
        capture_output=True,
        text=True,
        env=environment,
        pass_fds=(pending.fileno(),),
        check=False,
    )
    assert result.returncode == 1, result
    assert "invalid pending-signal data" in result.stderr, result
    assert "Traceback" not in result.stderr, result

print("Command launch cancellation tests passed")
