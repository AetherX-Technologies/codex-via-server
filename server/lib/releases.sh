#!/usr/bin/env bash

set -euo pipefail

cliproxy_asset_for() {
  version="$1"
  machine="${2:-$(uname -m)}"

  case "$machine" in
    x86_64|amd64) architecture="amd64" ;;
    aarch64|arm64) architecture="arm64" ;;
    *) printf 'unsupported architecture: %s\n' "$machine" >&2; return 1 ;;
  esac

  printf 'CLIProxyAPI_%s_linux_%s_no-plugin.tar.gz\n' "$version" "$architecture"
}

cliproxy_release_url() {
  version="$1"
  asset="$2"
  base_url="${CLIPROXY_RELEASE_BASE_URL:-https://github.com/router-for-me/CLIProxyAPI/releases/download}"
  printf '%s/v%s/%s\n' "${base_url%/}" "$version" "$asset"
}

cliproxy_checksums_url() {
  version="$1"
  cliproxy_release_url "$version" checksums.txt
}
