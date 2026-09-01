#!/usr/bin/env bash

codex_via_server_usage() {
  cat <<'EOF'
Usage:
  codex-via-server [official Codex arguments...]
  codex-via-server setup
  codex-via-server enroll <connection-profile.json>
  codex-via-server doctor [--live]
  codex-via-server desktop-install
  codex-via-server desktop-status
  codex-via-server desktop-restart
  codex-via-server desktop-uninstall
  codex-via-server update [--check-only]
  codex-via-server uninstall
  codex-via-server help

Commands are implemented incrementally during the v0.2 development cycle.
Arguments that do not match a command are passed unchanged to official Codex.
EOF
}

codex_via_server_library_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

codex_via_server_version_at_least() {
  current_version="$1"
  minimum_version="$2"
  current_core="${current_version%%-*}"
  minimum_core="${minimum_version%%-*}"
  oldest_version="$(printf '%s\n%s\n' "$current_core" "$minimum_core" | sort -V | head -n 1)"
  [[ "$oldest_version" == "$minimum_core" ]]
}

is_codex_via_server_command() {
  case "$1" in
    setup|enroll|doctor|desktop-install|desktop-status|desktop-restart|desktop-uninstall|update|uninstall|help) return 0 ;;
    *) return 1 ;;
  esac
}

run_codex_via_server_command() {
  command_name="$1"
  shift

  case "$command_name" in
    help)
      [[ $# -eq 0 ]] || return 2
      codex_via_server_usage
      ;;
    setup)
      source "$(codex_via_server_library_dir)/setup.sh"
      codex_via_server_setup "$@"
      ;;
    enroll)
      source "$(codex_via_server_library_dir)/enroll.sh"
      codex_via_server_enroll "$@"
      ;;
    doctor)
      source "$(codex_via_server_library_dir)/tunnel.sh"
      source "$(codex_via_server_library_dir)/doctor.sh"
      codex_via_server_doctor "$@"
      ;;
    desktop-install|desktop-status|desktop-restart|desktop-uninstall)
      source "$(codex_via_server_library_dir)/desktop.sh"
      "codex_via_server_${command_name//-/_}" "$@"
      ;;
    update)
      source "$(codex_via_server_library_dir)/update.sh"
      codex_via_server_update "$@"
      ;;
    uninstall)
      source "$(codex_via_server_library_dir)/uninstall.sh"
      codex_via_server_uninstall "$@"
      ;;
  esac
}
