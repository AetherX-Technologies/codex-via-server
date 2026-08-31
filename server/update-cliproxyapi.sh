#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="update-cliproxyapi"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""
MODEL=""
TRANSACTION_COMMITTED=0
RUNTIME_DIR=""
BACKUP_DIR=""
AUTH_DIGEST_BEFORE=""

CLIPROXY_BINARY="${CLIPROXY_BINARY:-/usr/local/bin/cli-proxy-api}"
CLIPROXY_CONFIG="${CLIPROXY_CONFIG:-/etc/cliproxyapi/config.yaml}"
CLIPROXY_UNIT="${CLIPROXY_UNIT:-/etc/systemd/system/cliproxyapi.service}"
CLIPROXY_AUTH_DIR="${CLIPROXY_AUTH_DIR:-/var/lib/cliproxyapi/auth}"
BACKUP_ROOT="${CLIPROXY_BACKUP_ROOT:-/var/backups/codex-via-server/cliproxyapi}"
LOCK_FILE="${CLIPROXY_UPDATE_LOCK_FILE:-/run/lock/codex-via-server-cliproxyapi.lock}"
CURL_BINARY="${CURL_BINARY:-/usr/bin/curl}"
SYSTEMCTL_BINARY="${SYSTEMCTL_BINARY:-/usr/bin/systemctl}"
DOCTOR_BINARY="${DOCTOR_BINARY:-/usr/local/sbin/codex-via-server-doctor}"
CANARY_BINARY="${CANARY_BINARY:-/usr/local/sbin/codex-via-server-canary}"
MINIMUM_VERSION="${CLIPROXY_MINIMUM_VERSION:-7.2.146}"
RELEASES_LIB="${CLIPROXY_RELEASES_LIB:-${SCRIPT_DIR}/lib/releases.sh}"

fail() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: server/update-cliproxyapi.sh --version <version> --model <canary-model>

