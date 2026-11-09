#!/bin/bash

# Copyright 2026 The Radius Authors.
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

set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

# Official v1.2.0 multi-platform image. Docker verifies the manifest and layers
# against their digests; no mutable tag or release archive is used.
image="ghcr.io/oras-project/oras@sha256:0087224dd0decc354b5b0689068fbbc40cd5dc3dbf65fcb3868dfbd363dc790b"
install_dir="$(mktemp -d "$RUNNER_TEMP/rtc-oras-XXXXXX")"
container=""

cleanup() {
    local status=$?
    if [[ -n "$container" ]]; then
        if ! docker rm "$container" >&2; then
            echo "Failed to remove the ORAS setup container" >&2
            status=1
        fi
    fi
    if ((status != 0)); then
        rm -f "$install_dir/oras"
        rmdir "$install_dir"
    fi
    exit "$status"
}
trap cleanup EXIT

# Create, but do not start, a container so the CLI runs natively with the
# runner's existing registry credentials, file paths, and environment.
container="$(docker create "$image")"
docker cp "$container:/bin/oras" "$install_dir/oras"
chmod +x "$install_dir/oras"
version="$("$install_dir/oras" version)"
printf '%s\n' "$version"
if ! grep -Eq '^Version:[[:space:]]+1\.2\.0$' <<<"$version"; then
    echo "Expected ORAS version 1.2.0" >&2
    exit 1
fi
docker rm "$container" >&2
container=""
printf '%s\n' "$install_dir" >>"$GITHUB_PATH"
