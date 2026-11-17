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
export FAKE_REAL_KEYGEN="$(command -v ssh-keygen)"
"$FAKE_REAL_KEYGEN" -q -t ed25519 -N '' -C test-device -f "${RUNTIME_DIR}/device-key"
export FAKE_DEVICE_FINGERPRINT="$("$FAKE_REAL_KEYGEN" -lf "${RUNTIME_DIR}/device-key.pub" -E sha256 | awk '{print $2}')"

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
jq --arg key "$(cat "${RUNTIME_DIR}/device-key.pub")" '.public_key = $key' "$REQUEST_FILE" >"${RUNTIME_DIR}/request.next"
mv "${RUNTIME_DIR}/request.next" "$REQUEST_FILE"

cat >"${FAKE_BIN}/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
printf '100.64.10.20 ssh-ed25519 AAAATESTKEY\n'
EOF

cat >"${FAKE_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *device.pub*) exec "$FAKE_REAL_KEYGEN" "$@" ;;
  *)
    if [[ "${FAKE_HOST_MISMATCH:-0}" == 1 ]]; then
      printf '256 SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC test (ED25519)\n'
    else
      printf '256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test (ED25519)\n'
    fi
    ;;
esac
EOF

cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
printf '%s\n' "$arguments" >>"${FAKE_ADMIN_STATE}"
case "$arguments" in
  *'approve -'*)
    cat >/dev/null
    if [[ "${FAKE_APPROVAL_FAIL:-0}" == 1 ]]; then touch "${FAKE_ADMIN_STATE}.approved"; exit 255; fi
    device=test-device; platform=macos; fingerprint="$FAKE_DEVICE_FINGERPRINT"
    case "${FAKE_MISMATCH:-0}" in
      1) device=other-device ;;
      platform) platform=windows ;;
      fingerprint) fingerprint=SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB ;;
    esac
    printf '{"status":"approved","device_id":"%s","platform":"%s","public_key_fingerprint":"%s","approved_at":"2026-08-31T07:31:00Z"}\n' "$device" "$platform" "$fingerprint"
    ;;
  *' list')
    mode="${FAKE_LIST_MODE:-empty}"
    if [[ -f "${FAKE_ADMIN_STATE}.approved" ]]; then mode=approved; fi
    case "$mode" in
      empty) printf '[]\n' ;;
      invalid) printf '{}\n' ;;
      approved|conflict|duplicate)
        fingerprint="$FAKE_DEVICE_FINGERPRINT"
        if [[ "$mode" == conflict ]]; then fingerprint=SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC; fi
        record="$(jq -nc --arg fingerprint "$fingerprint" '{device_id:"test-device", platform:"macos", public_key_fingerprint:$fingerprint}')"
        if [[ "$mode" == duplicate ]]; then printf '[%s,%s]\n' "$record" "$record"; else printf '[%s]\n' "$record"; fi
        ;;
    esac
    ;;
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
if stat -f '%Lp' "$OUTPUT_FILE" >/dev/null 2>&1; then
  [[ "$(stat -f '%Lp' "$OUTPUT_FILE")" == "600" ]]
else
  [[ "$(stat -c '%a' "$OUTPUT_FILE")" == "600" ]]
fi
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

MISMATCH_OUTPUT="${RUNTIME_DIR}/mismatch.connection.json"
if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" FAKE_MISMATCH=1 \
  CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
    bash "${ROOT_DIR}/admin/codex-via-server-admin" \
      approve "$REQUEST_FILE" --output "$MISMATCH_OUTPUT" >/dev/null 2>&1; then
  printf 'administrator wrapper exported approval for a different device\n' >&2
  exit 1
fi
[[ ! -e "$MISMATCH_OUTPUT" ]]

if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
  CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" \
    bash "${ROOT_DIR}/admin/codex-via-server-admin" \
      approve "$REQUEST_FILE" --output "$OUTPUT_FILE" >/dev/null 2>&1; then
  printf 'administrator wrapper overwrote an existing profile\n' >&2
  exit 1
fi

bash -n "${ROOT_DIR}/admin/approve-device.command"

