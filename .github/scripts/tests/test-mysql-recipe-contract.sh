#!/bin/bash

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

# Runs Data/mySqlDatabases/test/assert-recipe-result.sh on copies of the AWS
# MySQL Recipe and the aws-eks pack with new required Recipe parameters. A
# parameter that the pack passes must not fail the contract test, whatever its
# type, and one that the pack doesn't pass must. Needs the Bicep CLI that the
# rad CLI installs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mysql-recipe-contract-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

RECIPE=Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep
PACK=recipe-packs/aws-eks/aws-eks.bicep

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# The Python helpers below edit copies of the Recipe and the pack.
cat >"$TEST_ROOT/edit.py" <<'PY'
import json, re, sys

IDENTIFIER = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
PARAMETER_REFERENCE = re.compile(r"\[parameters\('([A-Za-z_][A-Za-z0-9_]*)'\)\]")
TRIPLE_QUOTE = "'" * 3

def skip_string(source, i):
    """Index after the string that starts at i, including ${...} expressions
    with their own strings and braces."""
    if source.startswith(TRIPLE_QUOTE, i):
        return source.index(TRIPLE_QUOTE, i + 3) + 3
    i += 1
    while source[i] != "'":
        if source[i] == '\\':
            i += 2
        elif source.startswith('${', i):
            depth, i = 1, i + 2
            while depth:
                if source[i] == "'":
                    i = skip_string(source, i)
                    continue
                depth += {'{': 1, '}': -1}.get(source[i], 0)
                i += 1
        else:
            i += 1
    return i + 1

def tokens(source):
    """The (start, text) of each token, without whitespace and comments.
    A string is one token."""
    i, result = 0, []
    while i < len(source):
        if source[i].isspace():
            i += 1
        elif source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            i = source.index('*/', i) + 2
        else:
            match = IDENTIFIER.match(source, i)
            end = skip_string(source, i) if source[i] == "'" else match.end() if match else i + 1
            result.append((i, source[i:end]))
            i = end
    return result

def object_tokens(toks, k):
    """Yields (index, depth) for the tokens from the { at toks[k] to its
    closing }. Depth counts { and [ opened after toks[k]."""
    depth = 0
    for index in range(k, len(toks)):
        text = toks[index][1]
        if text in ('}', ']'):
            depth -= 1
        yield index, depth
        if text in ('{', '['):
            depth += 1
        if depth == 0:
            return
    sys.exit('unbalanced object')

def property_object(toks, k, names):
    """True when toks[k] is one of the keys in names, followed by : and {."""
    return toks[k][1] in names and [t for _, t in toks[k + 1:k + 3]] == [':', '{']

def parameters_brace(source):
    """(tokens, index of the token) for the { that opens the MySQL entry's
    parameters object."""
    toks = tokens(source)
    entries = [k for k in range(len(toks)) if property_object(toks, k, ["'Radius.Data/mySqlDatabases'"])]
    if len(entries) != 1:
        sys.exit('the pack must have exactly one Radius.Data/mySqlDatabases entry')
    for k, depth in object_tokens(toks, entries[0] + 2):
        if depth == 1 and property_object(toks, k, ['parameters', "'parameters'"]):
            return toks, k + 2
    sys.exit('the MySQL entry must have a parameters object')

def add(recipe_path, pack_path, recipe_params, pack_params):
    """Adds Recipe parameters at the end of the Recipe, and pack entries on
    their own lines after the parameters object's {. Bicep accepts that
    however the object's other entries are written."""
    if recipe_params:
        with open(recipe_path, 'a') as recipe:
            recipe.write('\n' + recipe_params + '\n')
    if pack_params:
        source = open(pack_path).read()
        toks, k = parameters_brace(source)
        brace = toks[k][0]
        open(pack_path, 'w').write(source[:brace + 1] + '\n' + pack_params + '\n' + source[brace + 1:])

def string_literal(text):
    for char, escaped in (('\\', '\\\\'), ("'", "\\'"), ('${', '\\${'), ('\n', '\\n'), ('\r', '\\r'), ('\t', '\\t')):
        text = text.replace(char, escaped)
    return "'" + text + "'"

def bicep(value):
    """Bicep text for a compiled ARM value: a pack parameter or a literal.
    ARM writes a literal string that starts with [ as [[."""
    if isinstance(value, str) and value.startswith('[') and not value.startswith('[['):
        match = PARAMETER_REFERENCE.fullmatch(value)
        if not match:
            sys.exit(f'restyling supports only pack parameters and literals, not {value}. Extend bicep() in this test')
        return match.group(1)
    if isinstance(value, str):
        return string_literal(value[1:] if value.startswith('[[') else value)
    if isinstance(value, dict):
        return '{ ' + ', '.join(f'{key(k, False)}: {bicep(v)}' for k, v in value.items()) + ' }'
    if isinstance(value, list):
        return '[' + ', '.join(bicep(v) for v in value) + ']'
    return json.dumps(value)

def key(name, quoted):
    if not quoted and IDENTIFIER.fullmatch(name):
        return name
    return string_literal(name)

