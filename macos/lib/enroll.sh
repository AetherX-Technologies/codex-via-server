#!/usr/bin/env bash

codex_via_server_enroll() {
  [[ $# -eq 1 ]] \
    || { printf 'codex-via-server: enroll: expected one connection profile\n' >&2; return 2; }

  connection_profile_source="$1"
  [[ -f "$connection_profile_source" && ! -L "$connection_profile_source" ]] \
    || { printf 'codex-via-server: enroll: profile must be a regular non-symlink file\n' >&2; return 2; }

  for dependency in jq ssh-keygen; do
    command -v "$dependency" >/dev/null 2>&1 \
      || { printf 'codex-via-server: enroll: missing command: %s\n' "$dependency" >&2; return 1; }
  done

  jq -e '
    type == "object" and
    (keys | sort) == ["approved_device", "client", "gateway", "issued_at", "profile_id", "schema_version", "server"] and
    .schema_version == 1 and
    (.profile_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$")) and
    (.server | type == "object") and
    (.server | keys | sort) == ["host", "host_fingerprints", "ssh_port", "ssh_user"] and
    (.server.host | type == "string") and
    (.server.ssh_port | type == "number" and . >= 1 and . <= 65535) and
    .server.ssh_user == "codex-tunnel" and
    (.server.host_fingerprints | type == "array" and length >= 1 and length <= 4) and
    (all(.server.host_fingerprints[]; type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$"))) and
    (.gateway | type == "object") and
    (.gateway | keys | sort) == ["remote_host", "remote_port"] and
    .gateway.remote_host == "127.0.0.1" and
    (.gateway.remote_port | type == "number" and . >= 1024 and . <= 65535) and
    (.client | type == "object") and
    (.client | keys | sort) == ["codex_profile", "local_port", "minimum_client_version", "minimum_codex_version"] and
    (.client.local_port | type == "number" and . >= 1024 and . <= 65535) and
    (.client.codex_profile | type == "string" and test("^[A-Za-z0-9_-]{3,64}$")) and
    (.client.minimum_client_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")) and
    (.client.minimum_codex_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")) and
    (.approved_device | type == "object") and
    (.approved_device | keys | sort) == ["device_id", "public_key_fingerprint"] and
    (.approved_device.device_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$")) and
    (.approved_device.public_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$")) and
    (.issued_at | fromdateiso8601 | type == "number")
  ' "$connection_profile_source" >/dev/null \
    || { printf 'codex-via-server: enroll: invalid connection profile\n' >&2; return 2; }

  server_host="$(jq -r '.server.host' "$connection_profile_source")"
  HOST_PATTERN='^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?){1,6})$'
  [[ "$server_host" =~ $HOST_PATTERN ]] \
    || { printf 'codex-via-server: enroll: invalid server host\n' >&2; return 2; }

  client_version="${CODEX_VIA_SERVER_VERSION:-0.2.0-dev.1}"
  minimum_client_version="$(jq -r '.client.minimum_client_version' "$connection_profile_source")"
  if ! codex_via_server_version_at_least "$client_version" "$minimum_client_version"; then
    printf 'codex-via-server: enroll: client %s is older than required %s\n' \
      "$client_version" "$minimum_client_version" >&2
    return 1
  fi

  device_id="$(jq -r '.approved_device.device_id' "$connection_profile_source")"
  key_dir="${CODEX_VIA_SERVER_KEY_DIR:-${HOME}/.ssh/codex-via-server}"
  private_key="${key_dir}/${device_id}"
  public_key_file="${private_key}.pub"
  [[ -f "$private_key" && -f "$public_key_file" && ! -L "$private_key" && ! -L "$public_key_file" ]] \
    || { printf 'codex-via-server: enroll: approved device key pair is missing or unsafe\n' >&2; return 1; }

  actual_fingerprint="$(ssh-keygen -lf "$public_key_file" -E sha256 | awk 'NR == 1 {print $2}')"
  expected_fingerprint="$(jq -r '.approved_device.public_key_fingerprint' "$connection_profile_source")"
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] \
    || { printf 'codex-via-server: enroll: approved device fingerprint does not match this Mac\n' >&2; return 1; }

  config_dir="${HOME}/.config/codex-via-server"
  connection_profile_target="${config_dir}/connection-profile.json"
  codex_dir="${CODEX_HOME:-${HOME}/.codex}"
  codex_profile_name="$(jq -r '.client.codex_profile' "$connection_profile_source")"
  codex_profile_target="${codex_dir}/${codex_profile_name}.config.toml"
  local_port="$(jq -r '.client.local_port' "$connection_profile_source")"

  [[ ! -L "$connection_profile_target" && ! -L "$codex_profile_target" ]] \
    || { printf 'codex-via-server: enroll: target path must not be a symbolic link\n' >&2; return 1; }

  install -d -m 0700 "$config_dir" "$codex_dir"
  runtime_dir="$(mktemp -d /tmp/codex-enroll.XXXXXX)"
  temporary_connection="${runtime_dir}/connection-profile.json"
  temporary_codex="${runtime_dir}/codex-profile.toml"
  trap '[[ ! -d "$runtime_dir" ]] || find "$runtime_dir" -depth -delete' RETURN

  install -m 0600 "$connection_profile_source" "$temporary_connection"
  cat >"$temporary_codex" <<EOF
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "CLIProxyAPI through a restricted SSH tunnel"
base_url = "http://127.0.0.1:${local_port}/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 2
stream_max_retries = 4
stream_idle_timeout_ms = 300000
EOF
  chmod 0600 "$temporary_codex"

  install -m 0600 "$temporary_connection" "$connection_profile_target"
  install -m 0600 "$temporary_codex" "$codex_profile_target"
  find "$runtime_dir" -depth -delete
  trap - RETURN

  printf 'Connection profile installed: %s\n' "$connection_profile_target"
  printf 'Codex profile installed: %s\n' "$codex_profile_target"
}

codex_via_server_version_at_least() {
  current_version="$1"
  minimum_version="$2"
  current_core="${current_version%%-*}"
  minimum_core="${minimum_version%%-*}"
  oldest_version="$(printf '%s\n%s\n' "$current_core" "$minimum_core" | sort -V | head -n 1)"
  [[ "$oldest_version" == "$minimum_core" ]]
}
