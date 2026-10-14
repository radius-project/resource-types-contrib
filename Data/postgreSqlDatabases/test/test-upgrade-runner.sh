#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
cp "$TEST_DIR/test-upgrade.sh" "$TEST_ROOT/scripts/"

cat > "$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "rad $*" >> "$MOCK_STATE/invocations"
table() {
    printf '%-48s %-12s %-15s %-12s %s\n' WORKSPACE KIND KUBECONTEXT GROUP ENVIRONMENT
    printf '%-48s %-12s %-15s %-12s %s\n' "$1" kubernetes kind-radius default env
}
case "$1 $2" in
    "workspace show")
        [[ "$*" == "workspace show -o table" ]]
        case "$MOCK_CASE" in
            current-failure) exit 21 ;;
            malformed-current) echo '{"connection": {}}' ;;
            missing-current) table "" ;;
            spaced-current) table "user workspace" ;;
            multiple-current) table user-current; table second ;;
            *) table user-current ;;
        esac
        ;;
    "workspace list")
        case "$MOCK_CASE" in
            list-failure) exit 22 ;;
            malformed-list) echo unknown ;;
            workspace-collision) table postgresql-upgrade-bicep-fixture ;;
            *) table user-current ;;
        esac
        ;;
    "group list")
        case "$MOCK_CASE" in
            group-lookup-failure) exit 23 ;;
            group-collision) echo '[{"name":"postgresql-upgrade-bicep-fixture"}]' ;;
            malformed-groups) echo '{}' ;;
            malformed-group-entry) echo '[{}]' ;;
            *) echo '[]' ;;
        esac
        ;;
    "group create")
        [[ "$*" == *"--workspace $MOCK_EXECUTION" ]]
        [[ "$MOCK_CASE" != group-create-failure ]] || exit 24
        touch "$MOCK_STATE/group"
        ;;
    "group delete")
        [[ "$*" == *"--workspace $MOCK_EXECUTION --yes" ]]
        [[ -f "$MOCK_STATE/group" ]]
        rm "$MOCK_STATE/group"
        ;;
    "workspace create")
        [[ "$*" != *--force* ]]
        [[ "$MOCK_CASE" != workspace-create-failure ]] || exit 25
        touch "$MOCK_STATE/workspace"
        echo "$4" > "$MOCK_STATE/current"
        ;;
    "workspace switch")
        [[ "$3" == user-current ]]
        [[ "$MOCK_CASE" != restore-failure ]] || exit 26
        echo "$3" > "$MOCK_STATE/current"
        ;;
    "workspace delete")
        [[ "$3" == postgresql-upgrade-bicep-fixture && "$4" == --yes ]]
        [[ "$(cat "$MOCK_STATE/current")" == user-current && -f "$MOCK_STATE/workspace" ]]
        [[ "$MOCK_CASE" != delete-failure ]] || exit 27
        rm "$MOCK_STATE/workspace"
        ;;
    "env create") [[ "$MOCK_CASE" != env-create-failure ]] || exit 28 ;;
    "env show") echo '{"id":"/planes/radius/local/resourceGroups/fixture/providers/Radius.Core/environments/fixture"}' ;;
    *) echo "Unexpected rad call: $*" >&2; exit 99 ;;
esac
EOF

cat > "$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "kubectl $*" >> "$MOCK_STATE/invocations"
case "$1 $2" in
    "get namespace")
        [[ "$MOCK_CASE" != namespace-lookup-failure ]] || exit 31
        if [[ "$MOCK_CASE" == namespace-collision ]]; then echo namespace/preexisting; fi
        ;;
    "create namespace")
        [[ "$MOCK_CASE" != namespace-create-failure ]] || exit 32
        touch "$MOCK_STATE/namespace"
        ;;
    "delete namespace")
        [[ -f "$MOCK_STATE/namespace" ]]
        rm "$MOCK_STATE/namespace"
        ;;
    *) echo "Unexpected kubectl call: $*" >&2; exit 99 ;;
esac
EOF

cat > "$TEST_ROOT/bin/oras" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "oras $*" >> "$MOCK_STATE/invocations"
[[ "$*" == "manifest fetch --descriptor ghcr.io/radius-project/kube-recipes/postgresqldatabases:18142182e52e19a46b0ed172037357e8e142dcd2" ]]
case "$MOCK_CASE" in
    registry-failure) exit 41 ;;
    digest-mismatch) echo '{"digest":"sha256:wrong"}' ;;
    missing-digest) echo '{}' ;;
    *) echo '{"digest":"sha256:ca65f43501f39fc31689e8a292e9e0e3179e4ebf7a89ec0143c12b4a1dc24ddd"}' ;;
esac
EOF

