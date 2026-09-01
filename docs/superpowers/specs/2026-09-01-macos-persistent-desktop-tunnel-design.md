# macOS 桌面端常驻隧道设计

日期：2026-09-01

状态：设计已确认，等待实施

目标版本：`v0.2.0`

## 问题

当前 v0.2 的受限 SSH 隧道只在运行 `codex-via-server` 命令期间存在。Codex 桌面端独立启动，因此访问 `http://127.0.0.1:18319/v1` 时本机没有进程监听，持续显示重新连接和请求失败。

修复后必须满足：真实 CLIProxyAPI Key 继续只保存在服务器；Mac 登录后自动可用；网络切换或短暂断线后自动恢复；兼容同时开启 Tailscale 和 Shadowrocket；保留旧 CLI 用法和回滚能力。

## 方案

安装当前 macOS 用户级别的 LaunchAgent，由它长期维护受限 SSH 本地转发：

```text
Codex 桌面端
  -> 127.0.0.1:18319
  -> launchd 管理的受限 SSH 隧道（通过 Tailscale）
  -> 服务器 127.0.0.1:18319 网关
  -> CLIProxyAPI
```

LaunchAgent 直接运行 macOS 自带的 `ssh`，使用每台设备独立的受限密钥、严格服务器指纹校验、仅允许本地端口转发、禁止远程 shell，并启用 SSH 保活。登录时自动启动，断线后由 `launchd` 自动重启，不额外安装 `autossh`。

## 组成部分

### 常驻隧道命令

本地脚本读取并严格校验 `connection-profile.json`，根据已批准的服务器指纹生成临时 `known_hosts`，然后执行：

```text
ssh -N -T -L 127.0.0.1:<本机端口>:127.0.0.1:<服务器网关端口> ...
```

脚本拒绝公网地址和任意转发目标，不读取、不保存、也不传输 CLIProxyAPI 的真实 Key。

### LaunchAgent

安装文件：

```text
~/Library/LaunchAgents/com.aetherx.codex-via-server-tunnel.plist
```

配置包括：

- `RunAtLoad`：用户登录后自动启动。
- `KeepAlive`：隧道退出后自动恢复。
- 重启节流：避免异常时无限高速重试。
- 私有日志目录：`~/.local/state/codex-via-server/`。
- 仅使用系统 SSH 和当前设备的独立密钥。

安装可以重复执行。替换已有文件前必须创建备份。

### Codex 桌面端配置

安装器先备份 `~/.codex/config.toml`，再把桌面端当前生效的 provider 指向：

```text
http://127.0.0.1:18319/v1
```

客户端不保存真实 Key。如果 Codex 在格式上强制要求 Key，则只使用固定的非敏感占位值；服务器网关会覆盖客户端发送的 Authorization。

现有 `codex-via-server-v2` profile 继续保留，供命令行使用。

### 与命令行共存

`codex-via-server` 启动时先检查常驻隧道。如果本机 `18319` 已由健康的常驻隧道提供，CLI 直接复用，不再因为“端口已占用”而失败。如果常驻隧道尚未安装，继续支持当前的临时隧道模式。

### 管理命令

macOS 客户端增加：

- `desktop-install`：安装桌面端配置和 LaunchAgent。
- `desktop-status`：检查 launchd、监听端口、models 接口和 Codex 配置。
- `desktop-restart`：重载 LaunchAgent 并验证自动恢复。
- `desktop-uninstall`：卸载常驻隧道并恢复原桌面端配置。

卸载桌面端集成不会撤销设备。设备撤销仍由管理员单独执行。

## 故障处理

- Tailscale 不可用：SSH 退出，launchd 按节流策略重试。
- 网络切换：SSH 保活检测断线，launchd 自动重连。
- 端口被其他程序占用：明确报告占用进程，不杀死任何未知进程。
- 服务器指纹变化：拒绝连接，防止连接到冒充服务器。
- enrollment 配置错误或权限不安全：修改 launchd 和 Codex 配置前立即终止。
- 安装后健康检查失败：卸载新 LaunchAgent，并恢复原 Codex 配置。

## 验证要求

自动测试必须证明：

1. SSH 命令只允许转发到已登记的服务器 loopback 网关。
2. LaunchAgent 登录后启动，并能在模拟断线后重新启动。
3. CLI 能复用已经运行的常驻隧道。
4. 启动命令退出后，`127.0.0.1:18319/v1/models` 仍持续可用。
5. 客户端文件、环境变量、日志和进程参数中不存在真实 API Key。
6. 卸载能够恢复此前的桌面端配置。

生产验收必须直接复现并验证用户遇到的问题：不运行任何交互式 CLI 时，`18319` 仍保持监听，并且通过桌面端使用的本地地址完成一次低用量真实 Responses 请求。

## 回滚

回滚时卸载 LaunchAgent，只停止经过身份确认的隧道进程，恢复带时间戳备份的 `~/.codex/config.toml`。旧 v0.1 launcher、服务器网关、CLIProxyAPI、VPN 和已批准设备均保持不变。
