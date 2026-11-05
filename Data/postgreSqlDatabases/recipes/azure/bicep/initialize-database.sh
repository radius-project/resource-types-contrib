#!/bin/sh
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed
# under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

set -eu

if ! command -v psql >/dev/null 2>&1; then
    # Avoid loading unrelated package indexes in the memory-limited runner.
    if ! tdnf install -y --disablerepo='*' --enablerepo=azurelinux-official-base postgresql >/dev/null; then
        echo "Error: Could not install the PostgreSQL client." >&2
        exit 1
    fi
fi

# Do not print SQL results or errors: init scripts can contain credentials.
if ! printf '%s\n' "$INIT_SQL" | psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --file=- >/dev/null 2>&1; then
    echo "Error: PostgreSQL initSql failed. Check the SQL and database connection settings." >&2
    exit 1
fi
