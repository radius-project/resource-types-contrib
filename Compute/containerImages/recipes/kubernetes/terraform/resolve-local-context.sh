#!/bin/sh

set -eu

fail() {
    echo "containerImages: $1" >&2
    exit 1
}

[ "$#" -eq 3 ] || fail "local context resolver requires root, source, and Dockerfile arguments"

context_root=$1
build_source=$2
dockerfile=$3

# Keep these checks aligned with the local-source confinement in ../bicep/build.sh.
[ -d "$context_root" ] ||
    fail "local build sources are disabled; operator-managed root does not exist: $context_root"
[ ! -L "$context_root" ] ||
    fail "local build context root must not be a symbolic link: $context_root"

resolved_root=$(realpath "$context_root") ||
    fail "failed to resolve local build context root: $context_root"
[ "$resolved_root" != / ] || fail "local build context root must not be the filesystem root"

source_path=$build_source
while [ "${source_path%/}" != "$source_path" ]; do
    source_path=${source_path%/}
done

[ ! -L "$source_path" ] ||
    fail "local build source must not be a symbolic link: $build_source"

# busybox realpath tolerates a missing final path component, so check
# existence explicitly to keep the error consistent across implementations.
[ -e "$source_path" ] ||
    fail "local build source directory not found: $build_source"

resolved_source=$(realpath "$source_path") ||
    fail "local build source directory not found: $build_source"

case "$resolved_source" in
    "$resolved_root"/*) ;;
    *) fail "local build source must be beneath operator-managed root $resolved_root (got $resolved_source)" ;;
esac

[ -d "$resolved_source" ] ||
    fail "local build source must be a directory: $resolved_source"

printf '%s' "$resolved_source" | grep -Eq '^[A-Za-z0-9._/+~-]+$' ||
    fail "resolved local build source contains unsupported characters: $resolved_source"

dockerfile_path="$resolved_source/$dockerfile"
[ ! -L "$dockerfile_path" ] ||
    fail "Dockerfile must not be a symbolic link: $dockerfile"

[ -e "$dockerfile_path" ] ||
    fail "Dockerfile not found in local build source: $dockerfile"

resolved_dockerfile=$(realpath "$dockerfile_path") ||
    fail "Dockerfile not found in local build source: $dockerfile"

case "$resolved_dockerfile" in
    "$resolved_source"/*) ;;
    *) fail "Dockerfile must resolve within the local build source: $dockerfile" ;;
esac

[ -f "$resolved_dockerfile" ] ||
    fail "Dockerfile must be a regular file: $dockerfile"

symlink_path=$(find "$resolved_source" -type l -print -quit) ||
    fail "failed to inspect local build source symlinks: $resolved_source"
[ -z "$symlink_path" ] ||
    fail "local build source must not contain symbolic links: $resolved_source"

printf '%s\n' "$resolved_source"
