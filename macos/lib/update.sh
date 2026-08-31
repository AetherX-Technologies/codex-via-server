#!/usr/bin/env bash

codex_via_server_update() {
  check_only=0
  force_check=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-only) check_only=1; shift ;;
      --force) force_check=1; shift ;;
      -h|--help) printf 'Usage: codex-via-server update [--check-only] [--force]\n'; return 0 ;;
      *) printf 'codex-via-server: update: unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  for dependency in curl jq shasum tar; do
    command -v "$dependency" >/dev/null 2>&1 || return 1
  done

  state_dir="${CODEX_VIA_SERVER_STATE_DIR:-${HOME}/.local/share/codex-via-server}"
  cache_dir="${CODEX_VIA_SERVER_CACHE_DIR:-${HOME}/.cache/codex-via-server}"
  cache_file="${cache_dir}/update-check.json"
  installed_version_file="${state_dir}/VERSION"
  release_api="${CODEX_VIA_SERVER_RELEASE_API:-https://api.github.com/repos/AetherX-Technologies/codex-via-server/releases/latest}"
  asset_name="codex-via-server-macos.tar.gz"
  install -d -m 0700 "$state_dir" "$cache_dir"

  now_seconds="$(date +%s)"
  use_cache=0
  if [[ "$force_check" -eq 0 && -f "$cache_file" && ! -L "$cache_file" ]]; then
    checked_at="$(jq -r '.checked_at // 0' "$cache_file" 2>/dev/null || printf 0)"
    [[ "$checked_at" =~ ^[0-9]+$ && $((now_seconds - checked_at)) -lt 86400 ]] && use_cache=1
  fi

  if [[ "$use_cache" -eq 1 ]]; then
    release_json="$(cat "$cache_file")"
  else
    response="$(curl -LfsS --retry 3 --retry-all-errors "$release_api")" || return 1
    release_json="$(printf '%s\n' "$response" | jq -c --argjson checked_at "$now_seconds" --arg asset "$asset_name" '{checked_at: $checked_at, tag_name: .tag_name, asset_url: ([.assets[] | select(.name == $asset) | .browser_download_url][0]), checksums_url: ([.assets[] | select(.name == "checksums.txt") | .browser_download_url][0])}')"
    temporary_cache="$(mktemp /tmp/codex-update-cache.XXXXXX)"
    printf '%s\n' "$release_json" >"$temporary_cache"
    install -m 0600 "$temporary_cache" "$cache_file"
    rm -f -- "$temporary_cache"
  fi

  latest_version="$(printf '%s\n' "$release_json" | jq -r '.tag_name' | sed 's/^v//')"
  asset_url="$(printf '%s\n' "$release_json" | jq -r '.asset_url')"
  checksums_url="$(printf '%s\n' "$release_json" | jq -r '.checksums_url')"
  [[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$asset_url" == https://* || "$asset_url" == http://127.0.0.1:* ]] || return 1
  [[ "$checksums_url" == https://* || "$checksums_url" == http://127.0.0.1:* ]] || return 1
  installed_version="0.0.0"
  [[ ! -f "$installed_version_file" ]] || installed_version="$(tr -d '[:space:]' <"$installed_version_file")"

  if [[ "$check_only" -eq 1 ]]; then
    printf 'installed=%s latest=%s cached=%s\n' "$installed_version" "$latest_version" "$use_cache"
    return 0
  fi
  codex_via_server_version_at_least "$installed_version" "$latest_version" \
    && { printf 'codex-via-server is current: %s\n' "$installed_version"; return 0; }

  runtime_dir="$(mktemp -d /tmp/codex-client-update.XXXXXX)"
  backup_dir="${state_dir}/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  archive_file="${runtime_dir}/${asset_name}"
  checksums_file="${runtime_dir}/checksums.txt"
  extract_dir="${runtime_dir}/extract"
  install -d -m 0700 "$backup_dir" "$extract_dir"
  transaction_committed=0
  trap 'codex_via_server_update_cleanup' RETURN

  curl -LfsS --retry 3 --retry-all-errors -o "$archive_file" "$asset_url"
  curl -LfsS --retry 3 --retry-all-errors -o "$checksums_file" "$checksums_url"
  expected="$(awk -v asset="$asset_name" '$2 == asset || $2 == "*" asset {print $1; exit}' "$checksums_file")"
  actual="$(shasum -a 256 "$archive_file" | awk '{print $1}')"
  [[ "$expected" =~ ^[a-f0-9]{64}$ && "$actual" == "$expected" ]] || return 1
  tar -xzf "$archive_file" -C "$extract_dir"
  package_root="${extract_dir}/codex-via-server-macos"
  [[ -f "${package_root}/codex-via-server" && -f "${package_root}/VERSION" ]] || return 1
  [[ "$(tr -d '[:space:]' <"${package_root}/VERSION")" == "$latest_version" ]] || return 1
  bash -n "${package_root}/codex-via-server"
  for file in commands setup enroll tunnel doctor update uninstall; do
    [[ -f "${package_root}/macos/lib/${file}.sh" && ! -L "${package_root}/macos/lib/${file}.sh" ]] || return 1
    bash -n "${package_root}/macos/lib/${file}.sh"
  done

  codex_via_server_backup_path "${HOME}/.local/bin/codex-via-server" "$backup_dir" launcher
  codex_via_server_backup_path "${HOME}/.local/lib/codex-via-server" "$backup_dir" library
  codex_via_server_backup_path "$installed_version_file" "$backup_dir" version
  install -d -m 0755 "${HOME}/.local/bin" "${HOME}/.local/lib/codex-via-server"
  install -m 0755 "${package_root}/codex-via-server" "${HOME}/.local/bin/codex-via-server"
  [[ "${CODEX_VIA_SERVER_TEST_FAIL_STAGE:-}" != "after-launcher" ]] || return 1
  for library_file in "${package_root}"/macos/lib/*.sh; do install -m 0644 "$library_file" "${HOME}/.local/lib/codex-via-server/$(basename "$library_file")"; done
  install -m 0644 "${package_root}/VERSION" "$installed_version_file"
  transaction_committed=1
  find "$runtime_dir" -depth -delete
  trap - RETURN
  printf 'Updated to %s. Backup: %s\n' "$latest_version" "$backup_dir"
}

codex_via_server_update_cleanup() {
  status=$?
  trap - RETURN
  if [[ "$transaction_committed" -eq 0 ]]; then
    codex_via_server_restore_path "${HOME}/.local/bin/codex-via-server" "$backup_dir" launcher
    codex_via_server_restore_path "${HOME}/.local/lib/codex-via-server" "$backup_dir" library
    codex_via_server_restore_path "$installed_version_file" "$backup_dir" version
  fi
  [[ ! -d "$runtime_dir" ]] || find "$runtime_dir" -depth -delete
  return "$status"
}

codex_via_server_backup_path() {
  source_path="$1"; backup_dir="$2"; backup_name="$3"
  if [[ -e "$source_path" ]]; then cp -R -p "$source_path" "${backup_dir}/${backup_name}"; else : >"${backup_dir}/${backup_name}.absent"; fi
}

codex_via_server_restore_path() {
  destination="$1"; backup_dir="$2"; backup_name="$3"
  if [[ -e "${backup_dir}/${backup_name}" ]]; then
    [[ ! -d "$destination" ]] || find "$destination" -depth -delete
    cp -R -p "${backup_dir}/${backup_name}" "$destination"
  elif [[ -e "${backup_dir}/${backup_name}.absent" ]]; then
    if [[ -d "$destination" ]]; then find "$destination" -depth -delete; else rm -f -- "$destination"; fi
  fi
}
