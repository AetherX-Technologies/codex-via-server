# Windows Codex desktop persistent tunnel

Windows support is currently available on the `feature/v0.2-hardened-enrollment-design`
branch. It uses a per-device restricted SSH key and a current-user Scheduled Task.
It does not install a system service and does not require administrator privileges
after the prerequisites are installed.

## Requirements

- PowerShell 7 (`pwsh`), not Windows PowerShell 5.1.
- Git, Tailscale, and the Windows OpenSSH client.
- Official Codex CLI `0.149.1` or newer.
- An approved, secret-free connection profile from the server administrator.

Install the prerequisites from an elevated PowerShell terminal if needed:

```powershell
winget install --id Microsoft.PowerShell -e
winget install --id Git.Git -e
winget install --id Tailscale.Tailscale -e
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Install the official Codex CLI from a normal PowerShell 7 terminal:

```powershell
irm https://chatgpt.com/codex/install.ps1 | iex
codex --version
tailscale status
```

## Install and enroll

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

Create one enrollment request per Windows device:

```powershell
$Request = Join-Path $HOME "windows-device.request.json"
& $Client setup --device-id windows-device --output $Request
```

Send only the request JSON to the administrator. Never send the private key from
`$HOME\.codex-via-server\keys`. After the administrator returns the connection
profile, import it:

```powershell
& $Client enroll "$HOME\Downloads\windows-device.connection.json"
& $Client doctor
```

Connection profiles contain no API key, but they still contain private network
metadata and must not be committed to a public repository.

## Enable Codex desktop at logon

Close Codex desktop before the first install, then run:

```powershell
& $Client desktop-install
& $Client desktop-status
```

`desktop-install` performs these actions:

1. Backs up `$HOME\.codex\config.toml` once.
2. Adds a clearly marked `codex_via_server_desktop` provider.
3. Registers the hidden `CodexViaServer Persistent Tunnel` Scheduled Task for
   the current user at logon.
4. Starts the restricted SSH tunnel immediately.
5. Verifies that `/v1/models` is available through the loopback endpoint.

The task restarts after failures and has no execution time limit. Tailscale DERP
connectivity is accepted; the client does not require a direct peer-to-peer path.

The managed desktop provider is equivalent to:

```toml
model_provider = "codex_via_server_desktop"

[model_providers.codex_via_server_desktop]
name = "Codex via Server persistent tunnel"
base_url = "http://127.0.0.1:<APPROVED_LOCAL_PORT>/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = false
```

The loopback URL intentionally uses `http://`. SSH already protects the traffic
after it leaves the machine. `https://127.0.0.1:...` fails because the local SSH
listener is not a TLS server. `requires_openai_auth = true` is also incorrect for
this server-side credential-injection design.

## Operations

```powershell
& $Client desktop-status
& $Client desktop-start
& $Client desktop-restart
& $Client desktop-stop
& $Client doctor --live --yes --model <MODEL_ID>
```

`desktop-stop` leaves the Scheduled Task and Codex configuration installed, so
`desktop-start` can bring the tunnel back without re-enrollment. The task uses
`IgnoreNew` instance policy to prevent duplicate scheduled tunnel processes.

The persistent tunnel log is stored at:

```text
%USERPROFILE%\.codex-via-server\state\persistent-tunnel.log
```

The log records lifecycle and error type information, not connection profiles,
keys, request bodies, or API credentials. Review it before sharing and remove any
environment-specific identifiers.

## Troubleshooting `Reconnecting... waiting for network`

Run these checks in order:

```powershell
tailscale status
& $Client desktop-status
& $Client desktop-restart
& $Client doctor
```

Also verify the desktop provider has an `http://127.0.0.1:.../v1` base URL and
`requires_openai_auth = false`. Do not replace the approved port, SSH key, host,
or fingerprints by hand. Re-enroll with a newly approved profile when those
values change.

The client will reuse or terminate a listener only when its process is `ssh.exe`
and its complete command line matches the approved key, local and remote ports,
restricted SSH options, and approved `user@host`. A program that merely returns
a valid-looking `/v1/models` response is never treated as project-owned.

The outbound SSH client is non-interactive (`-N -T`) and explicitly enables
`TCPKeepAlive=yes` together with the application-level 15-second server-alive
probe. Installed scripts, the state directory, and tunnel logs use protected
current-user ACLs.

## Roll back

```powershell
& $Client desktop-uninstall
```

This removes the Scheduled Task, stops only an exactly matching managed SSH
tunnel, and restores the pre-install Codex configuration. It does not revoke the
device key on the server.

To remove the complete client while preserving the device key:

```powershell
& $Client uninstall
```

Device-key removal requires explicit confirmation:

```powershell
& $Client uninstall --remove-device-key --yes
```
