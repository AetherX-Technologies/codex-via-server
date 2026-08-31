#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_DIR="$(mktemp -d /tmp/cliproxy-update-test.XXXXXX)"
BIN_DIR="${RUNTIME_DIR}/bin"
RELEASE_DIR="${RUNTIME_DIR}/releases/v9.9.9"
INSTALL_ROOT="${RUNTIME_DIR}/install"
AUTH_DIR="${INSTALL_ROOT}/auth"
BACKUP_ROOT="${RUNTIME_DIR}/backups"
IMAGE_NAME="codex-update-test:$$"
CONTAINER_NAME="codex-update-test-$$"
HTTP_PORT=""
HTTP_PID=""
VERSION="9.9.9"
ASSET="CLIProxyAPI_${VERSION}_linux_arm64_no-plugin.tar.gz"

cleanup() {
  trap - EXIT HUP INT TERM
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
  find "$RUNTIME_DIR" -depth -delete
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$BIN_DIR" "$RELEASE_DIR" "$AUTH_DIR" "$BACKUP_ROOT"
docker info >/dev/null

cat >"${RUNTIME_DIR}/CLIProxyAPI" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-help" ]]; then
  printf 'candidate help\n'
  exit 0
fi
printf 'candidate binary\n'
EOF
chmod 0755 "${RUNTIME_DIR}/CLIProxyAPI"
python3 - "$RUNTIME_DIR" "${RELEASE_DIR}/${ASSET}" <<'PYTHON'
import sys
import tarfile
from pathlib import Path

source_directory = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
with tarfile.open(archive_path, "w:gz") as archive:
    archive.add(source_directory / "CLIProxyAPI", arcname="CLIProxyAPI")
PYTHON
asset_sha256="$(sha256sum "${RELEASE_DIR}/${ASSET}" | awk '{print $1}')"
printf '%s  %s\n' "$asset_sha256" "$ASSET" >"${RELEASE_DIR}/checksums.txt"

cat >"${INSTALL_ROOT}/cli-proxy-api" <<'EOF'
#!/usr/bin/env bash
printf 'original binary\n'
EOF
chmod 0755 "${INSTALL_ROOT}/cli-proxy-api"
printf 'original-config\n' >"${INSTALL_ROOT}/config.yaml"
printf 'original-unit\n' >"${INSTALL_ROOT}/cliproxyapi.service"
printf 'oauth-state\n' >"${AUTH_DIR}/account.json"

cat >"${BIN_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UPDATE_STATE}/systemctl.log"
if [[ "${FAIL_STAGE:-}" == "restart" && "$*" == "restart cliproxyapi" ]]; then
  exit 1
fi
exit 0
EOF

cat >"${BIN_DIR}/doctor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UPDATE_STATE}/doctor.log"
[[ "${FAIL_STAGE:-}" != "doctor" ]]
EOF

cat >"${BIN_DIR}/canary" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UPDATE_STATE}/canary.log"
[[ "${FAIL_STAGE:-}" != "canary" ]]
EOF
cat >"${BIN_DIR}/canary-auth-mutation" <<'EOF'
#!/usr/bin/env bash
printf 'mutated-oauth-state\n' >"${UPDATE_STATE}/install/auth/account.json"
exit 0
EOF
chmod 0755 \
  "${BIN_DIR}/systemctl" \
  "${BIN_DIR}/doctor" \
  "${BIN_DIR}/canary" \
  "${BIN_DIR}/canary-auth-mutation"

HTTP_PORT="$(python3 -c 'import socket; value = socket.socket(); value.bind(("127.0.0.1", 0)); print(value.getsockname()[1]); value.close()')"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$RUNTIME_DIR/releases" \
  >"${RUNTIME_DIR}/http.log" 2>&1 &
HTTP_PID=$!

ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:${HTTP_PORT}/v${VERSION}/checksums.txt" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]]

docker build \
  -f "${ROOT_DIR}/server/tests/install/Dockerfile" \
  -t "$IMAGE_NAME" \
  "$ROOT_DIR" >/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  -v "${RUNTIME_DIR}:/run/test" \
  --add-host host.docker.internal:host-gateway \
  "$IMAGE_NAME" \
  sleep infinity >/dev/null

container_base_url="http://host.docker.internal:${HTTP_PORT}"

