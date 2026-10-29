#!/bin/bash

# Offline OCI publication tests using only Bash and jq.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPTS/recipe-oci.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/recipe-oci-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
REPOSITORY=ghcr.io/example/recipes/demo
SOURCE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST="sha256:$(printf '1%.0s' {1..64})"
OLDER="sha256:$(printf '2%.0s' {1..64})"
NEWER="sha256:$(printf '3%.0s' {1..64})"
CASES=0

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/oras" <<'EOF'
#!/bin/bash
set -euo pipefail
state="${REGISTRY_STATE:?}"
tool="${0##*/}"
call="$(jq -cn --args '$ARGS.positional' -- "$tool" "$@")"
jq --argjson call "$call" '.calls += [$call]' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
error() { echo "$*" >&2; exit 1; }
write_tag() {
    jq --arg ref "$1" --arg digest "$2" '.tags[$ref] = $digest' "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
}
if [[ "$tool" == rad ]]; then
    if jq -e '.build_error == true' "$state" >/dev/null; then
        error "Bicep compilation failed"
    fi
    while (($#)); do
        if [[ "$1" == --target ]]; then
            write_tag "${2#br:}" "$(jq -r '.build_digest' "$state")"
            exit
        fi
        shift
    done
    error "Missing publication target"
fi
case "${1:-}" in
resolve)
    if message="$(jq -er --arg ref "$2" '.resolve_errors[$ref] // empty' "$state")"; then
        error "$message"
    fi
    if digest="$(jq -er --arg ref "$2" '.tags[$ref] // empty' "$state")"; then
        echo "$digest"
    else
        error "Error response from registry: $2: not found"
    fi
    ;;
repo)
    [[ "${2:-} ${4:-} ${5:-}" == "tags --format json" ]] || error "Expected native ORAS --format json"
    if message="$(jq -er '.list_error // empty' "$state")"; then
        error "$message"
    fi
    if jq -e '.invalid_list == true' "$state" >/dev/null; then
        echo '{}'
    else
        jq --arg prefix "$3:" '{tags: [.tags | keys[] | select(startswith($prefix)) | ltrimstr($prefix)]}' "$state"
    fi
    ;;
tag)
    fault="$(jq -r '.tag_fault // empty' "$state")"
    [[ "$fault" != before ]] || error "Registry connection failed before write"
    repository="${2%@*}"
    digest="${2##*@}"
    shift 2
    for tag in "$@"; do write_tag "$repository:$tag" "$digest"; done
    [[ "$fault" != after ]] || error "Registry response lost after write"
    ;;
*) error "Unexpected invocation: $*" ;;
esac
EOF
cp "$TEST_ROOT/bin/oras" "$TEST_ROOT/bin/rad"
chmod +x "$TEST_ROOT/bin/oras" "$TEST_ROOT/bin/rad"
export PATH="$TEST_ROOT/bin:$PATH"

fail() {
    echo "FAIL ($CASE_NAME): $*" >&2
    exit 1
}
new_case() {
    CASE_NAME="$1"
    ((++CASES))
    CASE_ROOT="$TEST_ROOT/$CASES"
    mkdir "$CASE_ROOT"
    export REGISTRY_STATE="$CASE_ROOT/state.json"
    jq -n --arg digest "$DIGEST" '{tags:{}, calls:[], build_digest:$digest}' >"$REGISTRY_STATE"
    SUBJECTS="$CASE_ROOT/subjects.txt"
    printf '%s  %s\n' "${DIGEST#sha256:}" "$REPOSITORY" >"$SUBJECTS"
}
change() {
    jq "$@" "$REGISTRY_STATE" >"$REGISTRY_STATE.tmp"
    mv "$REGISTRY_STATE.tmp" "$REGISTRY_STATE"
}
seed() { change --arg ref "$REPOSITORY:$1" --arg digest "$2" ".tags[\$ref] = \$digest"; }
tag_is() {
    [[ "$(jq -r --arg ref "$REPOSITORY:$1" '.tags[$ref]' "$REGISTRY_STATE")" == "$2" ]] ||
        fail "unexpected digest for $1"
}
writes() { jq '[.calls[] | select(.[0] == "rad" or .[0:2] == ["oras","tag"])] | length' "$REGISTRY_STATE"; }
run_helper() {
    if RESULT="$(bash "$HELPER" "$@" 2>&1)"; then STATUS=0; else STATUS=$?; fi
}
publish() { run_helper publish recipe.bicep "$REPOSITORY" "$SOURCE" "$@"; }
promote() { run_helper promote "${1:-0.62.1}" "$SUBJECTS" "${2:-0.62}"; }
success() { [[ "$STATUS" == 0 ]] || fail "$RESULT"; }
failure() { [[ "$STATUS" != 0 && "$RESULT" == *"$1"* ]] || fail "expected failure '$1': $RESULT"; }
no_writes() { [[ "$(writes)" == 0 ]] || fail "unexpected registry writes"; }

new_case main
seed latest "$OLDER"
seed 0.62 "$OLDER"
publish edge
success
[[ "$RESULT" == "$DIGEST" ]] || fail "publisher output must be one digest"
tag_is edge "$DIGEST"
tag_is latest "$OLDER"
tag_is 0.62 "$OLDER"
[[ "$(jq '[.calls[] | select(.[0] == "rad")] | length' "$REGISTRY_STATE")" == 1 ]] || fail "content built more than once"

new_case retry
publish "$SOURCE" 0.62.1
success
before="$(writes)"
publish "$SOURCE" 0.62.1
success
[[ "$(writes)" == "$before" ]] || fail "retry rebuilt or retagged content"

