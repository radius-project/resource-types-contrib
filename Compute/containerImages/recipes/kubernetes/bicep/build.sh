#!/bin/sh
# Build and push for the Radius.Compute/containerImages Bicep recipe.
#
# Platform engineers can fork this recipe, edit this script, and republish the Bicep module.
# Radius passes each field of the recipe's imageBuild output as a --<fieldName> argument and
# provides DOCKER_CONFIG, RADIUS_EXEC_OUTPUT, and the pod's existing BUILDKIT_HOST environment
# variable. The flag names match the imageBuild property names, so this script and the recipe
# evolve together without any Radius driver change.

set -eu
umask 077

# Local sources must come from an operator-managed mount. The override exists so the
# confinement behavior can be exercised by the isolated script tests.
LOCAL_CONTEXT_ROOT=${RADIUS_CONTAINER_IMAGES_LOCAL_CONTEXT_ROOT:-/var/radius/build-contexts}

fail() {
    echo "containerImages: $1" >&2
    exit 1
}

reject_line_break() {
    case "$2" in
        *'
'*) fail "$1 must not contain newlines" ;;
    esac
}

RESOURCE_NAME=
REGISTRY=
TAG=
TAG_PROVIDED=0
BUILD_SOURCE=
DOCKERFILE=
PLATFORMS=
BUILD_ARGS=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --resourceName)
            [ "$#" -ge 2 ] || fail "--resourceName requires a value"
            RESOURCE_NAME=$2
            shift 2
            ;;
        --registry)
            [ "$#" -ge 2 ] || fail "--registry requires a value"
            REGISTRY=$2
            shift 2
            ;;
        --tag)
            [ "$#" -ge 2 ] || fail "--tag requires a value"
            TAG=$2
            shift 2
            ;;
        --tagProvided)
            TAG_PROVIDED=1
            shift
            ;;
        --source)
            [ "$#" -ge 2 ] || fail "--source requires a value"
            BUILD_SOURCE=$2
            shift 2
            ;;
        --dockerfile)
            [ "$#" -ge 2 ] || fail "--dockerfile requires a value"
            DOCKERFILE=$2
            shift 2
            ;;
        --platforms)
            [ "$#" -ge 2 ] || fail "--platforms requires a value"
            platform=$2
            reject_line_break "properties.build.platforms entries" "$platform"
            printf '%s' "$platform" | grep -Eq '^[a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?$' ||
                fail "properties.build.platforms entries must match <os>/<arch>[/<variant>] (got $platform)"
            if [ -z "$PLATFORMS" ]; then
                PLATFORMS=$platform
            else
                PLATFORMS="$PLATFORMS,$platform"
            fi
            shift 2
            ;;
        --buildArgs)
            [ "$#" -ge 3 ] || fail "--buildArgs requires a key and value"
            key=$2
            value=$3
            reject_line_break "properties.build.args keys" "$key"
            reject_line_break "properties.build.args values" "$value"
            printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' ||
                fail "properties.build.args keys must match [A-Za-z_][A-Za-z0-9_]* (got $key)"
            if printf '%s' "$value" | grep -Eq '[[:space:]]'; then
                fail "properties.build.args values must not contain whitespace (got value for $key)"
            fi
            case "$value" in
                *\"*|*\'*|*\`*|*\$*|*\\*)
                    fail "properties.build.args values must not contain shell metacharacters (got value for $key)"
                    ;;
            esac
            pair="$key=$value"
            if [ -z "$BUILD_ARGS" ]; then
                BUILD_ARGS=$pair
            else
                BUILD_ARGS="$BUILD_ARGS
$pair"
            fi
            shift 3
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "$PLATFORMS" ] || fail "properties.build.platforms must contain at least one platform"

# Keep generated tags and buildctl arguments deterministic even when callers provide
# build arguments in a different order.
if [ -n "$BUILD_ARGS" ]; then
    BUILD_ARGS=$(printf '%s\n' "$BUILD_ARGS" | LC_ALL=C sort)
fi

# Validate the scalar inputs against the Terraform recipe's preconditions. Explicit newline
# checks keep grep's line-oriented anchors from accepting only one line of a supplied value.
reject_line_break "registry" "$REGISTRY"
printf '%s' "$REGISTRY" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)*$' ||
    fail "registry must be <host>[:<port>][/<lowercase-path>] (no scheme, no '@', lowercase path components) (got $REGISTRY)"

reject_line_break "resource name" "$RESOURCE_NAME"
IMAGE_NAME=$(printf '%s' "$RESOURCE_NAME" | tr '[:upper:]' '[:lower:]')
printf '%s' "$IMAGE_NAME" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' ||
    fail "image name (lowercased) must match [a-z0-9][a-z0-9._-]* (got $IMAGE_NAME)"

