#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="codex-via-server-server-install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY_FILE=""
DRY_RUN=0
RELOAD_SERVICES=1
TRANSACTION_COMMITTED=0
BACKUP_DIR=""

NGINX_BINARY="${NGINX_BINARY:-/usr/sbin/nginx}"
SSHD_BINARY="${SSHD_BINARY:-/usr/sbin/sshd}"
SYSTEMCTL_BINARY="${SYSTEMCTL_BINARY:-/usr/bin/systemctl}"
NGINX_CONFIG_SOURCE="${NGINX_CONFIG_SOURCE:-${SCRIPT_DIR}/nginx/codex-gateway.conf}"
NGINX_CONFIG_TARGET="/etc/nginx/conf.d/codex-via-server.conf"
SECRET_DIR="/etc/codex-via-server"
SECRET_TARGET="${SECRET_DIR}/gateway-secret.conf"
SSHD_CONFIG_TARGET="/etc/ssh/sshd_config.d/90-codex-via-server.conf"
BACKUP_ROOT="/var/backups/codex-via-server"
RESTRICTED_USER_INSTALLER="${SCRIPT_DIR}/install-restricted-user.sh"
DEVICE_TOOL_SOURCE="${SCRIPT_DIR}/codex-via-server-devices"
DEVICE_TOOL_TARGET="/usr/local/sbin/codex-via-server-devices"
DEVICE_STATE_DIR="/var/lib/codex-via-server/devices"
DOCTOR_SOURCE="${SCRIPT_DIR}/doctor.sh"
DOCTOR_TARGET="/usr/local/sbin/codex-via-server-doctor"
CANARY_SOURCE="${SCRIPT_DIR}/canary.sh"
CANARY_TARGET="/usr/local/sbin/codex-via-server-canary"
CANARY_SERVICE_SOURCE="${SCRIPT_DIR}/systemd/codex-via-server-canary.service"
CANARY_SERVICE_TARGET="/etc/systemd/system/codex-via-server-canary.service"

usage() {
  cat <<'EOF'
Usage:
  server/install.sh --api-key-file <root-owned-0400-or-0600-file> [options]

Options:
  --dry-run     Validate inputs and print planned paths without changing state.
  --no-reload   Install and validate files without reloading services.
  -h, --help    Show this help.

The API key file must contain exactly one CLIPROXY_API_KEY=<value> line.
The key is never accepted as a command-line argument or printed.
EOF
}

