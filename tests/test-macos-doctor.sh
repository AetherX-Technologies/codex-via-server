#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-macos-doctor-test.XXXXXX)"
FAKE_HOME="${TEST_ROOT}/home"
FAKE_BIN="${TEST_ROOT}/bin"
FAKE_STATE="${TEST_ROOT}/state"
COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh"
TUNNEL_FILE="${ROOT_DIR}/macos/lib/tunnel.sh"
REQUEST_FILE="${TEST_ROOT}/request.json"
PROFILE_FILE="${TEST_ROOT}/approved-profile.json"
SERVER_KEY="${TEST_ROOT}/server-key"

cleanup() {
  trap - EXIT HUP INT TERM
  find "$TEST_ROOT" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$FAKE_STATE"
HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  bash "${ROOT_DIR}/codex-via-server" setup \
    --device-id mac-doctor-01 \
    --output "$REQUEST_FILE" >/dev/null

device_fingerprint="$(ssh-keygen -lf "${FAKE_HOME}/.ssh/codex-via-server/mac-doctor-01.pub" -E sha256 | awk 'NR == 1 {print $2}')"
ssh-keygen -q -t ed25519 -N '' -C server-test -f "$SERVER_KEY"
server_fingerprint="$(ssh-keygen -lf "${SERVER_KEY}.pub" -E sha256 | awk 'NR == 1 {print $2}')"

jq -n \
  --arg device_fingerprint "$device_fingerprint" \
  --arg server_fingerprint "$server_fingerprint" \
  '{
    schema_version: 1,
    profile_id: "test-profile",
    server: {host: "100.64.10.20", ssh_port: 22, ssh_user: "codex-tunnel", host_fingerprints: [$server_fingerprint]},
    gateway: {remote_host: "127.0.0.1", remote_port: 18319},
    client: {local_port: 18317, codex_profile: "codex-via-server", minimum_client_version: "0.2.0-dev.1", minimum_codex_version: "0.149.1"},
    approved_device: {device_id: "mac-doctor-01", public_key_fingerprint: $device_fingerprint},
    issued_at: "2026-08-31T08:30:00Z"
  }' >"$PROFILE_FILE"

HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" \
CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
  bash "${ROOT_DIR}/codex-via-server" enroll "$PROFILE_FILE" >/dev/null

cat >"${FAKE_BIN}/route" <<'EOF'
#!/usr/bin/env bash
printf '   route to: 100.64.10.20\n'
printf '  interface: utun99\n'
EOF
cat >"${FAKE_BIN}/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"${FAKE_BIN}/ssh-keyscan" <<EOF
#!/usr/bin/env bash
printf '100.64.10.20 %s\n' "$(cut -d' ' -f1-2 "${SERVER_KEY}.pub")"
EOF
cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_STATE}/ssh.log"
case "$*" in
  *'-O exit'*) printf 'closed\n' >"${FAKE_STATE}/ssh-exit" ;;
esac
exit 0
EOF
cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_STATE}/curl.log"
case "$*" in
  *'/v1/models'*) printf '{"data":[]}\n' ;;
  *'/v1/responses'*) printf 'data: {"type":"response.completed"}\n\n' ;;
  *) exit 9 ;;
esac
EOF
cat >"${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--version" || "$*" == *'--profile codex-via-server --version'* ]]; then
  printf 'codex-cli 0.151.0\n'
  exit 0
fi
[[ -z "${SERVER_CODEX_API_KEY:-}" ]]
[[ -z "${CLIPROXY_API_KEY:-}" ]]
[[ -z "${OPENAI_API_KEY:-}" ]]
printf '%s\n' "$@" >"${FAKE_STATE}/codex-args"
EOF
chmod 0755 "${FAKE_BIN}/route" "${FAKE_BIN}/lsof" "${FAKE_BIN}/ssh-keyscan" "${FAKE_BIN}/ssh" "${FAKE_BIN}/curl" "${FAKE_BIN}/codex"

COMMON_ENV=(
  PATH="${FAKE_BIN}:${PATH}"
  HOME="$FAKE_HOME"
  CODEX_HOME="${FAKE_HOME}/.codex"
  CODEX_BINARY="${FAKE_BIN}/codex"
  CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE"
  CODEX_VIA_SERVER_TUNNEL_FILE="$TUNNEL_FILE"
  CODEX_VIA_SERVER_CONNECTION_PROFILE="${FAKE_HOME}/.config/codex-via-server/connection-profile.json"
  FAKE_STATE="$FAKE_STATE"
  SERVER_CODEX_API_KEY="must-not-leak"
  CLIPROXY_API_KEY="must-not-leak"
  OPENAI_API_KEY="must-not-leak"
)

env "${COMMON_ENV[@]}" bash "${ROOT_DIR}/codex-via-server" \
  exec --model test-model prompt >/dev/null
grep -q '^--profile$' "${FAKE_STATE}/codex-args"
grep -q '^codex-via-server$' "${FAKE_STATE}/codex-args"
grep -q '^prompt$' "${FAKE_STATE}/codex-args"
grep -q '127.0.0.1:18317:127.0.0.1:18319' "${FAKE_STATE}/ssh.log"
if grep -Eq 'CLIPROXY_API_KEY|SERVER_CODEX_API_KEY|Authorization|sed -n|/root/' \
    "${FAKE_STATE}/ssh.log" "${FAKE_STATE}/curl.log"; then
  printf 'v0.2 tunnel attempted to read or send a credential\n' >&2
  exit 1
fi

doctor_output="$(env "${COMMON_ENV[@]}" bash "${ROOT_DIR}/codex-via-server" doctor)"
printf '%s\n' "$doctor_output" | grep -q '^doctor=pass codex=0.151.0 profile=codex-via-server live=0$'

set +e
env "${COMMON_ENV[@]}" bash "${ROOT_DIR}/codex-via-server" doctor --live --model test-model >/dev/null 2>&1
unconfirmed_status=$?
set -e
[[ "$unconfirmed_status" == "2" ]]

live_output="$(env "${COMMON_ENV[@]}" bash "${ROOT_DIR}/codex-via-server" doctor --live --yes --model test-model)"
printf '%s\n' "$live_output" | grep -q 'live=1$'

grep -q 'closed' "${FAKE_STATE}/ssh-exit"
if find /tmp -maxdepth 1 \( -name 'codex-via-server.*' -o -name 'codex-client-canary.*' \) \
    | grep -q .; then
  printf 'v0.2 launcher left a runtime directory\n' >&2
  exit 1
fi

printf 'PASS: macOS no-secret tunnel, doctor, live confirmation, passthrough, and cleanup\n'
