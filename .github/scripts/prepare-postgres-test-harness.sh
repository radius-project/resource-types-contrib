#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

if (($# != 2)); then
    echo "Usage: $0 <pinned-test-app.bicep> <output-harness.bicep>" >&2
    exit 2
fi

python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])

def fail(message):
    print(f"Error: PostgreSQL test template cannot be parameterized safely: {message}", file=sys.stderr)
    raise SystemExit(1)

if not source.is_file():
    fail(f"source file not found: {source}")
if source.resolve() == destination.resolve():
    fail("output must not overwrite the pinned test app")

text = source.read_text(encoding="utf-8")
if len(re.findall(r"(?m)^[ \t]*param applicationName string\b", text)) != 1:
    fail("expected one applicationName string parameter")

resource_pattern = re.compile(
    r"(?m)^resource[ \t]+postgresql[ \t]+'Radius\.Data/postgreSqlDatabases@[A-Za-z0-9-]+'[ \t]*=[ \t]*\{"
)
resources = list(resource_pattern.finditer(text))
if len(resources) != 1:
    fail("expected one PostgreSQL database resource")
resource_start = resources[0].start()
next_resource = re.search(r"(?m)^resource[ \t]+", text[resources[0].end():])
resource_end = resources[0].end() + next_resource.start() if next_resource else len(text)
resource_text = text[resource_start:resource_end]
size_pattern = re.compile(r"(?m)^([ \t]*size:[ \t]*)([^ \t\r\n]+)([ \t]*(?://.*)?)$")
size_fields = list(size_pattern.finditer(resource_text))
if len(size_fields) != 1:
    fail("expected one explicit PostgreSQL size property")

parameter_pattern = re.compile(r"(?m)^[ \t]*param[ \t]+postgresSize[ \t]+string\b")
parameters = list(parameter_pattern.finditer(text))
if len(parameters) > 1:
    fail("found duplicate postgresSize parameters")

if parameters:
    if size_fields[0].group(2) != "postgresSize":
        fail("postgresSize must drive the PostgreSQL resource size")
    decorator = re.search(
        r"(?m)^[ \t]*@allowed\(\[([^\]]*)\]\)[ \t]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*param[ \t]+postgresSize[ \t]+string\b",
        text,
    )
    if decorator:
        allowed = set(re.findall(r"'([^']+)'|\"([^\"]+)\"", decorator.group(1)))
        allowed_values = {value for pair in allowed for value in pair if value}
        if not {"S", "M"}.issubset(allowed_values):
            fail("postgresSize must allow both S and M")
else:
    if re.search(r"\bpostgresSize\b", text):
        fail("found postgresSize references without a declaration")
    if size_fields[0].group(2) != "'S'":
        fail("an unparameterized PostgreSQL size must be the known fixed-S form")
    app_parameter = re.search(r"(?m)^[ \t]*param applicationName string[^\r\n]*$", text)
    if not app_parameter:
        fail("could not locate the applicationName parameter")
    start, end = size_fields[0].span(2)
    resource_text = resource_text[:start] + "postgresSize" + resource_text[end:]
    text = text[:resource_start] + resource_text + text[resource_end:]
    app_parameter = re.search(r"(?m)^[ \t]*param applicationName string[^\r\n]*$", text)
    insert_at = app_parameter.end()
    text = (
        text[:insert_at]
        + "\n\n@description('PostgreSQL test size selected by CI.')\n"
        + "@allowed(['S', 'M'])\n"
        + "param postgresSize string = 'S'"
        + text[insert_at:]
    )

destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text, encoding="utf-8")
PY
