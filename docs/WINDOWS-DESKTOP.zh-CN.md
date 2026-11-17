# Windows Codex 桌面端常驻隧道

Windows 支持及最新恢复修复位于 `fix/windows-persistent-desktop-tunnel` 分支。它为每台
设备使用独立的受限 SSH 密钥，并通过当前用户的任务计划程序在登录后启动。它不是
系统服务；安装好前置软件后，日常命令不需要管理员权限。

使用内置运行环境的 EXE 预览版请看[单文件安装程序说明](../windows/setup/README.zh-CN.md)。
下方手动安装步骤需要分别安装所列工具。

## 前提条件

- PowerShell 7（`pwsh`），不要使用 Windows PowerShell 5.1。
- Git、Tailscale 和 Windows OpenSSH 客户端。
- CLI 使用需要官方 Codex CLI `0.149.1` 或更高版本；桌面专用诊断不依赖它。
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
5. 确认监听器归属后，通过本机回环地址验证 `/healthz` 返回空正文 HTTP 204。

任务失败后会重启，而且没有最长运行时限。Tailscale 通过 DERP 中继可达也算正常，
客户端不会强制等待点对点直连。

Windows SSH 默认启用 `-C` 压缩，减少较大 Codex 文本请求在 DERP 中继上的传输量。
压缩只能减轻拥塞，不能消除中继中断或不可压缩流量造成的阻塞。
升级时仍严格识别原有未压缩连接；压缩在下一次建立 SSH 连接时生效。

启动期间在既有时间预算内每秒检查新监听器。SSH 若恰好在两次快照之间开始监听，
先重新验证进程身份，再判断是否被其他程序占用；身份不明的进程仍拒绝接管。

建立 SSH 不以 `tailscale ping` 成功为前提：客户端在启动预算内直接尝试严格校验指纹的
SSH 服务。Ping 仅供诊断，不能代替服务器身份校验。

