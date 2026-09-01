# macOS Codex 桌面端使用说明

## 当前可用地址

Codex 桌面端使用：

```text
http://127.0.0.1:18319/v1
```

客户端不需要服务器真实 API Key。真实 Key 只保存在服务器，由 loopback 网关注入。

## 安装常驻隧道

完成设备 setup、管理员 approve 和 enroll 后执行：

```bash
codex-via-server desktop-install
```

它会：

1. 备份 `~/.codex/config.toml`。
2. 把当前 Codex provider 的 URL 改成本机 `18319`。
3. 安装 macOS LaunchAgent。
4. 立即启动受限 SSH 隧道。
5. 验证 `/v1/models` 可用；失败时自动恢复原配置。

## 日常检查

```bash
codex-via-server desktop-status
```

正常输出：

```text
desktop-status=pass url=http://127.0.0.1:18319/v1
```

重启隧道：

```bash
codex-via-server desktop-restart
```

完整真实请求检查：

```bash
codex-via-server doctor --live --yes --model gpt-5.6-luna
```

## 开机和断线恢复

LaunchAgent 在当前用户登录后自动启动。Tailscale 暂时不可用、Wi-Fi 切换或 SSH 连接中断时，macOS 会自动重新启动隧道。无需保持终端窗口，也无需手动运行 `codex-via-server`。

## 故障处理

桌面端显示 `Reconnecting` 时先运行：

```bash
codex-via-server desktop-status
```

如果失败，再运行：

```bash
codex-via-server desktop-restart
```

日志位于：

```text
~/.local/state/codex-via-server/tunnel.log
~/.local/state/codex-via-server/tunnel-error.log
```

不要把日志中的完整敏感内容公开发布。

## 回滚

```bash
codex-via-server desktop-uninstall
```

该命令停止并移除常驻隧道，恢复安装前备份的 Codex 主配置。它不会撤销设备，也不会修改服务器 VPN 或 CLIProxyAPI。