set +e
docker exec \
  -e CLIPROXY_RELEASE_BASE_URL="$container_base_url" \
  -e CLIPROXY_BINARY=/run/test/install/cli-proxy-api \
  -e CLIPROXY_CONFIG=/run/test/install/config.yaml \
  -e CLIPROXY_UNIT=/run/test/install/cliproxyapi.service \
  -e CLIPROXY_AUTH_DIR=/run/test/install/auth \
  -e SYSTEMCTL_BINARY=/run/test/bin/systemctl \
  -e DOCTOR_BINARY=/run/test/bin/doctor \
  -e CANARY_BINARY=/run/test/bin/canary \
  "$CONTAINER_NAME" \
  bash /app/server/update-cliproxyapi.sh \
    --version 7.2.145 --model test-model \
    >"${RUNTIME_DIR}/minimum-version.log" 2>&1
minimum_status=$?
set -e
[[ "$minimum_status" -ne 0 ]]
grep -q 'below the supported minimum' "${RUNTIME_DIR}/minimum-version.log"

run_update() {
  fail_stage="$1"
  canary_binary="${2:-/run/test/bin/canary}"
  docker exec \
    -e CLIPROXY_RELEASE_BASE_URL="$container_base_url" \
    -e CLIPROXY_BINARY=/run/test/install/cli-proxy-api \
    -e CLIPROXY_CONFIG=/run/test/install/config.yaml \
    -e CLIPROXY_UNIT=/run/test/install/cliproxyapi.service \
    -e CLIPROXY_AUTH_DIR=/run/test/install/auth \
    -e CLIPROXY_BACKUP_ROOT=/run/test/backups \
    -e CLIPROXY_UPDATE_LOCK_FILE=/run/test/update.lock \
    -e CURL_BINARY=/usr/bin/curl \
    -e SYSTEMCTL_BINARY=/run/test/bin/systemctl \
    -e DOCTOR_BINARY=/run/test/bin/doctor \
    -e CANARY_BINARY="$canary_binary" \
    -e UPDATE_STATE=/run/test \
    -e FAIL_STAGE="$fail_stage" \
    "$CONTAINER_NAME" \
    bash /app/server/update-cliproxyapi.sh \
      --version "$VERSION" --model test-model
}

restore_original_fixture() {
  cp "$(find "$BACKUP_ROOT" -type f -name cli-proxy-api | head -1)" "${INSTALL_ROOT}/cli-proxy-api"
  chmod 0755 "${INSTALL_ROOT}/cli-proxy-api"
  printf 'original-config\n' >"${INSTALL_ROOT}/config.yaml"
  printf 'original-unit\n' >"${INSTALL_ROOT}/cliproxyapi.service"
}

original_auth_digest="$(sha256sum "${AUTH_DIR}/account.json")"
run_update "" >"${RUNTIME_DIR}/success.log"
grep -q 'candidate binary' "${INSTALL_ROOT}/cli-proxy-api"
[[ "$original_auth_digest" == "$(sha256sum "${AUTH_DIR}/account.json")" ]]
grep -q '^--foundation$' "${RUNTIME_DIR}/doctor.log"
grep -q '^--model test-model$' "${RUNTIME_DIR}/canary.log"

for failure_stage in restart doctor canary; do
  restore_original_fixture
  set +e
  run_update "$failure_stage" >"${RUNTIME_DIR}/${failure_stage}-failure.log" 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]]
  grep -q 'original binary' "${INSTALL_ROOT}/cli-proxy-api"
  [[ "$(cat "${INSTALL_ROOT}/config.yaml")" == "original-config" ]]
  [[ "$(cat "${INSTALL_ROOT}/cliproxyapi.service")" == "original-unit" ]]
  [[ "$original_auth_digest" == "$(sha256sum "${AUTH_DIR}/account.json")" ]]
done

restore_original_fixture
set +e
run_update "" /run/test/bin/canary-auth-mutation >"${RUNTIME_DIR}/auth-mutation.log" 2>&1
auth_mutation_status=$?
set -e
[[ "$auth_mutation_status" -ne 0 ]]
grep -q 'OAuth state changed during upgrade' "${RUNTIME_DIR}/auth-mutation.log"
grep -q 'original binary' "${INSTALL_ROOT}/cli-proxy-api"
printf 'oauth-state\n' >"${AUTH_DIR}/account.json"

printf '0%.0s' {1..64} >"${RELEASE_DIR}/checksums.txt"
printf '  %s\n' "$ASSET" >>"${RELEASE_DIR}/checksums.txt"
set +e
run_update "" >"${RUNTIME_DIR}/checksum-failure.log" 2>&1
checksum_status=$?
set -e
[[ "$checksum_status" -ne 0 ]]
grep -q 'original binary' "${INSTALL_ROOT}/cli-proxy-api"

if grep -R -Eq 'oauth-state|Authorization|test-server-only-key' \
    "${RUNTIME_DIR}"/*.log; then
  printf 'update logs contain sensitive material\n' >&2
  exit 1
fi

printf 'PASS: verified upgrade, health gates, OAuth preservation, and rollback\n'
