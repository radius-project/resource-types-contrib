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

"""Cancel at Popen entry and let the child run before Popen returns."""

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
sys.path.insert(0, str(script_dir))

for bounded in (False, True):
    helper_path = script_dir / (
        "run-bounded-command.py" if bounded else "run-command-in-process-group.py"
    )
    spec = importlib.util.spec_from_file_location("helper", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
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
                sys.argv = [str(helper_path)] + (["5"] if bounded else []) + command
                with patch.object(subprocess, "Popen", cancel_before_spawn):
                    status = helper.main()
                assert status == 128 + signum, (helper_path.name, signum, status)
                assert not marker.exists(), (helper_path.name, signum, "target started")
            finally:
                sys.argv = previous_argv
                signal.signal(signal.SIGINT, previous_int)
                signal.signal(signal.SIGTERM, previous_term)

print("Command launch cancellation tests passed")