run_admin() {
  PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" FAKE_ADMIN_STATE="$STATE_FILE" \
  CODEX_VIA_SERVER_ADMIN_CONFIG="$CONFIG_FILE" bash "${ROOT_DIR}/admin/codex-via-server-admin" "$@"
}

for mismatch in platform fingerprint; do
  if FAKE_MISMATCH="$mismatch" run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/${mismatch}.json" >/dev/null 2>&1; then
    printf 'accepted mismatched approval %s\n' "$mismatch" >&2; exit 1
  fi
  [[ ! -e "${RUNTIME_DIR}/${mismatch}.json" ]]
done

for mode in conflict duplicate invalid; do
  if FAKE_LIST_MODE="$mode" run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/${mode}.json" >/dev/null 2>&1; then
    printf 'accepted unsafe device list %s\n' "$mode" >&2; exit 1
  fi
  [[ ! -e "${RUNTIME_DIR}/${mode}.json" ]]
done

if FAKE_HOST_MISMATCH=1 run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/wrong-host.json" >/dev/null 2>&1; then
  printf 'accepted changed SSH host fingerprint\n' >&2; exit 1
fi
[[ ! -e "${RUNTIME_DIR}/wrong-host.json" ]]

approval_count="$(grep -c 'approve -' "$STATE_FILE")"
FAKE_LIST_MODE=approved run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/recovered.json" >/dev/null
[[ "$(grep -c 'approve -' "$STATE_FILE")" == "$approval_count" ]]
node "${ROOT_DIR}/tests/validate-instance.mjs" connection-profile "${RUNTIME_DIR}/recovered.json" >/dev/null

if FAKE_APPROVAL_FAIL=1 run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/lost.json" >/dev/null 2>&1; then
  printf 'reported approval success after lost SSH response\n' >&2; exit 1
fi
[[ ! -e "${RUNTIME_DIR}/lost.json" ]]
approval_count="$(grep -c 'approve -' "$STATE_FILE")"
run_admin approve "$REQUEST_FILE" --output "${RUNTIME_DIR}/lost.json" >/dev/null
[[ "$(grep -c 'approve -' "$STATE_FILE")" == "$approval_count" ]]
node "${ROOT_DIR}/tests/validate-instance.mjs" connection-profile "${RUNTIME_DIR}/lost.json" >/dev/null
rm "${STATE_FILE}.approved"

for invalid in '.["extra"] = "unexpected"' '.device_id = "../unsafe"' '.platform = "linux"' '.requested_at = "invalid"' '.public_key = "ssh-ed25519 INVALID"'; do
  jq "$invalid" "$REQUEST_FILE" >"${RUNTIME_DIR}/invalid-request.json"
  if run_admin approve "${RUNTIME_DIR}/invalid-request.json" --output "${RUNTIME_DIR}/invalid-output.json" >/dev/null 2>&1; then
    printf 'accepted invalid request %s\n' "$invalid" >&2; exit 1
  fi
  [[ ! -e "${RUNTIME_DIR}/invalid-output.json" ]]
done

NONROOT_CONFIG="${RUNTIME_DIR}/nonroot.json"
jq '.admin.user = "operator"' "$CONFIG_FILE" >"$NONROOT_CONFIG"
chmod 0600 "$NONROOT_CONFIG"
PATH="${FAKE_BIN}:${PATH}" FAKE_ADMIN_STATE="$STATE_FILE" CODEX_VIA_SERVER_ADMIN_CONFIG="$NONROOT_CONFIG" \
  bash "${ROOT_DIR}/admin/codex-via-server-admin" list >/dev/null
grep -q 'sudo -n /usr/local/sbin/codex-via-server-devices list' "$STATE_FILE"
for option in 'BatchMode=yes' 'StrictHostKeyChecking=yes' 'IdentitiesOnly=yes' 'PasswordAuthentication=no' 'KbdInteractiveAuthentication=no' 'ProxyCommand=none' 'ProxyJump=none' 'PermitLocalCommand=no' 'ClearAllForwardings=yes'; do
  grep -q -- "$option" "$STATE_FILE"
done

printf 'PASS: administrator simulated-SSH suite, real device-key fingerprint, schema, response binding, lost-response recovery, conflicts, safe output and fixed commands\n'
