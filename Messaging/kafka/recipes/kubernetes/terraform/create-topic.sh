#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ ! "$RADIUS_KAFKA_TOPIC" =~ ^[a-zA-Z0-9._-]{1,249}$ ||
      "$RADIUS_KAFKA_TOPIC" == "." || "$RADIUS_KAFKA_TOPIC" == ".." ||
      "$RADIUS_KAFKA_TOPIC" == __* ]]; then
    echo "Error: topic must be a non-internal Kafka topic name (1-249 ASCII letters, digits, dots, underscores or hyphens; not . or ..)." >&2
    exit 1
fi

# postStart runs beside the broker, not before it. Bound the startup wait.
for ((attempt = 0; attempt < 120; attempt++)); do
    if /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:19092 \
        --command-config <(printf 'request.timeout.ms=5000\ndefault.api.timeout.ms=5000\n') --list; then
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:19092 \
            --create --if-not-exists --topic "$RADIUS_KAFKA_TOPIC" \
            --partitions 1 --replication-factor 1
        exit 0
    fi
    sleep 2
done

echo "Error: Kafka did not become available for topic creation." >&2
exit 1
