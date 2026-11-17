# Windows 一体安装助手

把 `CodexViaServer-Setup-win-x64.exe` 复制到另一台 Windows 11 x64 电脑。目标机预先安装 Tailscale，并登录服务器所在网络。无需 Git、Node、系统 PowerShell 7，也不安装 OpenSSH Server。

## 使用

1. 双击 EXE。首次解包需要约 1.5 GB 可用空间。程序自动检查 Tailscale，生成这台电脑独立的设备申请。
2. 点击“打开申请文件夹”，只把 `*.request.json` 发送给服务器管理员。
3. 收到管理员返回的 `*.connection.json` 后，退出其他 Codex 窗口，点击“导入批准并配置”。程序会备份原配置、严格校验批准身份和服务器指纹，配置 HTTP loopback、代理绕过和当前用户登录自启动。
4. 如尚未安装 Codex Desktop，点击“安装官方桌面端”。内置的是 Microsoft 官方在线安装器，可能要求确认，受 Microsoft Store 和单位策略约束。已有桌面端不会重复安装。
5. 重新打开 Codex Desktop。点击“检查连接”取得模型列表，选定模型后点击“低用量真实测试”。该测试使用官方 CLI 并会产生少量用量；桌面端还需自行发送一条消息确认。

管理员批准是服务器安全边界，不能由新电脑自行绕过。不要拿其他电脑的批准文件代替本机申请，也不要发送 `keys` 中的私钥。安装包不含服务器地址、真实指纹、连接配置或 API Key。

## 管理员审批入口

同一个 EXE 主界面点击“管理员审批”，也可以用 `--admin` 直接打开。它是可信管理员电脑上的图形工具，复用服务器已有 `/usr/local/sbin/codex-via-server-devices`；无需部署网页服务。申请与批准仍由你通过可信渠道传送，程序不会自动发送文件。

1. 在持有服务器管理员 SSH 私钥的 Windows 电脑打开此入口。点击“首次配置”，选择已可信核实的连接文件，程序读取服务器地址、端口、指纹和网关；输入管理员用户名，选择本机已有管理员私钥，保存 `admin.json`。只保存私钥路径，不复制或读取私钥内容。也可直接选择已有管理员配置，其密钥路径须为本机绝对路径。管理员与隧道暂限同一 SSH 地址和端口。
2. 点击“验证管理员连接”。只有服务器指纹、管理员身份及设备管理命令均验证通过，界面才显示通过。普通 `codex-tunnel` 账号和隧道密钥不能代替管理员；非 root 用户需要服务器已有的 `sudo -n` 设备管理权限。程序不会替你修改服务器权限。
3. 点击“选择申请并批准”，选申请电脑的 `*.request.json`，与申请人核对设备名、平台和公钥指纹，再确认批准并选择一个尚不存在的输出文件。
4. 服务器确认批准后生成 `*.connection.json`；传回申请电脑，在主界面“导入批准并配置”。批准后丢失返回结果时，保留同一申请再次操作，程序会检查同一身份已批准的记录并恢复导出。同名但不同公钥会拒绝，绝不覆盖。

管理员配置、连接配置及管理员私钥均不进入 EXE 或 GitHub。本机审批测试使用隔离身份与模拟服务器响应，不能替代真实新设备批准。未配置管理员身份时，该步骤仍未完成，程序不会显示为连接成功。

## 安装位置与管理

- 便携运行环境：`%LOCALAPPDATA%\CodexViaServer\packages\<安装包版本哈希>`。
- 设备身份和批准配置：`%USERPROFILE%\.codex-via-server`。
- Codex 配置：`%USERPROFILE%\.codex\config.toml`。连接地址按批准文件写为 `http://127.0.0.1:<local_port>/v1`，默认部署端口为 18319。
- 日志：`%USERPROFILE%\.codex-via-server\state\setup.log`、`persistent-tunnel.log`；仅记录脱敏状态码。
- 开始菜单“Codex via Server”：连接管理器和已带运行环境的 Codex CLI 入口。安装包关闭后隧道继续运行；下次登录由计划任务启动。

管理器包含检查、启动、停止、重启、移除自启动。停止只影响当前运行，下次登录仍会启动；新监控进程取得单实例锁后清除旧停止标记。移除自启动会恢复安装前的 Codex 配置；保留设备密钥、批准文件、运行环境和 CLI 快捷方式。程序不会删除桌面端或 Tailscale。

已有安装会保留。存在同名计划任务时拒绝覆盖；若确需迁移，请先从旧安装入口移除自启动，再导入批准配置。不得在隧道任务仍引用某个版本时删除该版本目录。任务保存明确的运行时、配置与密钥目录，不依赖安装进程的环境。自定义客户端目录使用独立任务名，避免覆盖默认安装。

