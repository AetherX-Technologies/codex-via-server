#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-server-install-test.XXXXXX)"
IMAGE_NAME="codex-server-install-test:$$"
CONTAINER_NAME="codex-server-install-test-$$"
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
  /app/server/install.sh --api-key-file "$KEY_FILE" --dry-run >"${RUNTIME_DIR}/dry-run.log"

if docker exec "$CONTAINER_NAME" test -e /etc/nginx/conf.d/codex-via-server.conf; then
  printf 'dry run changed Nginx state\n' >&2
  exit 1
fi

docker exec "$CONTAINER_NAME" \
  /app/server/install.sh --api-key-file "$KEY_FILE" --no-reload >"${RUNTIME_DIR}/install-1.log"

docker exec "$CONTAINER_NAME" nginx -t >/dev/null
docker exec "$CONTAINER_NAME" /usr/sbin/sshd -t
docker exec "$CONTAINER_NAME" test "$(docker exec "$CONTAINER_NAME" stat -c '%a %U:%G' /etc/codex-via-server/gateway-secret.conf)" = "600 root:root"
docker exec "$CONTAINER_NAME" test "$(docker exec "$CONTAINER_NAME" stat -c '%a %U:%G' /etc/ssh/authorized_keys/codex-tunnel)" = "640 root:codex-tunnel"
docker exec "$CONTAINER_NAME" test -x /usr/local/sbin/codex-via-server-update-cliproxyapi
docker exec "$CONTAINER_NAME" test -r /usr/local/lib/codex-via-server/releases.sh

before_nginx="$(docker exec "$CONTAINER_NAME" sha256sum /etc/nginx/conf.d/codex-via-server.conf)"
before_secret="$(docker exec "$CONTAINER_NAME" sha256sum /etc/codex-via-server/gateway-secret.conf)"
before_sshd="$(docker exec "$CONTAINER_NAME" sha256sum /etc/ssh/sshd_config.d/90-codex-via-server.conf)"

docker exec "$CONTAINER_NAME" \
  /app/server/install.sh --api-key-file "$KEY_FILE" --no-reload >"${RUNTIME_DIR}/install-2.log"

[[ "$before_nginx" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/nginx/conf.d/codex-via-server.conf)" ]]
[[ "$before_secret" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/codex-via-server/gateway-secret.conf)" ]]
[[ "$before_sshd" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/ssh/sshd_config.d/90-codex-via-server.conf)" ]]

printf 'server { invalid; }\n' >"${RUNTIME_DIR}/invalid-nginx.conf"
set +e
docker exec \
  -e NGINX_CONFIG_SOURCE=/run/test/invalid-nginx.conf \
  "$CONTAINER_NAME" \
  /app/server/install.sh --api-key-file "$KEY_FILE" --no-reload \
  >"${RUNTIME_DIR}/install-failure.log" 2>&1
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]]

[[ "$before_nginx" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/nginx/conf.d/codex-via-server.conf)" ]]
[[ "$before_secret" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/codex-via-server/gateway-secret.conf)" ]]
[[ "$before_sshd" == "$(docker exec "$CONTAINER_NAME" sha256sum /etc/ssh/sshd_config.d/90-codex-via-server.conf)" ]]
docker exec "$CONTAINER_NAME" nginx -t >/dev/null
docker exec "$CONTAINER_NAME" /usr/sbin/sshd -t

combined_logs="$(cat "${RUNTIME_DIR}"/*.log)"
if printf '%s\n' "$combined_logs" | grep -q 'test-server-only-key'; then
  printf 'installer logs contain API key material\n' >&2
  exit 1
fi

backup_count="$(docker exec "$CONTAINER_NAME" find /var/backups/codex-via-server -mindepth 1 -maxdepth 1 -type d | wc -l)"
[[ "$backup_count" -ge 3 ]]

printf 'PASS: server dry-run, install, idempotency, validation, and rollback\n'
