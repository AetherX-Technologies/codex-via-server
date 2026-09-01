#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_BINARY="${CODEX_BINARY:-$(command -v codex || true)}"
EXPECTED_VERSION="${EXPECTED_CODEX_VERSION:-}"
RUNTIME_DIR="$(mktemp -d /tmp/codex-compatibility.XXXXXX)"
CODEX_HOME_DIR="${RUNTIME_DIR}/codex-home"
STATE_DIR="${RUNTIME_DIR}/state"
SERVER_PID=""

cleanup() {
  trap - EXIT HUP INT TERM
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  find "$RUNTIME_DIR" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -n "$CODEX_BINARY" && -x "$CODEX_BINARY" ]]
mkdir -p "$CODEX_HOME_DIR" "$STATE_DIR"
PORT="$(python3 -c 'import socket; value=socket.socket(); value.bind(("127.0.0.1",0)); print(value.getsockname()[1]); value.close()')"
cat >"${CODEX_HOME_DIR}/compat.config.toml" <<EOF
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "Codex via Server compatibility mock"
base_url = "http://127.0.0.1:${PORT}/v1"
wire_api = "responses"
supports_websockets = false
env_key = "COMPATIBILITY_API_KEY"
EOF

MOCK_STATE_DIRECTORY="$STATE_DIR" MOCK_PORT="$PORT" \
  python3 "${ROOT_DIR}/tests/mock-codex-responses.py" >"${RUNTIME_DIR}/server.log" 2>&1 &
SERVER_PID=$!
sleep 0.2

version_output="$(CODEX_HOME="$CODEX_HOME_DIR" "$CODEX_BINARY" --profile compat --version)"
if [[ -n "$EXPECTED_VERSION" ]]; then
  printf '%s\n' "$version_output" | grep -q "$EXPECTED_VERSION"
fi

env -u OPENAI_API_KEY -u SERVER_CODEX_API_KEY -u CLIPROXY_API_KEY COMPATIBILITY_API_KEY=compatibility-test-key \
  CODEX_HOME="$CODEX_HOME_DIR" \
  "$CODEX_BINARY" --profile compat exec \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    --model gpt-5.6-luna \
    --output-last-message "${RUNTIME_DIR}/last-message.txt" \
    "Reply only OK." \
    >"${RUNTIME_DIR}/codex.log" 2>&1 || { rtk proxy cat "${RUNTIME_DIR}/codex.log" >&2; exit 1; }

[[ "$(tr -d '\r\n' <"${RUNTIME_DIR}/last-message.txt")" == "OK" ]]
jq -e '.stream == true and .model == "gpt-5.6-luna"' "${STATE_DIR}/request.json" >/dev/null
if ! jq -e '.authorization == "Bearer compatibility-test-key"' "${STATE_DIR}/headers.json" >/dev/null; then
  printf 'Codex compatibility request had unexpected Authorization\n' >&2
  exit 1
fi

printf 'PASS: official Codex %s parsed profile and completed mock Responses\n' "$version_output"