安装和手动启动最多等待两个启动预算加首次重试间隔，默认 65 秒、总上限 120 秒。
每次连接仍使用默认 30 秒预算，手动停止仍可取消等待。这样计划任务启动和一次短暂
失败后的重试有机会完成，避免安装器提前回滚即将成功的连接。

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
& $Client desktop-start
& $Client desktop-restart
& $Client desktop-stop
& $Client desktop-doctor
& $Client doctor --desktop --api
```

`desktop-stop` 只停止任务和托管隧道，不删除任务计划或 Codex 配置；随后可用
`desktop-start` 恢复，无需重新申请设备。任务使用 `IgnoreNew` 策略，防止计划任务
重复启动多个隧道进程。文件独占锁还会阻止手工启动第二个 supervisor。
停止标记优先于重连；重复 start/stop 安全，控制命令用互斥锁串行。
下次登录或显式重新启动计划任务时，新监控进程取得单实例锁后清除旧停止标记。

`desktop-status` 只读，不重启、不改配置，也不下载模型列表。
探测互斥忙时，仅复用相同受管 PID/启动时间对应的近期 Healthy 快照，标记
`HealthSource=recent_supervisor_probe`；没有可靠快照则返回 `Status=checking`，不把忙误报为失败。
`TunnelHealth=healthy` 只证明 Windows → SSH → Ubuntu Nginx 的轻量路径可用，
不证明模型能推理。默认 `UpstreamAPI=not_checked`。`desktop-doctor --api` 或
`doctor --desktop --api` 会单独检查 `/v1/models`，超时为 45 秒；它失败不会触发重连。
真实推理请通过官方 Codex 发起一次小请求，不把 models/healthz 成功当作推理验收。

常驻隧道日志位于：

```text
%USERPROFILE%\.codex-via-server\state\persistent-tunnel.log
```

日志为 JSONL；超过 1 MiB 后保留一份 `.1` 轮换，最新快照为同目录的
`tunnel-status.json`。记录 UTC/当地带时区时间、耗时、失败数、最后成功时间、
重连原因/轮次、PID、HTTP 状态与 SSH 退出码。不记录异常原文、完整命令行、
地址、指纹、密钥、HTTP 正文或 API 凭据。状态与日志使用当前用户保护 ACL。
旧版本已有日志不自动脱敏；分享前仍须检查。

新建 SSH 的 `SshError` 只记录固定类别：`server_not_responding`（保活无响应）、
`connection_reset`、`connection_closed`、`connection_refused`、`connection_timeout`、
`host_key_rejected` 或 `authentication_failed`。持续读取标准错误且限制内存，
原文不写入磁盘。使用 `LogLevel=INFO`，因为 ERROR 会屏蔽保活超时提示；
升级时仍识别旧 ERROR 连接。`none` 表示未观察到诊断；`unclassified` 表示未匹配已知类别。
`unavailable` 包括交接守护程序后复用的旧 SSH：新进程无法继承旧错误输出管道。
这些类别表示 SSH 观察到的症状，不能单独证明底层网络根因。

## 持续阻塞恢复与本地策略

新建和复用的受管 SSH 统一监控：Starting → Healthy → Suspect → Recovering，
重建失败时 Backoff；手动停止为 Stopped。SSH 退出立即恢复；进程仍活着但 HTTP
持续无响应也能恢复，不再只看进程或 TCP Established。

默认策略（秒）：

| 字段 | 默认值 | 允许范围 |
| --- | --- | --- |
| HealthTimeoutSec | 8 | 1–60 |
| HealthIntervalSec | 10 | 1–300 |
| ConsecutiveFailureThreshold | 3 次 | 2–20 次 |
| MinUnhealthyDurationSec | 45 | 10–600 |
| ActiveSessionGraceSec | 90 | 45–1800 |
| RestartCooldownSec | 60 | 10–600 |
| ReconnectBackoffSec | [5,10,20,40,60] | 1–10 个非递减整数，每项 1–300 |
| StartupBudgetSec | 30 | 5–120，且不小于 HealthTimeoutSec |
| PortReleaseTimeoutSec | 10 | 1–30 |

探测不重叠。每轮探测结束后等待 HealthIntervalSec。成功清零失败计数。
持续失败次数和 `max(MinUnhealthyDurationSec, ActiveSessionGraceSec)` 必须同时
达到阈值，且满足上次恢复成功后的冷却，才进一步验证。默认统一宽限为 90 秒。
回收前用 `max(45, HealthTimeoutSec)` 秒确认一次 `/v1/models`。API 仍响应时
记录 `gateway_responsive` 并重置失败窗口，保留 SSH；不会仅凭 `/healthz` 超时重建。
该确认不产生推理用量，也不代表模型响应流已完成。两个接口都失败时，如果旧 SSH
还有本机客户端连接，记录 `recovery_deferred` 并保留连接。TCP 检查失败也保留。
没有客户端时，在系统分配的临时 loopback 端口建立另一条 SSH，使用相同批准身份、
目标网关和严格指纹验证，以至少 45 秒的启动预算验证 `/v1/models`。备用验证失败
记录 `replacement_unavailable`，保留旧通道并按冷却间隔复核，避免断网时反复销毁。
验证成功后清理临时通道，再次确认旧连接没有客户端，才重建固定端口的 SSH。
记录 `replacement_verified` 后才可能出现 `transport_stalled`。
这不是无缝迁移：固定端口重建期间仍有短暂空窗，检查后新接入的连接仍有竞态。
空闲连接池也会延后切换；程序不把 TCP Established 当成真实推理进度。SSH 自行
退出时，在监控等待期间每秒检查并唤醒重连；正在进行的 HTTP 探测仍受其超时约束。
复用现有 SSH 时保留进程句柄，确保退出后能记录 PID 和退出码。手工停止仍优先于自愈。
连续建连失败使用封顶退避；恢复健康后重置退避阶梯，重连总轮次不清零。
启动预算包含主机指纹验证与 SSH 建立阶段。重建前重新核对 PID、启动时间、
批准身份与完整受限参数，并有界等待端口释放；无关进程占用时拒绝抢占。

可选文件 `%USERPROFILE%\.codex-via-server\config\runtime-policy.json` 允许部分覆盖：

```json
{"HealthTimeoutSec":12,"HealthIntervalSec":15}
```

只在受保护 config 目录创建普通文件，并使用模块的 `Set-CvsPrivateAcl` 设置当前
用户 ACL。配置不含秘密；未知字段、非法类型/范围、链接与畸形 JSON 会拒绝启动。
修改后执行 `desktop-restart` 生效。移走该文件并重启即恢复默认；不要在批准的
`connection-profile.json` 中添加这些字段。

日志固定代码：

| 代码 | 含义 |
| --- | --- |
| starting / healthy / recovered / stopped | 启动、探测通过、重连后首次通过、主动停止 |
| tailscale_unreachable | 有界 Tailscale reachability 检查失败 |
| ssh_host_key_unavailable | 扫描失败或找不到批准的主机指纹 |
| ssh_auth_or_start_failed | SSH 创建/认证阶段失败；不凭退出码推断唯一原因 |
| gateway_timeout / gateway_connection_failed | HTTP 超时（含 0 字节）/请求连接失败 |
| gateway_bad_status | 非空 204 或非 204 响应 |
| managed_process_exited | 受管进程已退出 |
| managed_listener_missing | 尚无受管监听器，不据此认定 SSH 已退出 |
| gateway_responsive | healthz 持续异常，但 API 确认仍响应，保留连接 |
| recovery_deferred | 旧 SSH 仍有客户端或无法检查，延后切换 |
| replacement_unavailable | 备用 SSH/API 验证失败，保留旧连接 |
| replacement_verified | 备用 SSH/API 通过且旧连接无客户端，准备重建 |
| transport_stalled | 次数、时长、冷却、API 与备用验证完成后，开始重建 |
| unmanaged_listener | 监听归属不匹配或安全清理/端口释放被拒绝 |
| health_probe_busy | 另一轻量探测正在执行，本次不累计失败 |
| restart_backoff / invalid_runtime_policy | 等待下一次重建/本地策略非法 |

这修复的是客户端自动恢复缺口，不会消除 DERP、高延迟或底层网络丢包。

## 排查 `Reconnecting... waiting for network`

依次执行：

```powershell
tailscale status
& $Client desktop-status
& $Client desktop-restart
& $Client desktop-doctor --api
```

同时确认桌面 provider 的地址是 `http://127.0.0.1:.../v1`，且
`requires_openai_auth = false`。不要手工替换批准配置中的端口、SSH 密钥、主机或
指纹；这些值变化时应重新申请并导入管理员批准的新配置。

客户端只有在监听进程确实是 `ssh.exe`，并且完整命令行同时匹配批准的设备密钥、
本地/远端端口、受限 SSH 参数以及批准的 `user@host` 时，才会复用或结束该进程。
仅仅能返回 `/v1/models` 的其他程序绝不会被认作本项目隧道。
停止与启动复用也会检查尚未监听的 SSH，避免在建连期间停止后遗留进程。
此时仍须完整参数匹配；停止前再次核对 PID、启动时间及端口归属。

出站 SSH 客户端使用非交互的 `-N -T`，并在 15 秒应用层存活探测之外显式设置
`TCPKeepAlive=yes`。安装脚本、状态目录和隧道日志都使用仅限当前用户的受保护 ACL。

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
