#!/usr/bin/env bash

set -euo pipefail
umask 077

install -d -o root -g root -m 0700 /run/codex-via-server
printf 'CLIPROXY_API_KEY=integration-server-key\n' >/run/codex-via-server/cliproxy.env
chmod 0600 /run/codex-via-server/cliproxy.env
/app/server/install.sh --api-key-file /run/codex-via-server/cliproxy.env --no-reload >/dev/null

EXPECTED_AUTHORIZATION="Bearer integration-server-key" \
  python3 /app/server/tests/mock-cliproxyapi.py >/run/mock-cliproxyapi.log 2>&1 &
nginx
exec /usr/sbin/sshd -D -e
