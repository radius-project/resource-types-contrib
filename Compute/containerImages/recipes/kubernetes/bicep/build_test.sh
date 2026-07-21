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
        --resourceName Demo \
        --registry ghcr.io/example \
        --tag '' \
        --source 'git::https://example.com/repo.git//src?ref=main' \
        --dockerfile Dockerfile \
        --platforms linux/amd64 \
        --platforms linux/arm64 \
        --buildArgs A 'a&b<c>d' \
        --buildArgs Z z)
}

expect_failure() {
    expected=$1
    shift
    if (cd "$WORK_DIR/work" && sh "$SCRIPT" "$@") 2> "$WORK_DIR/validation.err"; then
        echo "expected build input validation to fail" >&2
        exit 1
    fi
    grep -F "$expected" "$WORK_DIR/validation.err" >/dev/null
}

run_build
[ "$(cat "$WORK_DIR/result.json")" = '{"imageReference":"ghcr.io/example/demo:sha256-ed8fc579e9dc133a"}' ]
grep -Fx -- '--output' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'type=image,name=ghcr.io/example/demo:sha256-ed8fc579e9dc133a,push=true' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'context=https://example.com/repo.git#main:src' "$WORK_DIR/buildctl.args" >/dev/null
grep -Fx -- 'build-arg:A=a&b<c>d' "$WORK_DIR/buildctl.args" >/dev/null

# The script canonicalizes build arguments without relying on the Radius driver's map ordering.
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resourceName Demo \
    --registry ghcr.io/example \
    --tag '' \
    --source 'git::https://example.com/repo.git//src?ref=main' \
    --dockerfile Dockerfile \
    --platforms linux/amd64 \
    --platforms linux/arm64 \
    --buildArgs Z z \
    --buildArgs A 'a&b<c>d')
[ "$(cat "$WORK_DIR/result.json")" = '{"imageReference":"ghcr.io/example/demo:sha256-ed8fc579e9dc133a"}' ]
a_line=$(grep -nFx -- 'build-arg:A=a&b<c>d' "$WORK_DIR/buildctl.args" | cut -d: -f1)
z_line=$(grep -nFx -- 'build-arg:Z=z' "$WORK_DIR/buildctl.args" | cut -d: -f1)
[ "$a_line" -lt "$z_line" ]

# Bicep has no Terraform state, so a second deployment still invokes buildctl.
run_build
[ "$(cat "$WORK_DIR/buildctl.calls")" = '3' ]

# A false tagProvided value and an empty buildArgs object emit no arguments. Local paths exercise
# both omissions while using a deterministic, NUL-delimited file-tree hash that accepts spaces
# and newlines in filenames.
export RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT="$WORK_DIR/local-root"
LOCAL_SOURCE="$RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT/source"
mkdir -p "$LOCAL_SOURCE"
RESOLVED_LOCAL_SOURCE=$(realpath "$LOCAL_SOURCE")
printf 'FROM scratch\n' > "$LOCAL_SOURCE/Dockerfile"
printf 'hello\n' > "$LOCAL_SOURCE/file with spaces.txt"
newline_file="$LOCAL_SOURCE/line
break.txt"
printf 'newline\n' > "$newline_file"
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source "$LOCAL_SOURCE" --dockerfile Dockerfile \
    --platforms linux/amd64)
first_local_result=$(cat "$WORK_DIR/result.json")
printf '%s' "$first_local_result" |
    grep -Eq '^\{"imageReference":"ghcr.io/example/demo:sha256-[a-f0-9]{16}"\}$'
grep -Fx -- "context=$RESOLVED_LOCAL_SOURCE" "$WORK_DIR/buildctl.args" >/dev/null
printf 'changed\n' > "$newline_file"
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source "$LOCAL_SOURCE" --dockerfile Dockerfile \
    --platforms linux/amd64)
[ "$first_local_result" != "$(cat "$WORK_DIR/result.json")" ]

# Canonical-path containment blocks sources outside the operator-owned mount.
OUTSIDE_SOURCE="$WORK_DIR/outside-source"
mkdir -p "$OUTSIDE_SOURCE"
printf 'FROM scratch\n' > "$OUTSIDE_SOURCE/Dockerfile"
expect_failure 'local build source must be beneath operator-managed root' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$OUTSIDE_SOURCE" --dockerfile Dockerfile --platforms linux/amd64

saved_local_context_root=$RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT
export RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT=/
expect_failure 'local build context root must not be the filesystem root' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$LOCAL_SOURCE" --dockerfile Dockerfile --platforms linux/amd64
export RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT="$saved_local_context_root"

# The source itself, the Dockerfile, and every other context entry must be symlink-free.
SOURCE_LINK="$RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT/source-link"
ln -s "$LOCAL_SOURCE" "$SOURCE_LINK"
expect_failure 'local build source must not be a symbolic link' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$SOURCE_LINK/" --dockerfile Dockerfile --platforms linux/amd64
rm "$SOURCE_LINK"

printf 'FROM scratch\n' > "$LOCAL_SOURCE/ActualDockerfile"
ln -s ActualDockerfile "$LOCAL_SOURCE/SymlinkDockerfile"
expect_failure 'Dockerfile must not be a symbolic link' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$LOCAL_SOURCE" --dockerfile SymlinkDockerfile --platforms linux/amd64
rm "$LOCAL_SOURCE/SymlinkDockerfile"

mkdir "$LOCAL_SOURCE/DockerfileDirectory"
expect_failure 'Dockerfile must be a regular file' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$LOCAL_SOURCE" --dockerfile DockerfileDirectory --platforms linux/amd64
rmdir "$LOCAL_SOURCE/DockerfileDirectory"

ln -s 'file with spaces.txt' "$LOCAL_SOURCE/app-link"
expect_failure 'local build source must not contain symbolic links' \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$LOCAL_SOURCE" --dockerfile Dockerfile --platforms linux/amd64
rm "$LOCAL_SOURCE/app-link"

# An explicit tag bypasses all default-tag hashing.
cat > "$WORK_DIR/bin/sha256sum" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$WORK_DIR/bin/sha256sum"
(cd "$WORK_DIR/work" && sh "$SCRIPT" \
    --resourceName Demo --registry ghcr.io/example --tag explicit --tagProvided \
    --source "$LOCAL_SOURCE" --dockerfile Dockerfile \
    --platforms linux/amd64)
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

# These cases were lossy when collections were serialized into environment strings.
expect_failure 'properties.build.platforms must contain at least one platform' \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile
newline_value=$(printf 'safe\nsmuggled')
expect_failure 'properties.build.args values must not contain newlines' \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platforms linux/amd64 \
    --buildArgs VALUE "$newline_value"
expect_failure 'properties.build.args keys must match' \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platforms linux/amd64 \
    --buildArgs 'BAD=KEY' value
expect_failure 'properties.build.platforms entries must match' \
    --resourceName Demo --registry ghcr.io/example --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platforms 'linux/amd64,linux/arm64'
expect_failure 'properties.tag must match Docker tag spec' \
    --resourceName Demo --registry ghcr.io/example --tag '' --tagProvided \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platforms linux/amd64
newline_registry=$(printf 'ghcr.io/example\nsmuggled')
expect_failure 'registry must not contain newlines' \
    --resourceName Demo --registry "$newline_registry" --tag '' \
    --source 'git::https://example.com/repo.git?ref=main' \
    --dockerfile Dockerfile --platforms linux/amd64
[ "$(cat "$WORK_DIR/buildctl.calls")" = '7' ]

echo "containerImages build.sh smoke test passed"
