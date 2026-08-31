#!/usr/bin/env bash

codex_via_server_setup() {
  device_id=""
  output_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id) device_id="${2:-}"; shift 2 ;;
      --output) output_file="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'Usage: codex-via-server setup --device-id <id> --output <request.json>\n'
        return 0
        ;;
      *) printf 'codex-via-server: setup: unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [[ "$device_id" =~ ^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$ ]] \
    || { printf 'codex-via-server: setup: invalid device id\n' >&2; return 2; }
  [[ "$output_file" = /* ]] \
    || { printf 'codex-via-server: setup: output path must be absolute\n' >&2; return 2; }
  [[ ! -L "$output_file" ]] \
    || { printf 'codex-via-server: setup: output path must not be a symbolic link\n' >&2; return 2; }
  if [[ -e "$output_file" && ! -f "$output_file" ]]; then
    printf 'codex-via-server: setup: output path must be a regular file\n' >&2
    return 2
  fi

  for dependency in jq ssh-keygen; do
    command -v "$dependency" >/dev/null 2>&1 \
      || { printf 'codex-via-server: setup: missing command: %s\n' "$dependency" >&2; return 1; }
  done

  key_dir="${CODEX_VIA_SERVER_KEY_DIR:-${HOME}/.ssh/codex-via-server}"
  private_key="${key_dir}/${device_id}"
  public_key_file="${private_key}.pub"
  install -d -m 0700 "$key_dir"

  [[ ! -L "$private_key" && ! -L "$public_key_file" ]] \
    || { printf 'codex-via-server: setup: key path must not be a symbolic link\n' >&2; return 1; }

  if [[ -e "$private_key" || -e "$public_key_file" ]]; then
    [[ -f "$private_key" && -f "$public_key_file" ]] \
      || { printf 'codex-via-server: setup: existing key pair is incomplete\n' >&2; return 1; }
  else
    ssh-keygen -q -t ed25519 -N '' -C "$device_id" -f "$private_key"
  fi

  chmod 0600 "$private_key"
  chmod 0644 "$public_key_file"
  public_key="$(cat "$public_key_file")"
  read -r key_type key_blob key_comment key_extra <<<"$public_key"
  [[ "$key_type" == "ssh-ed25519" && "$key_comment" == "$device_id" && -z "${key_extra:-}" ]] \
    || { printf 'codex-via-server: setup: existing public key has an unexpected shape\n' >&2; return 1; }

  requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output_directory="$(dirname "$output_file")"
  install -d -m 0700 "$output_directory"
  runtime_file="$(mktemp /tmp/codex-enrollment.XXXXXX)"
  trap 'rm -f -- "$runtime_file"' RETURN

  jq -n \
    --arg device_id "$device_id" \
    --arg public_key "$public_key" \
    --arg requested_at "$requested_at" \
    '{schema_version: 1, device_id: $device_id, platform: "macos", public_key: $public_key, requested_at: $requested_at}' \
    >"$runtime_file"
  install -m 0600 "$runtime_file" "$output_file"

  fingerprint="$(ssh-keygen -lf "$public_key_file" -E sha256 | awk 'NR == 1 {print $2}')"
  printf 'Enrollment request: %s\n' "$output_file"
  printf 'Device fingerprint: %s\n' "$fingerprint"
}
