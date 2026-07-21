#!/bin/sh
# Build and push for the Radius.Compute/containerImages Bicep recipe.
#
# Platform engineers can fork this recipe, edit this script, and republish the Bicep module.
# Radius supplies resource inputs as positional arguments and provides DOCKER_CONFIG,
# RADIUS_EXEC_OUTPUT, and the pod's existing BUILDKIT_HOST environment variable.

set -eu

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
        --resource-name)
            [ "$#" -ge 2 ] || fail "--resource-name requires a value"
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
        --tag-provided)
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
        --platform)
            [ "$#" -ge 2 ] || fail "--platform requires a value"
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
        --build-arg)
            [ "$#" -ge 3 ] || fail "--build-arg requires a key and value"
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
    [ -d "$BUILD_SOURCE" ] || fail "local build source directory not found: $BUILD_SOURCE"
fi

# Use an explicit tag as-is. Otherwise compute a deterministic tag from a newline-delimited
# manifest; validation rejects newlines, and the core sorts build arguments by key.
if [ "$TAG_PROVIDED" -eq 1 ]; then
    RESOLVED_TAG=$TAG
else
    HASH_INPUT=.radius-containerimages-hash-input
    FILE_LIST=.radius-containerimages-file-list
    trap 'rm -f "$HASH_INPUT" "$FILE_LIST"' EXIT

    : > "$HASH_INPUT"
    if [ "$IS_GIT" -eq 1 ]; then
        printf 'source=%s\n' "$BUILDKIT_CONTEXT" >> "$HASH_INPUT"
    else
        (cd "$BUILD_SOURCE" && find . -type f -print | LC_ALL=C sort) > "$FILE_LIST" ||
            fail "failed to enumerate local build source: $BUILD_SOURCE"
        while IFS= read -r file; do
            relative_path=${file#./}
            digest_line=$(sha256sum "$BUILD_SOURCE/$relative_path") ||
                fail "failed to hash local build source file: $relative_path"
            digest=${digest_line%% *}
            printf 'file.%s=%s\n' "$relative_path" "$digest" >> "$HASH_INPUT"
        done < "$FILE_LIST"
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
