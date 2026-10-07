#!/bin/bash
set -euo pipefail

NAMESPACE="${1:?Namespace required}"
DEPLOYMENT="${2:?Deployment required}"
OLD_POD_UID="${3:-}"
observed=false
for ((attempt=0; attempt<120; attempt++)); do
    pod_json=$(kubectl --request-timeout=15s get pods -n "$NAMESPACE" \
        -l "radapp.io/resource=$DEPLOYMENT" -o json)
    pod=$(jq -r --arg old "$OLD_POD_UID" '.items[] |
        select(.metadata.deletionTimestamp == null and .metadata.uid != $old) | .metadata.name' <<<"$pod_json")
    if [[ -z "$pod" ]]; then
        sleep 2
        continue
    fi
    ready=$(jq -r --arg old "$OLD_POD_UID" '.items[] |
        select(.metadata.deletionTimestamp == null and .metadata.uid != $old) |
        .status.conditions[]? | select(.type == "Ready") | .status' <<<"$pod_json")
    if [[ "$observed" == false ]]; then
        if [[ "$ready" == True ]]; then
            echo "Error: Database became Ready before the temporary-server window was observed." >&2
            exit 1
        fi
        if kubectl --request-timeout=15s exec -n "$NAMESPACE" "$pod" -c postgres -- \
            /bin/sh -ec 'pg_isready -q -h /var/run/postgresql && ! pg_isready -q -h 127.0.0.1' \
            >/dev/null 2>&1; then
            [[ "$ready" == False ]] || {
                echo "Error: Temporary socket-only server did not have Ready=False." >&2
                exit 1
            }
            observed=true
            echo "==> Observed socket ready, TCP unavailable, and Pod Ready=False during initialization"
        fi
    else
        marker=$(kubectl --request-timeout=15s logs -n "$NAMESPACE" "$pod" -c postgres --timestamps |
            grep 'PostgreSQL init process complete; ready for start up' || true)
        if [[ "$ready" == True ]]; then
            [[ -n "$marker" ]] || {
                echo "Error: Pod became Ready before initialization completed." >&2
                exit 1
            }
            init_time="${marker%% *}"
            ready_time=$(jq -r --arg old "$OLD_POD_UID" '.items[] |
                select(.metadata.deletionTimestamp == null and .metadata.uid != $old) |
                .status.conditions[] | select(.type == "Ready") | .lastTransitionTime' <<<"$pod_json")
            # Kubernetes condition timestamps have lower precision than log timestamps.
            [[ "$(date -d "$ready_time" +%s)" -ge "$(date -d "$init_time" +%s)" ]] || {
                echo "Error: First readiness transition preceded initialization completion." >&2
                exit 1
            }
            kubectl --request-timeout=15s exec -n "$NAMESPACE" "$pod" -c postgres -- \
                pg_isready -q -h 127.0.0.1
            echo "==> TCP readiness passed after initialization: init=$init_time ready=$ready_time"
            exit 0
        fi
    fi
    sleep 2
done
echo "Error: Did not observe the temporary server and final TCP readiness within the bounded test." >&2
exit 1
