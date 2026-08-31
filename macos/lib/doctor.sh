#!/usr/bin/env bash

codex_via_server_doctor() {
  live_check=0
  confirmed=0
  live_model=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live_check=1; shift ;;
      --yes) confirmed=1; shift ;;
      --model) live_model="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'Usage: codex-via-server doctor [--live --yes --model <model>]\n'
        return 0
        ;;
      *) printf 'codex-via-server: doctor: unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [[ "$live_check" -eq 1 ]]; then
    [[ "$confirmed" -eq 1 ]] \
      || { printf 'codex-via-server: doctor: --live requires --yes confirmation\n' >&2; return 2; }
    [[ "$live_model" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] \
      || { printf 'codex-via-server: doctor: --live requires a valid --model\n' >&2; return 2; }
  fi

  codex_via_server_load_v2_profile || return 1
  CODEX_BINARY="${CODEX_BINARY:-$(command -v codex || true)}"
  [[ -n "$CODEX_BINARY" && -x "$CODEX_BINARY" ]] \
    || { printf 'codex-via-server: doctor: official Codex CLI was not found\n' >&2; return 1; }

  codex_version_output="$($CODEX_BINARY --version 2>/dev/null)" \
    || { printf 'codex-via-server: doctor: Codex version check failed\n' >&2; return 1; }
  codex_version="$(printf '%s\n' "$codex_version_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -n 1)"
  [[ -n "$codex_version" ]] || return 1
  minimum_codex_version="$(jq -r '.client.minimum_codex_version' "$CONNECTION_PROFILE_FILE")"
  codex_via_server_version_at_least "$codex_version" "$minimum_codex_version" \
    || { printf 'codex-via-server: doctor: Codex %s is older than required %s\n' "$codex_version" "$minimum_codex_version" >&2; return 1; }

  "$CODEX_BINARY" --profile "$CODEX_PROFILE" --version >/dev/null 2>&1 \
    || { printf 'codex-via-server: doctor: Codex profile parsing failed\n' >&2; return 1; }

  codex_via_server_open_v2_tunnel || return 1

  if [[ "$live_check" -eq 1 ]]; then
    live_runtime="$(mktemp -d /tmp/codex-client-canary.XXXXXX)"
    live_request="${live_runtime}/request.json"
    live_response="${live_runtime}/response.sse"
    trap '[[ ! -d "$live_runtime" ]] || find "$live_runtime" -depth -delete' RETURN
    jq -n --arg model "$live_model" '{model: $model, input: "Reply only OK.", stream: true}' >"$live_request"
    curl --proxy '' --noproxy '*' --no-buffer \
      --connect-timeout 5 --max-time 45 \
      --fail-with-body --silent --show-error \
      -H 'Content-Type: application/json' \
      --data-binary "@${live_request}" \
      "http://127.0.0.1:${LOCAL_PORT}/v1/responses" \
      >"$live_response" 2>/dev/null \
      || { printf 'codex-via-server: doctor: live Responses check failed\n' >&2; return 1; }
    grep -q '"type"[[:space:]]*:[[:space:]]*"response.completed"' "$live_response" \
      || { printf 'codex-via-server: doctor: live response did not complete\n' >&2; return 1; }
    find "$live_runtime" -depth -delete
    trap - RETURN
  fi

  printf 'doctor=pass codex=%s profile=%s live=%s\n' \
    "$codex_version" "$CODEX_PROFILE" "$live_check"
}
