#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/codex-admin-test.XXXXXX)"
FAKE_BIN="${RUNTIME_DIR}/bin"
FAKE_HOME="${RUNTIME_DIR}/home"
CONFIG_FILE="${RUNTIME_DIR}/admin.json"
REQUEST_FILE="${RUNTIME_DIR}/request.json"
OUTPUT_FILE="${RUNTIME_DIR}/connection-profile.json"
FAKE_IDENTITY="${RUNTIME_DIR}/admin-key"
STATE_FILE="${RUNTIME_DIR}/ssh-state"

cleanup() {
  trap - EXIT HUP INT TERM
  find "$RUNTIME_DIR" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FAKE_BIN" "$FAKE_HOME"
printf 'test admin identity\n' >"$FAKE_IDENTITY"
chmod 0600 "$FAKE_IDENTITY"

cat >"$CONFIG_FILE" <<EOF
{
  "schema_version": 1,
  "profile_id": "test-profile",
  "admin": {
    "host": "100.64.10.20",
    "port": 22,
    "user": "root",
    "identity": "${FAKE_IDENTITY}",
    "host_fingerprints": ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
  },
  "tunnel": {"host": "100.64.10.20", "port": 22, "user": "codex-tunnel"},
  "gateway": {"remote_host": "127.0.0.1", "remote_port": 18319},
  "client": {
    "local_port": 18317,
    "codex_profile": "codex-via-server",
    "minimum_client_version": "0.2.0",
    "minimum_codex_version": "0.149.1"
  }
}
EOF
chmod 0600 "$CONFIG_FILE"

cat >"$REQUEST_FILE" <<'EOF'
{
  "schema_version": 1,
  "device_id": "test-device",
  "platform": "macos",
  "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5vbi1zZWNyZXQtdGVzdC1rZXktbWF0ZXJpYWw test-device",
  "requested_at": "2026-08-31T07:30:00Z"
}
EOF

cat >"${FAKE_BIN}/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
printf '100.64.10.20 ssh-ed25519 AAAATESTKEY\n'
EOF

cat >"${FAKE_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf '256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test (ED25519)\n'
EOF

cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
printf '%s\n' "$arguments" >>"${FAKE_ADMIN_STATE}"
case "$arguments" in
  *'approve -'*)
    cat >/dev/null
    printf '{"status":"approved","device_id":"test-device","platform":"macos","public_key_fingerprint":"SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","approved_at":"2026-08-31T07:31:00Z"}\n'
    ;;
  *' list') printf '[]\n' ;;
  *'revoke test-device'*) printf '{"status":"revoked","device_id":"test-device"}\n' ;;
  *) exit 9 ;;
esac
EOF

chmod 0755 "${FAKE_BIN}/ssh-keyscan" "${FAKE_BIN}/ssh-keygen" "${FAKE_BIN}/ssh"

PATH="${FAKE_BIN}:${PATH}" \
HOME="$FAKE_HOME" \
FAKE_ADMIN_STATE="$STATE_FILE" \
CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
  bash "${ROOT_DIR}/admin/codex-via-server-admin" \
    approve "$REQUEST_FILE" --output "$OUTPUT_FILE" >/dev/null

node "${ROOT_DIR}/tests/validate-instance.mjs" connection-profile "$OUTPUT_FILE" >/dev/null
[[ "$(stat -f '%Lp' "$OUTPUT_FILE")" == "600" ]]
[[ "$(jq -r '.approved_device.device_id' "$OUTPUT_FILE")" == "test-device" ]]
[[ "$(jq -r '.server.ssh_user' "$OUTPUT_FILE")" == "codex-tunnel" ]]

PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
  bash "${ROOT_DIR}/admin/codex-via-server-admin" list >/dev/null

PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
  bash "${ROOT_DIR}/admin/codex-via-server-admin" revoke test-device >/dev/null

if grep -Eq 'cliproxy|api.key|private.key|command=' "$OUTPUT_FILE"; then
  printf 'connection profile contains forbidden credential or command fields\n' >&2
  exit 1
fi

if grep -q 'sh -c' "$STATE_FILE"; then
  printf 'administrator wrapper invoked a general remote shell\n' >&2
  exit 1
fi

grep -q '/usr/local/sbin/codex-via-server-devices approve -' "$STATE_FILE"
grep -q '/usr/local/sbin/codex-via-server-devices list' "$STATE_FILE"
grep -q '/usr/local/sbin/codex-via-server-devices revoke test-device' "$STATE_FILE"

UNSAFE_CONFIG="${RUNTIME_DIR}/unsafe-admin.json"
jq '.admin.host = "-oProxyCommand=unsafe"' "$CONFIG_FILE" >"$UNSAFE_CONFIG"
chmod 0600 "$UNSAFE_CONFIG"
if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
  CODEX_VIA_SERVER_ADMIN_CONFIG="$UNSAFE_CONFIG" \
    bash "${ROOT_DIR}/admin/codex-via-server-admin" list >/dev/null 2>&1; then
  printf 'administrator wrapper accepted an unsafe host\n' >&2
  exit 1
fi

SYMLINK_TARGET="${RUNTIME_DIR}/symlink-target"
SYMLINK_OUTPUT="${RUNTIME_DIR}/symlink-output"
printf 'preserve\n' >"$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_OUTPUT"
if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
  CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
    bash "${ROOT_DIR}/admin/codex-via-server-admin" \
      approve "$REQUEST_FILE" --output "$SYMLINK_OUTPUT" >/dev/null 2>&1; then
  printf 'administrator wrapper wrote through a symbolic link\n' >&2
  exit 1
fi
[[ "$(cat "$SYMLINK_TARGET")" == "preserve" ]]

printf 'PASS: administrator approve, profile, list, revoke, and fixed remote commands\n'
