#!/usr/bin/env bash
#
# Exercises a running stack end to end, the way a browser does: csrf -> login ->
# authenticated reads -> async writes -> idempotency replay -> authorization.
#
#   ./scripts/smoke.sh http://acme.localhost:8080 acme
#
# Exits non-zero on the first unexpected status, so it is usable as a CI gate or a
# post-deploy check.
set -uo pipefail

BASE="${1:-http://acme.localhost:8080}"
TENANT="${2:-acme}"
JAR="$(mktemp)"
FAILURES=0

cleanup() { rm -f "$JAR" "$JAR.viewer"; }
trap cleanup EXIT

# shellcheck disable=SC2016
check() {
    local label="$1" want="$2"
    shift 2

    local body status
    body="$(curl -s -o /dev/null -w '%{http_code}' "$@")"
    status="$body"

    if [[ "$status" == "$want" ]]; then
        printf '  \033[32mPASS\033[0m  %-48s %s\n' "$label" "$status"
    else
        printf '  \033[31mFAIL\033[0m  %-48s %s (want %s)\n' "$label" "$status" "$want"
        FAILURES=$((FAILURES + 1))
    fi
}

json() { curl -s -b "$JAR" -c "$JAR" "$@"; }

xsrf() {
    # The cookie is URL-encoded in the jar; the header must be the decoded value.
    awk '/XSRF-TOKEN/ {print $7}' "$JAR" | tail -1 | sed 's/%3D/=/g'
}

echo
echo "smoke: ${BASE} (tenant ${TENANT})"
echo

echo "unauthenticated"
check 'GET  /api/v1/whoami' 200 -b "$JAR" -c "$JAR" "$BASE/api/v1/whoami"
check 'GET  /api/v1/employees' 401 -b "$JAR" "$BASE/api/v1/employees"

echo
echo "login"
check 'GET  /sanctum/csrf-cookie' 204 -b "$JAR" -c "$JAR" "$BASE/sanctum/csrf-cookie"

LOGIN=$(json -X POST "$BASE/api/v1/auth/login" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $(xsrf)" \
    -d "{\"email\":\"admin@${TENANT}.test\",\"password\":\"password\"}")

if echo "$LOGIN" | grep -q '"abilities"'; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' 'POST /api/v1/auth/login' '200'
else
    printf '  \033[31mFAIL\033[0m  %-48s %s\n' 'POST /api/v1/auth/login' "$LOGIN"
    FAILURES=$((FAILURES + 1))
fi

echo
echo "authenticated reads"
check 'GET  /api/v1/auth/user' 200 -b "$JAR" "$BASE/api/v1/auth/user"
check 'GET  /api/v1/employees' 200 -b "$JAR" "$BASE/api/v1/employees?per_page=2"
check 'GET  /api/v1/audit-logs' 200 -b "$JAR" "$BASE/api/v1/audit-logs?per_page=3"

echo
echo "async writes + idempotency"
PAYROLL='{"period_start":"2026-09-01","period_end":"2026-09-15","include_commission":true,"tax_rate":0.22}'
KEY="smoke-$(date +%s)-$RANDOM"

check 'POST /api/v1/payroll/calculations (no key)' 400 \
    -b "$JAR" -X POST "$BASE/api/v1/payroll/calculations" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $(xsrf)" -d "$PAYROLL"

FIRST=$(json -X POST "$BASE/api/v1/payroll/calculations" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $(xsrf)" \
    -H "Idempotency-Key: $KEY" -d "$PAYROLL")

REQUEST_ID=$(echo "$FIRST" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')

if [[ -n "$REQUEST_ID" ]]; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' 'POST /api/v1/payroll/calculations' "202 ${REQUEST_ID:0:8}..."
else
    printf '  \033[31mFAIL\033[0m  %-48s %s\n' 'POST /api/v1/payroll/calculations' "$FIRST"
    FAILURES=$((FAILURES + 1))
fi

# The assertion that matters: a retry must replay, not queue a second payroll run.
RETRY=$(json -X POST "$BASE/api/v1/payroll/calculations" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $(xsrf)" \
    -H "Idempotency-Key: $KEY" -d "$PAYROLL")

RETRY_ID=$(echo "$RETRY" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')

if [[ "$RETRY_ID" == "$REQUEST_ID" && -n "$RETRY_ID" ]]; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' 'retry replayed (no duplicate run)' 'same request_id'
else
    printf '  \033[31mFAIL\033[0m  %-48s %s\n' 'retry produced a NEW request_id' "$RETRY_ID"
    FAILURES=$((FAILURES + 1))
fi

check 'POST same key, changed payload' 409 \
    -b "$JAR" -X POST "$BASE/api/v1/payroll/calculations" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $(xsrf)" \
    -H "Idempotency-Key: $KEY" \
    -d '{"period_start":"2026-09-01","period_end":"2026-09-30","include_commission":true,"tax_rate":0.22}'

echo
echo "worker completion"
# Poll until the Go worker finishes, then confirm it wrote to MySQL.
TERMINAL=""
for _ in $(seq 1 30); do
    STATUS=$(json "$BASE/api/v1/requests/$REQUEST_ID")

    if echo "$STATUS" | grep -q '"terminal":true'; then
        TERMINAL=$(echo "$STATUS" | sed -n 's/.*"status":"\([A-Z]*\)".*/\1/p' | head -1)
        break
    fi

    sleep 1
done

if [[ "$TERMINAL" == "COMPLETED" ]]; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' 'worker completed the payroll run' "$TERMINAL"
    check 'GET  /api/v1/payroll/calculations/{id}' 200 -b "$JAR" "$BASE/api/v1/payroll/calculations/$REQUEST_ID"
else
    printf '  \033[31mFAIL\033[0m  %-48s %s\n' 'worker did not complete in 30s' "${TERMINAL:-still running}"
    FAILURES=$((FAILURES + 1))
fi

echo
echo "authorization"
VJAR="$JAR.viewer"
curl -s -c "$VJAR" "$BASE/sanctum/csrf-cookie" >/dev/null
VTOKEN=$(awk '/XSRF-TOKEN/ {print $7}' "$VJAR" | tail -1 | sed 's/%3D/=/g')

curl -s -b "$VJAR" -c "$VJAR" -X POST "$BASE/api/v1/auth/login" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $VTOKEN" \
    -d "{\"email\":\"viewer@${TENANT}.test\",\"password\":\"password\"}" >/dev/null

VTOKEN=$(awk '/XSRF-TOKEN/ {print $7}' "$VJAR" | tail -1 | sed 's/%3D/=/g')

check 'POST payroll as viewer' 403 \
    -b "$VJAR" -X POST "$BASE/api/v1/payroll/calculations" \
    -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: $VTOKEN" \
    -H "Idempotency-Key: smoke-viewer-$RANDOM$RANDOM" -d "$PAYROLL"

check 'GET  audit-logs as viewer' 403 -b "$VJAR" "$BASE/api/v1/audit-logs"

echo
if [[ "$FAILURES" -eq 0 ]]; then
    printf '\033[32mall checks passed\033[0m\n\n'
    exit 0
fi

printf '\033[31m%d check(s) failed\033[0m\n\n' "$FAILURES"
exit 1
