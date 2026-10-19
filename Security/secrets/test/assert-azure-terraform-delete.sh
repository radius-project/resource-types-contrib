#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

cp "$ROOT/Security/secrets/recipes/azure/terraform/"*.tf "$TEMP/"
mkdir "$TEMP/tests"
cp "$ROOT/Security/secrets/test/azure-terraform/"*.tftest.hcl "$TEMP/tests/"
terraform -chdir="$TEMP" init -backend=false -input=false -no-color
terraform -chdir="$TEMP" validate -no-color
terraform -chdir="$TEMP" test -no-color -filter=tests/lifecycle.tftest.hcl

# Expected failures must come from the real provider/input validation, not mocks
# accepting invalid values or unrelated initialization/authentication failures.
for operation in absent deploy null unknown; do
  case "$operation" in
    absent) field='' ;;
    null) field='operation=null,' ;;
    *) field="operation=\"$operation\"," ;;
  esac
  context="context={$field resource={name=\"fixture-secret\",properties={data={username={value=null},password={value=null}}}},azure={resourceGroup={name=\"fixture-group\"}}}"
  if terraform -chdir="$TEMP" test -no-color -filter=tests/invalid-create.tftest.hcl \
    -var="$context" > "$TEMP/invalid.log" 2>&1; then
    echo "FAIL: null create values accepted with operation=$operation" >&2
    exit 1
  fi
  if ! grep -F "one of \`value,value_wo\` must be specified" "$TEMP/invalid.log" >/dev/null; then
    cat "$TEMP/invalid.log" >&2
    echo "FAIL: expected AzureRM required-value validation with operation=$operation" >&2
    exit 1
  fi
done

for operation in absent deploy; do
  field=''
  if [ "$operation" = deploy ]; then field='operation="deploy",'; fi
  context="context={$field resource={name=\"fixture-secret\",properties={data={username={}}}},azure={resourceGroup={name=\"fixture-group\"}}}"
  if terraform -chdir="$TEMP" test -no-color -filter=tests/invalid-create.tftest.hcl \
    -var="$context" > "$TEMP/invalid.log" 2>&1; then
    echo "FAIL: missing create value accepted with operation=$operation" >&2
    exit 1
  fi
  if ! grep -F 'Unsupported attribute' "$TEMP/invalid.log" >/dev/null ||
    ! grep -F 'each.value.value' "$TEMP/invalid.log" >/dev/null; then
    cat "$TEMP/invalid.log" >&2
    echo "FAIL: expected missing-value validation with operation=$operation" >&2
    exit 1
  fi
done

echo "PASS: Azure Secret Terraform lifecycle and six fail-closed create cases"
