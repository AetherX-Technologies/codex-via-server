#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM_NAME="install-codex-via-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_MODE=0

SSH_HOST=""
SSH_PORT="22"
SSH_USER="root"
SSH_IDENTITY=""
SSH_HOST_FINGERPRINT=""
SERVER_API_HOST=""
SERVER_API_PORT="8317"
REMOTE_ENV_FILE="/root/cliproxyapi-client.env"
LOCAL_PORT="18317"
CODEX_PROFILE="codex-via-server"

usage() {
  cat <<'EOF'
Usage:
  install.sh \
    --host <tailscale-ip> \
    --identity <absolute-ssh-key-path> \
    --fingerprint <SHA256:...> \
    [--user root] [--ssh-port 22] [--api-host <tailscale-ip>] \
    [--api-port 8317] [--local-port 18317]

This installer stores connection metadata but never stores the CLIProxyAPI key.
Run without connection arguments to install v0.2 setup and enrollment tooling.
EOF
}

fail() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) SSH_HOST="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --user) SSH_USER="${2:-}"; shift 2 ;;
    --identity) SSH_IDENTITY="${2:-}"; shift 2 ;;
    --fingerprint) SSH_HOST_FINGERPRINT="${2:-}"; shift 2 ;;
    --api-host) SERVER_API_HOST="${2:-}"; shift 2 ;;
    --api-port) SERVER_API_PORT="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --remote-env-file) REMOTE_ENV_FILE="${2:-}"; shift 2 ;;
    --profile) CODEX_PROFILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [[ -n "$SSH_HOST" || -n "$SSH_IDENTITY" || -n "$SSH_HOST_FINGERPRINT" ]]; then
  LEGACY_MODE=1
fi

if [[ "$LEGACY_MODE" -eq 1 ]]; then
  [[ -n "$SSH_HOST" ]] || fail "--host is required"
  [[ -n "$SSH_IDENTITY" ]] || fail "--identity is required"
  [[ -n "$SSH_HOST_FINGERPRINT" ]] || fail "--fingerprint is required"
  [[ "$SSH_IDENTITY" = /* ]] || fail "--identity must be an absolute path"
  [[ -r "$SSH_IDENTITY" ]] || fail "SSH identity is not readable: $SSH_IDENTITY"
fi

if [[ "$LEGACY_MODE" -eq 1 && -z "$SERVER_API_HOST" ]]; then
  SERVER_API_HOST="$SSH_HOST"
fi

if [[ "$LEGACY_MODE" -eq 1 ]]; then
  [[ "$SSH_HOST" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
    || fail "--host must be a Tailscale IPv4 address in 100.64.0.0/10"
  [[ "$SERVER_API_HOST" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
    || fail "--api-host must be a Tailscale IPv4 address in 100.64.0.0/10"
fi
if [[ "$LEGACY_MODE" -eq 1 ]]; then
  [[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--user contains unsupported characters"
  [[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] \
    || fail "--ssh-port must be between 1 and 65535"
  [[ "$SERVER_API_PORT" =~ ^[0-9]+$ && "$SERVER_API_PORT" -ge 1 && "$SERVER_API_PORT" -le 65535 ]] \
    || fail "--api-port must be between 1 and 65535"
  [[ "$SSH_HOST_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]+={0,2}$ ]] \
    || fail "--fingerprint must be an SHA256 fingerprint"
  [[ "$REMOTE_ENV_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || fail "--remote-env-file must be a safe absolute path"
fi
[[ "$LOCAL_PORT" =~ ^[0-9]+$ && "$LOCAL_PORT" -ge 1024 && "$LOCAL_PORT" -le 65535 ]] \
  || fail "--local-port must be between 1024 and 65535"
[[ "$CODEX_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]] || fail "--profile contains unsupported characters"

for dependency in codex install mkdir; do
  command -v "$dependency" >/dev/null 2>&1 || fail "required command is missing: $dependency"
done

BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/codex-via-server"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_FILE="${CONFIG_DIR}/config"
PROFILE_FILE="${CODEX_DIR}/${CODEX_PROFILE}.config.toml"
LAUNCHER_FILE="${BIN_DIR}/codex-via-server"
LIB_DIR="${HOME}/.local/lib/codex-via-server"
COMMANDS_FILE="${LIB_DIR}/commands.sh"
SETUP_FILE="${LIB_DIR}/setup.sh"
ENROLL_FILE="${LIB_DIR}/enroll.sh"
TUNNEL_FILE="${LIB_DIR}/tunnel.sh"
DOCTOR_FILE="${LIB_DIR}/doctor.sh"
UPDATE_FILE="${LIB_DIR}/update.sh"
UNINSTALL_FILE="${LIB_DIR}/uninstall.sh"
STATE_DIR="${HOME}/.local/share/codex-via-server"
INSTALLED_VERSION_FILE="${STATE_DIR}/VERSION"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CODEX_DIR" "$LIB_DIR" "$STATE_DIR"
chmod 0700 "$CONFIG_DIR"

install -m 0755 "${SCRIPT_DIR}/codex-via-server" "$LAUNCHER_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/commands.sh" "$COMMANDS_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/setup.sh" "$SETUP_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/enroll.sh" "$ENROLL_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/tunnel.sh" "$TUNNEL_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/doctor.sh" "$DOCTOR_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/update.sh" "$UPDATE_FILE"
install -m 0644 "${SCRIPT_DIR}/macos/lib/uninstall.sh" "$UNINSTALL_FILE"
install -m 0644 "${SCRIPT_DIR}/VERSION" "$INSTALLED_VERSION_FILE"

if [[ "$LEGACY_MODE" -eq 1 ]]; then
{
  printf 'SSH_HOST='; shell_quote "$SSH_HOST"; printf '\n'
  printf 'SSH_PORT='; shell_quote "$SSH_PORT"; printf '\n'
  printf 'SSH_USER='; shell_quote "$SSH_USER"; printf '\n'
  printf 'SSH_IDENTITY='; shell_quote "$SSH_IDENTITY"; printf '\n'
  printf 'SSH_HOST_FINGERPRINT='; shell_quote "$SSH_HOST_FINGERPRINT"; printf '\n'
  printf 'SERVER_API_HOST='; shell_quote "$SERVER_API_HOST"; printf '\n'
  printf 'SERVER_API_PORT='; shell_quote "$SERVER_API_PORT"; printf '\n'
  printf 'REMOTE_ENV_FILE='; shell_quote "$REMOTE_ENV_FILE"; printf '\n'
  printf 'LOCAL_PORT='; shell_quote "$LOCAL_PORT"; printf '\n'
  printf 'CODEX_PROFILE='; shell_quote "$CODEX_PROFILE"; printf '\n'
} >"$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

cat >"$PROFILE_FILE" <<EOF
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "CLIProxyAPI through a local SSH tunnel"
base_url = "http://127.0.0.1:${LOCAL_PORT}/v1"
env_key = "SERVER_CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false
request_max_retries = 2
stream_max_retries = 4
stream_idle_timeout_ms = 300000

[shell_environment_policy.filters]
SERVER_CODEX_API_KEY = "exclude"
EOF
chmod 0600 "$PROFILE_FILE"
fi

printf 'Installed launcher: %s\n' "$LAUNCHER_FILE"
printf 'Installed config:   %s\n' "$CONFIG_FILE"
printf 'Installed profile:  %s\n' "$PROFILE_FILE"
printf 'Installed commands: %s\n' "$COMMANDS_FILE"
printf 'Installed version:  %s\n' "$INSTALLED_VERSION_FILE"
printf 'Run: codex-via-server\n'
