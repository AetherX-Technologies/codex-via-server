#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="install-restricted-user"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_USER="codex-tunnel"
TUNNEL_GROUP="codex-tunnel"
TUNNEL_HOME="/var/lib/codex-via-server/tunnel"
TUNNEL_SHELL="/usr/sbin/nologin"
AUTHORIZED_KEYS_DIR="/etc/ssh/authorized_keys"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_DIR}/${TUNNEL_USER}"
SSHD_CONFIG_SOURCE="${SCRIPT_DIR}/sshd/codex-tunnel.conf"
SSHD_CONFIG_TARGET="/etc/ssh/sshd_config.d/90-codex-via-server.conf"
SSHD_BINARY="${SSHD_BINARY:-/usr/sbin/sshd}"

fail() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || fail "run as root"
[[ -r "$SSHD_CONFIG_SOURCE" ]] || fail "missing SSH configuration template"
[[ -x "$SSHD_BINARY" ]] || fail "missing SSH daemon: $SSHD_BINARY"

for dependency in getent groupadd id install useradd usermod; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing command: $dependency"
done

if ! getent group "$TUNNEL_GROUP" >/dev/null; then
  groupadd --system "$TUNNEL_GROUP"
fi

if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "$TUNNEL_GROUP" \
    --home-dir "$TUNNEL_HOME" \
    --create-home \
    --shell "$TUNNEL_SHELL" \
    --password '*' \
    "$TUNNEL_USER"
else
  existing_home="$(getent passwd "$TUNNEL_USER" | cut -d: -f6)"
  existing_shell="$(getent passwd "$TUNNEL_USER" | cut -d: -f7)"
  [[ "$existing_home" == "$TUNNEL_HOME" ]] || fail "existing user has unexpected home: $existing_home"
  [[ "$existing_shell" == "$TUNNEL_SHELL" ]] || fail "existing user has unexpected shell: $existing_shell"
  usermod --password '*' "$TUNNEL_USER"
fi

install -d -o "$TUNNEL_USER" -g "$TUNNEL_GROUP" -m 0700 "$TUNNEL_HOME"
install -d -o root -g root -m 0755 "$AUTHORIZED_KEYS_DIR"

if [[ ! -e "$AUTHORIZED_KEYS_FILE" ]]; then
  install -o root -g "$TUNNEL_GROUP" -m 0640 /dev/null "$AUTHORIZED_KEYS_FILE"
else
  chown root:"$TUNNEL_GROUP" "$AUTHORIZED_KEYS_FILE"
  chmod 0640 "$AUTHORIZED_KEYS_FILE"
fi

install -o root -g root -m 0644 "$SSHD_CONFIG_SOURCE" "$SSHD_CONFIG_TARGET"
"$SSHD_BINARY" -t

printf 'Restricted SSH account installed: %s\n' "$TUNNEL_USER"
printf 'Authorized keys file: %s\n' "$AUTHORIZED_KEYS_FILE"
