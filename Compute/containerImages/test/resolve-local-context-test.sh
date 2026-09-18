#!/bin/sh
# Exercises the Terraform recipe's local build context resolver against a
# fixture tree. Runs with POSIX sh on both busybox (Alpine, the dynamic-rp
# base image) and BSD/GNU userlands. Fixture setup runs under set -e so a
# failed symlink or mkdir cannot be mistaken for a rejected source.
#
# Usage: Compute/containerImages/test/resolve-local-context-test.sh

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
resolver="$script_dir/../recipes/kubernetes/terraform/resolve-local-context.sh"
base=$(mktemp -d "${TMPDIR:-/tmp}/resolve-local-context.XXXXXX")
trap 'rm -rf "$base"' EXIT INT TERM

root="$base/var/radius/build-contexts"
outside="$base/outside/secret"

mkdir -p "$root/good/sub" "$root/nodocker" "$root/withlink" "$root/dflink" \
    "$root/deep/a/b" "$root/.hidden" "$root/dirdocker/Dockerfile" \
    "$outside" "$base/rootlink-parent"
printf 'FROM scratch\nCOPY . /\n' >"$root/good/Dockerfile"
printf 'FROM scratch\n' >"$root/good/sub/Dockerfile"
printf 'x' >"$root/good/sub/file"
printf 'FROM scratch\n' >"$root/deep/a/b/Dockerfile"
printf 'FROM scratch\n' >"$root/.hidden/Dockerfile"
printf 'FROM scratch\n' >"$outside/Dockerfile"
printf 'FROM scratch\n' >"$root/withlink/Dockerfile"
ln -s "$outside" "$root/withlink/leak"
ln -s "$outside/Dockerfile" "$root/dflink/Dockerfile"
ln -s "$outside" "$root/srclink"
ln -s "$root" "$base/rootlink-parent/build-contexts"

pass=0
fail=0

# expect_error <message fragment> <label> [resolver arguments...]
# The resolver must exit nonzero and report the given error, so a case cannot
# pass because a later, unrelated check happened to reject the fixture.
expect_error() {
    want=$1
    label=$2
    shift 2
    if out=$(sh "$resolver" "$@" 2>"$base/stderr"); then
        fail=$((fail + 1))
        printf 'FAIL %s: expected rejection, got %s\n' "$label" "$out" >&2
        return
    fi
    if grep -Fq "containerImages: $want" "$base/stderr"; then
        pass=$((pass + 1))
        return
    fi
    fail=$((fail + 1))
    printf 'FAIL %s: expected error containing %s\n' "$label" "$want" >&2
    sed 's/^/  stderr: /' "$base/stderr" >&2
}

# expect_output <expected> <label> [resolver arguments...]
expect_output() {
    want=$1
    label=$2
    shift 2
    out=$(sh "$resolver" "$@" 2>"$base/stderr") || out="<exit $?>"
    if [ "$out" = "$want" ]; then
        pass=$((pass + 1))
        return
    fi
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$label" "$want" "$out" >&2
}

resolved_root=$(realpath "$root")

expect_output "$resolved_root/good" "valid source" "$root" "$root/good" Dockerfile
expect_output "$resolved_root/good" "trailing slash is normalized" "$root" "$root/good/" Dockerfile
expect_output "$resolved_root/good" "repeated trailing slashes are normalized" "$root" "$root/good//" Dockerfile
expect_output "$resolved_root/good" "Dockerfile in a subdirectory" "$root" "$root/good" sub/Dockerfile
expect_output "$resolved_root/deep/a/b" "nested source" "$root" "$root/deep/a/b" Dockerfile
expect_output "$resolved_root/.hidden" "hidden source directory" "$root" "$root/.hidden" Dockerfile

expect_error "local build source must be beneath operator-managed root" "root itself" "$root" "$root" Dockerfile
expect_error "local build source must be beneath operator-managed root" "root with trailing slash" "$root" "$root/" Dockerfile
expect_error "local build source must be beneath operator-managed root" "root via /." "$root" "$root/." Dockerfile
expect_error "local build source must be beneath operator-managed root" "root via /./" "$root" "$root/./" Dockerfile
expect_error "local build source must be beneath operator-managed root" "root via child/.." "$root" "$root/good/.." Dockerfile
expect_error "local build source must be beneath operator-managed root" "source outside root" "$root" "$outside" Dockerfile
expect_error "local build source directory not found" "sibling directory sharing the root prefix" "$root" "${root}-evil/x" Dockerfile
expect_error "local build source directory not found" "missing source" "$root" "$root/missing" Dockerfile
expect_error "local build source must be a directory" "source is a file" "$root" "$root/good/Dockerfile" Dockerfile
expect_error "local build source must not be a symbolic link" "source is a symbolic link" "$root" "$root/srclink" Dockerfile
expect_error "local build source must not contain symbolic links" "source contains a symbolic link" "$root" "$root/withlink" Dockerfile
expect_error "Dockerfile must not be a symbolic link" "Dockerfile is a symbolic link" "$root" "$root/dflink" Dockerfile
expect_error "Dockerfile not found in local build source" "Dockerfile is missing" "$root" "$root/nodocker" Dockerfile
expect_error "Dockerfile must be a regular file" "Dockerfile is a directory" "$root" "$root/dirdocker" Dockerfile
expect_error "Dockerfile must resolve within the local build source" "Dockerfile escapes the source" "$root" "$root/good" ../withlink/Dockerfile
expect_error "local build sources are disabled; operator-managed root does not exist" "root does not exist" "$base/absent" "$base/absent/app" Dockerfile
expect_error "local build context root must not be a symbolic link" "root is a symbolic link" "$base/rootlink-parent/build-contexts" "$base/rootlink-parent/build-contexts/good" Dockerfile
expect_error "local build context root must not be the filesystem root" "root is the filesystem root" / /etc Dockerfile
expect_error "local context resolver requires root, source, and Dockerfile arguments" "wrong argument count" "$root" "$root/good"

printf 'resolve-local-context: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
