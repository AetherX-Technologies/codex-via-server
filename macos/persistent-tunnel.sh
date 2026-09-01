#!/usr/bin/env bash

set -euo pipefail
umask 077

PROFILE_FILE="${CODEX_VIA_SERVER_CONNECTION_PROFILE:-${HOME}/.config/codex-via-server/connection-profile.json}"
KNOWN_HOSTS_FILE="${CODEX_VIA_SERVER_KNOWN_HOSTS:-${HOME}/.config/codex-via-server/known_hosts}"

[[ -f "$PROFILE_FILE" && ! -L "$PROFILE_FILE" ]] || exit 20
[[ -f "$KNOWN_HOSTS_FILE" && ! -L "$KNOWN_HOSTS_FILE" ]] || exit 21

ssh_host="$(jq -r '.server.host' "$PROFILE_FILE")"
ssh_port="$(jq -r '.server.ssh_port' "$PROFILE_FILE")"
ssh_user="$(jq -r '.server.ssh_user' "$PROFILE_FILE")"
remote_host="$(jq -r '.gateway.remote_host' "$PROFILE_FILE")"
remote_port="$(jq -r '.gateway.remote_port' "$PROFILE_FILE")"
local_port="$(jq -r '.client.local_port' "$PROFILE_FILE")"
device_id="$(jq -r '.approved_device.device_id' "$PROFILE_FILE")"
identity="${CODEX_VIA_SERVER_KEY_DIR:-${HOME}/.ssh/codex-via-server}/${device_id}"

[[ "$ssh_user" == "codex-tunnel" ]] || exit 22
[[ "$remote_host" == "127.0.0.1" ]] || exit 23
[[ "$ssh_port" =~ ^[0-9]+$ && "$remote_port" =~ ^[0-9]+$ && "$local_port" =~ ^[0-9]+$ ]] || exit 24
[[ -f "$identity" && ! -L "$identity" ]] || exit 25

exec /usr/bin/ssh \
  -F /dev/null \
  -p "$ssh_port" \
  -i "$identity" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -o GlobalKnownHostsFile=/dev/null \
  -o UpdateHostKeys=no \
  -o ProxyCommand=none \
  -o ProxyJump=none \
  -o PermitLocalCommand=no \
  -o ExitOnForwardFailure=yes \
  -o ConnectTimeout=8 \
  -o ConnectionAttempts=1 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o TCPKeepAlive=yes \
  -o LogLevel=ERROR \
  -N -T \
  -L "127.0.0.1:${local_port}:${remote_host}:${remote_port}" \
  "${ssh_user}@${ssh_host}"
