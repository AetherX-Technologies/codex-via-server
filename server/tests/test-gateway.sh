#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-gateway-test.XXXXXX)"
SUFFIX="$$"
NETWORK_NAME="codex-gateway-test-${SUFFIX}"
MOCK_NAME="codex-gateway-mock-${SUFFIX}"
GATEWAY_NAME="codex-gateway-nginx-${SUFFIX}"
PYTHON_IMAGE="${PYTHON_IMAGE:-python@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6}"

cleanup() {
  trap - EXIT HUP INT TERM
  docker stop "$GATEWAY_NAME" "$MOCK_NAME" >/dev/null 2>&1 || true
  docker rm "$GATEWAY_NAME" "$MOCK_NAME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  find "$RUNTIME_DIR" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

command -v docker >/dev/null 2>&1
docker info >/dev/null

sed 's#proxy_pass http://127.0.0.1:8317;#proxy_pass http://codex-gateway-mock-'"${SUFFIX}"':8317;#' \
  "${ROOT_DIR}/server/nginx/codex-gateway.conf" >"${RUNTIME_DIR}/default.conf"
printf 'proxy_set_header Authorization "Bearer test-upstream-key";\n' \
  >"${RUNTIME_DIR}/gateway-secret.conf"

docker network create "$NETWORK_NAME" >/dev/null
docker run -d \
  --name "$MOCK_NAME" \
  --network "$NETWORK_NAME" \
  --read-only \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v "${ROOT_DIR}/server/tests/mock-cliproxyapi.py:/app/mock-cliproxyapi.py:ro" \
  "$PYTHON_IMAGE" \
  python /app/mock-cliproxyapi.py >/dev/null

docker run -d \
  --name "$GATEWAY_NAME" \
  --network "$NETWORK_NAME" \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add DAC_OVERRIDE \
  --cap-add SETGID \
  --cap-add SETUID \
  -v "${RUNTIME_DIR}/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "${RUNTIME_DIR}/gateway-secret.conf:/etc/codex-via-server/gateway-secret.conf:ro" \
  "$NGINX_IMAGE" >/dev/null

docker exec "$GATEWAY_NAME" nginx -t >/dev/null

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if docker run --rm --network "container:${GATEWAY_NAME}" "$CURL_IMAGE" \
      -fsS http://127.0.0.1:18319/healthz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]]

models_response="$(
  docker run --rm --network "container:${GATEWAY_NAME}" "$CURL_IMAGE" \
    -fsS \
    -H 'Authorization: Bearer client-supplied-key' \
    http://127.0.0.1:18319/v1/models
)"
printf '%s\n' "$models_response" | grep -q '"authorized": true'

management_status="$(
  docker run --rm --network "container:${GATEWAY_NAME}" "$CURL_IMAGE" \
    -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:18319/management.html
)"
[[ "$management_status" == "404" ]]

upstream_failure_status="$(
  docker run --rm --network "container:${GATEWAY_NAME}" "$CURL_IMAGE" \
    -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:18319/v1/fail
)"
[[ "$upstream_failure_status" == "503" ]]

sse_response="$(
  head -c 1048576 /dev/zero \
    | tr '\0' a \
    | docker run -i --rm --network "container:${GATEWAY_NAME}" "$CURL_IMAGE" \
        -fsS \
        -H 'Authorization: Bearer client-supplied-key' \
        -H 'Content-Type: application/octet-stream' \
        --data-binary @- \
        http://127.0.0.1:18319/v1/responses
)"
printf '%s\n' "$sse_response" | grep -q '"type": "response.completed"'
printf '%s\n' "$sse_response" | grep -q '"received_bytes": 1048576'

access_log="$(docker exec "$GATEWAY_NAME" cat /var/log/nginx/codex-via-server-access.log)"
if printf '%s\n' "$access_log" | grep -Eq 'Authorization|test-upstream-key|client-supplied-key'; then
  printf 'gateway access log contains credential material\n' >&2
  exit 1
fi

printf 'PASS: loopback gateway auth, routing, large POST, SSE, errors, and logs\n'
