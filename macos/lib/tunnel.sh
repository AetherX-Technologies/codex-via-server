#!/usr/bin/env bash

codex_via_server_load_v2_profile() {
  [[ -f "$CONNECTION_PROFILE_FILE" && ! -L "$CONNECTION_PROFILE_FILE" ]] \
    || { printf 'codex-via-server: connection profile is missing or unsafe\n' >&2; return 1; }

  for dependency in awk curl jq lsof mktemp route ssh ssh-keygen ssh-keyscan; do
    command -v "$dependency" >/dev/null 2>&1 \
      || { printf 'codex-via-server: missing command: %s\n' "$dependency" >&2; return 1; }
  done

  SSH_HOST="$(jq -r '.server.host' "$CONNECTION_PROFILE_FILE")"
  SSH_PORT="$(jq -r '.server.ssh_port' "$CONNECTION_PROFILE_FILE")"
  SSH_USER="$(jq -r '.server.ssh_user' "$CONNECTION_PROFILE_FILE")"
  SERVER_API_HOST="$(jq -r '.gateway.remote_host' "$CONNECTION_PROFILE_FILE")"
  SERVER_API_PORT="$(jq -r '.gateway.remote_port' "$CONNECTION_PROFILE_FILE")"
  LOCAL_PORT="$(jq -r '.client.local_port' "$CONNECTION_PROFILE_FILE")"
  CODEX_PROFILE="$(jq -r '.client.codex_profile' "$CONNECTION_PROFILE_FILE")"
  DEVICE_ID="$(jq -r '.approved_device.device_id' "$CONNECTION_PROFILE_FILE")"
  SSH_IDENTITY="${CODEX_VIA_SERVER_KEY_DIR:-${HOME}/.ssh/codex-via-server}/${DEVICE_ID}"

  HOST_PATTERN='^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?){1,6})$'
  [[ "$SSH_HOST" =~ $HOST_PATTERN ]] || { printf 'codex-via-server: invalid server host\n' >&2; return 1; }
  [[ "$SSH_USER" == "codex-tunnel" ]] || { printf 'codex-via-server: invalid tunnel user\n' >&2; return 1; }
  [[ "$SERVER_API_HOST" == "127.0.0.1" ]] || { printf 'codex-via-server: invalid gateway destination\n' >&2; return 1; }
  [[ "$SSH_IDENTITY" = /* && -r "$SSH_IDENTITY" && ! -L "$SSH_IDENTITY" ]] \
    || { printf 'codex-via-server: device SSH identity is missing or unsafe\n' >&2; return 1; }
  [[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || return 1
  [[ "$SERVER_API_PORT" =~ ^[0-9]+$ && "$SERVER_API_PORT" -ge 1024 && "$SERVER_API_PORT" -le 65535 ]] || return 1
  [[ "$LOCAL_PORT" =~ ^[0-9]+$ && "$LOCAL_PORT" -ge 1024 && "$LOCAL_PORT" -le 65535 ]] || return 1
  [[ "$CODEX_PROFILE" =~ ^[A-Za-z0-9_-]{3,64}$ ]] || return 1

  PROFILE_FILE="${CODEX_HOME:-${HOME}/.codex}/${CODEX_PROFILE}.config.toml"
  [[ -r "$PROFILE_FILE" && ! -L "$PROFILE_FILE" ]] \
    || { printf 'codex-via-server: Codex profile is missing or unsafe\n' >&2; return 1; }
}

codex_via_server_open_v2_tunnel() {
  codex_via_server_load_v2_profile || return 1

  route_output="$(route -n get "$SSH_HOST" 2>/dev/null)" \
    || { printf 'codex-via-server: no route to Tailscale server\n' >&2; return 1; }
  route_interface="$(printf '%s\n' "$route_output" | awk '/interface:/{print $2; exit}')"
  case "$route_interface" in
    utun*) ;;
    *) printf 'codex-via-server: server route is not using Tailscale utun\n' >&2; return 1 ;;
  esac

  if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    models_response="$(curl --proxy '' --noproxy '*' --connect-timeout 3 --max-time 8 -fsS "http://127.0.0.1:${LOCAL_PORT}/v1/models")" \
      || { printf 'codex-via-server: local port %s is occupied by an unhealthy service\n' "$LOCAL_PORT" >&2; return 1; }
    printf '%s\n' "$models_response" | jq -e '.data | type == "array"' >/dev/null \
      || { printf 'codex-via-server: local port %s returned an invalid response\n' "$LOCAL_PORT" >&2; return 1; }
    SSH_MASTER_STARTED=0
    return 0
  fi

  RUNTIME_DIR="$(mktemp -d /tmp/codex-via-server.XXXXXX)"
  CONTROL_SOCKET="${RUNTIME_DIR}/control"
  scanned_host_keys="${RUNTIME_DIR}/known_hosts.scanned"
  verified_host_keys="${RUNTIME_DIR}/known_hosts"
  candidate_key="${RUNTIME_DIR}/candidate-key"

  ssh-keyscan -T 5 -p "$SSH_PORT" "$SSH_HOST" >"$scanned_host_keys" 2>/dev/null \
    || { printf 'codex-via-server: could not read server SSH host keys\n' >&2; return 1; }

  while IFS= read -r host_key_line; do
    case "$host_key_line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$host_key_line" >"$candidate_key"
    fingerprint="$(ssh-keygen -lf "$candidate_key" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')"
    if jq -e --arg fingerprint "$fingerprint" '.server.host_fingerprints | index($fingerprint) != null' \
        "$CONNECTION_PROFILE_FILE" >/dev/null; then
      printf '%s\n' "$host_key_line" >>"$verified_host_keys"
    fi
  done <"$scanned_host_keys"

  [[ -s "$verified_host_keys" ]] \
    || { printf 'codex-via-server: server SSH fingerprint changed\n' >&2; return 1; }

  SSH_TARGET="${SSH_USER}@${SSH_HOST}"
  SSH_COMMAND=(
    ssh
    -F /dev/null
    -p "$SSH_PORT"
    -i "$SSH_IDENTITY"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$verified_host_keys"
    -o GlobalKnownHostsFile=/dev/null
    -o UpdateHostKeys=no
    -o ProxyCommand=none
    -o ProxyJump=none
    -o PermitLocalCommand=no
    -o ConnectTimeout=8
    -o ConnectionAttempts=1
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o LogLevel=ERROR
  )

  if ! "${SSH_COMMAND[@]}" \
      -M -S "$CONTROL_SOCKET" \
      -o ControlPersist=no \
      -o ExitOnForwardFailure=yes \
      -fN \
      -L "127.0.0.1:${LOCAL_PORT}:${SERVER_API_HOST}:${SERVER_API_PORT}" \
      "$SSH_TARGET"; then
    printf 'codex-via-server: could not establish restricted SSH tunnel\n' >&2
    return 1
  fi
  SSH_MASTER_STARTED=1

  "${SSH_COMMAND[@]}" -S "$CONTROL_SOCKET" -O check "$SSH_TARGET" >/dev/null 2>&1 \
    || { printf 'codex-via-server: restricted SSH tunnel did not remain active\n' >&2; return 1; }

  models_response="$(
    curl --proxy '' --noproxy '*' --connect-timeout 5 --max-time 15 \
      -fsS "http://127.0.0.1:${LOCAL_PORT}/v1/models"
  )" || { printf 'codex-via-server: gateway models check failed\n' >&2; return 1; }
  printf '%s\n' "$models_response" | jq -e '.data | type == "array"' >/dev/null \
    || { printf 'codex-via-server: gateway models response is invalid\n' >&2; return 1; }
}

codex_via_server_run_v2() {
  codex_via_server_open_v2_tunnel || return 1
  CODEX_BINARY="${CODEX_BINARY:-$(command -v codex || true)}"
  [[ -n "$CODEX_BINARY" && -x "$CODEX_BINARY" ]] \
    || { printf 'codex-via-server: official Codex CLI was not found\n' >&2; return 1; }

  unset SERVER_CODEX_API_KEY CLIPROXY_API_KEY OPENAI_API_KEY
  printf 'Restricted tunnel ready. Starting local Codex with profile %s.\n' "$CODEX_PROFILE"
  "$CODEX_BINARY" --profile "$CODEX_PROFILE" "$@"
}
