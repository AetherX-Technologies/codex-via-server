#!/usr/bin/env bash

codex_via_server_uninstall() {
  remove_key=0; confirmed=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove-device-key) remove_key=1; shift ;;
      --yes) confirmed=1; shift ;;
      -h|--help) printf 'Usage: codex-via-server uninstall [--remove-device-key --yes]\n'; return 0 ;;
      *) return 2 ;;
    esac
  done
  [[ "$remove_key" -eq 0 || "$confirmed" -eq 1 ]] || return 2

  state_dir="${CODEX_VIA_SERVER_STATE_DIR:-${HOME}/.local/share/codex-via-server}"
  backup_dir="${state_dir}/uninstall-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  connection="${HOME}/.config/codex-via-server/connection-profile.json"
  codex_profile_name="codex-via-server"; device_id=""
  if [[ -f "$connection" && ! -L "$connection" ]]; then
    codex_profile_name="$(jq -r '.client.codex_profile // "codex-via-server"' "$connection")"
    device_id="$(jq -r '.approved_device.device_id // empty' "$connection")"
  fi
  [[ "$codex_profile_name" =~ ^[A-Za-z0-9_-]{3,64}$ ]] || return 1
  install -d -m 0700 "$backup_dir"
  paths=("${HOME}/.local/bin/codex-via-server" "${HOME}/.local/lib/codex-via-server" "$connection" "${HOME}/.config/codex-via-server/config" "${CODEX_HOME:-${HOME}/.codex}/${codex_profile_name}.config.toml" "${state_dir}/VERSION")
  for target in "${paths[@]}"; do
    [[ ! -L "$target" ]] || return 1
    if [[ -e "$target" ]]; then
      name="$(printf '%s' "$target" | shasum -a 256 | cut -c1-16)"
      cp -R -p "$target" "${backup_dir}/${name}"
      if [[ -d "$target" ]]; then find "$target" -depth -delete; else rm -f -- "$target"; fi
    fi
  done
  if [[ "$remove_key" -eq 1 && -n "$device_id" ]]; then
    key="${CODEX_VIA_SERVER_KEY_DIR:-${HOME}/.ssh/codex-via-server}/${device_id}"
    for file in "$key" "${key}.pub"; do [[ ! -L "$file" ]] || return 1; [[ ! -f "$file" ]] || { cp -p "$file" "$backup_dir/$(basename "$file")"; rm -f -- "$file"; }; done
  fi
  printf 'Uninstalled. Backup: %s\n' "$backup_dir"
}
