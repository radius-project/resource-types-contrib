#!/bin/sh

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

set -eu

case "$MYSQL_TLS" in
    required) expected=1 ;;
    optional) expected=0 ;;
    *) echo "Error: Unknown MySQL transport policy." >&2; exit 1 ;;
esac

if ! actual=$(MYSQL_PWD="$MYSQL_PASSWORD" mysql \
    --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
    --database="$MYSQL_DB" --connect-timeout=5 --batch --skip-column-names \
    --execute='SELECT @@GLOBAL.require_secure_transport'); then
    echo "Error: Could not read the MySQL transport setting." >&2
    exit 1
fi

if [ "$actual" != "$expected" ]; then
    echo "Error: MySQL require_secure_transport is '$actual'; expected '$expected' for '$MYSQL_TLS'." >&2
    exit 1
fi
