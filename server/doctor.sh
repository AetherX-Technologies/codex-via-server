#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="codex-via-server-doctor"
MODE="foundation"
CHECK_SERVICES=1
GATEWAY_HOST="127.0.0.1"
GATEWAY_PORT="18319"
CLIPROXY_HOST="127.0.0.1"
CLIPROXY_PORT="8317"
NGINX_BINARY="${NGINX_BINARY:-/usr/sbin/nginx}"
SSHD_BINARY="${SSHD_BINARY:-/usr/sbin/sshd}"
SYSTEMCTL_BINARY="${SYSTEMCTL_BINARY:-/usr/bin/systemctl}"
SECRET_FILE="/etc/codex-via-server/gateway-secret.conf"
AUTHORIZED_KEYS_FILE="/etc/ssh/authorized_keys/codex-tunnel"
DEVICE_STATE_DIR="/var/lib/codex-via-server/devices"

fail() {
  printf '%s: FAIL: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: server/doctor.sh [--foundation|--cutover] [--skip-services]

--foundation validates the side-by-side gateway and restricted SSH foundation.
--cutover additionally requires CLIProxyAPI to listen on loopback only.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foundation) MODE="foundation"; shift ;;
    --cutover) MODE="cutover"; shift ;;
    --skip-services) CHECK_SERVICES=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "run as root"
[[ -x "$NGINX_BINARY" ]] || fail "missing Nginx binary"
[[ -x "$SSHD_BINARY" ]] || fail "missing SSH daemon"

for dependency in curl jq ss stat; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing command: $dependency"
done

"$NGINX_BINARY" -t >/dev/null
"$SSHD_BINARY" -t

secret_state="$(stat -c '%a %U:%G' "$SECRET_FILE")"
[[ "$secret_state" == "600 root:root" ]] || fail "gateway secret permissions are $secret_state"

authorized_keys_state="$(stat -c '%a %U:%G' "$AUTHORIZED_KEYS_FILE")"
[[ "$authorized_keys_state" == "640 root:codex-tunnel" ]] \
  || fail "authorized keys permissions are $authorized_keys_state"

device_state="$(stat -c '%a %U:%G' "$DEVICE_STATE_DIR")"
[[ "$device_state" == "700 root:root" ]] || fail "device state permissions are $device_state"

gateway_endpoint="${GATEWAY_HOST}:${GATEWAY_PORT}"
ss -lntH | awk -v endpoint="$gateway_endpoint" '$4 == endpoint {found = 1} END {exit !found}' \
  || fail "gateway is not listening on $gateway_endpoint"

if ss -lntH | awk -v port=":${GATEWAY_PORT}" '$4 ~ port "$" && $4 != "127.0.0.1" port {found = 1} END {exit !found}'; then
  fail "gateway has a non-loopback listener"
fi

health_status="$(
  curl --proxy '' --noproxy '*' --connect-timeout 3 --max-time 5 \
    -sS -o /dev/null -w '%{http_code}' \
    "http://${gateway_endpoint}/healthz"
)"
[[ "$health_status" == "204" ]] || fail "gateway health returned HTTP $health_status"

models_response="$(
  curl --proxy '' --noproxy '*' --connect-timeout 3 --max-time 10 \
    -fsS "http://${gateway_endpoint}/v1/models"
)" || fail "gateway models request failed"
printf '%s\n' "$models_response" | jq -e '.data | type == "array"' >/dev/null \
  || fail "gateway models response has an unexpected shape"

if [[ "$MODE" == "cutover" ]]; then
  cliproxy_endpoint="${CLIPROXY_HOST}:${CLIPROXY_PORT}"
  ss -lntH | awk -v endpoint="$cliproxy_endpoint" '$4 == endpoint {found = 1} END {exit !found}' \
    || fail "CLIProxyAPI is not listening on $cliproxy_endpoint"

  if ss -lntH | awk -v port=":${CLIPROXY_PORT}" '$4 ~ port "$" && $4 != "127.0.0.1" port {found = 1} END {exit !found}'; then
    fail "CLIProxyAPI has a non-loopback listener after cutover"
  fi
fi

if [[ "$CHECK_SERVICES" -eq 1 ]]; then
  [[ -x "$SYSTEMCTL_BINARY" ]] || fail "missing systemctl"
  "$SYSTEMCTL_BINARY" is-active --quiet nginx || fail "nginx service is not active"
  "$SYSTEMCTL_BINARY" is-active --quiet cliproxyapi || fail "cliproxyapi service is not active"
  "$SYSTEMCTL_BINARY" is-active --quiet ssh \
    || "$SYSTEMCTL_BINARY" is-active --quiet sshd \
    || fail "SSH service is not active"
fi

printf 'doctor=pass mode=%s gateway=%s\n' "$MODE" "$gateway_endpoint"
