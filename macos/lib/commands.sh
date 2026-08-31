#!/usr/bin/env bash

codex_via_server_usage() {
  cat <<'EOF'
Usage:
  codex-via-server [official Codex arguments...]
  codex-via-server setup
  codex-via-server enroll <connection-profile.json>
  codex-via-server doctor [--live]
  codex-via-server update [--check-only]
  codex-via-server uninstall
  codex-via-server help

Commands are implemented incrementally during the v0.2 development cycle.
Arguments that do not match a command are passed unchanged to official Codex.
EOF
}

is_codex_via_server_command() {
  case "$1" in
    setup|enroll|doctor|update|uninstall|help) return 0 ;;
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
    setup|enroll|doctor|update|uninstall)
      printf 'codex-via-server: %s is not available in this development build yet\n' \
        "$command_name" >&2
      return 69
      ;;
  esac
}
