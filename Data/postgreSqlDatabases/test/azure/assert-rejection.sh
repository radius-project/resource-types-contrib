#!/bin/bash
set -euo pipefail
# Both snapshots must be captured successfully by the caller, never defaulted.
log="${1:?Deployment log required}"
before="${2:?Before snapshot required}"
after="${3:?After snapshot required}"
grep -Fq 'Azure PostgreSQL does not support this tls policy. Use required or optional; disabled is Kubernetes-only.' "$log" || {
    echo "Error: Azure rejection did not contain the expected unsupported-policy diagnostic." >&2
    exit 1
}
jq -e 'type == "array"' "$before" >/dev/null
jq -e 'type == "array"' "$after" >/dev/null
diff -u <(jq -S 'sort_by(.id)' "$before") <(jq -S 'sort_by(.id)' "$after") || {
    echo "Error: Azure rejection changed PostgreSQL server state." >&2
    exit 1
}
