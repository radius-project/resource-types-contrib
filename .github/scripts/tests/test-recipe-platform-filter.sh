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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-platform-filter-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo with spaces [fixture]"
TYPE_DIR="$FIXTURE_ROOT/Data/testResources"
EMPTY_TYPE_DIR="$FIXTURE_ROOT/Data/emptyResources"
PLATFORMS=(azure azure-aks AZURE-ACI aws aws-rds Kubernetes notazure gazure)
mkdir -p "$TYPE_DIR" "$EMPTY_TYPE_DIR" "$FIXTURE_ROOT/.github/scripts" "$TEST_ROOT/bin"
printf 'namespace: Radius.Data\ntypes:\n' >"$TYPE_DIR/testResources.yaml"
printf 'namespace: Radius.Data\ntypes:\n' >"$EMPTY_TYPE_DIR/emptyResources.yaml"
cp "$REPO_ROOT/.github/scripts/list-resource-type-folders.sh" "$FIXTURE_ROOT/.github/scripts/"
chmod +x "$FIXTURE_ROOT/.github/scripts/list-resource-type-folders.sh"

for platform in "${PLATFORMS[@]}" azure-aca; do
    mkdir -p "$TYPE_DIR/recipes/$platform/bicep" "$TYPE_DIR/recipes/$platform/terraform"
    touch "$TYPE_DIR/recipes/$platform/bicep/main.bicep" \
        "$TYPE_DIR/recipes/$platform/bicep/second.bicep" \
        "$TYPE_DIR/recipes/$platform/terraform/main.tf"
done

export CALL_LOG="$TEST_ROOT/build-calls"
cat >"$TEST_ROOT/bin/make" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$#" == 3 && "$1" == "-s" ]] || exit 1
case "$2" in
    build-resource-type)
        [[ "$3" == TYPE_FOLDER=* ]] || exit 1
        printf 'type|%s\n' "${3#TYPE_FOLDER=}" >>"$CALL_LOG"
        ;;
    build-bicep-recipe|build-terraform-recipe)
        [[ "$3" == RECIPE_PATH=* ]] || exit 1
        printf '%s|%s\n' "$2" "${3#RECIPE_PATH=}" >>"$CALL_LOG"
        ;;
    *)
        echo "Unexpected make target: $2" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/make"
export PATH="$TEST_ROOT/bin:$PATH"

check_selection() {
    local label="$1"
    shift
    local platform recipe_type path target
    printf 'type|%s\ntype|%s\n' "$TYPE_DIR" "$EMPTY_TYPE_DIR" >"$TEST_ROOT/expected-build"
    : >"$TEST_ROOT/expected-bicep"
    : >"$TEST_ROOT/expected-terraform"
    for platform in "$@"; do
        path="$TYPE_DIR/recipes/$platform"
        printf 'build-bicep-recipe|%s/bicep/main.bicep\nbuild-bicep-recipe|%s/bicep/second.bicep\nbuild-terraform-recipe|%s/terraform\n' \
            "$path" "$path" "$path" >>"$TEST_ROOT/expected-build"
        printf '%s/bicep\n' "$path" >>"$TEST_ROOT/expected-bicep"
        printf '%s/terraform\n' "$path" >>"$TEST_ROOT/expected-terraform"
    done
    cat "$TEST_ROOT/expected-bicep" "$TEST_ROOT/expected-terraform" >"$TEST_ROOT/expected-all"

    : >"$CALL_LOG"
    (
        cd "$FIXTURE_ROOT"
        bash "$REPO_ROOT/.github/scripts/build-all.sh" "$FIXTURE_ROOT"
    ) >"$TEST_ROOT/build-output"
    sort "$CALL_LOG" >"$TEST_ROOT/actual-build"
    sort -o "$TEST_ROOT/expected-build" "$TEST_ROOT/expected-build"
    if ! diff -u "$TEST_ROOT/expected-build" "$TEST_ROOT/actual-build"; then
        echo "FAIL: build selection ($label)" >&2
        cat "$TEST_ROOT/build-output" >&2
        exit 1
    fi

    : >"$TEST_ROOT/built-bicep"
    : >"$TEST_ROOT/built-terraform"
    while IFS='|' read -r target path; do
        case "$target" in
            build-bicep-recipe) dirname "$path" >>"$TEST_ROOT/built-bicep" ;;
            build-terraform-recipe) printf '%s\n' "$path" >>"$TEST_ROOT/built-terraform" ;;
        esac
    done <"$CALL_LOG"
    cat "$TEST_ROOT/built-bicep" "$TEST_ROOT/built-terraform" >"$TEST_ROOT/built-all"

    for recipe_type in bicep terraform all; do
        bash "$REPO_ROOT/.github/scripts/list-recipe-folders.sh" "$FIXTURE_ROOT" "$recipe_type" \
            >"$TEST_ROOT/actual-discovery"
        sort -u -o "$TEST_ROOT/expected-$recipe_type" "$TEST_ROOT/expected-$recipe_type"
        if ! diff -u "$TEST_ROOT/expected-$recipe_type" "$TEST_ROOT/actual-discovery"; then
            echo "FAIL: $recipe_type discovery selection ($label)" >&2
            exit 1
        fi
        sort -u -o "$TEST_ROOT/built-$recipe_type" "$TEST_ROOT/built-$recipe_type"
        if ! diff -u "$TEST_ROOT/built-$recipe_type" "$TEST_ROOT/actual-discovery"; then
            echo "FAIL: $recipe_type build/discovery parity ($label)" >&2
            exit 1
        fi
    done
    echo "PASS: $label"
}