fail() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key-file) API_KEY_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-reload) RELOAD_SERVICES=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "run as root"
[[ -n "$API_KEY_FILE" ]] || fail "--api-key-file is required"
[[ "$API_KEY_FILE" = /* ]] || fail "--api-key-file must be an absolute path"
[[ -f "$API_KEY_FILE" && ! -L "$API_KEY_FILE" ]] || fail "API key file must be a regular non-symlink file"
[[ -r "$NGINX_CONFIG_SOURCE" ]] || fail "missing Nginx configuration template"
[[ -x "$RESTRICTED_USER_INSTALLER" ]] || fail "missing restricted-user installer"
[[ -x "$DEVICE_TOOL_SOURCE" ]] || fail "missing device lifecycle tool"
[[ -x "$DOCTOR_SOURCE" ]] || fail "missing server doctor"
[[ -x "$CANARY_SOURCE" ]] || fail "missing server canary"
[[ -r "$CANARY_SERVICE_SOURCE" ]] || fail "missing canary systemd unit"
[[ -x "$NGINX_BINARY" ]] || fail "missing Nginx binary: $NGINX_BINARY"
[[ -x "$SSHD_BINARY" ]] || fail "missing SSH daemon: $SSHD_BINARY"

for dependency in awk cp date find install stat; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing command: $dependency"
done

read -r key_file_owner key_file_mode < <(stat -c '%u %a' "$API_KEY_FILE")
[[ "$key_file_owner" == "0" ]] || fail "API key file must be owned by root"
case "$key_file_mode" in
  400|600) ;;
  *) fail "API key file mode must be 0400 or 0600" ;;
esac

key_line_count="$(awk -F= '$1 == "CLIPROXY_API_KEY" {count += 1} END {print count + 0}' "$API_KEY_FILE")"
[[ "$key_line_count" == "1" ]] || fail "API key file must contain exactly one CLIPROXY_API_KEY entry"
API_KEY="$(awk -F= '$1 == "CLIPROXY_API_KEY" {sub(/^[^=]*=/, ""); print; exit}' "$API_KEY_FILE")"
[[ "$API_KEY" =~ ^[A-Za-z0-9._-]{16,256}$ ]] || fail "API key contains unsupported characters or length"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Dry run passed. Planned targets:\n'
  printf '  %s\n' "$NGINX_CONFIG_TARGET" "$SECRET_TARGET" "$SSHD_CONFIG_TARGET"
  printf '  %s\n' "$DEVICE_TOOL_TARGET" "$DEVICE_STATE_DIR"
  printf '  %s\n' "$DOCTOR_TARGET" "$CANARY_TARGET" "$CANARY_SERVICE_TARGET"
  exit 0
fi

backup_path() {
  source_path="$1"
  backup_name="$2"

  if [[ -e "$source_path" ]]; then
    cp -p "$source_path" "${BACKUP_DIR}/${backup_name}"
  else
    : >"${BACKUP_DIR}/${backup_name}.absent"
  fi
}

restore_path() {
  destination="$1"
  backup_name="$2"

  if [[ -e "${BACKUP_DIR}/${backup_name}" ]]; then
    cp -p "${BACKUP_DIR}/${backup_name}" "$destination"
  elif [[ -e "${BACKUP_DIR}/${backup_name}.absent" ]]; then
    rm -f -- "$destination"
  fi
}

reload_ssh() {
  "$SYSTEMCTL_BINARY" reload ssh >/dev/null 2>&1 \
    || "$SYSTEMCTL_BINARY" reload sshd >/dev/null
}

rollback() {
  exit_status=$?
  trap - EXIT HUP INT TERM

  if [[ "$TRANSACTION_COMMITTED" -eq 0 && -n "$BACKUP_DIR" ]]; then
    printf 'Installation failed; restoring previous configuration.\n' >&2
    restore_path "$NGINX_CONFIG_TARGET" nginx.conf
    restore_path "$SECRET_TARGET" gateway-secret.conf
    restore_path "$SSHD_CONFIG_TARGET" sshd.conf
    restore_path "$DEVICE_TOOL_TARGET" device-tool
    restore_path "$DOCTOR_TARGET" doctor
    restore_path "$CANARY_TARGET" canary
    restore_path "$CANARY_SERVICE_TARGET" canary-service
    "$NGINX_BINARY" -t >/dev/null 2>&1 || true
    "$SSHD_BINARY" -t >/dev/null 2>&1 || true

    if [[ "$RELOAD_SERVICES" -eq 1 && -x "$SYSTEMCTL_BINARY" ]]; then
      "$SYSTEMCTL_BINARY" reload nginx >/dev/null 2>&1 || true
      reload_ssh >/dev/null 2>&1 || true
    fi
  fi

  unset API_KEY
  exit "$exit_status"
}

trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -o root -g root -m 0700 "$BACKUP_ROOT"
BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
backup_path "$NGINX_CONFIG_TARGET" nginx.conf
backup_path "$SECRET_TARGET" gateway-secret.conf
backup_path "$SSHD_CONFIG_TARGET" sshd.conf
backup_path "$DEVICE_TOOL_TARGET" device-tool
backup_path "$DOCTOR_TARGET" doctor
backup_path "$CANARY_TARGET" canary
backup_path "$CANARY_SERVICE_TARGET" canary-service

"$RESTRICTED_USER_INSTALLER"
install -d -o root -g root -m 0700 "$DEVICE_STATE_DIR"
install -o root -g root -m 0750 "$DEVICE_TOOL_SOURCE" "$DEVICE_TOOL_TARGET"
install -o root -g root -m 0750 "$DOCTOR_SOURCE" "$DOCTOR_TARGET"
install -o root -g root -m 0750 "$CANARY_SOURCE" "$CANARY_TARGET"
install -o root -g root -m 0644 "$CANARY_SERVICE_SOURCE" "$CANARY_SERVICE_TARGET"

install -d -o root -g root -m 0700 "$SECRET_DIR"
install -o root -g root -m 0644 "$NGINX_CONFIG_SOURCE" "$NGINX_CONFIG_TARGET"
printf 'proxy_set_header Authorization "Bearer %s";\n' "$API_KEY" \
  | install -o root -g root -m 0600 /dev/stdin "$SECRET_TARGET"

"$NGINX_BINARY" -t
"$SSHD_BINARY" -t

if [[ "$RELOAD_SERVICES" -eq 1 ]]; then
  [[ -x "$SYSTEMCTL_BINARY" ]] || fail "missing systemctl: $SYSTEMCTL_BINARY"
  "$SYSTEMCTL_BINARY" daemon-reload
  "$SYSTEMCTL_BINARY" reload nginx
  reload_ssh
fi

TRANSACTION_COMMITTED=1
unset API_KEY
trap - EXIT HUP INT TERM

printf 'Server foundation installed and validated.\n'
printf 'Backup: %s\n' "$BACKUP_DIR"
