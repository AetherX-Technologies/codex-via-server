# Codex via Server

[English](README.md) | **简体中文**

在本机运行官方 Codex CLI，通过 **Tailscale + SSH 本地端口转发**连接服务器上的
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)。本机不保存 CLIProxyAPI
API Key；日常使用时不需要远程操作服务器终端。

> English summary: run the official Codex CLI locally while securely forwarding
> its Responses API traffic to a private CLIProxyAPI server over Tailscale and
> SSH. The API key is fetched into memory for one Codex process and is never
> stored locally.

## 它解决什么问题

正常情况下，可以让 Codex直接访问服务器的 Tailscale地址：

```text
local Codex -> Tailscale IP:8317 -> CLIProxyAPI
```

但在部分双 TUN环境中，例如 macOS同时运行 Shadowrocket Enhanced/TUN 和
Tailscale，小请求可能正常，大型 Responses API POST却会被截断。CLIProxyAPI
随后只能看到不完整请求，并返回 `unexpected EOF`。

本项目不改变 Codex或 CLIProxyAPI，而是更换运输通道：

```text
local official Codex
  -> 127.0.0.1:18317
  -> SSH local forward over Tailscale
  -> private CLIProxyAPI server:8317
  -> server-side ChatGPT/Codex OAuth
```

SSH只负责可靠转发字节。Codex仍在本机运行，读取和修改的也是本机项目。本项目
不提供远程终端、远程 IDE或托管 Codex网页界面。

## 当前支持范围

- macOS。
- Windows PowerShell 7 CLI（v0.2 feature 分支）。
- Windows Codex 桌面端当前用户登录任务和常驻受限 SSH 隧道。
- 官方 Codex CLI。
- Tailscale IPv4地址 `100.64.0.0/10`。
- 通过 SSH密钥登录服务器。
- CLIProxyAPI使用 Responses API和 Bearer API Key。
- 交互式 `codex` 与 `codex exec` 参数透传。

Linux客户端也尚未验证。

Windows 的完整安装、设备申请、桌面端开机启动、断线恢复和回滚步骤见
[Windows Codex 桌面端常驻隧道](docs/WINDOWS-DESKTOP.zh-CN.md)。Windows 客户端
使用管理员批准的每设备独立密钥和 v0.2 服务器回环网关，不在本机保存真实 API Key。

## 前提条件

### 本机

1. 已安装并登录 Tailscale。
2. 已安装官方 Codex CLI，`codex --version` 可以运行。
3. 已有可登录服务器的 SSH私钥。
4. 服务器 Tailscale IP当前应通过 macOS `utun` 路由。

检查路由：

```bash
route -n get <SERVER_TAILSCALE_IP>
```

输出中的 `interface` 应为 `utunN`，而不是 `en0`、`en1` 或其他物理网卡。

### 服务器

1. SSH监听服务器的 Tailscale地址或可以通过该地址访问。
2. CLIProxyAPI已经运行并绑定到 Tailscale地址。
3. 客户端配置文件只允许所配置的 SSH用户读取，格式包含：

```text
CLIPROXY_BASE_URL=http://<SERVER_TAILSCALE_IP>:8317/v1
CLIPROXY_API_KEY=<SECRET>
```

默认用户是 `root`，默认路径为 `/root/cliproxyapi-client.env`，权限建议为 `600`。

## 安装

### 1. 克隆仓库

```bash
git clone https://github.com/AetherX-Technologies/codex-via-server.git
cd codex-via-server
```

### 2. 核对服务器 SSH指纹

在 DigitalOcean Console、云服务商控制台或其他已经可信的服务器终端执行：

```bash
for key in /etc/ssh/ssh_host_*_key.pub; do
  ssh-keygen -lf "$key" -E sha256
done
```

记录输出中的 `SHA256:...`。不要只相信同一条尚未验证的网络连接返回的指纹。
启动器接受 `ssh-keyscan` 返回的任意服务器 host key类型，但实际 key的 SHA256
指纹必须与固定值一致。

### 3. 运行安装器

```bash
bash install.sh \
  --host <SERVER_TAILSCALE_IP> \
  --identity "$HOME/.ssh/<SSH_PRIVATE_KEY>" \
  --fingerprint 'SHA256:<VERIFIED_FINGERPRINT>'
```

