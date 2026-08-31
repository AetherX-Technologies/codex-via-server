#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-macos-enroll-test.XXXXXX)"
FAKE_HOME="${TEST_ROOT}/home"
COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh"
REQUEST_FILE="${TEST_ROOT}/request.json"
PROFILE_FILE="${TEST_ROOT}/approved-profile.json"
KEY_DIR="${FAKE_HOME}/.ssh/codex-via-server"

cleanup() {
  trap - EXIT HUP INT TERM
  find "$TEST_ROOT" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  bash "${ROOT_DIR}/codex-via-server" setup \
    --device-id mac-enroll-01 \
    --output "$REQUEST_FILE" >/dev/null

fingerprint="$(ssh-keygen -lf "${KEY_DIR}/mac-enroll-01.pub" -E sha256 | awk 'NR == 1 {print $2}')"
jq -n \
  --arg fingerprint "$fingerprint" \
  '{
    schema_version: 1,
    profile_id: "test-profile",
    server: {
      host: "100.64.10.20",
      ssh_port: 22,
      ssh_user: "codex-tunnel",
      host_fingerprints: ["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
    },
    gateway: {remote_host: "127.0.0.1", remote_port: 18319},
    client: {
      local_port: 18317,
      codex_profile: "codex-via-server",
      minimum_client_version: "0.2.0-dev.1",
      minimum_codex_version: "0.149.1"
    },
    approved_device: {device_id: "mac-enroll-01", public_key_fingerprint: $fingerprint},
    issued_at: "2026-08-31T08:00:00Z"
  }' >"$PROFILE_FILE"

mkdir -p "${FAKE_HOME}/.codex"
printf 'sentinel = "unchanged"\n' >"${FAKE_HOME}/.codex/config.toml"
before_hash="$(shasum -a 256 "${FAKE_HOME}/.codex/config.toml" | awk '{print $1}')"

HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" \
CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
  bash "${ROOT_DIR}/codex-via-server" enroll "$PROFILE_FILE" >/dev/null

after_hash="$(shasum -a 256 "${FAKE_HOME}/.codex/config.toml" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]]

installed_connection="${FAKE_HOME}/.config/codex-via-server/connection-profile.json"
installed_codex="${FAKE_HOME}/.codex/codex-via-server.config.toml"
node "${ROOT_DIR}/tests/validate-instance.mjs" connection-profile "$installed_connection" >/dev/null
[[ "$(stat -f '%Lp' "$installed_connection")" == "600" ]]
[[ "$(stat -f '%Lp' "$installed_codex")" == "600" ]]
grep -q 'base_url = "http://127.0.0.1:18317/v1"' "$installed_codex"
grep -q 'wire_api = "responses"' "$installed_codex"
grep -q 'supports_websockets = false' "$installed_codex"

if grep -Eq 'env_key|requires_openai_auth|model_catalog_json|api_key|private_key|command' \
    "$installed_codex" "$installed_connection"; then
  printf 'installed profiles contain a forbidden credential or command field\n' >&2
  exit 1
fi

wrong_profile="${TEST_ROOT}/wrong-profile.json"
jq '.approved_device.public_key_fingerprint = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"' \
  "$PROFILE_FILE" >"$wrong_profile"
if HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" \
  CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
    bash "${ROOT_DIR}/codex-via-server" enroll "$wrong_profile" >/dev/null 2>&1; then
  printf 'enroll accepted a connection profile for another device\n' >&2
  exit 1
fi

unknown_field_profile="${TEST_ROOT}/unknown-field-profile.json"
jq '.api_key = "forbidden-placeholder"' "$PROFILE_FILE" >"$unknown_field_profile"
if HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" \
  CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
    bash "${ROOT_DIR}/codex-via-server" enroll "$unknown_field_profile" >/dev/null 2>&1; then
  printf 'enroll accepted an unknown credential field\n' >&2
  exit 1
fi

old_client_profile="${TEST_ROOT}/old-client-profile.json"
jq '.client.minimum_client_version = "9.0.0"' "$PROFILE_FILE" >"$old_client_profile"
if HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" \
  CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  CODEX_VIA_SERVER_VERSION="0.2.0-dev.1" \
    bash "${ROOT_DIR}/codex-via-server" enroll "$old_client_profile" >/dev/null 2>&1; then
  printf 'enroll accepted an unsupported client version\n' >&2
  exit 1
fi

printf 'PASS: macOS enroll validates device, versions, no-secret profile, and default config preservation\n'
