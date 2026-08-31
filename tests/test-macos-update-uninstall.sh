#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-macos-update-test.XXXXXX)"
FAKE_HOME="${TEST_ROOT}/home"
COMMANDS_FILE="${ROOT_DIR}/macos/lib/commands.sh"
RELEASE_ROOT="${TEST_ROOT}/release-http"
RELEASE_DIR="${TEST_ROOT}/package/codex-via-server-macos"
HTTP_PORT=""
HTTP_PID=""

cleanup() {
  trap - EXIT HUP INT TERM
  [[ -z "$HTTP_PID" ]] || { kill "$HTTP_PID" >/dev/null 2>&1 || true; wait "$HTTP_PID" 2>/dev/null || true; }
  find "$TEST_ROOT" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FAKE_HOME" "$RELEASE_ROOT" "$RELEASE_DIR/macos/lib"
cp "${ROOT_DIR}/codex-via-server" "$RELEASE_DIR/codex-via-server"
cp "${ROOT_DIR}/macos/lib/"*.sh "$RELEASE_DIR/macos/lib/"
printf '0.2.0\n' >"${RELEASE_DIR}/VERSION"
python3 - "$RELEASE_DIR" "${RELEASE_ROOT}/codex-via-server-macos.tar.gz" <<'PYTHON'
import sys
import tarfile
from pathlib import Path

source = Path(sys.argv[1])
archive = Path(sys.argv[2])
with tarfile.open(archive, "w:gz") as handle:
    handle.add(source, arcname="codex-via-server-macos")
PYTHON
archive_sha="$(shasum -a 256 "${RELEASE_ROOT}/codex-via-server-macos.tar.gz" | awk '{print $1}')"
printf '%s  codex-via-server-macos.tar.gz\n' "$archive_sha" >"${RELEASE_ROOT}/checksums.txt"

HTTP_PORT="$(python3 -c 'import socket; value = socket.socket(); value.bind(("127.0.0.1", 0)); print(value.getsockname()[1]); value.close()')"
cat >"${RELEASE_ROOT}/release.json" <<EOF
{"tag_name":"v0.2.0","assets":[
  {"name":"codex-via-server-macos.tar.gz","browser_download_url":"http://127.0.0.1:${HTTP_PORT}/codex-via-server-macos.tar.gz"},
  {"name":"checksums.txt","browser_download_url":"http://127.0.0.1:${HTTP_PORT}/checksums.txt"}
]}
EOF
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$RELEASE_ROOT" >"${TEST_ROOT}/http.log" 2>&1 &
HTTP_PID=$!
for attempt in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "http://127.0.0.1:${HTTP_PORT}/release.json" >/dev/null 2>&1 && break; sleep 1; done

mkdir -p "${FAKE_HOME}/.local/bin" "${FAKE_HOME}/.local/lib/codex-via-server" "${FAKE_HOME}/.local/share/codex-via-server"
printf 'old-launcher\n' >"${FAKE_HOME}/.local/bin/codex-via-server"
printf 'old-library\n' >"${FAKE_HOME}/.local/lib/codex-via-server/old.sh"
printf '0.1.0\n' >"${FAKE_HOME}/.local/share/codex-via-server/VERSION"

check_output="$(HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" CODEX_VIA_SERVER_RELEASE_API="http://127.0.0.1:${HTTP_PORT}/release.json" bash "${ROOT_DIR}/codex-via-server" update --check-only --force)"
printf '%s\n' "$check_output" | grep -q 'installed=0.1.0 latest=0.2.0 cached=0'
cached_output="$(HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" CODEX_VIA_SERVER_RELEASE_API="http://127.0.0.1:${HTTP_PORT}/missing.json" bash "${ROOT_DIR}/codex-via-server" update --check-only)"
printf '%s\n' "$cached_output" | grep -q 'cached=1'

set +e
HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" CODEX_VIA_SERVER_RELEASE_API="http://127.0.0.1:${HTTP_PORT}/release.json" CODEX_VIA_SERVER_TEST_FAIL_STAGE=after-launcher bash "${ROOT_DIR}/codex-via-server" update --force >/dev/null 2>&1
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]]
[[ "$(cat "${FAKE_HOME}/.local/bin/codex-via-server")" == "old-launcher" ]]
[[ "$(cat "${FAKE_HOME}/.local/lib/codex-via-server/old.sh")" == "old-library" ]]
[[ "$(cat "${FAKE_HOME}/.local/share/codex-via-server/VERSION")" == "0.1.0" ]]

HOME="$FAKE_HOME" CODEX_VIA_SERVER_COMMANDS_FILE="$COMMANDS_FILE" CODEX_VIA_SERVER_RELEASE_API="http://127.0.0.1:${HTTP_PORT}/release.json" bash "${ROOT_DIR}/codex-via-server" update --force >/dev/null
[[ "$(cat "${FAKE_HOME}/.local/share/codex-via-server/VERSION")" == "0.2.0" ]]
bash -n "${FAKE_HOME}/.local/bin/codex-via-server"

mkdir -p "${FAKE_HOME}/.codex" "${FAKE_HOME}/.ssh/codex-via-server" "${FAKE_HOME}/.config/codex-via-server"
printf 'default-sentinel\n' >"${FAKE_HOME}/.codex/config.toml"
printf 'unrelated-key\n' >"${FAKE_HOME}/.ssh/unrelated-key"
printf 'device-private\n' >"${FAKE_HOME}/.ssh/codex-via-server/test-device"
printf 'device-public\n' >"${FAKE_HOME}/.ssh/codex-via-server/test-device.pub"
cat >"${FAKE_HOME}/.config/codex-via-server/connection-profile.json" <<'EOF'
{"client":{"codex_profile":"codex-via-server"},"approved_device":{"device_id":"test-device"}}
EOF
printf 'generated-profile\n' >"${FAKE_HOME}/.codex/codex-via-server.config.toml"

HOME="$FAKE_HOME" CODEX_HOME="${FAKE_HOME}/.codex" CODEX_VIA_SERVER_COMMANDS_FILE="${FAKE_HOME}/.local/lib/codex-via-server/commands.sh" bash "${FAKE_HOME}/.local/bin/codex-via-server" uninstall >/dev/null
[[ -f "${FAKE_HOME}/.codex/config.toml" ]]
[[ -f "${FAKE_HOME}/.ssh/unrelated-key" ]]
[[ -f "${FAKE_HOME}/.ssh/codex-via-server/test-device" ]]
[[ ! -e "${FAKE_HOME}/.local/bin/codex-via-server" ]]

printf 'PASS: macOS update cache, checksum, rollback, success, and scoped uninstall\n'