Downloads a pinned no-plugin CLIProxyAPI release and official checksums,
installs the candidate transactionally, runs doctor and canary, and restores
the previous binary/config/unit on any failure. OAuth state is never modified.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "run as root"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version"
[[ "$MINIMUM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid minimum version"
[[ "$MODEL" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] || fail "invalid model"
[[ -x "$CLIPROXY_BINARY" ]] || fail "current CLIProxyAPI binary is missing"
[[ -f "$CLIPROXY_CONFIG" && ! -L "$CLIPROXY_CONFIG" ]] || fail "CLIProxyAPI config is missing or unsafe"
[[ -f "$CLIPROXY_UNIT" && ! -L "$CLIPROXY_UNIT" ]] || fail "CLIProxyAPI unit is missing or unsafe"
[[ -d "$CLIPROXY_AUTH_DIR" && ! -L "$CLIPROXY_AUTH_DIR" ]] || fail "CLIProxyAPI auth directory is missing or unsafe"

for executable in "$CURL_BINARY" "$SYSTEMCTL_BINARY" "$DOCTOR_BINARY" "$CANARY_BINARY"; do
  [[ -x "$executable" ]] || fail "missing executable: $executable"
done

for dependency in awk find flock install sha256sum sort tar; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing command: $dependency"
done

if [[ ! -r "$RELEASES_LIB" && -r "${SCRIPT_DIR}/../lib/codex-via-server/releases.sh" ]]; then
  RELEASES_LIB="${SCRIPT_DIR}/../lib/codex-via-server/releases.sh"
fi
[[ -r "$RELEASES_LIB" ]] || fail "missing release helper"
source "$RELEASES_LIB"

oldest_version="$(printf '%s\n%s\n' "$MINIMUM_VERSION" "$VERSION" | sort -V | head -n 1)"
[[ "$oldest_version" == "$MINIMUM_VERSION" ]] \
  || fail "version is below the supported minimum ${MINIMUM_VERSION}"

asset="$(cliproxy_asset_for "$VERSION")"
release_url="$(cliproxy_release_url "$VERSION" "$asset")"
checksums_url="$(cliproxy_checksums_url "$VERSION")"

auth_tree_digest() {
  find "$CLIPROXY_AUTH_DIR" -xdev -type f -print0 \
    | sort -z \
    | while IFS= read -r -d '' auth_file; do sha256sum "$auth_file"; done \
    | sha256sum \
    | awk '{print $1}'
}

restore_candidate() {
  install -o root -g root -m 0755 "${BACKUP_DIR}/cli-proxy-api" "$CLIPROXY_BINARY"
  cp -p "${BACKUP_DIR}/config.yaml" "$CLIPROXY_CONFIG"
  cp -p "${BACKUP_DIR}/cliproxyapi.service" "$CLIPROXY_UNIT"
  "$SYSTEMCTL_BINARY" daemon-reload >/dev/null 2>&1 || true
  "$SYSTEMCTL_BINARY" restart cliproxyapi >/dev/null 2>&1 || true
}

cleanup() {
  exit_status=$?
  trap - EXIT HUP INT TERM

  if [[ "$TRANSACTION_COMMITTED" -eq 0 && -n "$BACKUP_DIR" ]]; then
    printf 'Upgrade failed; restoring the previous CLIProxyAPI version.\n' >&2
    restore_candidate
  fi

  if [[ -n "$RUNTIME_DIR" ]]; then
    find "$RUNTIME_DIR" -depth -delete
  fi

  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -o root -g root -m 0755 "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "another CLIProxyAPI update is running"

RUNTIME_DIR="$(mktemp -d /tmp/cliproxyapi-update.XXXXXX)"
archive_path="${RUNTIME_DIR}/${asset}"
checksums_path="${RUNTIME_DIR}/checksums.txt"
extract_path="${RUNTIME_DIR}/extract"
install -d -m 0700 "$extract_path"

"$CURL_BINARY" -LfsS --retry 3 --retry-all-errors -o "$archive_path" "$release_url"
"$CURL_BINARY" -LfsS --retry 3 --retry-all-errors -o "$checksums_path" "$checksums_url"

expected_sha256="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset {print $1; exit}' "$checksums_path")"
[[ "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "release checksum is missing"
actual_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail "release checksum mismatch"

tar -xzf "$archive_path" -C "$extract_path"
candidate_binary="$(find "$extract_path" -maxdepth 3 -type f \( -name CLIProxyAPI -o -name cli-proxy-api \) -print -quit)"
[[ -n "$candidate_binary" ]] || fail "candidate binary is missing"
chmod 0755 "$candidate_binary"
"$candidate_binary" -help >/dev/null

install -d -o root -g root -m 0700 "$BACKUP_ROOT"
BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-v${VERSION}-$$"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -p "$CLIPROXY_BINARY" "${BACKUP_DIR}/cli-proxy-api"
cp -p "$CLIPROXY_CONFIG" "${BACKUP_DIR}/config.yaml"
cp -p "$CLIPROXY_UNIT" "${BACKUP_DIR}/cliproxyapi.service"
printf '%s\n' "$actual_sha256" >"${BACKUP_DIR}/candidate.sha256"

AUTH_DIGEST_BEFORE="$(auth_tree_digest)"
install -o root -g root -m 0755 "$candidate_binary" "$CLIPROXY_BINARY"
"$SYSTEMCTL_BINARY" daemon-reload
"$SYSTEMCTL_BINARY" restart cliproxyapi
"$SYSTEMCTL_BINARY" is-active --quiet cliproxyapi
"$DOCTOR_BINARY" --foundation
"$CANARY_BINARY" --model "$MODEL"

auth_digest_after="$(auth_tree_digest)"
[[ "$auth_digest_after" == "$AUTH_DIGEST_BEFORE" ]] || fail "OAuth state changed during upgrade"

TRANSACTION_COMMITTED=1
trap - EXIT HUP INT TERM
find "$RUNTIME_DIR" -depth -delete
RUNTIME_DIR=""

printf 'status=pass version=%s sha256=%s backup=%s\n' "$VERSION" "$actual_sha256" "$BACKUP_DIR"
