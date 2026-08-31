#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-integration.XXXXXX)"
IMAGE_NAME="codex-via-server-integration:$$"
CONTAINER_NAME="codex-via-server-integration-$$"
CLIENT_HOME="${RUNTIME_DIR}/client-home"
FAKE_BIN="${RUNTIME_DIR}/bin"
REQUEST_FILE="${RUNTIME_DIR}/request.json"
PROFILE_FILE="${RUNTIME_DIR}/connection-profile.json"
KNOWN_HOSTS="${RUNTIME_DIR}/known_hosts"
LOCAL_PORT="18317"

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
mkdir -p "$CLIENT_HOME" "$FAKE_BIN"

docker build -f "${ROOT_DIR}/integration/Dockerfile" -t "$IMAGE_NAME" "$ROOT_DIR" >/dev/null
docker run -d --name "$CONTAINER_NAME" -p 127.0.0.1::22 "$IMAGE_NAME" >/dev/null
mapped_port="$(docker port "$CONTAINER_NAME" 22/tcp | head -n 1)"
ssh_port="${mapped_port##*:}"

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if ssh-keyscan -T 2 -p "$ssh_port" test-server.localhost >"$KNOWN_HOSTS" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" -eq 1 ]]

HOME="$CLIENT_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh" \
  bash "${ROOT_DIR}/codex-via-server" setup --device-id integration-device --output "$REQUEST_FILE" >/dev/null
docker cp "$REQUEST_FILE" "${CONTAINER_NAME}:/run/enrollment.json"
approval="$(docker exec "$CONTAINER_NAME" /usr/local/sbin/codex-via-server-devices approve /run/enrollment.json)"
device_fingerprint="$(printf '%s\n' "$approval" | jq -r '.public_key_fingerprint')"

host_fingerprints="$(
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" != \#* ]] || continue
    printf '%s\n' "$line" >"${RUNTIME_DIR}/host-key"
    ssh-keygen -lf "${RUNTIME_DIR}/host-key" -E sha256 | awk '{print $2}'
  done <"$KNOWN_HOSTS" | jq -R . | jq -s 'unique'
)"

jq -n \
  --argjson ssh_port "$ssh_port" \
  --argjson host_fingerprints "$host_fingerprints" \
  --arg device_fingerprint "$device_fingerprint" \
  --argjson local_port "$LOCAL_PORT" \
  '{
    schema_version: 1,
    profile_id: "integration-server",
    server: {host: "test-server.localhost", ssh_port: $ssh_port, ssh_user: "codex-tunnel", host_fingerprints: $host_fingerprints},
    gateway: {remote_host: "127.0.0.1", remote_port: 18319},
    client: {local_port: $local_port, codex_profile: "codex-via-server", minimum_client_version: "0.2.0-dev.1", minimum_codex_version: "0.149.1"},
    approved_device: {device_id: "integration-device", public_key_fingerprint: $device_fingerprint},
    issued_at: "2026-08-31T10:00:00Z"
  }' >"$PROFILE_FILE"

HOME="$CLIENT_HOME" CODEX_HOME="${CLIENT_HOME}/.codex" CODEX_VIA_SERVER_COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh" CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
  bash "${ROOT_DIR}/codex-via-server" enroll "$PROFILE_FILE" >/dev/null

cat >"${FAKE_BIN}/route" <<'EOF'
#!/usr/bin/env bash
printf '   route to: test-server.localhost\n'
printf '  interface: utun99\n'
EOF
cat >"${FAKE_BIN}/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${SERVER_CODEX_API_KEY:-}" && -z "${CLIPROXY_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]
head -c 1048576 /dev/zero | tr '\0' a \
  | curl --proxy '' --noproxy '*' -fsS -H 'Content-Type: application/octet-stream' --data-binary @- http://127.0.0.1:18317/v1/responses \
  >"${INTEGRATION_STATE}/response.sse"
grep -q '"type": "response.completed"' "${INTEGRATION_STATE}/response.sse"
grep -q '"received_bytes": 1048576' "${INTEGRATION_STATE}/response.sse"
printf '%s\n' "$@" >"${INTEGRATION_STATE}/codex-args"
EOF
chmod 0755 "${FAKE_BIN}/route" "${FAKE_BIN}/lsof" "${FAKE_BIN}/codex"

PATH="${FAKE_BIN}:${PATH}" HOME="$CLIENT_HOME" CODEX_HOME="${CLIENT_HOME}/.codex" CODEX_BINARY="${FAKE_BIN}/codex" \
CODEX_VIA_SERVER_COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh" CODEX_VIA_SERVER_TUNNEL_FILE="${ROOT_DIR}/macos/lib/tunnel.sh" \
CODEX_VIA_SERVER_CONNECTION_PROFILE="${CLIENT_HOME}/.config/codex-via-server/connection-profile.json" INTEGRATION_STATE="$RUNTIME_DIR" \
SERVER_CODEX_API_KEY=forbidden CLIPROXY_API_KEY=forbidden OPENAI_API_KEY=forbidden \
  bash "${ROOT_DIR}/codex-via-server" exec integration-prompt >/dev/null

grep -q '^--profile$' "${RUNTIME_DIR}/codex-args"
grep -q '^integration-prompt$' "${RUNTIME_DIR}/codex-args"
if curl -fsS --connect-timeout 1 http://127.0.0.1:18319/healthz >/dev/null 2>&1; then
  printf 'gateway is directly exposed to the client host\n' >&2
  exit 1
fi

docker exec "$CONTAINER_NAME" /usr/local/sbin/codex-via-server-devices revoke integration-device >/dev/null
if PATH="${FAKE_BIN}:${PATH}" HOME="$CLIENT_HOME" CODEX_HOME="${CLIENT_HOME}/.codex" CODEX_BINARY="${FAKE_BIN}/codex" \
  CODEX_VIA_SERVER_COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh" CODEX_VIA_SERVER_TUNNEL_FILE="${ROOT_DIR}/macos/lib/tunnel.sh" \
  CODEX_VIA_SERVER_CONNECTION_PROFILE="${CLIENT_HOME}/.config/codex-via-server/connection-profile.json" INTEGRATION_STATE="$RUNTIME_DIR" \
    bash "${ROOT_DIR}/codex-via-server" exec after-revoke >/dev/null 2>&1; then
  printf 'revoked device still established a tunnel\n' >&2
  exit 1
fi

printf 'PASS: setup, approve, enroll, restricted tunnel, large SSE, no direct API, and revoke\n'
