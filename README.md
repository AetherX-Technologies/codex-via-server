# Codex via Server

**English** | [简体中文](README.zh-CN.md)

[![CI](https://github.com/AetherX-Technologies/codex-via-server/actions/workflows/test.yml/badge.svg)](https://github.com/AetherX-Technologies/codex-via-server/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#requirements)

Run the official Codex CLI on your Mac while routing its Responses API traffic
through a private [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
server over Tailscale and an SSH local-forward tunnel.

Codex still runs locally and works on local files. SSH only transports API
traffic. The CLIProxyAPI key is fetched into memory for one Codex process and is
never stored on the client.

## Why this exists

A direct private connection normally looks like this:

```text
local Codex -> Tailscale IP:8317 -> CLIProxyAPI
```

On some dual-TUN macOS setups, such as Shadowrocket Enhanced/TUN running next to
Tailscale, small requests succeed while larger Responses API POST bodies are
truncated. CLIProxyAPI then receives an incomplete request and may report
`unexpected EOF`.

This project keeps Codex local but changes the transport path:

```text
local official Codex
  -> 127.0.0.1:18317
  -> SSH local forward over Tailscale
  -> private CLIProxyAPI server:8317
  -> server-side ChatGPT/Codex OAuth
```

The tunnel avoids sending the Codex HTTP request directly through the competing
packet-tunnel path. It does not provide a remote terminal, remote IDE, or hosted
Codex user interface.

## Features

- Runs the official Codex CLI locally.
- Uses a dedicated Codex profile without changing your default provider.
- Opens one short-lived SSH ControlMaster connection over Tailscale.
- Verifies the server SSH host key against a pinned SHA256 fingerprint.
- Fetches the CLIProxyAPI key through the authenticated SSH connection.
- Keeps the API key out of local files, command-line arguments, and logs.
- Binds the forwarded port to `127.0.0.1` only.
- Passes all arguments through to the official `codex` executable.
- Cleans up the tunnel, environment variable, and temporary files on exit.
- Refuses to start when the server is not routed through a macOS `utun` device.

## Current support

| Capability | Status |
|---|---|
| macOS | Supported and tested |
| Official Codex CLI | Supported |
| Tailscale IPv4 (`100.64.0.0/10`) | Required |
| SSH key authentication | Required |
| CLIProxyAPI Responses API | Required |
| Windows | Not yet implemented or claimed |
| Linux client | Not yet tested |

## Requirements

### Mac

1. Tailscale is installed, signed in, and connected.
2. The official Codex CLI is installed and `codex --version` succeeds.
3. You have an SSH private key authorized on the server.
4. The server Tailscale address is currently routed through a macOS `utun`
   interface.

Check the route:

```bash
route -n get <SERVER_TAILSCALE_IP>
```

The `interface` line must show `utunN`, not `en0`, `en1`, or another physical
interface.

### Server

1. SSH is reachable through the server's Tailscale address.
2. CLIProxyAPI is running and bound to a Tailscale address.
3. The SSH user can read a permission-restricted client environment file with this
   shape:

```text
CLIPROXY_BASE_URL=http://<SERVER_TAILSCALE_IP>:8317/v1
CLIPROXY_API_KEY=<SECRET>
```

The default path is `/root/cliproxyapi-client.env`. Recommended permissions are
`0600`.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/AetherX-Technologies/codex-via-server.git
cd codex-via-server
```

### 2. Verify the server SSH fingerprint

Use a trusted server console, such as your cloud provider's web console, and run:

```bash
for key in /etc/ssh/ssh_host_*_key.pub; do
  ssh-keygen -lf "$key" -E sha256
done
```

Record the `SHA256:...` value. Do not obtain the expected fingerprint only
through the same unverified network path you are trying to authenticate.
The launcher accepts any server host-key type returned by `ssh-keyscan` as long
as its SHA256 fingerprint matches the pinned value.

### 3. Run the installer

```bash
bash install.sh \
  --host <SERVER_TAILSCALE_IP> \
  --identity "$HOME/.ssh/<SSH_PRIVATE_KEY>" \
  --fingerprint 'SHA256:<VERIFIED_FINGERPRINT>'
```

Optional installer arguments:

| Argument | Default | Purpose |
|---|---:|---|
| `--user` | `root` | SSH username |
| `--ssh-port` | `22` | SSH port reachable through Tailscale |
| `--api-host` | Same as `--host` | CLIProxyAPI bind address |
| `--api-port` | `8317` | CLIProxyAPI port |
| `--local-port` | `18317` | Local loopback port |
| `--remote-env-file` | `/root/cliproxyapi-client.env` | Server credential file |
| `--profile` | `codex-via-server` | Codex profile name |

The installer never asks for or stores the CLIProxyAPI key.

If `--user` is not `root`, create a separate credential file that only that SSH
user can read and pass its path with `--remote-env-file`. Do not make the
default root-only file world-readable.

### 4. Check your PATH

The launcher is installed at `~/.local/bin/codex-via-server`. If your shell
cannot find it, add this line to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new terminal or run:

```bash
source ~/.zshrc
```

## Usage

Start the interactive official Codex CLI:

```bash
codex-via-server
```

Run a non-interactive task:

```bash
codex-via-server exec --skip-git-repo-check "Reply only OK."
```

Pass a model or any other supported Codex argument:

```bash
codex-via-server exec \
  --skip-git-repo-check \
  --model <MODEL_ID> \
  "Summarize this project."
```

Every argument is forwarded unchanged to the local `codex` executable. The
tunnel closes when Codex exits.

## What happens at startup

Each `codex-via-server` invocation:

1. Validates its configuration, dependencies, SSH identity, and Codex profile.
2. Confirms that the server Tailscale IP is routed through `utun`.
3. Confirms that the configured local port is available.
4. Reads the server SSH host keys and keeps only the key matching the pinned
   SHA256 fingerprint.
5. Opens an SSH ControlMaster connection with local forwarding and keepalives.
6. Reads the CLIProxyAPI key through another channel on that same connection.
7. Checks `/v1/models` through the local tunnel without placing the key in the
   `curl` command line.
8. Exports `SERVER_CODEX_API_KEY` only to the local Codex child process.
9. Closes the SSH connection and removes temporary state when Codex exits.

The SSH handshake usually adds one to several seconds at startup. Once the
tunnel is open, there is no extra public-network hop. Loopback forwarding and
SSH framing usually add only a few milliseconds.

## Reboot behavior

The launcher and Codex profile persist across reboots. No always-on background
tunnel is required:

1. Configure Tailscale to start and reconnect at login.
2. Run `codex-via-server` whenever you need Codex.
3. The launcher creates a fresh tunnel and removes it at exit.

An always-on tunnel is intentionally not installed. Keeping the tunnel
on-demand avoids a permanent SSH session, a permanently occupied local port,
and extra recovery logic after network changes or sleep.

## Installed files

```text
~/.local/bin/codex-via-server
~/.config/codex-via-server/config
~/.codex/codex-via-server.config.toml
```

- `config` is mode `0600` and contains only connection metadata, the SSH key
  path, and the expected host fingerprint.
- The Codex profile is mode `0600` and points to the local loopback URL.
- The real CLIProxyAPI key is not written to any installed file.
- `~/.codex/config.toml`, your default provider, and `OPENAI_API_KEY` are not
  modified.

## Generated Codex profile

The installer creates a separate profile:

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

Do not add `requires_openai_auth = true`. That would make Codex use a local
ChatGPT login or another stored credential instead of the temporary
`SERVER_CODEX_API_KEY` supplied by this launcher.

The shell environment filter keeps the provider credential available to Codex
itself while removing it from commands that Codex launches inside a project.

The profile and custom-provider format follows the official
[OpenAI Codex Advanced Configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)
documentation.

## Security model

- The local forward listens only on `127.0.0.1`.
- The server API remains private on Tailscale.
- SSH password fallback, keyboard-interactive authentication, extra identities,
  proxy commands, and proxy jumps are disabled.
- Every connection verifies a pre-pinned SSH SHA256 host fingerprint.
- The API key is not placed in repository files, local configuration,
  command-line arguments, or launcher logs.
- Codex-spawned project commands do not inherit `SERVER_CODEX_API_KEY`.
- Temporary files are protected by `umask 077`.
- The key exists only in launcher memory and the Codex child environment.

A malicious process running as the same macOS user may be able to inspect the
environment of other user processes. The Codex `env_key` mechanism cannot
provide isolation after the local user account itself is compromised.

## Troubleshooting

### `not Tailscale utun`

The server address is not using Tailscale. Confirm that Tailscale is connected:

```bash
route -n get <SERVER_TAILSCALE_IP>
```

Dual-TUN users may need an exact `/32` route for the server address through the
current Tailscale `utun` interface.

### `server SSH fingerprint changed`

Do not update the configured fingerprint blindly. Verify the current host key
from your cloud provider's trusted console. Re-run the installer only after you
confirm a legitimate server rebuild or host-key rotation.

### `local port 18317 is already in use`

Find the listener:

```bash
lsof -nP -iTCP:18317 -sTCP:LISTEN
```

Stop the conflicting process or reinstall with another `--local-port`.

### `could not establish the SSH tunnel`

Test a minimal SSH connection:

```bash
ssh -o IdentitiesOnly=yes \
  -i "$HOME/.ssh/<SSH_PRIVATE_KEY>" \
  <SSH_USER>@<SERVER_TAILSCALE_IP>
```

If the key is passphrase-protected and was not restored after a reboot, load it
into the macOS keychain-backed agent:

```bash
ssh-add --apple-load-keychain "$HOME/.ssh/<SSH_PRIVATE_KEY>"
```

### `server API key could not be read`

Connect as the configured SSH user and check that the configured file exists and
is readable:

```bash
stat <REMOTE_ENV_FILE>
```

If that user cannot inspect the path, use a trusted privileged server console
to correct the owner, permissions, or configured `--remote-env-file` path.

Never paste that file's contents into an issue, README, screenshot, or public
log.

### Plugin catalog warnings

An API-key custom provider may not authenticate remote Codex plugin-catalog
requests that require a local ChatGPT login. Such warnings do not mean the model
request failed. Confirm that Codex reports provider `server_cliproxy` and that
the selected model returns a response.

## Uninstall

Exit every `codex-via-server` session, then remove the three dedicated files:

```bash
rm -f "$HOME/.local/bin/codex-via-server"
rm -f "$HOME/.config/codex-via-server/config"
rm -f "$HOME/.codex/codex-via-server.config.toml"
rmdir "$HOME/.config/codex-via-server" 2>/dev/null || true
```

Uninstalling does not change `~/.codex/config.toml`, Tailscale, the SSH private
key, or the server.

## Development

Run local checks:

```bash
bash tests/test.sh
```

The test suite checks Bash syntax, installer behavior in an isolated home,
permissions, generated profile contents, invalid inputs, and obvious secret
leaks. It does not connect to a real Tailscale network or server.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Responsible disclosure

Do not include real API keys, OAuth files, server addresses, SSH private keys,
email addresses, or VPN subscription data in public issues. For a suspected
security issue, open a GitHub security advisory instead of a public issue.
See [SECURITY.md](SECURITY.md) for the private reporting process and security
boundaries.

## Project scope

This is not an official OpenAI, Tailscale, or CLIProxyAPI project. It does not
install or manage server-side CLIProxyAPI. It provides only a short-lived local
SSH forwarding launcher for an existing private server.

The OpenAI documentation linked above describes Codex profile and custom
provider syntax. It does not endorse CLIProxyAPI or forwarding subscription
credentials through third-party software. Users are responsible for complying
with the terms and policies of every service they connect.

## License

Released under the [MIT License](LICENSE).
