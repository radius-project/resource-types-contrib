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

if ! result=$(psql --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 \
    --command='CREATE EXTENSION IF NOT EXISTS pg_trgm;' \
    --command="SELECT EXISTS (SELECT FROM pg_extension WHERE extname = 'pg_trgm')
AND current_setting('log_min_duration_statement') = '1s'
AND EXISTS (SELECT FROM radius_test.seed WHERE id = 1 AND value = 'ready');" 2>/dev/null); then
    echo "Error: PostgreSQL extension, server setting, or seed query failed." >&2
    exit 1
fi

if [ "$result" != t ]; then
    echo "Error: PostgreSQL extension, server setting, or seed data is missing." >&2
    exit 1
fi
