# Windows Codex 桌面端常驻隧道

Windows 支持目前位于 `feature/v0.2-hardened-enrollment-design` 分支。它为每台
设备使用独立的受限 SSH 密钥，并通过当前用户的任务计划程序在登录后启动。它不是
系统服务；安装好前置软件后，日常命令不需要管理员权限。

## 前提条件

- PowerShell 7（`pwsh`），不要使用 Windows PowerShell 5.1。
- Git、Tailscale 和 Windows OpenSSH 客户端。
- 官方 Codex CLI `0.149.1` 或更高版本。
- 服务器管理员批准并返回的不含密钥连接配置。

如未安装，在管理员 PowerShell 中执行：

```powershell
winget install --id Microsoft.PowerShell -e
winget install --id Git.Git -e
winget install --id Tailscale.Tailscale -e
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

在普通 PowerShell 7 中安装并检查官方 Codex CLI：

```powershell
irm https://chatgpt.com/codex/install.ps1 | iex
codex --version
tailscale status
```

## 安装和设备批准

```powershell
Set-Location $HOME
git clone `
  --branch feature/v0.2-hardened-enrollment-design `
  --single-branch `
  https://github.com/AetherX-Technologies/codex-via-server.git
Set-Location "$HOME\codex-via-server"

pwsh -ExecutionPolicy Bypass -File .\windows\install.ps1
$Client = Join-Path $HOME ".codex-via-server\bin\codex-via-server.ps1"
```

每台 Windows 设备生成一份独立申请：

```powershell
$Request = Join-Path $HOME "windows-device.request.json"
& $Client setup --device-id windows-device --output $Request
```

只把申请 JSON 发给管理员。不要发送 `$HOME\.codex-via-server\keys` 中的私钥。
管理员返回连接配置后导入并检查：

```powershell
& $Client enroll "$HOME\Downloads\windows-device.connection.json"
& $Client doctor
```

连接配置不含 API Key，但包含私有网络元数据，仍然不能提交到公开仓库。

## 设置登录后自动启动

首次安装前先退出 Codex 桌面端，然后执行：

```powershell
& $Client desktop-install
& $Client desktop-status
```

`desktop-install` 会：

1. 只备份一次 `$HOME\.codex\config.toml`。
2. 写入有明确标记的 `codex_via_server_desktop` provider。
3. 为当前用户创建隐藏的 `CodexViaServer Persistent Tunnel` 登录任务。
4. 立即启动受限 SSH 隧道。
5. 通过本机回环地址验证 `/v1/models`。

任务失败后会重启，而且没有最长运行时限。Tailscale 通过 DERP 中继可达也算正常，
客户端不会强制等待点对点直连。

桌面端托管配置等价于：

```toml
model_provider = "codex_via_server_desktop"

[model_providers.codex_via_server_desktop]
name = "Codex via Server persistent tunnel"
base_url = "http://127.0.0.1:<批准的本地端口>/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = false
```

回环地址必须使用 `http://`。离开本机后的流量已经由 SSH 保护，本机 SSH 监听器
本身不是 TLS 服务器，所以写成 `https://127.0.0.1:...` 会连接失败。这个由服务器
注入凭据的设计也必须使用 `requires_openai_auth = false`。

## 日常检查

```powershell
& $Client desktop-status
& $Client desktop-restart
& $Client doctor --live --yes --model <MODEL_ID>
```

常驻隧道日志位于：

```text
%USERPROFILE%\.codex-via-server\state\persistent-tunnel.log
```

日志只记录生命周期和错误类型，不记录连接配置、密钥、请求正文或 API 凭据。公开
分享前仍应人工检查并删除环境专属标识。

## 排查 `Reconnecting... waiting for network`

依次执行：

```powershell
tailscale status
& $Client desktop-status
& $Client desktop-restart
& $Client doctor
```

同时确认桌面 provider 的地址是 `http://127.0.0.1:.../v1`，且
`requires_openai_auth = false`。不要手工替换批准配置中的端口、SSH 密钥、主机或
指纹；这些值变化时应重新申请并导入管理员批准的新配置。

客户端只有在监听进程确实是 `ssh.exe`，并且完整命令行同时匹配批准的设备密钥、
本地/远端端口、受限 SSH 参数以及批准的 `user@host` 时，才会复用或结束该进程。
仅仅能返回 `/v1/models` 的其他程序绝不会被认作本项目隧道。

## 回滚

```powershell
& $Client desktop-uninstall
```

该命令删除任务计划，只停止严格匹配的托管 SSH 隧道，并恢复安装前的 Codex 主配置。
它不会撤销服务器上的设备密钥。

保留设备密钥并删除整个客户端：

```powershell
& $Client uninstall
```

删除设备私钥必须显式确认：

```powershell
& $Client uninstall --remove-device-key --yes
```
