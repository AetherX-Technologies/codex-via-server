#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-ssh-test.XXXXXX)"
SUFFIX="$$"
IMAGE_NAME="codex-restricted-ssh-test:${SUFFIX}"
CONTAINER_NAME="codex-restricted-ssh-test-${SUFFIX}"
PRIVATE_KEY="${RUNTIME_DIR}/id_ed25519"
PUBLIC_KEY="${PRIVATE_KEY}.pub"
KNOWN_HOSTS="${RUNTIME_DIR}/known_hosts"
ALLOWED_CONTROL="${RUNTIME_DIR}/allowed-control"
DENIED_CONTROL="${RUNTIME_DIR}/denied-control"

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

available_port() {
  python3 -c 'import socket; value = socket.socket(); value.bind(("127.0.0.1", 0)); print(value.getsockname()[1]); value.close()'
}

command -v curl >/dev/null 2>&1
command -v docker >/dev/null 2>&1
command -v ssh >/dev/null 2>&1
command -v ssh-keygen >/dev/null 2>&1

docker info >/dev/null
ssh-keygen -q -t ed25519 -N '' -C test-device -f "$PRIVATE_KEY"

docker build \
  -f "${ROOT_DIR}/server/tests/ssh/Dockerfile" \
  -t "$IMAGE_NAME" \
  "$ROOT_DIR" >/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1::22 \
  --security-opt no-new-privileges \
  -v "${PUBLIC_KEY}:/run/test-key.pub:ro" \
  "$IMAGE_NAME" >/dev/null

mapped_port="$(docker port "$CONTAINER_NAME" 22/tcp | head -n 1)"
ssh_port="${mapped_port##*:}"
[[ "$ssh_port" =~ ^[0-9]+$ ]]

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if ssh-keyscan -T 2 -p "$ssh_port" 127.0.0.1 >"$KNOWN_HOSTS" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]]

SSH_COMMAND=(
  ssh
  -F /dev/null
  -p "$ssh_port"
  -i "$PRIVATE_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  -o UpdateHostKeys=no
  -o ConnectTimeout=5
  -o LogLevel=ERROR
)
SSH_TARGET="codex-tunnel@127.0.0.1"

docker exec "$CONTAINER_NAME" /app/server/install-restricted-user.sh >/dev/null

effective_config="$(
  docker exec "$CONTAINER_NAME" \
    /usr/sbin/sshd -T -C user=codex-tunnel,host=localhost,addr=127.0.0.1
)"
printf '%s\n' "$effective_config" | grep -q '^allowtcpforwarding local$'
printf '%s\n' "$effective_config" | grep -q '^allowstreamlocalforwarding no$'
printf '%s\n' "$effective_config" | grep -q '^permitopen 127.0.0.1:18319$'
printf '%s\n' "$effective_config" | grep -q '^allowagentforwarding no$'
printf '%s\n' "$effective_config" | grep -q '^x11forwarding no$'
printf '%s\n' "$effective_config" | grep -q '^permittty no$'
printf '%s\n' "$effective_config" | grep -q '^permituserrc no$'
printf '%s\n' "$effective_config" | grep -q '^gatewayports no$'

authorized_keys_state="$(
  docker exec "$CONTAINER_NAME" stat -c '%a %U:%G' /etc/ssh/authorized_keys/codex-tunnel
)"
[[ "$authorized_keys_state" == "640 root:codex-tunnel" ]]

if "${SSH_COMMAND[@]}" "$SSH_TARGET" true >/dev/null 2>&1; then
  printf 'restricted account executed a command\n' >&2
  exit 1
fi

if "${SSH_COMMAND[@]}" -tt "$SSH_TARGET" >/dev/null 2>&1; then
  printf 'restricted account received a PTY\n' >&2
  exit 1
fi

if "${SSH_COMMAND[@]}" \
    -o ExitOnForwardFailure=yes \
    -N -f \
    -R 127.0.0.1:19319:127.0.0.1:18319 \
    "$SSH_TARGET" >/dev/null 2>&1; then
  printf 'restricted account created a remote forward\n' >&2
  exit 1
fi

allowed_port="$(available_port)"
"${SSH_COMMAND[@]}" \
  -M -S "$ALLOWED_CONTROL" \
  -o ExitOnForwardFailure=yes \
  -N -f \
  -L "127.0.0.1:${allowed_port}:127.0.0.1:18319" \
  "$SSH_TARGET"
allowed_response="$(curl -fsS --connect-timeout 3 "http://127.0.0.1:${allowed_port}/")"
[[ "$allowed_response" == "gateway-ok" ]]

denied_port="$(available_port)"
"${SSH_COMMAND[@]}" \
  -M -S "$DENIED_CONTROL" \
  -o ExitOnForwardFailure=yes \
  -N -f \
  -L "127.0.0.1:${denied_port}:127.0.0.1:18320" \
  "$SSH_TARGET"
if curl -fsS --connect-timeout 2 "http://127.0.0.1:${denied_port}/" >/dev/null 2>&1; then
  printf 'restricted account forwarded to an unapproved destination\n' >&2
  exit 1
fi

"${SSH_COMMAND[@]}" -S "$DENIED_CONTROL" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
"${SSH_COMMAND[@]}" -S "$ALLOWED_CONTROL" -O exit "$SSH_TARGET" >/dev/null 2>&1

printf 'PASS: restricted SSH permits one local forward and denies other capabilities\n'
