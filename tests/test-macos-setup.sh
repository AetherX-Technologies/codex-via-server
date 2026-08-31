#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-macos-setup-test.XXXXXX)"
FAKE_HOME="${TEST_ROOT}/home"
COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh"
REQUEST_FILE="${TEST_ROOT}/request.json"

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
    --device-id mac-test-01 \
    --output "$REQUEST_FILE" >/dev/null

node "${ROOT_DIR}/tests/validate-instance.mjs" enrollment-request "$REQUEST_FILE" >/dev/null
private_key="${FAKE_HOME}/.ssh/codex-via-server/mac-test-01"
public_key="${private_key}.pub"
[[ "$(stat -f '%Lp' "$private_key")" == "600" ]]
[[ "$(stat -f '%Lp' "$public_key")" == "644" ]]
[[ "$(stat -f '%Lp' "$REQUEST_FILE")" == "600" ]]
first_fingerprint="$(ssh-keygen -lf "$public_key" -E sha256 | awk 'NR == 1 {print $2}')"

HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
  bash "${ROOT_DIR}/codex-via-server" setup \
    --device-id mac-test-01 \
    --output "$REQUEST_FILE" >/dev/null
second_fingerprint="$(ssh-keygen -lf "$public_key" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$first_fingerprint" == "$second_fingerprint" ]]

if grep -Eq 'BEGIN (OPENSSH|RSA|EC) PRIVATE KEY|api_key|command' "$REQUEST_FILE"; then
  printf 'enrollment request contains a forbidden field or private key\n' >&2
  exit 1
fi

if HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
    bash "${ROOT_DIR}/codex-via-server" setup \
      --device-id '../../unsafe' \
      --output "${TEST_ROOT}/unsafe.json" >/dev/null 2>&1; then
  printf 'setup accepted an unsafe device id\n' >&2
  exit 1
fi

symlink_target="${TEST_ROOT}/symlink-target"
symlink_output="${TEST_ROOT}/symlink-output"
printf 'preserve\n' >"$symlink_target"
ln -s "$symlink_target" "$symlink_output"
if HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" \
    bash "${ROOT_DIR}/codex-via-server" setup \
      --device-id mac-test-01 \
      --output "$symlink_output" >/dev/null 2>&1; then
  printf 'setup wrote through a symbolic link\n' >&2
  exit 1
fi
[[ "$(cat "$symlink_target")" == "preserve" ]]

find "$TEST_ROOT" -name '*.partial' -o -name 'codex-enrollment.*' | grep -q . \
  && { printf 'setup left a temporary file\n' >&2; exit 1; }

printf 'PASS: macOS setup, idempotent key, schema, permissions, and safety\n'
