#!/bin/sh
#
# Creates the topics and subscriptions the application expects.
#
# Works against the Pub/Sub emulator (set PUBSUB_EMULATOR_HOST) and against real
# Pub/Sub (set ACCESS_TOKEN, or run scripts/gcp-setup.sh which uses gcloud).
# Uses the REST API so the only dependency is curl.
set -eu

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-local-dev}"
PAYROLL_TOPIC="${PUBSUB_TOPIC_PAYROLL:-payroll-calc-events}"
SALES_TOPIC="${PUBSUB_TOPIC_SALES:-sales-import}"
PAYROLL_SUB="${PUBSUB_SUB_PAYROLL:-payroll-calc-events-worker}"
SALES_SUB="${PUBSUB_SUB_SALES:-sales-import-worker}"

if [ -n "${PUBSUB_EMULATOR_HOST:-}" ]; then
    BASE="http://${PUBSUB_EMULATOR_HOST}"
    AUTH=""
else
    BASE="https://pubsub.googleapis.com"
    AUTH="Authorization: Bearer ${ACCESS_TOKEN:?ACCESS_TOKEN is required when not using the emulator}"
fi

echo "[bootstrap-pubsub] target=${BASE} project=${PROJECT_ID}"

# The emulator container may still be starting when this runs.
i=0
until curl -sf -o /dev/null "${BASE}/v1/projects/${PROJECT_ID}/topics" \
        ${AUTH:+-H "${AUTH}"} || [ "${i}" -ge 30 ]; do
    i=$((i + 1))
    echo "[bootstrap-pubsub] waiting for Pub/Sub (${i}/30)"
    sleep 1
done

put() {
    path="$1"
    body="$2"

    # 409 ALREADY_EXISTS is the expected result on re-runs, so this script is
    # safe to run on every stack start.
    code=$(curl -s -o /tmp/pubsub-out -w '%{http_code}' -X PUT \
        "${BASE}/v1/${path}" \
        -H 'Content-Type: application/json' \
        ${AUTH:+-H "${AUTH}"} \
        -d "${body}")

    case "${code}" in
        200|201) echo "[bootstrap-pubsub] created ${path}" ;;
        409)     echo "[bootstrap-pubsub] exists  ${path}" ;;
        *)       echo "[bootstrap-pubsub] FAILED ${path} (HTTP ${code})"; cat /tmp/pubsub-out; return 1 ;;
    esac
}

DLQ_TOPIC="${PUBSUB_TOPIC_DLQ:-worker-dead-letter}"

put "projects/${PROJECT_ID}/topics/${PAYROLL_TOPIC}" '{}'
put "projects/${PROJECT_ID}/topics/${SALES_TOPIC}" '{}'
put "projects/${PROJECT_ID}/topics/${DLQ_TOPIC}" '{}'

# Somewhere to inspect poison messages from. Without a subscription attached, the
# dead-letter topic silently discards everything sent to it.
put "projects/${PROJECT_ID}/subscriptions/${DLQ_TOPIC}-inspect" "$(cat <<JSON
{
  "topic": "projects/${PROJECT_ID}/topics/${DLQ_TOPIC}",
  "ackDeadlineSeconds": 60,
  "messageRetentionDuration": "604800s"
}
JSON
)"

# ackDeadlineSeconds is 60 here: the worker extends the deadline while a long
# payroll run is in flight, so the initial value only needs to cover a fast case.
put "projects/${PROJECT_ID}/subscriptions/${PAYROLL_SUB}" "$(cat <<JSON
{
  "topic": "projects/${PROJECT_ID}/topics/${PAYROLL_TOPIC}",
  "ackDeadlineSeconds": 60,
  "messageRetentionDuration": "604800s",
  "enableMessageOrdering": false
}
JSON
)"

put "projects/${PROJECT_ID}/subscriptions/${SALES_SUB}" "$(cat <<JSON
{
  "topic": "projects/${PROJECT_ID}/topics/${SALES_TOPIC}",
  "ackDeadlineSeconds": 60,
  "messageRetentionDuration": "604800s",
  "enableMessageOrdering": false
}
JSON
)"

echo "[bootstrap-pubsub] done"
