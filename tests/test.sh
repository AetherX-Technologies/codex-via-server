#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-via-server-tests.XXXXXX)"

cleanup() {
  find "$TEST_ROOT" -depth -delete
}

trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  file="$1"
  expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

bash -n "${ROOT_DIR}/codex-via-server"
bash -n "${ROOT_DIR}/install.sh"
bash -n "${ROOT_DIR}/macos/lib/commands.sh"

FAKE_BIN="${TEST_ROOT}/bin"
FAKE_HOME="${TEST_ROOT}/home"
FAKE_IDENTITY="${TEST_ROOT}/id_ed25519"
mkdir -p "$FAKE_BIN" "${FAKE_HOME}/.codex"

cat >"${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli test-double\n'
EOF
chmod 0755 "${FAKE_BIN}/codex"

printf 'test identity placeholder\n' >"$FAKE_IDENTITY"
chmod 0600 "$FAKE_IDENTITY"
printf 'sentinel = "unchanged"\n' >"${FAKE_HOME}/.codex/config.toml"

PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" \
  bash "${ROOT_DIR}/install.sh" \
    --host 100.64.0.10 \
    --identity "$FAKE_IDENTITY" \
    --fingerprint 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

LAUNCHER="${FAKE_HOME}/.local/bin/codex-via-server"
CONFIG="${FAKE_HOME}/.config/codex-via-server/config"
PROFILE="${FAKE_HOME}/.codex/codex-via-server.config.toml"
COMMANDS="${FAKE_HOME}/.local/lib/codex-via-server/commands.sh"

[[ -x "$LAUNCHER" ]] || fail "launcher was not installed"
[[ -f "$CONFIG" ]] || fail "client config was not installed"
[[ -f "$PROFILE" ]] || fail "Codex profile was not installed"
[[ -f "$COMMANDS" ]] || fail "command dispatcher was not installed"
[[ "$(file_mode "$LAUNCHER")" == "755" ]] || fail "launcher mode is not 755"
[[ "$(file_mode "$CONFIG")" == "600" ]] || fail "config mode is not 600"
[[ "$(file_mode "$PROFILE")" == "600" ]] || fail "profile mode is not 600"
[[ "$(file_mode "$COMMANDS")" == "644" ]] || fail "command dispatcher mode is not 644"

help_output="$(HOME="$FAKE_HOME" bash "$LAUNCHER" help)"
printf '%s\n' "$help_output" | grep -q 'codex-via-server setup'
set +e
HOME="$FAKE_HOME" bash "$LAUNCHER" setup >/dev/null 2>&1
setup_status=$?
set -e
[[ "$setup_status" == "69" ]]

assert_contains "$CONFIG" 'SSH_HOST=100.64.0.10'
assert_contains "$CONFIG" 'SERVER_API_PORT=8317'
assert_contains "$CONFIG" 'LOCAL_PORT=18317'
assert_contains "$PROFILE" 'model_provider = "server_cliproxy"'
assert_contains "$PROFILE" 'base_url = "http://127.0.0.1:18317/v1"'
assert_contains "$PROFILE" 'env_key = "SERVER_CODEX_API_KEY"'
assert_contains "$PROFILE" '[shell_environment_policy.filters]'
assert_contains "$PROFILE" 'SERVER_CODEX_API_KEY = "exclude"'
assert_contains "${FAKE_HOME}/.codex/config.toml" 'sentinel = "unchanged"'

if grep -R -E 'cpak-[A-Za-z0-9]{12,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' \
  "$FAKE_HOME" >/dev/null 2>&1; then
  fail "installed files contain secret-like material"
fi

FAKE_STATE="${TEST_ROOT}/state"
mkdir -p "$FAKE_STATE"

cat >"${FAKE_BIN}/route" <<'EOF'
#!/usr/bin/env bash
printf '   route to: 100.64.0.10\n'
printf 'destination: 100.64.0.10\n'
printf '  interface: utun99\n'
EOF

cat >"${FAKE_BIN}/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"${FAKE_BIN}/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
printf '# test SSH banner\n'
printf '100.64.0.10 ssh-ed25519 AAAATESTKEY\n'
EOF

cat >"${FAKE_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_FINGERPRINT_MODE:-match}" == "wrong" ]]; then
  printf '256 SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB test (ED25519)\n'
else
  printf '256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test (ED25519)\n'
fi
EOF

cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
arguments="$*"
case "$arguments" in
  *'-O exit'*) printf 'closed\n' >"${FAKE_STATE}/ssh-exit" ;;
  *'CLIPROXY_API_KEY'*) printf 'test-provider-key\n' ;;
esac
exit 0
EOF

cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
cat >"${FAKE_STATE}/curl-header"
exit 0
EOF

cat >"${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
[[ "${SERVER_CODEX_API_KEY:-}" == "test-provider-key" ]] || exit 9
printf '%s\n' "$@" >"${FAKE_STATE}/codex-args"
EOF

chmod 0755 \
  "${FAKE_BIN}/route" \
  "${FAKE_BIN}/lsof" \
  "${FAKE_BIN}/ssh-keyscan" \
  "${FAKE_BIN}/ssh-keygen" \
  "${FAKE_BIN}/ssh" \
  "${FAKE_BIN}/curl" \
  "${FAKE_BIN}/codex"

before_runtime_count="$(find /tmp -maxdepth 1 -name 'codex-via-server.*' | wc -l | tr -d ' ')"
PATH="${FAKE_BIN}:${PATH}" \
CODEX_HOME="${FAKE_HOME}/.codex" \
CODEX_VIA_SERVER_CONFIG="$CONFIG" \
FAKE_STATE="$FAKE_STATE" \
  bash "$LAUNCHER" exec --model test-model prompt >/dev/null
after_runtime_count="$(find /tmp -maxdepth 1 -name 'codex-via-server.*' | wc -l | tr -d ' ')"

[[ "$before_runtime_count" == "$after_runtime_count" ]] || fail "launcher left a runtime directory"
assert_contains "${FAKE_STATE}/ssh-exit" 'closed'
assert_contains "${FAKE_STATE}/curl-header" 'Authorization: Bearer test-provider-key'
assert_contains "${FAKE_STATE}/codex-args" '--profile'
assert_contains "${FAKE_STATE}/codex-args" 'codex-via-server'
assert_contains "${FAKE_STATE}/codex-args" 'test-model'
assert_contains "${FAKE_STATE}/codex-args" 'prompt'

if PATH="${FAKE_BIN}:${PATH}" \
  CODEX_HOME="${FAKE_HOME}/.codex" \
  CODEX_VIA_SERVER_CONFIG="$CONFIG" \
  FAKE_STATE="$FAKE_STATE" \
  FAKE_FINGERPRINT_MODE=wrong \
    bash "$LAUNCHER" >/dev/null 2>&1; then
  fail "launcher accepted a changed SSH fingerprint"
fi

if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" \
  bash "${ROOT_DIR}/install.sh" \
    --host 192.0.2.10 \
    --identity "$FAKE_IDENTITY" \
    --fingerprint 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
    >/dev/null 2>&1; then
  fail "installer accepted a non-Tailscale host"
fi

if PATH="${FAKE_BIN}:${PATH}" HOME="$FAKE_HOME" \
  bash "${ROOT_DIR}/install.sh" \
    --host 100.64.0.10 \
    --identity relative-key \
    --fingerprint 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
    >/dev/null 2>&1; then
  fail "installer accepted a relative identity path"
fi

bash "${ROOT_DIR}/install.sh" --help >/dev/null

printf 'PASS: syntax, install, launcher lifecycle, fingerprint, profile, and validation\n'
