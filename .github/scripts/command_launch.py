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

"""Keep a command behind a pipe until its supervisor confirms launch."""

import os
import signal
import subprocess
import sys


class CommandLaunch:
    def __init__(self):
        self.read_fd, self.write_fd = os.pipe()

    def cancel(self):
        if self.write_fd is not None:
            descriptor, self.write_fd = self.write_fd, None
            os.close(descriptor)

    def start(self, command, pass_fds=()):
        return subprocess.Popen(
            [sys.executable, __file__, str(self.read_fd), *command],
            start_new_session=True, stdin=subprocess.DEVNULL,
            pass_fds=(*pass_fds, self.read_fd),
        )

    def release(self):
        # Commit launch before dispatching any later cancellation handler.
        signals = {signal.SIGINT, signal.SIGTERM}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            if self.write_fd is not None and not signal.sigpending() & signals:
                os.write(self.write_fd, b"1")
        finally:
            self.cancel()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def close(self):
        self.cancel()
        if self.read_fd is not None:
            descriptor, self.read_fd = self.read_fd, None
            os.close(descriptor)


def main():
    if len(sys.argv) < 3 or not sys.argv[1].isdigit():
        print("Error: expected a launch descriptor and a command.", file=sys.stderr)
        return 1
    try:
        descriptor = int(sys.argv[1])
        allowed = os.read(descriptor, 1)
        os.close(descriptor)
        if allowed != b"1":
            return 125
        os.execvpe(sys.argv[2], sys.argv[2:], os.environ)
    except OSError as error:
        print(f"Error: could not launch command: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
