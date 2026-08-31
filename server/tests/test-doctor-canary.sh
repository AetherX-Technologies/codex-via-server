#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-doctor-canary-test.XXXXXX)"
IMAGE_NAME="codex-doctor-canary-test:$$"
CONTAINER_NAME="codex-doctor-canary-test-$$"
KEY_FILE="/run/test/cliproxyapi-client.env"

cleanup() {
  trap - EXIT HUP INT TERM
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
  find "$RUNTIME_DIR" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

docker info >/dev/null
printf 'CLIPROXY_API_KEY=test-server-only-key\n' >"${RUNTIME_DIR}/cliproxyapi-client.env"
chmod 0600 "${RUNTIME_DIR}/cliproxyapi-client.env"

docker build \
  -f "${ROOT_DIR}/server/tests/install/Dockerfile" \
  -t "$IMAGE_NAME" \
  "$ROOT_DIR" >/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  -v "${RUNTIME_DIR}:/run/test" \
  "$IMAGE_NAME" \
  sleep infinity >/dev/null

docker exec "$CONTAINER_NAME" chown root:root "$KEY_FILE"
docker exec "$CONTAINER_NAME" chmod 0600 "$KEY_FILE"
docker exec "$CONTAINER_NAME" \
  /app/server/install.sh --api-key-file "$KEY_FILE" --no-reload >/dev/null

docker exec "$CONTAINER_NAME" bash -c '
  EXPECTED_AUTHORIZATION="Bearer test-server-only-key" \
    python3 /app/server/tests/mock-cliproxyapi.py >/run/mock-cliproxyapi.log 2>&1 &
  nginx
  /usr/sbin/sshd
'

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$CONTAINER_NAME" \
      curl --proxy '' --noproxy '*' -fsS http://127.0.0.1:18319/v1/models \
      >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]]

doctor_output="$(
  docker exec "$CONTAINER_NAME" \
    /app/server/doctor.sh --foundation --skip-services
)"
printf '%s\n' "$doctor_output" | grep -q '^doctor=pass mode=foundation '

canary_output="$(
  docker exec "$CONTAINER_NAME" \
    /app/server/canary.sh --model test-model
)"
printf '%s\n' "$canary_output" | grep -Eq '^status=pass duration_ms=[0-9]+ model=test-model$'

if printf '%s\n%s\n' "$doctor_output" "$canary_output" \
    | grep -Eq 'test-server-only-key|Authorization|response body|Reply only OK'; then
  printf 'doctor or canary output contains sensitive material\n' >&2
  exit 1
fi

docker exec "$CONTAINER_NAME" pkill -f mock-cliproxyapi.py
if docker exec "$CONTAINER_NAME" \
    /app/server/doctor.sh --foundation --skip-services \
    >"${RUNTIME_DIR}/doctor-failure.log" 2>&1; then
  printf 'doctor passed with CLIProxyAPI unavailable\n' >&2
  exit 1
fi

if grep -Eq 'test-server-only-key|Authorization|Reply only OK' "${RUNTIME_DIR}/doctor-failure.log"; then
  printf 'doctor failure log contains sensitive material\n' >&2
  exit 1
fi
grep -q 'gateway models request failed' "${RUNTIME_DIR}/doctor-failure.log"

printf 'PASS: server doctor, canary, safe output, and failure detection\n'
