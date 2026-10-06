#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail
shift # --request-timeout
case "$1" in
    get)
        ready=False
        [[ "$(cat "$STATE/phase")" == 0 && "$MODE" != early ]] || ready=True
        timestamp=2026-10-06T21:00:06Z
        [[ "$MODE" != backwards ]] || timestamp=2026-10-06T21:00:04Z
        jq -nc --arg ready "$ready" --arg timestamp "$timestamp" \
            '{items: [
                {metadata: {name: "old-pod", uid: "ignored"}, status: {conditions: [{type: "Ready", status: "True"}]}},
                {metadata: {name: "new-pod", uid: "new"}, status: {conditions: [{type: "Ready", status: $ready, lastTransitionTime: $timestamp}]}}
            ]}'
        ;;
    exec)
        [[ "$*" == *"new-pod"* ]]
        if [[ "$*" == *"/var/run/postgresql"* ]]; then
            printf '1' >"$STATE/phase"
        fi
        ;;
    logs)
        if [[ "$MODE" != missing ]]; then
            echo '2026-10-06T21:00:05.123456Z PostgreSQL init process complete; ready for start up.'
        fi
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/"*

for mode in success early missing backwards; do
    state="$TEST_ROOT/$mode"
    mkdir "$state"
    printf '0' >"$state/phase"
    status=0
    MODE="$mode" STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_DIR/assert-readiness.sh" test postgresql ignored \
        >"$state/output" 2>&1 || status=$?
    if [[ "$mode" == success ]]; then
        [[ "$status" == 0 ]]
        grep -q 'Observed socket ready, TCP unavailable, and Pod Ready=False' "$state/output"
        grep -q 'TCP readiness passed after initialization' "$state/output"
    else
        [[ "$status" == 1 ]]
        grep -q '^Error:' "$state/output"
    fi
done
echo "Readiness observation, old-Pod exclusion, and invalid evidence tests passed"