cat > "$TEST_ROOT/bin/mktemp" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$*" == "-d -t postgresql-upgrade-bicep-XXXXXXXXXX" ]]
mkdir "$MOCK_STATE/postgresql-upgrade-bicep-fixture"
echo "$MOCK_STATE/postgresql-upgrade-bicep-fixture"
EOF

cat > "$TEST_ROOT/scripts/test-tls.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "transport $*" >> "$MOCK_STATE/invocations"
[[ "$POSTGRESQL_UPGRADE_OLD_SOURCE" == "ghcr.io/radius-project/kube-recipes/postgresqldatabases@sha256:ca65f43501f39fc31689e8a292e9e0e3179e4ebf7a89ec0143c12b4a1dc24ddd" ]]
[[ "$POSTGRESQL_UPGRADE_NEW_SOURCE" == "reciperegistry:5000/radius-recipes/data/postgresqldatabases/kubernetes/bicep/kubernetes-postgresql:latest" ]]
[[ "$POSTGRESQL_UPGRADE_PACK" == postgresql-upgrade-bicep-fixture ]]
[[ "$1" == bicep && "$3" == "$POSTGRESQL_UPGRADE_PACK" && "$4" == "$POSTGRESQL_UPGRADE_PACK" ]]
[[ "$MOCK_CASE" != transport-failure ]] || exit 51
EOF
chmod +x "$TEST_ROOT/bin/"*

assert_absent() {
    if grep -q "$1" "$MOCK_STATE/invocations"; then
        echo "Unexpected invocation in $MOCK_CASE: $1" >&2
        exit 1
    fi
}

count=0
for scenario in success explicit-workspace current-failure malformed-current missing-current \
    spaced-current multiple-current list-failure malformed-list workspace-collision \
    registry-failure digest-mismatch missing-digest group-lookup-failure group-collision \
    malformed-groups malformed-group-entry namespace-lookup-failure namespace-collision group-create-failure \
    workspace-create-failure namespace-create-failure env-create-failure transport-failure \
    restore-failure delete-failure; do
    export MOCK_STATE="$TEST_ROOT/$scenario" MOCK_CASE="$scenario" MOCK_EXECUTION=default
    mkdir -p "$MOCK_STATE/home"
    echo user-current > "$MOCK_STATE/current"
    : > "$MOCK_STATE/invocations"
    args=(bicep)
    if [[ "$scenario" == explicit-workspace ]]; then
        MOCK_EXECUTION=execution-only
        args+=("$MOCK_EXECUTION")
    fi
    status=0
    HOME="$MOCK_STATE/home" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_ROOT/scripts/test-upgrade.sh" "${args[@]}" > "$MOCK_STATE/output" 2>&1 || status=$?
    if [[ "$scenario" == success || "$scenario" == explicit-workspace ]]; then
        [[ "$status" -eq 0 ]] || { cat "$MOCK_STATE/output"; exit 1; }
        grep -q '^transport ' "$MOCK_STATE/invocations"
    else
        [[ "$status" -ne 0 ]] || { echo "Expected failure: $scenario" >&2; exit 1; }
    fi
    [[ ! -d "$MOCK_STATE/postgresql-upgrade-bicep-fixture" ]]
    [[ ! -f "$MOCK_STATE/group" && ! -f "$MOCK_STATE/namespace" ]]
    if [[ "$scenario" == restore-failure ]]; then
        [[ -f "$MOCK_STATE/workspace" ]]
        assert_absent '^rad workspace delete '
        grep -q 'Could not restore workspace' "$MOCK_STATE/output"
    else
        [[ "$(cat "$MOCK_STATE/current")" == user-current ]]
        if [[ "$scenario" == delete-failure ]]; then
            [[ -f "$MOCK_STATE/workspace" ]]
        else
            [[ ! -f "$MOCK_STATE/workspace" ]]
        fi
    fi
    case "$scenario" in
        success|explicit-workspace|namespace-create-failure|env-create-failure|transport-failure|delete-failure)
            grep -q '^rad workspace switch user-current$' "$MOCK_STATE/invocations"
            grep -q '^rad workspace delete postgresql-upgrade-bicep-fixture --yes$' "$MOCK_STATE/invocations"
            ;;
        restore-failure) ;;
        *)
            assert_absent '^rad workspace \(switch\|delete\) '
            assert_absent '^transport '
            ;;
    esac
    case "$scenario" in
        digest-mismatch)
            grep -q 'Released baseline digest mismatch' "$MOCK_STATE/output"
            assert_absent '^rad group create '
            ;;
        workspace-collision|group-collision|namespace-collision)
            assert_absent '^rad \(group\|workspace\) \(create\|delete\) '
            assert_absent '^kubectl \(create\|delete\) '
            ;;
    esac
    count=$((count + 1))
done
echo "PostgreSQL upgrade runner: $count mocked cases passed."