def restyle(pack_path, compiled_path, style):
    """Writes the MySQL entry's parameters object again on one line, with
    quoted keys, or with comments that hold quotes and braces. It reads them
    from the compiled pack, so it doesn't depend on how the checked-in pack
    writes them."""
    compiled = json.load(open(compiled_path))
    packs = [r for r in compiled['resources'].values() if r['type'].startswith('Radius.Core/recipePacks@')]
    params = packs[0]['properties']['properties']['recipes']['Radius.Data/mySqlDatabases']['parameters']
    if style == 'one-line':
        rendered = '{ ' + ', '.join(f'{key(k, False)}: {bicep(v)}' for k, v in params.items()) + ' }'
    elif style == 'quoted':
        rendered = '{\n' + ''.join(f'  {key(k, True)}: {bicep(v)}\n' for k, v in params.items()) + '}'
    else:
        rendered = "/* it's { */ { // it's }\n" + ''.join(f"  {key(k, False)}: /* ' */ {bicep(v)} // }}\n" for k, v in params.items()) + '}'
    source = open(pack_path).read()
    toks, k = parameters_brace(source)
    start, end = toks[k][0], toks[list(object_tokens(toks, k))[-1][0]][0]
    open(pack_path, 'w').write(source[:start] + rendered + source[end + 1:])

if sys.argv[1] == 'add':
    add(*sys.argv[2:])
else:
    restyle(*sys.argv[2:])
PY

# Copies the files the contract test reads, adds the Recipe parameter
# declarations and pack parameter entries from stdin (separated by a `---`
# line), runs the contract test, and prints its output. Set PACK_STYLE to
# `one-line`, `quoted`, or `commented` to first write the checked-in pack's
# MySQL parameters that way, as a contributor could.
run_contract_test() {
    local dir="$TEST_ROOT/$1" input
    rm -rf "$dir"
    mkdir -p "$dir/Data" "$dir/recipe-packs" "$dir/.github"
    cp -R "$REPO_ROOT/Data/mySqlDatabases" "$dir/Data/"
    cp -R "$REPO_ROOT/recipe-packs/aws-eks" "$dir/recipe-packs/"
    cp -R "$REPO_ROOT/.github/scripts" "$dir/.github/"
    input="$(cat)"
    if [[ -n "${PACK_STYLE:-}" ]]; then
        # shellcheck source=/dev/null
        (source "$dir/.github/scripts/lib-recipe-packs.sh" && rtc_build_recipe_pack "$dir/$PACK") >"$dir/pack.json" &&
            python3 "$TEST_ROOT/edit.py" restyle "$dir/$PACK" "$dir/pack.json" "$PACK_STYLE" || return 1
    fi
    python3 "$TEST_ROOT/edit.py" add "$dir/$RECIPE" "$dir/$PACK" \
        "$(sed '/^---$/,$d' <<<"$input")" "$(sed '1,/^---$/d' <<<"$input")" || return 1
    "$dir/Data/mySqlDatabases/test/assert-recipe-result.sh" 2>&1
}

expect_pass() {
    local label="$1" output
    output="$(run_contract_test "$label")" || fail "$label: the contract test should pass: $output"
}

expect_fail() {
    local label="$1" message="$2" output
    if output="$(run_contract_test "$label")"; then
        fail "$label: the contract test should fail"
    fi
    [[ "$output" == *"$message"* ]] || fail "$label: expected '$message' in: $output"
}

expect_pass required-object <<'EOF'
param extra object
---
          extra: {
            a: 'b'
          }
EOF

expect_pass required-string <<'EOF'
param extra string
---
          extra: 'value'
EOF

# The checked-in pack can write the MySQL parameters on one line, with quoted
# keys, or with comments, which the contract test accepts. Building the
# fixtures must too.
for style in one-line quoted commented; do
    PACK_STYLE=$style expect_pass "$style-unchanged" <<<'---'
    PACK_STYLE=$style expect_pass "$style-required-object" <<'EOF'
param extra object
---
extra: { a: 'b' }
EOF
    PACK_STYLE=$style expect_fail "$style-required-object-not-passed" 'Radius.Data/mySqlDatabases in the pack passes [' <<'EOF'
param extra object
---
EOF
done

# The placeholders must satisfy the parameter's decorators, and a string
# value must survive Bicep quoting.
expect_pass required-other-types <<'EOF'
@minValue(20)
param size int
param enabled bool
param zones array
@secure()
param token string
@secure()
param settings object
@allowed(['it\'s \${x} \\', 'b'])
param mode string
@minLength(5)
param label string
@allowed(['line1\nline2', 'fallback'])
param note string
@allowed(['a', 'b'])
@minLength(1)
param tiers array
---
          size: 30
          enabled: true
          zones: ['a']
          token: 'secret'
          settings: {}
          mode: 'b'
          label: 'abcde'
          note: 'fallback'
          tiers: ['b']
EOF

# The pack check must report it, not the snapshot.
expect_fail required-object-not-passed 'Radius.Data/mySqlDatabases in the pack passes [' <<'EOF'
param extra object
---
EOF

# The test can't choose a value for an object with a declared shape, so it
# must say what to do instead of failing in Bicep.
expect_fail required-typed-object 'Add a sample value for the Recipe parameter extra' <<'EOF'
param extra { name: string }
---
          extra: { name: 'x' }
EOF

expect_fail required-discriminated-object 'Add a sample value for the Recipe parameter extra' <<'EOF'
@discriminator('kind')
type extraType = { kind: 'a', name: string } | { kind: 'b' }
param extra extraType
---
          extra: { kind: 'b' }
EOF

expect_fail required-typed-array 'Add a sample value for the Recipe parameter extra' <<'EOF'
@minLength(1)
param extra string[]
---
          extra: ['x']
EOF

echo "MySQL Recipe contract test tests passed"
