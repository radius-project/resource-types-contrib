#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/build.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/work"
cat > "$WORK_DIR/bin/buildctl" <<'EOF'
#!/bin/sh
set -eu
count=$(cat "$FAKE_CALLS" 2>/dev/null || printf '0')
printf '%s\n' "$@" > "$FAKE_ARGS"
printf '%s' "$((count + 1))" > "$FAKE_CALLS"
[ "${FAKE_BUILDKIT_FAILURE:-0}" -eq 0 ] || exit "$FAKE_BUILDKIT_FAILURE"
EOF
chmod +x "$WORK_DIR/bin/buildctl"

export PATH="$WORK_DIR/bin:$PATH"
export FAKE_ARGS="$WORK_DIR/buildctl.args"
export FAKE_CALLS="$WORK_DIR/buildctl.calls"
export RADIUS_EXEC_OUTPUT="$WORK_DIR/result.json"
export BUILDKIT_HOST=tcp://127.0.0.1:1234

run_build() {
    (cd "$WORK_DIR/work" && sh "$SCRIPT" \
        --resource-name Demo \
        --registry ghcr.io/example \
        --tag '' \
        --source 'git::https://example.com/repo.git//src?ref=main' \
        --dockerfile Dockerfile \
        --platform linux/amd64 \
        --platform linux/arm64 \
        --build-arg A 'a&b<c>d' \
        --build-arg Z z)
}

run_build
[ "$(cat "$WORK_DIR/result.json")" = '{"imageReference":"ghcr.io/example/demo:sha256-ed8fc579e9dc133a"}' ]
grep -Fx -- '--output' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'type=image,name=ghcr.io/example/demo:sha256-ed8fc579e9dc133a,push=true' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'context=https://example.com/repo.git#main:src' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'build-arg:A=a&b<c>d' "$WORK_DIR/buildctl.args" >/dev/null

# Bicep has no Terraform state, so a second deployment still invokes buildctl.
run_build
[ "$(cat "$WORK_DIR/buildctl.calls")" = '2' ]

# Local paths already visible to dynamic-rp use a deterministic file-tree hash.
mkdir -p "$WORK_DIR/source"
printf 'FROM scratch\n' > "$WORK_DIR/source/Dockerfile"
printf 'hello\n' > "$WORK_DIR/source/app.txt"
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resource-name Demo --registry ghcr.io/example --tag '' \
    --source "$WORK_DIR/source" --dockerfile Dockerfile \
    --platform linux/amd64)
[ "$(cat "$WORK_DIR/result.json")" = '{"imageReference":"ghcr.io/example/demo:sha256-34d9003fabeec515"}' ]
grep -Fx -- "context=$WORK_DIR/source" "$WORK_DIR/buildctl.args" >/dev/null

# An explicit tag bypasses all default-tag hashing.
cat > "$WORK_DIR/bin/sha256sum" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$WORK_DIR/bin/sha256sum"
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resource-name Demo --registry ghcr.io/example --tag explicit --tag-provided \
    --source "$WORK_DIR/source" --dockerfile Dockerfile \
    --platform linux/amd64)
[ "$(cat "$WORK_DIR/result.json")" = '{"imageReference":"ghcr.io/example/demo:explicit"}' ]
rm -f "$WORK_DIR/bin/sha256sum"

# imageReference is not reported unless buildctl completes successfully.
rm -f "$RADIUS_EXEC_OUTPUT"
export FAKE_BUILDKIT_FAILURE=7
if run_build > "$WORK_DIR/build-failure.log" 2>&1; then
    echo "expected buildctl failure to fail the recipe script" >&2
    exit 1
fi
unset FAKE_BUILDKIT_FAILURE
[ ! -e "$RADIUS_EXEC_OUTPUT" ]

expect_failure() {
    expected=$1
    shift
    if (cd "$WORK_DIR/work" && sh "$SCRIPT" "$@") 2> "$WORK_DIR/validation.err"; then
        echo "expected build input validation to fail" >&2
        exit 1
    fi
    grep -F "$expected" "$WORK_DIR/validation.err" >/dev/null
}

# These cases were lossy when collections were serialized into environment strings.
newline_value=$(printf 'safe\nsmuggled')
expect_failure 'properties.build.args values must not contain newlines' \
    --resource-name Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platform linux/amd64 \
    --build-arg VALUE "$newline_value"
expect_failure 'properties.build.args keys must match' \
    --resource-name Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platform linux/amd64 \
    --build-arg 'BAD=KEY' value
expect_failure 'properties.build.platforms entries must match' \
    --resource-name Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platform 'linux/amd64,linux/arm64'
expect_failure 'properties.tag must match Docker tag spec' \
    --resource-name Demo --registry ghcr.io/example --tag '' --tag-provided \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platform linux/amd64
newline_registry=$(printf 'ghcr.io/example\nsmuggled')
expect_failure 'registry must not contain newlines' \
    --resource-name Demo --registry "$newline_registry" --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platform linux/amd64
[ "$(cat "$WORK_DIR/buildctl.calls")" = '5' ]

echo "containerImages build.sh smoke test passed"
