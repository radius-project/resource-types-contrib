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
if [[ "$1" == env && " $* " == *" --preview "* ]]; then
    echo "Error: unknown flag: --preview" >&2
    exit 29
fi
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
    "env create")
        [[ "$*" == "env create postgresql-upgrade-bicep-fixture --workspace postgresql-upgrade-bicep-fixture --kubernetes-namespace postgresql-upgrade-bicep-fixture" ]]
        [[ "$MOCK_CASE" != env-create-failure ]] || exit 28
        ;;
    "env show")
        [[ "$*" == "env show postgresql-upgrade-bicep-fixture --workspace postgresql-upgrade-bicep-fixture -o json" ]]
        echo '{"id":"/planes/radius/local/resourceGroups/fixture/providers/Radius.Core/environments/fixture"}'
        ;;
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
if [[ -f "$MOCK_STATE/registry-checked" ]]; then
    case "$MOCK_CASE" in
        post-registry-failure) exit 42 ;;
        post-digest-mismatch) echo '{"digest":"sha256:changed"}'; exit ;;
        post-missing-digest) echo '{}'; exit ;;
    esac
fi
touch "$MOCK_STATE/registry-checked"
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
case "$POSTGRESQL_UPGRADE_POLICY" in default|disabled) ;; *) exit 53 ;; esac
if [[ "$MOCK_POLICY" != all ]]; then
    [[ "$POSTGRESQL_UPGRADE_POLICY" == "$MOCK_POLICY" ]]
fi
echo "policy $POSTGRESQL_UPGRADE_POLICY" >> "$MOCK_STATE/invocations"
if [[ "$POSTGRESQL_UPGRADE_OLD_SOURCE" == *@* ]]; then
    echo "RecipeDownloadFailed: digest references are not supported" >&2
    exit 52
fi
[[ "$POSTGRESQL_UPGRADE_OLD_SOURCE" == "ghcr.io/radius-project/kube-recipes/postgresqldatabases:18142182e52e19a46b0ed172037357e8e142dcd2" ]]
[[ "$POSTGRESQL_UPGRADE_NEW_SOURCE" == "reciperegistry:5000/radius-recipes/data/postgresqldatabases/kubernetes/bicep/kubernetes-postgresql:latest" ]]
[[ "$POSTGRESQL_UPGRADE_PACK" == postgresql-upgrade-bicep-fixture ]]
[[ "$1" == bicep && "$3" == "$POSTGRESQL_UPGRADE_PACK" && "$4" == "$POSTGRESQL_UPGRADE_PACK" ]]
[[ "$MOCK_CASE" != transport-failure ]] || exit 51
if [[ "$MOCK_CASE" == disabled-transport-failure && "$POSTGRESQL_UPGRADE_POLICY" == disabled ]]; then
    exit 54
fi
EOF
chmod +x "$TEST_ROOT/bin/"*

assert_absent() {
    if grep -q "$1" "$MOCK_STATE/invocations"; then
        echo "Unexpected invocation in $MOCK_CASE: $1" >&2
        exit 1
    fi
}

count=0
for policy in default disabled; do
for scenario in success explicit-workspace current-failure malformed-current missing-current \
    spaced-current multiple-current list-failure malformed-list workspace-collision \
    registry-failure digest-mismatch missing-digest group-lookup-failure group-collision \
    malformed-groups malformed-group-entry namespace-lookup-failure namespace-collision group-create-failure \
    workspace-create-failure namespace-create-failure env-create-failure transport-failure \
    restore-failure delete-failure post-registry-failure post-digest-mismatch post-missing-digest; do
    export MOCK_STATE="$TEST_ROOT/$policy-$scenario" MOCK_CASE="$scenario" MOCK_EXECUTION=default MOCK_POLICY="$policy"
    mkdir -p "$MOCK_STATE/home"
    echo user-current > "$MOCK_STATE/current"
    : > "$MOCK_STATE/invocations"
    if [[ "$scenario" == explicit-workspace ]]; then
        MOCK_EXECUTION=execution-only
    fi
    args=(bicep "$MOCK_EXECUTION" "$policy")
    status=0
    HOME="$MOCK_STATE/home" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_ROOT/scripts/test-upgrade.sh" "${args[@]}" > "$MOCK_STATE/output" 2>&1 || status=$?
    if [[ "$scenario" == success || "$scenario" == explicit-workspace ]]; then
        [[ "$status" -eq 0 ]] || { cat "$MOCK_STATE/output"; exit 1; }
        grep -q '^transport ' "$MOCK_STATE/invocations"
        grep -Fxq "policy $policy" "$MOCK_STATE/invocations"
        [[ "$(grep -c '^oras manifest fetch ' "$MOCK_STATE/invocations")" -eq 2 ]]
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
        success|explicit-workspace|namespace-create-failure|env-create-failure|transport-failure|delete-failure|post-*)
            grep -q '^rad workspace switch user-current$' "$MOCK_STATE/invocations"
            grep -q '^rad workspace delete postgresql-upgrade-bicep-fixture --yes$' "$MOCK_STATE/invocations"
            ;;
        restore-failure) ;;
        *)
            assert_absent '^rad workspace \(switch\|delete\) '
            assert_absent '^transport '
            ;;
    esac
    if [[ "$scenario" == post-* ]]; then
        grep -q '^transport ' "$MOCK_STATE/invocations"
        [[ "$(grep -c '^oras manifest fetch ' "$MOCK_STATE/invocations")" -eq 2 ]]
        if grep -q 'old-to-new Recipe upgrade and transport suite passed' "$MOCK_STATE/output"; then
            echo "Post-upgrade digest failure reported success" >&2
            exit 1
        fi
    fi
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
done

