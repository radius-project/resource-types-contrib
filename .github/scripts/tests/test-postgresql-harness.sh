#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed
# under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgresql-harness-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/released source's" "$TEST_ROOT/release candidate" "$TEST_ROOT/deployment"
cp "$REPO_ROOT/Data/postgreSqlDatabases/test/app.bicep" "$TEST_ROOT/released source's/app.bicep"
cp "$REPO_ROOT/Data/postgreSqlDatabases/test/verify-database.sh" "$TEST_ROOT/released source's/verify-database.sh"

prepare="$REPO_ROOT/.github/scripts/prepare-postgres-test-harness.sh"
bash "$prepare" "$TEST_ROOT/released source's/app.bicep" "$TEST_ROOT/release candidate/app.bicep"
bash "$prepare" "$TEST_ROOT/release candidate/app.bicep" "$TEST_ROOT/deployment/app.bicep"
cmp "$REPO_ROOT/Data/postgreSqlDatabases/test/app.bicep" "$TEST_ROOT/released source's/app.bicep"

python3 - "$TEST_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
expected = (root / "released source's/verify-database.sh").read_bytes()
for relative in ("release candidate/app.bicep", "deployment/app.bicep"):
    template = root / relative
    text = template.read_text(encoding="utf-8")
    assert re.search(r"resource postgresql 'postgreSqlDatabases:Radius\.Data/postgreSqlDatabases@", text), (
        f"PostgreSQL must select its local schema explicitly in {template}"
    )
    references = re.findall(r"loadTextContent\('((?:[^'\\]|\\.)*)'\)", text)
    assert len(references) == 1, f"Expected one probe file reference in {template}"
    file_path = references[0].replace("\\'", "'").replace("\\\\", "\\")
    loaded = (template.parent / file_path).resolve()
    assert loaded.read_bytes() == expected, f"Probe content changed in {template}"
PY

rm "$TEST_ROOT/released source's/verify-database.sh"
if bash "$prepare" "$TEST_ROOT/released source's/app.bicep" "$TEST_ROOT/missing.bicep" >/dev/null 2>&1; then
    echo "FAIL: a missing companion file must fail harness preparation" >&2
    exit 1
fi
echo "PostgreSQL harness file references survive both preparation steps"
