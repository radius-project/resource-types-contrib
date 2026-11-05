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

"""Run a command in a supervised process group, with an optional timeout."""

import ctypes
import os
import signal
import subprocess
import sys
import time


_SIGNALS = {"INT": signal.SIGINT, "TERM": signal.SIGTERM}


def _set_parent_death_signal():
    if sys.platform != "linux":
        return
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG) failed")
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


class LaunchGate:
    def __init__(self):
        self.read_fd, self.write_fd = os.pipe()

    def cancel(self):
        if self.write_fd is not None:
            descriptor, self.write_fd = self.write_fd, None
            os.close(descriptor)

    def start(self, command, pass_fds=()):
        return subprocess.Popen(
            [
                sys.executable,
                __file__,
                "--child",
                str(self.read_fd),
                *command,
            ],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            pass_fds=(*pass_fds, self.read_fd),
            preexec_fn=_set_parent_death_signal if sys.platform == "linux" else None,
        )

    def release(self):
        blocked = {signal.SIGINT, signal.SIGTERM}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            if self.write_fd is not None and not signal.sigpending() & blocked:
                os.write(self.write_fd, b"1")
        finally:
            self.cancel()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def close(self):
        self.cancel()
        if self.read_fd is not None:
            descriptor, self.read_fd = self.read_fd, None
            os.close(descriptor)


def _child_main(arguments):
    if len(arguments) < 2 or not arguments[0].isdigit():
        print("Error: expected a launch descriptor and a command.", file=sys.stderr)
        return 1
    descriptor = int(arguments[0])
    try:
        allowed = os.read(descriptor, 1)
        os.close(descriptor)
        if allowed != b"1":
            return 125
        os.execvpe(arguments[1], arguments[1:], os.environ)
    except OSError as error:
        print(f"Error: could not launch command: {error}", file=sys.stderr)
        return 1


def _parse_arguments(arguments):
    timeout = None
    if arguments[:1] == ["--timeout"]:
        if len(arguments) < 3:
            raise ValueError("--timeout requires a positive integer and a command")
        try:
            timeout = int(arguments[1])
        except ValueError as error:
            raise ValueError("--timeout requires a positive integer") from error
        if timeout <= 0:
            raise ValueError("--timeout requires a positive integer")
        arguments = arguments[2:]
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError("expected a command")
    return timeout, arguments


def _pending_signal():
    descriptor = os.environ.pop("RTC_COMMAND_SIGNAL_FD", None)
    if descriptor is None:
        return 0
    if not descriptor.isdigit():
        raise ValueError("invalid pending-signal descriptor")
    try:
        with os.fdopen(int(descriptor), encoding="ascii") as pending:
            value = pending.read().strip()
    except (OSError, UnicodeError) as error:
        raise ValueError("could not read pending-signal data") from error
    if not value:
        return 0
    if value not in _SIGNALS:
        raise ValueError("invalid pending-signal data")
    return _SIGNALS[value]


def _pass_fds():
    descriptor = os.environ.get("RTC_AZURE_LOGIN_LOG_FD")
    if descriptor is None:
        return ()
    if not descriptor.isdigit():
        raise ValueError("invalid Azure login log descriptor")
    return (int(descriptor),)


def _kill_group(process, signum):
    if process is None:
        return
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def supervise(timeout, command):
    process = None
    interrupted = 0
    gate = LaunchGate()

    def forward_signal(signum, _frame):
        nonlocal interrupted
        if interrupted == 0:
            interrupted = signum
        gate.cancel()
        _kill_group(process, signum)

    signal.signal(signal.SIGINT, forward_signal)
    signal.signal(signal.SIGTERM, forward_signal)
    try:
        pending = _pending_signal()
        if pending:
            return 128 + pending
        pass_fds = _pass_fds()
        process = gate.start(command, pass_fds=pass_fds)
        if interrupted:
            forward_signal(interrupted, None)
        gate.release()
        timeout_deadline = time.monotonic() + timeout if timeout is not None else None
        interrupt_deadline = time.monotonic() + 2 if interrupted else None
        while True:
            try:
                status = process.wait(timeout=0.1)
                if interrupted:
                    return 128 + interrupted
                return status if status >= 0 else 128 - status
            except subprocess.TimeoutExpired:
                now = time.monotonic()
                if interrupted and interrupt_deadline is None:
                    interrupt_deadline = now + 2
                if interrupt_deadline is not None and now >= interrupt_deadline:
                    _kill_group(process, signal.SIGKILL)
                if timeout_deadline is not None and now >= timeout_deadline:
                    _kill_group(process, signal.SIGKILL)
                    process.wait()
                    return 124
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Error: could not supervise command: {error}", file=sys.stderr)
        return 1
    finally:
        gate.close()
        if process is not None:
            _kill_group(process, signal.SIGKILL)
            if process.poll() is None:
                process.wait()


def main():
    if sys.argv[1:2] == ["--child"]:
        return _child_main(sys.argv[2:])
    try:
        timeout, command = _parse_arguments(sys.argv[1:])
    except ValueError as error:
        print(f"Error: {error}.", file=sys.stderr)
        return 1
    return supervise(timeout, command)


if __name__ == "__main__":
    sys.exit(main())