可选参数：

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--user` | `root` | SSH用户名 |
| `--ssh-port` | `22` | 服务器 Tailscale SSH端口 |
| `--api-host` | 与 `--host` 相同 | CLIProxyAPI监听地址 |
| `--api-port` | `8317` | CLIProxyAPI端口 |
| `--local-port` | `18317` | 本机回环监听端口 |
| `--remote-env-file` | `/root/cliproxyapi-client.env` | 服务器凭据文件 |
| `--profile` | `codex-via-server` | Codex profile名称 |

安装器不会要求或保存 CLIProxyAPI API Key。

如果 `--user` 不是 `root`，请单独创建只有该 SSH用户可读的凭据文件，并通过
`--remote-env-file` 指定路径。不要把默认的 root-only文件改成所有人可读。

### 4. 确认命令在 PATH中

安装位置为 `~/.local/bin/codex-via-server`。如果终端找不到命令，把下面一行加入
`~/.zshrc`：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

重新打开终端，或者执行：

```bash
source ~/.zshrc
```

## 使用

启动交互式官方 Codex：

```bash
codex-via-server
```

执行一次非交互任务：

```bash
codex-via-server exec --skip-git-repo-check "Reply only OK."
```

选择模型或传递其他官方 Codex参数：

```bash
codex-via-server exec \
  --skip-git-repo-check \
  --model <MODEL_ID> \
  "Summarize this project."
```

所有参数都会原样交给本机 `codex`。不带参数时启动 TUI；退出 Codex后，SSH隧道
和本地监听端口会自动关闭。

## 启动过程

每次执行 `codex-via-server` 时，启动器会：

1. 检查 Codex、SSH、curl和配置文件。
2. 确认服务器 Tailscale IP当前走 `utun`。
3. 确认本地端口没有被其他程序占用。
4. 从服务器读取 SSH host key并核对预先配置的 SHA256指纹。
5. 建立一条带 keepalive的 SSH ControlMaster连接。
6. 在同一条 SSH连接内读取服务器 API Key到内存。
7. 通过 `127.0.0.1` 隧道检查 `/v1/models`。
8. 使用独立 Codex profile启动本机官方 Codex。
9. Codex退出时清理环境变量、SSH连接和临时目录。

首次建立 SSH隧道通常增加一到数秒启动时间。隧道建立后没有额外公网绕路，正常
请求只增加本机回环和 SSH封装开销，通常是几毫秒级。

## 重启后的行为

启动器和 Codex profile会在重启后保留，不需要安装常驻隧道：

1. 让 Tailscale在登录时自动启动并恢复连接。
2. 需要 Codex时运行 `codex-via-server`。
3. 启动器自动创建新隧道，并在 Codex退出后清理。

本项目刻意不安装常驻 SSH隧道，避免永久 SSH会话、长期占用本地端口，以及睡眠、
切换网络后额外的恢复逻辑。

## 安装了哪些文件

```text
~/.local/bin/codex-via-server
~/.config/codex-via-server/config
~/.codex/codex-via-server.config.toml
```

- `config` 权限为 `600`，只保存地址、端口、SSH私钥路径和 host fingerprint。
- Codex profile权限为 `600`，只指向 `http://127.0.0.1:18317/v1`。
- 真实 CLIProxyAPI API Key不会写入这三个文件。
- 现有 `~/.codex/config.toml`、默认 provider和 `OPENAI_API_KEY`不会被修改。

## Codex provider配置

安装器创建一个独立 profile：

```toml
model_provider = "server_cliproxy"

[model_providers.server_cliproxy]
name = "CLIProxyAPI through a local SSH tunnel"
base_url = "http://127.0.0.1:18317/v1"
env_key = "SERVER_CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false

[shell_environment_policy.filters]
SERVER_CODEX_API_KEY = "exclude"
```

这里不能设置 `requires_openai_auth = true`，否则 Codex会尝试使用本机 ChatGPT登录
或其他已保存凭据，而不是本次进程临时获得的 `SERVER_CODEX_API_KEY`。

shell环境过滤器让 Codex自身可以读取 provider凭据，但 Codex在项目中启动的命令
不会继承这个变量。

自定义 provider和独立 profile的格式来自
[OpenAI Codex Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)。

## 安全设计