for scenario in success transport-failure disabled-transport-failure restore-failure; do
    export MOCK_STATE="$TEST_ROOT/matrix-$scenario" MOCK_CASE="$scenario" MOCK_EXECUTION=execution-only MOCK_POLICY=all
    mkdir -p "$MOCK_STATE/home"
    echo user-current > "$MOCK_STATE/current"
    : > "$MOCK_STATE/invocations"
    status=0
    HOME="$MOCK_STATE/home" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_ROOT/scripts/test-upgrade.sh" bicep "$MOCK_EXECUTION" > "$MOCK_STATE/output" 2>&1 || status=$?
    if [[ "$scenario" == success ]]; then
        [[ "$status" -eq 0 ]] || { cat "$MOCK_STATE/output"; exit 1; }
        [[ "$(grep '^policy ' "$MOCK_STATE/invocations")" == $'policy default\npolicy disabled' ]]
        [[ "$(grep -c '^oras manifest fetch ' "$MOCK_STATE/invocations")" -eq 4 ]]
        # The first owned workspace must be deleted before the next is created.
        [[ "$(grep '^rad workspace \(create\|switch\|delete\) ' "$MOCK_STATE/invocations" |
            awk '{print $3}')" == $'create\nswitch\ndelete\ncreate\nswitch\ndelete' ]]
        grep -q 'pre-TLS upgrades to default and disabled passed' "$MOCK_STATE/output"
    else
        [[ "$status" -ne 0 ]] || { echo "Expected matrix failure: $scenario" >&2; exit 1; }
        if grep -q 'pre-TLS upgrades to default and disabled passed' "$MOCK_STATE/output"; then
            echo "Failed upgrade matrix reported success" >&2
            exit 1
        fi
        if [[ "$scenario" != disabled-transport-failure ]]; then
            assert_absent '^policy disabled$'
        else
            grep -Fxq 'policy disabled' "$MOCK_STATE/invocations"
        fi
    fi
    [[ ! -f "$MOCK_STATE/group" && ! -f "$MOCK_STATE/namespace" ]]
    [[ ! -d "$MOCK_STATE/postgresql-upgrade-bicep-fixture" ]]
    if [[ "$scenario" == restore-failure ]]; then
        [[ -f "$MOCK_STATE/workspace" ]]
    else
        [[ ! -f "$MOCK_STATE/workspace" && "$(cat "$MOCK_STATE/current")" == user-current ]]
    fi
    count=$((count + 1))
done

export MOCK_STATE="$TEST_ROOT/invalid-policy" MOCK_CASE=success MOCK_EXECUTION=default MOCK_POLICY=invalid
mkdir -p "$MOCK_STATE/home"
: > "$MOCK_STATE/invocations"
if HOME="$MOCK_STATE/home" PATH="$TEST_ROOT/bin:$PATH" \
    bash "$TEST_ROOT/scripts/test-upgrade.sh" bicep default invalid > "$MOCK_STATE/output" 2>&1; then
    echo "Invalid upgrade policy was accepted" >&2
    exit 1
fi
grep -q 'Unsupported upgrade policy' "$MOCK_STATE/output"
[[ ! -s "$MOCK_STATE/invocations" ]]
count=$((count + 1))
echo "PostgreSQL upgrade runner: $count mocked cases passed."
