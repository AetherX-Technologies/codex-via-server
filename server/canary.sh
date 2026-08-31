#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="codex-via-server-canary"
MODEL=""
GATEWAY_URL="${CODEX_GATEWAY_URL:-http://127.0.0.1:18319/v1}"
RUNTIME_DIR=""

fail() {
  printf '%s: status=fail reason=%s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

cleanup() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$RUNTIME_DIR" ]]; then
    find "$RUNTIME_DIR" -depth -delete
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'Usage: server/canary.sh --model <model-id>\n'
      exit 0
      ;;
    *) fail "unknown-argument" ;;
  esac
done

[[ "$MODEL" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] || fail "invalid-model"
[[ "$GATEWAY_URL" == "http://127.0.0.1:"*"/v1" ]] || fail "invalid-gateway-url"

for dependency in curl date grep jq; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing-${dependency}"
done

RUNTIME_DIR="$(mktemp -d /tmp/codex-canary.XXXXXX)"
REQUEST_FILE="${RUNTIME_DIR}/request.json"
RESPONSE_FILE="${RUNTIME_DIR}/response.sse"

jq -n \
  --arg model "$MODEL" \
  '{model: $model, input: "Reply only OK.", stream: true}' \
  >"$REQUEST_FILE"

start_milliseconds="$(date +%s%3N)"
if ! curl --proxy '' --noproxy '*' --no-buffer \
    --connect-timeout 5 --max-time 45 \
    --fail-with-body --silent --show-error \
    -H 'Content-Type: application/json' \
    --data-binary "@${REQUEST_FILE}" \
    "${GATEWAY_URL}/responses" \
    >"$RESPONSE_FILE" 2>/dev/null; then
  fail "responses-request"
fi
end_milliseconds="$(date +%s%3N)"

grep -q '"type"[[:space:]]*:[[:space:]]*"response.completed"' "$RESPONSE_FILE" \
  || fail "missing-response-completed"

duration_milliseconds=$((end_milliseconds - start_milliseconds))
printf 'status=pass duration_ms=%s model=%s\n' "$duration_milliseconds" "$MODEL"