new_case immutable_conflict
seed "$SOURCE" "$DIGEST"
seed 0.62.1 "$OLDER"
publish 0.62.1
failure "conflicting digest"
no_writes

for tag in latest 0.62 'bad tag' "$(printf 'a%.0s' {1..129})"; do
    new_case invalid_tag
    publish "$tag"
    [[ "$STATUS" != 0 ]] || fail "accepted $tag"
    no_writes
done

new_case source_identity
run_helper publish recipe.bicep "$REPOSITORY" short edge
failure "full source commit SHA"
no_writes

for message in 'HTTP 401 unauthorized' 'HTTP 403 forbidden' 'not found: denied' 'TLS handshake timeout'; do
    new_case lookup_failure
    change --arg ref "$REPOSITORY:$SOURCE" --arg message "$message" ".resolve_errors[\$ref] = \$message"
    publish edge
    failure "$message"
    no_writes
done

new_case reference_is_not_error_code
run_helper publish recipe.bicep "$REPOSITORY" "403${SOURCE:3}" edge
success
tag_is edge "$DIGEST"

new_case malformed_digest
seed "$SOURCE" sha256:1234
publish edge
failure "Invalid digest"
no_writes

new_case build_failure
seed edge "$OLDER"
seed latest "$OLDER"
change '.build_error = true'
publish edge
failure "Bicep compilation failed"
tag_is edge "$OLDER"
tag_is latest "$OLDER"

new_case prerelease_staging
seed edge "$OLDER"
seed latest "$OLDER"
publish 0.63.0-rc.1
success
tag_is 0.63.0-rc.1 "$DIGEST"
tag_is edge "$OLDER"
tag_is latest "$OLDER"

new_case stable_promotion
seed 0.62.1 "$DIGEST"
seed latest "$OLDER"
seed 0.62 "$OLDER"
seed edge "$NEWER"
promote
success
tag_is latest "$DIGEST"
tag_is 0.62 "$DIGEST"
tag_is edge "$NEWER"
[[ "$(jq '[.calls[] | select(.[0] == "rad")] | length' "$REGISTRY_STATE")" == 0 ]] || fail "promotion rebuilt content"

new_case older_line
seed 0.62.1 "$DIGEST"
seed 0.63.0 "$NEWER"
seed latest "$NEWER"
seed 0.62 "$OLDER"
promote
success
tag_is latest "$NEWER"
tag_is 0.62 "$DIGEST"

new_case older_same_line
seed 0.62.1 "$DIGEST"
seed 0.62.2 "$NEWER"
seed latest "$NEWER"
seed 0.62 "$NEWER"
promote
success
no_writes
[[ "$RESULT" == *"newer version 0.62.2"* ]] || fail "missing skip reason"

new_case channel_boundary
seed 0.62.1 "$DIGEST"
seed 10.62.2 "$NEWER"
seed latest "$NEWER"
promote
success
tag_is 0.62 "$DIGEST"
tag_is latest "$NEWER"

new_case numeric_order
seed 0.62.10 "$DIGEST"
seed 0.62.9 "$OLDER"
seed 99.0.0-rc.1 "$NEWER"
seed Radius.Data/v99.0.0 "$NEWER"
promote 0.62.10 0.62
success
tag_is latest "$DIGEST"

new_case no_rc_promotion
promote 0.63.0-rc.1
failure "stable full version"
no_writes

new_case subject_digest
seed 0.62.1 "$OLDER"
promote
failure "Full-version digest changed"
no_writes

for subject in '' $'\n' 'invalid subject' "${DIGEST#sha256:}  $REPOSITORY extra"; do
    new_case invalid_subject
    printf '%s' "$subject" >"$SUBJECTS"
    promote
    [[ "$STATUS" != 0 ]] || fail "accepted malformed subjects"
    no_writes
done

new_case listing_failure
seed 0.62.1 "$DIGEST"
change '.list_error = "HTTP 403 forbidden"'
promote
failure "HTTP 403 forbidden"
no_writes

new_case malformed_listing
seed 0.62.1 "$DIGEST"
change '.invalid_list = true'
promote
failure "Invalid registry tag listing"
no_writes

new_case lost_response
seed 0.62.1 "$DIGEST"
change '.tag_fault = "after"'
promote
success
tag_is latest "$DIGEST"
before="$(writes)"
promote
success
[[ "$(writes)" == "$before" ]] || fail "reconciled retry wrote again"

new_case failed_write
seed 0.62.1 "$DIGEST"
seed latest "$OLDER"
seed 0.62 "$OLDER"
change '.tag_fault = "before"'
promote
failure "did not resolve"
tag_is latest "$OLDER"

new_case latest_only
seed 0.62.1 "$DIGEST"
run_helper promote 0.62.1 "$SUBJECTS"
success
tag_is latest "$DIGEST"
jq -e --arg ref "$REPOSITORY:0.62" '.tags | has($ref) | not' "$REGISTRY_STATE" >/dev/null ||
    fail "modern promotion created a channel alias"

new_case workflow_contract
workflow="$SCRIPTS/../workflows/publish-bicep-recipes.yaml"
for expected in \
    'group: publish-bicep-recipes' 'queue: max' \
    'needs: [publish-bicep-recipes, attest-bicep-recipes]' \
    "!contains(inputs.release_version, '-') && !inputs.pin_only" \
    "repos/radius-project/radius/releases/tags/v\${RELEASE_VERSION}" \
    "tags=\"\$COMMIT_SHA\""; do
    grep -Fq "$expected" "$workflow" || fail "missing workflow contract: $expected"
done
[[ "$(grep -Fc 'id-token: write' "$workflow")" == 1 ]] || fail "signing permissions leaked"

echo "Recipe OCI tests passed ($CASES cases)"