健康探测持续失败达到宽限后，先确认 API 是否仍响应。若两者都失败，仍保护已有客户端连接；只有无客户端、独立备用隧道通过严格指纹和 API 验证，再次确认无客户端后，才替换原 SSH。备用连接失败则保留原连接。空闲连接池也可能推迟替换，固定端口重建会有短暂中断。

SSH 自行退出后，守护程序在等待期间每秒检查退出，按 5/10/20/40/60 秒退避自动重连；正在进行的 HTTP 探测最多仍受其超时约束。保活设置为 15 秒/3 次。本机独立断网实测约 59 秒判定 SSH 无响应、约 81 秒恢复，不是所有网络情况下的时间保证。

新建 SSH 只记录脱敏固定错误类别及退出码，不把标准错误原文、服务器地址、指纹或密钥写入日志。升级后复用的旧 SSH 无法补接错误输出，明确显示 `unavailable`；新诊断从后续新建 SSH 生效。详细状态、超时及限制见[常驻隧道说明](../../docs/WINDOWS-DESKTOP.zh-CN.md)。

## 构建

在 Windows x64 PowerShell 7 中使用 `Build.ps1`，显式提供来自官方发行包的目录：

```powershell
.\windows\setup\Build.ps1 `
  -PowerShellDirectory 'D:\official\powershell-7.6.4-win-x64' `
  -CodexDirectory 'D:\official\codex-0.167.0-win-x64' `
  -OpenSshDirectory 'D:\official\OpenSSH-Win64' `
  -DesktopInstaller 'D:\official\CodexInstaller.exe' `
  -OutputDirectory 'D:\build\codex-via-server'
```

Codex 目录应包含 `codex.exe`、`codex-code-mode-host.exe`、`codex-command-runner.exe`、`codex-windows-sandbox-setup.exe`、`codex-windows-sandbox-service.exe`、`codex-exec-server.exe`、`LICENSE` 和 `NOTICE`。GitHub 单文件发行附件的架构后缀需改为上述名称。另需官方 `@openai/codex@0.167.0-win32-x64` npm 包 `vendor/x86_64-pc-windows-msvc/codex-path/rg.exe` 和 ripgrep 的 `RIPGREP-LICENSE-MIT`、`RIPGREP-UNLICENSE`。该搜索工具上游未签名，构建脚本固定验证 SHA256；本次取得输入时已验证 npm 包的官方 SHA512 integrity。

构建器只收集指定发行目录和源码允许列表，并验证 Microsoft/OpenAI 数字签名。OpenSSH 仅包含三种客户端工具、DLL、许可文件；不打包 `sshd`、服务安装脚本、用户身份或配置。PowerShell 发行目录须是干净的官方发行包。使用 Windows 自带 .NET Framework C# 编译器，不需要 NuGet 或目标机器 SDK。

官方输入来源：

- PowerShell：[PowerShell/PowerShell](https://github.com/PowerShell/PowerShell/releases)
- Codex CLI：[openai/codex rust-v0.167.0](https://github.com/openai/codex/releases/tag/rust-v0.167.0)
- OpenSSH Client：[PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH/releases)
- Codex Desktop：[Microsoft Store 官方入口](https://apps.microsoft.com/detail/9plm9xgg6vks)，在线安装器 URL 与 OpenAI CLI 官方源码 `desktop_app/windows.rs` 一致。

构建产物不要放进公开源码仓库。附带 `build.json` 中的 EXE SHA256，便于复制后核对。安装器自身未签名，Windows SmartScreen 可能提示未知发布者；不要关闭系统安全功能。

## 自动验证

```powershell
$process = Start-Process .\CodexViaServer-Setup-win-x64.exe `
  -ArgumentList '--self-test "D:\test\a-new-empty-directory"' -PassThru -Wait
$process.ExitCode
```

自检目录必须不存在。程序实际解包并验证哈希、运行内置 PowerShell/Codex/SSH、生成独立测试密钥、校验申请复用、拒绝错误批准和凭据字段、验证 HTTP 配置幂等及卸载恢复。任务计划程序操作在独立测试进程中替换，不会操作真实登录任务。输出 `self-test.json` 和未显示窗口的界面预览 `setup-preview.png`；测试身份只在该隔离目录。

这不替代另一台电脑、真实设备批准、Microsoft Store 安装、桌面端消息和重启后的实际验收。

维护者可用 `Test-Installed.ps1` 做真实隔离安装测试。显式传入解包后的 `PackageDirectory`、本机的 `ApprovedProfile`、已有 `KeyDirectory` 和脱敏结果的 `EvidenceDirectory`。它注册实际任务、用独立端口测试 SSH 恢复、调用官方 CLI 发少量真实请求，再卸载并核对原配置及现用连接。批准文件仅写入受保护的本机测试目录，私钥只按原路径引用；测试留存目录含真实批准信息，不得上传。该测试使用当前已批准设备，不等于新电脑申请已获管理员批准。