check_filter() {
    local filter="$1"
    shift
    RECIPE_PLATFORM_FILTER="$filter" check_selection "filter '$filter'" "$@"
}

unset RECIPE_PLATFORM_FILTER
check_selection "unset filter" "${PLATFORMS[@]}"
check_filter "" "${PLATFORMS[@]}"
check_filter " , , " "${PLATFORMS[@]}"
check_filter "azure" azure azure-aks AZURE-ACI
check_filter "AZURE" azure azure-aks AZURE-ACI
check_filter "Az" azure azure-aks AZURE-ACI
check_filter "azure-aks" azure-aks
check_filter "azure-aci" AZURE-ACI
check_filter "azure-aca" azure-aca
check_filter "AZURE-ACA" azure-aca
check_filter "azure,azure-aca" azure azure-aks AZURE-ACI azure-aca
check_filter "aws" aws aws-rds
check_filter "KUBERNETES" Kubernetes
check_filter " AZURE , aws , " azure azure-aks AZURE-ACI aws aws-rds
check_filter "aws,azure-aks" aws aws-rds azure-aks
check_filter "azure,AZURE" azure azure-aks AZURE-ACI
check_filter "unknown"
check_filter "azure*"
check_filter "azure aws"

CONTAINER_DIR="$FIXTURE_ROOT/Compute/containers"
SECRET_DIR="$FIXTURE_ROOT/Security/secrets"
mkdir -p "$CONTAINER_DIR/recipes/kubernetes/bicep" "$CONTAINER_DIR/recipes/kubernetes/terraform" \
    "$SECRET_DIR/recipes/kubernetes/bicep" "$SECRET_DIR/recipes/kubernetes/terraform" \
    "$SECRET_DIR/recipes/azure/bicep"
printf 'namespace: Radius.Compute\ntypes:\n' >"$CONTAINER_DIR/containers.yaml"
printf 'namespace: Radius.Security\ntypes:\n' >"$SECRET_DIR/secrets.yaml"
touch "$CONTAINER_DIR/recipes/kubernetes/bicep/main.bicep" \
    "$CONTAINER_DIR/recipes/kubernetes/terraform/main.tf" \
    "$SECRET_DIR/recipes/kubernetes/bicep/main.bicep" \
    "$SECRET_DIR/recipes/kubernetes/terraform/main.tf" \
    "$SECRET_DIR/recipes/azure/bicep/main.bicep"
: >"$CALL_LOG"
(
    cd "$FIXTURE_ROOT"
    RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
        bash "$REPO_ROOT/.github/scripts/build-all.sh" "$FIXTURE_ROOT"
) >"$TEST_ROOT/build-output"
grep -Fxq "build-bicep-recipe|$CONTAINER_DIR/recipes/kubernetes/bicep/main.bicep" "$CALL_LOG" ||
    { echo "FAIL: Azure builds must publish the Kubernetes container dependency" >&2; exit 1; }
for secret_recipe in kubernetes azure; do
    grep -Fxq "build-bicep-recipe|$SECRET_DIR/recipes/$secret_recipe/bicep/main.bicep" "$CALL_LOG" ||
        { echo "FAIL: Azure builds must publish both secret backends" >&2; exit 1; }
done
for dependency in "$CONTAINER_DIR" "$SECRET_DIR"; do
    if grep -Fq "build-terraform-recipe|$dependency/recipes/kubernetes/terraform" "$CALL_LOG"; then
        echo "FAIL: Azure dependencies must not add Kubernetes Terraform recipes" >&2
        exit 1
    fi
done
RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
    bash "$REPO_ROOT/.github/scripts/list-recipe-folders.sh" "$FIXTURE_ROOT" bicep >"$TEST_ROOT/actual-discovery"
for dependency in "$CONTAINER_DIR" "$SECRET_DIR"; do
    if grep -Fq "$dependency/recipes/kubernetes" "$TEST_ROOT/actual-discovery"; then
        echo "FAIL: a pack dependency must not become an independent Azure recipe test" >&2
        exit 1
    fi
done
grep -Fxq "$SECRET_DIR/recipes/azure/bicep" "$TEST_ROOT/actual-discovery" ||
    { echo "FAIL: Azure secrets must retain independent recipe coverage" >&2; exit 1; }

echo "Recipe platform filter tests passed"