- 本地转发只监听 `127.0.0.1`，不会暴露给局域网或公网。
- 服务器 API继续只绑定 Tailscale地址。
- SSH禁用密码回退、交互式密码和额外身份文件。
- SSH禁用 ProxyCommand和 ProxyJump，避免继承意外代理路径。
- 每次连接都核对预先验证的 SSH SHA256 host fingerprint。
- API Key不进入仓库、本地配置、命令行参数或日志。
- Codex启动的项目命令不会继承 `SERVER_CODEX_API_KEY`。
- 临时目录权限受 `umask 077`保护。
- API Key仅存在于启动器内存和 Codex子进程环境中。

同一 macOS用户权限下运行的恶意进程可能检查其他进程环境。若本机已被同用户恶意
程序控制，`env_key`本身不能建立额外隔离边界。

## 常见故障

### `not Tailscale utun`

服务器 IP没有走 Tailscale。先确认 Tailscale显示 Connected，再检查：

```bash
route -n get <SERVER_TAILSCALE_IP>
```

双 TUN用户还应检查是否有一条精确的服务器 `/32` 路由指向当前 Tailscale `utun`。

### `server SSH fingerprint changed`

不要直接更新配置。先从云服务商控制台核对服务器当前 host fingerprint。只有确认是
服务器重装或合法换 key后，才重新运行安装器写入新指纹。

### `local port 18317 is already in use`

找出占用者：

```bash
lsof -nP -iTCP:18317 -sTCP:LISTEN
```

关闭冲突程序，或者重新安装并指定另一个 `--local-port`。

### `could not establish the SSH tunnel`

先测试最小 SSH连接：

```bash
ssh -o IdentitiesOnly=yes \
  -i "$HOME/.ssh/<SSH_PRIVATE_KEY>" \
  <SSH_USER>@<SERVER_TAILSCALE_IP>
```

如果私钥有密码且重启后没有加载到 macOS Keychain，可执行：

```bash
ssh-add --apple-load-keychain "$HOME/.ssh/<SSH_PRIVATE_KEY>"
```

### `server API key could not be read`

使用配置的 SSH用户登录服务器，检查凭据文件存在且当前用户可读：

```bash
stat <REMOTE_ENV_FILE>
```

如果该用户无法检查路径，请从可信的服务器特权控制台修正所有者、权限，或修正
`--remote-env-file` 路径。

不要把该文件内容粘贴到 Issue、README或公开日志。

### Codex出现 plugin同步 401警告

使用 API Key custom provider时，Codex可能无法访问需要本机 ChatGPT认证的远程
plugin catalog。这类警告不等于模型调用失败；以 provider是否显示
`server_cliproxy`、模型是否正常返回为准。

## 卸载

先退出所有 `codex-via-server` 会话，然后删除三个专用文件：

```bash
rm -f "$HOME/.local/bin/codex-via-server"
rm -f "$HOME/.config/codex-via-server/config"
rm -f "$HOME/.codex/codex-via-server.config.toml"
rmdir "$HOME/.config/codex-via-server" 2>/dev/null || true
```

卸载不会修改 `~/.codex/config.toml`、Tailscale、SSH私钥或服务器。

## 开发

运行本地测试：

```bash
bash tests/test.sh
```

测试覆盖 Bash语法、隔离 Home安装、文件权限、生成的 profile、非法输入和明显的
密钥泄漏。测试不会连接真实 Tailscale网络或服务器。

提交 Pull Request前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 安全问题报告

公开 Issue中不要粘贴以下内容：

- 真实服务器公网或 Tailscale地址。
- API Key、OAuth文件或 device auth响应。
- SSH私钥或私钥内容。
- 邮箱、订阅地址、VPN UUID或面板凭据。

如果怀疑存在安全漏洞，请使用 GitHub Security Advisory，而不是公开 Issue。
私下报告流程和安全边界见 [SECURITY.md](SECURITY.md)。

## 项目边界

本项目不是 OpenAI、Tailscale或 CLIProxyAPI的官方项目，也不安装服务器端
CLIProxyAPI。它只提供一个本地、短生命周期的 SSH转发启动器。

文中引用的 OpenAI文档只说明 Codex profile和 custom provider语法，不代表
OpenAI认可 CLIProxyAPI或通过第三方软件转发订阅凭据。使用者需要自行遵守所连接
服务的条款与政策。

官方 Codex配置说明：
[Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)

CLIProxyAPI：
[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)

## 许可证

本项目使用 [MIT License](LICENSE)。
