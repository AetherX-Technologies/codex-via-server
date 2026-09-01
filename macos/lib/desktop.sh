#!/usr/bin/env bash

CODEX_VIA_SERVER_DESKTOP_LABEL="com.aetherx.codex-via-server-tunnel"

codex_via_server_desktop_paths() {
  desktop_config_dir="${HOME}/.config/codex-via-server"
  desktop_profile="${CODEX_VIA_SERVER_CONNECTION_PROFILE:-${desktop_config_dir}/connection-profile.json}"
  desktop_known_hosts="${desktop_config_dir}/known_hosts"
  desktop_tunnel="${HOME}/.local/lib/codex-via-server/persistent-tunnel.sh"
  desktop_plist="${HOME}/Library/LaunchAgents/${CODEX_VIA_SERVER_DESKTOP_LABEL}.plist"
  desktop_state_dir="${HOME}/.local/state/codex-via-server"
  desktop_codex_config="${CODEX_HOME:-${HOME}/.codex}/config.toml"
  desktop_codex_backup="${desktop_config_dir}/desktop-config.toml.backup"
  desktop_domain="gui/$(id -u)"
  desktop_service="${desktop_domain}/${CODEX_VIA_SERVER_DESKTOP_LABEL}"
}

codex_via_server_desktop_update_codex_config() {
  provider="$(awk -F'"' '/^[[:space:]]*model_provider[[:space:]]*=/{print $2; exit}' "$desktop_codex_config")"
  [[ "$provider" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  local_port="$(jq -r '.client.local_port' "$desktop_profile")"
  temporary_config="$(mktemp /tmp/codex-desktop-config.XXXXXX)"
  awk -v section="[model_providers.${provider}]" -v endpoint="http://127.0.0.1:${local_port}/v1" '
    BEGIN {inside = 0; replaced = 0}
    /^\[/ {inside = ($0 == section)}
    inside && /^[[:space:]]*base_url[[:space:]]*=/ {print "base_url = \"" endpoint "\""; replaced = 1; next}
    {print}
    END {if (!replaced) exit 7}
  ' "$desktop_codex_config" >"$temporary_config" || { rm -f -- "$temporary_config"; return 1; }
  install -m 0600 "$temporary_config" "$desktop_codex_config"
  rm -f -- "$temporary_config"
}

codex_via_server_desktop_write_known_hosts() {
  runtime_dir="$(mktemp -d /tmp/codex-desktop-hosts.XXXXXX)"
  scanned="${runtime_dir}/scanned"
  candidate="${runtime_dir}/candidate"
  verified="${runtime_dir}/verified"
  ssh_host="$(jq -r '.server.host' "$desktop_profile")"
  ssh_port="$(jq -r '.server.ssh_port' "$desktop_profile")"
  ssh-keyscan -T 5 -p "$ssh_port" "$ssh_host" >"$scanned" 2>/dev/null || { find "$runtime_dir" -depth -delete; return 1; }
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line" >"$candidate"
    fingerprint="$(ssh-keygen -lf "$candidate" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')"
    if jq -e --arg fingerprint "$fingerprint" '.server.host_fingerprints | index($fingerprint) != null' "$desktop_profile" >/dev/null; then
      printf '%s\n' "$line" >>"$verified"
    fi
  done <"$scanned"
  [[ -s "$verified" ]] || { find "$runtime_dir" -depth -delete; return 1; }
  install -m 0600 "$verified" "$desktop_known_hosts"
  find "$runtime_dir" -depth -delete
}

codex_via_server_desktop_write_plist() {
  install -d -m 0700 "$(dirname "$desktop_plist")" "$desktop_state_dir"
  temporary_plist="$(mktemp /tmp/codex-desktop-plist.XXXXXX)"
  cat >"$temporary_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${CODEX_VIA_SERVER_DESKTOP_LABEL}</string>
  <key>ProgramArguments</key><array><string>${desktop_tunnel}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>${desktop_state_dir}/tunnel.log</string>
  <key>StandardErrorPath</key><string>${desktop_state_dir}/tunnel-error.log</string>
</dict></plist>
EOF
  plutil -lint "$temporary_plist" >/dev/null
  install -m 0600 "$temporary_plist" "$desktop_plist"
  rm -f -- "$temporary_plist"
}

codex_via_server_desktop_wait() {
  local_port="$(jq -r '.client.local_port' "$desktop_profile")"
  attempts=0
  while [[ "$attempts" -lt 15 ]]; do
    if curl --proxy '' --noproxy '*' --connect-timeout 2 --max-time 4 -fsS "http://127.0.0.1:${local_port}/v1/models" | jq -e '.data | type == "array"' >/dev/null; then
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  return 1
}

codex_via_server_desktop_install() {
  [[ $# -eq 0 ]] || return 2
  codex_via_server_desktop_paths
  for dependency in awk curl jq launchctl plutil ssh-keygen ssh-keyscan; do command -v "$dependency" >/dev/null || return 1; done
  [[ -f "$desktop_profile" && ! -L "$desktop_profile" ]] || { printf 'codex-via-server: desktop: connection profile is missing\n' >&2; return 1; }
  [[ -f "$desktop_codex_config" && ! -L "$desktop_codex_config" ]] || { printf 'codex-via-server: desktop: Codex config is missing\n' >&2; return 1; }
  install -d -m 0700 "$desktop_config_dir"
  [[ -f "$desktop_codex_backup" ]] || install -m 0600 "$desktop_codex_config" "$desktop_codex_backup"
  codex_via_server_desktop_write_known_hosts || return 1
  codex_via_server_desktop_update_codex_config || return 1
  codex_via_server_desktop_write_plist || { install -m 0600 "$desktop_codex_backup" "$desktop_codex_config"; return 1; }
  launchctl bootout "$desktop_service" >/dev/null 2>&1 || true
  launchctl bootstrap "$desktop_domain" "$desktop_plist" || { install -m 0600 "$desktop_codex_backup" "$desktop_codex_config"; return 1; }
  launchctl kickstart -k "$desktop_service"
  if ! codex_via_server_desktop_wait; then
    launchctl bootout "$desktop_service" >/dev/null 2>&1 || true
    install -m 0600 "$desktop_codex_backup" "$desktop_codex_config"
    printf 'codex-via-server: desktop: tunnel health check failed; Codex config restored\n' >&2
    return 1
  fi
  printf 'desktop-install=pass url=http://127.0.0.1:%s/v1\n' "$(jq -r '.client.local_port' "$desktop_profile")"
}

codex_via_server_desktop_status() {
  [[ $# -eq 0 ]] || return 2
  codex_via_server_desktop_paths
  launchctl print "$desktop_service" >/dev/null 2>&1 || { printf 'desktop-status=fail launchd=missing\n' >&2; return 1; }
  codex_via_server_desktop_wait || { printf 'desktop-status=fail endpoint=unavailable\n' >&2; return 1; }
  printf 'desktop-status=pass url=http://127.0.0.1:%s/v1\n' "$(jq -r '.client.local_port' "$desktop_profile")"
}

codex_via_server_desktop_restart() {
  [[ $# -eq 0 ]] || return 2
  codex_via_server_desktop_paths
  launchctl kickstart -k "$desktop_service" || return 1
  codex_via_server_desktop_wait || return 1
  printf 'desktop-restart=pass\n'
}

codex_via_server_desktop_uninstall() {
  [[ $# -eq 0 ]] || return 2
  codex_via_server_desktop_paths
  launchctl bootout "$desktop_service" >/dev/null 2>&1 || true
  [[ ! -f "$desktop_codex_backup" ]] || install -m 0600 "$desktop_codex_backup" "$desktop_codex_config"
  rm -f -- "$desktop_plist" "$desktop_known_hosts"
  printf 'desktop-uninstall=pass\n'
}