reject_line_break "properties.tag" "$TAG"
if [ "$TAG_PROVIDED" -eq 1 ]; then
    printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$' ||
        fail "properties.tag must match Docker tag spec [A-Za-z0-9_][A-Za-z0-9._-]{0,127} (got $TAG)"
fi

reject_line_break "properties.build.dockerfile" "$DOCKERFILE"
case "$DOCKERFILE" in
    /*|*..*) fail "properties.build.dockerfile must be a relative path with no '..' (got $DOCKERFILE)" ;;
esac
printf '%s' "$DOCKERFILE" | grep -Eq '^[A-Za-z0-9._/-]+$' ||
    fail "properties.build.dockerfile must match [A-Za-z0-9._/-]+ (got $DOCKERFILE)"

reject_line_break "properties.build.source" "$BUILD_SOURCE"
IS_GIT=0
case "$BUILD_SOURCE" in
    git::https://*)
        IS_GIT=1
        printf '%s' "$BUILD_SOURCE" | grep -Eq '^git::https://[A-Za-z0-9._:/@?=&%~+#-]+$' ||
            fail "properties.build.source must be a git::https URL or a filesystem path (got $BUILD_SOURCE)"
        ;;
    *)
        case "$BUILD_SOURCE" in
            *..*) fail "properties.build.source must not contain '..' (got $BUILD_SOURCE)" ;;
        esac
        printf '%s' "$BUILD_SOURCE" | grep -Eq '^[A-Za-z0-9._/+~-]+$' ||
            fail "properties.build.source must be a git::https URL or a filesystem path (got $BUILD_SOURCE)"
        ;;
esac

SCRIPT_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/radius-containerimages.XXXXXX") ||
    fail "failed to create script work directory"
trap 'rm -rf "$SCRIPT_WORK_DIR"' EXIT

# Translate go-getter git::https://host/repo.git//subdir?ref=ref into the BuildKit
# https://host/repo.git#ref:subdir form used by the Terraform recipe.
BUILDKIT_CONTEXT=
if [ "$IS_GIT" -eq 1 ]; then
    stripped=${BUILD_SOURCE#git::}
    url_no_query=${stripped%%\?*}
    query=
    case "$stripped" in
        *\?*) query=${stripped#*\?} ;;
    esac

    ref=
    old_ifs=$IFS
    IFS='&'
    for item in $query; do
        case "$item" in
            ref=*)
                candidate=${item#ref=}
                [ -n "$ref" ] || ref=$candidate
                ;;
        esac
    done
    IFS=$old_ifs

    scheme=${url_no_query%%://*}
    rest=${url_no_query#*://}
    repo_part=$rest
    subdir=
    case "$rest" in
        *//*)
            repo_part=${rest%%//*}
            subdir=${rest#*//}
            ;;
    esac

    if [ -n "$subdir" ]; then
        fragment="#$ref:$subdir"
    elif [ -n "$ref" ]; then
        fragment="#$ref"
    else
        fragment=
    fi
    BUILDKIT_CONTEXT="$scheme://$repo_part$fragment"
