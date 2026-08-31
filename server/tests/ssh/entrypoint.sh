#!/usr/bin/env bash

set -euo pipefail
umask 077

AUTHORIZED_KEYS_FILE="/etc/ssh/authorized_keys/codex-tunnel"
PUBLIC_KEY="$(cat /run/test-key.pub)"

case "$PUBLIC_KEY" in
  ssh-ed25519\ *) ;;
  *) printf 'invalid test public key\n' >&2; exit 1 ;;
esac

printf 'restrict,port-forwarding,permitopen="127.0.0.1:18319" %s\n' "$PUBLIC_KEY" \
  >"$AUTHORIZED_KEYS_FILE"
chown root:codex-tunnel "$AUTHORIZED_KEYS_FILE"
chmod 0640 "$AUTHORIZED_KEYS_FILE"

python3 /app/mock-gateway.py &
exec /usr/sbin/sshd -D -e
