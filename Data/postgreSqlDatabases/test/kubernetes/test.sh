#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$TEST_DIR/test-tls.sh" "${2:?Recipe kind required}" \
    "${3:?Environment ID required}" "${4:?Workspace required}" "${5:?Namespace required}"