else
    [ -d "$LOCAL_CONTEXT_ROOT" ] ||
        fail "local build sources are disabled; operator-managed root does not exist: $LOCAL_CONTEXT_ROOT"
    resolved_root=$(realpath "$LOCAL_CONTEXT_ROOT") ||
        fail "failed to resolve local build context root: $LOCAL_CONTEXT_ROOT"
    [ "$resolved_root" != / ] || fail "local build context root must not be the filesystem root"

    source_path=$BUILD_SOURCE
    while [ "${source_path%/}" != "$source_path" ]; do
        source_path=${source_path%/}
    done
    [ ! -L "$source_path" ] || fail "local build source must not be a symbolic link: $BUILD_SOURCE"
    resolved_source=$(realpath "$source_path") ||
        fail "local build source directory not found: $BUILD_SOURCE"
    case "$resolved_source" in
        "$resolved_root"/*) ;;
        *) fail "local build source must be beneath operator-managed root $resolved_root (got $resolved_source)" ;;
    esac
    [ -d "$resolved_source" ] || fail "local build source must be a directory: $resolved_source"

    dockerfile_path="$resolved_source/$DOCKERFILE"
    [ ! -L "$dockerfile_path" ] || fail "Dockerfile must not be a symbolic link (got $DOCKERFILE)"
    resolved_dockerfile=$(realpath "$dockerfile_path") ||
        fail "Dockerfile not found in local build source: $DOCKERFILE"
    case "$resolved_dockerfile" in
        "$resolved_source"/*) ;;
        *) fail "Dockerfile must resolve within the local build source (got $DOCKERFILE)" ;;
    esac
    [ -f "$resolved_dockerfile" ] || fail "Dockerfile must be a regular file (got $DOCKERFILE)"

    SYMLINK_LIST="$SCRIPT_WORK_DIR/symlink-list"
    (cd "$resolved_source" && find . -type l -print0) > "$SYMLINK_LIST" ||
        fail "failed to inspect local build source symlinks: $resolved_source"
    [ ! -s "$SYMLINK_LIST" ] ||
        fail "local build source must not contain symbolic links: $resolved_source"

    BUILD_SOURCE=$resolved_source
fi

# Use an explicit tag as-is. Otherwise compute a deterministic tag. Local file records use
# NUL delimiters because filenames within the operator-managed context may contain newlines.
if [ "$TAG_PROVIDED" -eq 1 ]; then
    RESOLVED_TAG=$TAG
else
    HASH_INPUT="$SCRIPT_WORK_DIR/hash-input"
    FILE_LIST="$SCRIPT_WORK_DIR/file-list"
    SORTED_FILE_LIST="$SCRIPT_WORK_DIR/file-list-sorted"

    : > "$HASH_INPUT"
    if [ "$IS_GIT" -eq 1 ]; then
        printf 'source=%s\n' "$BUILDKIT_CONTEXT" >> "$HASH_INPUT"
    else
        (cd "$BUILD_SOURCE" && find . -type f -print0) > "$FILE_LIST" ||
            fail "failed to enumerate local build source: $BUILD_SOURCE"
        LC_ALL=C sort -z "$FILE_LIST" -o "$SORTED_FILE_LIST" ||
            fail "failed to sort local build source entries: $BUILD_SOURCE"
        # shellcheck disable=SC2016 # Expanded by the inner shell after xargs supplies its arguments.
        xargs -0 sh -c '
            output=$1
            root=$2
            shift 2
            for path do
                digest_line=$(sha256sum < "$root/${path#./}") || exit 1
                digest=${digest_line%% *}
                printf "file.%s\0%s\0" "${path#./}" "$digest" >> "$output" || exit 1
            done
        ' radius-local-hash "$HASH_INPUT" "$BUILD_SOURCE" < "$SORTED_FILE_LIST" ||
            fail "failed to hash local build source: $BUILD_SOURCE"
    fi
    printf 'dockerfile=%s\n' "$DOCKERFILE" >> "$HASH_INPUT"
    old_ifs=$IFS
    IFS=','
    for platform in $PLATFORMS; do
        printf 'platform=%s\n' "$platform" >> "$HASH_INPUT"
    done
    IFS=$old_ifs
    if [ -n "$BUILD_ARGS" ]; then
        old_ifs=$IFS
        IFS='
'
        for pair in $BUILD_ARGS; do
            printf 'buildArg.%s\n' "$pair" >> "$HASH_INPUT"
        done
        IFS=$old_ifs
    fi

    hash_line=$(sha256sum "$HASH_INPUT") || fail "failed to hash build inputs"
    SOURCE_HASH=${hash_line%% *}
    RESOLVED_TAG=$(printf 'sha256-%.16s' "$SOURCE_HASH")
fi
IMAGE_REFERENCE="$REGISTRY/$IMAGE_NAME:$RESOLVED_TAG"

# Always run the synchronous build. This recipe intentionally accepts a rebuild on every
# execution; reusing the deterministic tag preserves stable references between executions.
set -- build \
    --frontend dockerfile.v0 \
    --opt "filename=$DOCKERFILE" \
    --opt "platform=$PLATFORMS" \
    --output "type=image,name=$IMAGE_REFERENCE,push=true"

if [ "$IS_GIT" -eq 1 ]; then
    set -- "$@" --opt "context=$BUILDKIT_CONTEXT"
else
    set -- "$@" --local "context=$BUILD_SOURCE" --local "dockerfile=$BUILD_SOURCE"
fi

if [ -n "$BUILD_ARGS" ]; then
    old_ifs=$IFS
    IFS='
'
    for pair in $BUILD_ARGS; do
        set -- "$@" --opt "build-arg:$pair"
    done
    IFS=$old_ifs
fi

echo "containerImages: building $IMAGE_REFERENCE"
buildctl "$@"
printf '{"imageReference":"%s"}' "$IMAGE_REFERENCE" > "$RADIUS_EXEC_OUTPUT"
