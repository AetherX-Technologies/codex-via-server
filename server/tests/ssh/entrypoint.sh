#!/usr/bin/env bash

set -euo pipefail
umask 077

PUBLIC_KEY="$(cat /run/test-key.pub)"

case "$PUBLIC_KEY" in
  ssh-ed25519\ *) ;;
  *) printf 'invalid test public key\n' >&2; exit 1 ;;
esac

requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg public_key "$PUBLIC_KEY" \
  --arg requested_at "$requested_at" \
  '{schema_version: 1, device_id: "test-device", platform: "macos", public_key: $public_key, requested_at: $requested_at}' \
  >/run/test-request.json
/app/server/codex-via-server-devices approve /run/test-request.json >/run/test-approval.json

python3 /app/mock-gateway.py &
exec /usr/sbin/sshd -D -e
