#!/bin/bash
set -euo pipefail
umask 077

# Finder does not inherit the administrator's interactive Homebrew PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

notify() {
  /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
  display dialog (item 1 of argv) with title "Codex 设备审批" buttons {"好"} default button "好"
end run
APPLESCRIPT
}

fail() { printf '%s\n' "$1" >&2; notify "$1" || true; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || { printf 'This entry point requires macOS.\n' >&2; exit 1; }
for dependency in jq ssh ssh-keygen ssh-keyscan; do
  command -v "$dependency" >/dev/null 2>&1 || fail "缺少 ${dependency}。请让这台 Mac 上的管理员完成工具准备后重试。"
done
[[ -f "${DIRECTORY}/codex-via-server-admin" && ! -L "${DIRECTORY}/codex-via-server-admin" ]] || fail '审批工具缺失，请重新解压完整交接包。'

config="${CODEX_VIA_SERVER_ADMIN_CONFIG:-${HOME}/.config/codex-via-server/admin.json}"
if [[ ! -f "$config" ]]; then
  config="$(/usr/bin/osascript <<'APPLESCRIPT'
POSIX path of (choose file with prompt "选择这台 Mac 已有的管理员 admin.json；不要选择设备 connection.json 或私钥")
APPLESCRIPT
  )" || exit 0
fi
export CODEX_VIA_SERVER_ADMIN_CONFIG="$config"

request_file="$(/usr/bin/osascript - "$DIRECTORY" <<'APPLESCRIPT'
on run argv
  set folderPath to POSIX file (item 1 of argv) as alias
  return POSIX path of (choose file with prompt "选择待批准电脑的 .request.json" default location folderPath)
end run
APPLESCRIPT
)" || exit 0
[[ -f "$request_file" && ! -L "$request_file" ]] || fail '申请必须是普通文件。'

# The CLI validates a private copy and binds the response to that identity.
runtime="$(mktemp -d /tmp/codex-approve-ui.XXXXXX)"
trap 'find "$runtime" -depth -delete' EXIT
cp "$request_file" "${runtime}/request.json"
[[ "$(wc -c <"${runtime}/request.json")" -le 65536 ]] || fail '申请文件过大，未执行审批。'
device_id="$(jq -ser 'select(length == 1) | .[0].device_id | select(type == "string" and test("^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$"))' "${runtime}/request.json" 2>/dev/null)" || fail '申请文件不合法，未执行审批。'
platform="$(jq -er '.platform | select(. == "windows" or . == "macos")' "${runtime}/request.json")" || fail '申请平台不合法。'
jq -er '.public_key | select(type == "string")' "${runtime}/request.json" >"${runtime}/public-key.pub" || fail '申请缺少公钥。'
fingerprint="$(ssh-keygen -lf "${runtime}/public-key.pub" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || fail '申请公钥不合法。'
[[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail '申请公钥不合法。'

/usr/bin/osascript - "$device_id" "$fingerprint" "$platform" <<'APPLESCRIPT' || exit 0
on run argv
  display dialog ("通过可信渠道核对设备和公钥指纹后再批准。" & return & return & "设备：" & item 1 of argv & return & "平台：" & item 3 of argv & return & "公钥指纹：" & item 2 of argv & return & return & "允许此设备使用服务器 Codex？") with title "批准独立设备" buttons {"取消", "批准"} default button "取消" cancel button "取消"
end run
APPLESCRIPT

output="$(/usr/bin/osascript - "${device_id}.connection.json" <<'APPLESCRIPT'
on run argv
  return POSIX path of (choose file name with prompt "保存连接批准文件，然后传回原申请电脑" default name (item 1 of argv))
end run
APPLESCRIPT
)" || exit 0
if /bin/bash "${DIRECTORY}/codex-via-server-admin" approve "${runtime}/request.json" --output "$output"; then
  notify "服务器已确认批准。把生成的 connection.json 传回原申请电脑，并在 Windows 安装器中导入。"
else
  fail '未确认审批完成。请在这台 Mac 上检查管理员配置、Tailscale 和 SSH 权限。保留原申请；不要重新生成身份或复制私钥。'
fi
