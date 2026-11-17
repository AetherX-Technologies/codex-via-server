# Windows Codex desktop persistent tunnel

Windows support and the latest recovery fixes are available on the `fix/windows-persistent-desktop-tunnel`
branch. It uses a per-device restricted SSH key and a current-user Scheduled Task.
It does not install a system service and does not require administrator privileges
after the prerequisites are installed.

For the bundled EXE preview, follow the [single-file setup guide](../windows/setup/README.zh-CN.md).
The manual installation below requires the individual tools.

## Requirements

- PowerShell 7 (`pwsh`), not Windows PowerShell 5.1.
- Git, Tailscale, and the Windows OpenSSH client.
- Official Codex CLI `0.149.1` or newer for CLI use; desktop-only diagnostics do not depend on it.
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
5. Verifies listener ownership and an empty HTTP 204 from loopback `/healthz`.

The task restarts after failures and has no execution time limit. Tailscale DERP
connectivity is accepted; the client does not require a direct peer-to-peer path.

Windows SSH enables `-C` compression to reduce DERP traffic from large Codex text
requests. This mitigates congestion; it cannot eliminate relay outages or stalls
from incompressible traffic. Upgrades retain strict ownership checks for existing
uncompressed connections; compression takes effect when SSH next connects.

During startup, the supervisor checks new listeners every second within the
existing startup budget. If SSH binds between listener snapshots, ownership is
checked again before reporting a conflicting program; unknown owners still fail
closed.

SSH startup does not require a successful `tailscale ping`: the client attempts
the pinned SSH service directly within the startup budget. Ping remains a
diagnostic and cannot override host-key validation.

Installation and interactive start wait for up to two startup budgets plus the
first reconnect backoff (65 seconds by default, capped at 120). Each connection
attempt retains its 30-second default budget, and manual stop still cancels the
wait. This allows scheduled startup and one transient retry to finish before
installation rolls back.

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
& $Client desktop-doctor
& $Client doctor --desktop --api
```

`desktop-stop` leaves the Scheduled Task and Codex configuration installed, so
`desktop-start` can bring the tunnel back without re-enrollment. The task uses
`IgnoreNew` instance policy plus an exclusive supervisor file lock to prevent
duplicates. A persistent stop marker wins over retry, and a control mutex
serializes idempotent start/stop/restart operations.
A new logon or explicit task activation clears the old stop marker only after
acquiring the supervisor lock; duplicate activations cannot cancel a stop.

`desktop-status` is read-only: no restart, configuration change or models download.
When a probe is busy, only a recent Healthy snapshot for the same managed PID
and birth time may be reused (`HealthSource=recent_supervisor_probe`). Otherwise
status is `checking`, not a false transport failure.
`TunnelHealth=healthy` proves only the Windows → SSH → Ubuntu Nginx path, not
inference. `UpstreamAPI=not_checked` is the default. `desktop-doctor --api` or
`doctor --desktop --api` separately checks `/v1/models` with a 45-second timeout.
An API failure does not restart SSH. Test real inference separately with official Codex.

The persistent tunnel log is stored at:

```text
%USERPROFILE%\.codex-via-server\state\persistent-tunnel.log
```

The JSONL log rotates above 1 MiB, retaining one `.1` file. `tunnel-status.json`
contains the latest snapshot. Fields include UTC/local zoned time, duration,
failure count, last success, reconnect reason/attempt, PID, HTTP status and SSH
exit code. No exception text, command line, address, fingerprint, key, HTTP body
or API credential is logged. Files use protected current-user ACLs. Existing
legacy logs are not retroactively sanitized; review before sharing.

For newly created SSH processes, `SshError` records a fixed category such as
`server_not_responding`, `connection_reset`, `connection_closed`,
`connection_refused`, `connection_timeout`, `host_key_rejected` or
`authentication_failed`. Standard error is drained with bounded memory and its
raw text is never written to disk. SSH uses `LogLevel=INFO` because its keepalive
timeout message is suppressed at ERROR. The previous ERROR contract remains
recognized during upgrade. `none` means no diagnostic was observed;
`unclassified` means the text did not match a known category. `unavailable`
includes a process reused after supervisor handoff: its old stderr pipe cannot
be inherited. A category identifies an SSH symptom, not the underlying network cause.

## Stalled forwarding recovery and local policy

New and reused SSH connections share a monitor: Starting → Healthy → Suspect →
Recovering; failed creation enters Backoff; manual stop enters Stopped. An exited
SSH is recovered immediately. A live process with blocked HTTP forwarding is
also detected; TCP Established is not treated as healthy or active inference.

| Setting | Default | Accepted range |
| --- | --- | --- |
| HealthTimeoutSec | 8 | 1–60 seconds |
| HealthIntervalSec | 10 | 1–300 seconds |
| ConsecutiveFailureThreshold | 3 | 2–20 failures |
| MinUnhealthyDurationSec | 45 | 10–600 seconds |
| ActiveSessionGraceSec | 90 | 45–1800 seconds |
| RestartCooldownSec | 60 | 10–600 seconds |
| ReconnectBackoffSec | [5,10,20,40,60] | 1–10 nondecreasing integers, 1–300 seconds each |
| StartupBudgetSec | 30 | 5–120 seconds, at least HealthTimeoutSec |
| PortReleaseTimeoutSec | 10 | 1–30 seconds |

Probes never overlap. The interval starts after each probe completes. Success
resets failures. Both the failure count and `max(MinUnhealthyDurationSec,
ActiveSessionGraceSec)` must be reached, with cooldown since recovery success,
before checking a live suspected SSH further. The default uniform grace is 90 seconds;
before teardown, one `/v1/models` confirmation is bounded by
`max(45, HealthTimeoutSec)` seconds. An answering API records `gateway_responsive`
and resets the failure window while keeping SSH. A failed health endpoint alone
does not cause teardown. This does not consume inference tokens or prove a model
stream completed. If both endpoints fail, established clients on the managed
loopback port defer recovery (`recovery_deferred`); TCP inspection errors also
preserve SSH. When no clients remain, a temporary loopback SSH verifies the same
approved destination, identity and pinned host key, with a startup budget of at
least 45 seconds and a real models API check. A failed candidate records
`replacement_unavailable` and preserves the old SSH; cooldown bounds retries.
After successful candidate cleanup, clients are checked again before rebuilding
the fixed port (`replacement_verified`, then `transport_stalled`). This is not
seamless migration: rebinding has a short outage and a new client may race the
last check. Idle pooled connections can delay recovery; established TCP is not
proof of inference progress. During monitor delays, SSH exit is checked at least
once per second; an HTTP probe already in progress retains its timeout. Reused
SSH handles retain the PID and exit code for diagnosis. Manual stop takes priority.
Repeated creation failures use capped backoff;
a healthy channel resets its step, not the total reconnect counter. Startup
budget includes pinned-host-key verification and SSH establishment. Cleanup revalidates
PID, birth time and the entire approved SSH contract, then waits boundedly for
port release. Unrelated listeners are never displaced.

Optional `%USERPROFILE%\.codex-via-server\config\runtime-policy.json` accepts partial overrides:

```json
{"HealthTimeoutSec":12,"HealthIntervalSec":15}
```

Create a regular file in the protected config directory and apply the module's
`Set-CvsPrivateAcl` for a current-user ACL. Unknown fields, invalid types/ranges,
links and malformed JSON fail closed. Run `desktop-restart` to apply. Move the
file away and restart to restore defaults. Never add policy fields to the
administrator-approved connection profile.

Fixed diagnostic codes:

| Code | Trigger |
| --- | --- |
| starting / healthy / recovered / stopped | Start, successful probe, first success after reconnect, manual stop |
| tailscale_unreachable | Bounded Tailscale reachability failure |
| ssh_host_key_unavailable | Scan failure or no approved pinned host key |
| ssh_auth_or_start_failed | SSH creation/authentication-stage failure; exit code alone is not a cause |
| gateway_timeout / gateway_connection_failed | HTTP timeout including zero bytes / request connection failure |
| gateway_bad_status | Nonempty 204 or any non-204 response |
| managed_process_exited | Managed process exited |
| managed_listener_missing | No managed listener yet; not evidence of SSH exit |
| gateway_responsive | Health endpoint failed but API confirmation answered; keep SSH |
| recovery_deferred | Clients remain or TCP inspection failed; preserve SSH |
| replacement_unavailable | Candidate SSH/API failed; preserve old SSH |
| replacement_verified | Candidate SSH/API passed and no clients remain |
| transport_stalled | Failure thresholds and candidate verification permit recovery |
| unmanaged_listener | Owner mismatch, refused cleanup or port release failure |
| health_probe_busy | Another probe holds the lock; no failure counted |
| restart_backoff / invalid_runtime_policy | Bounded retry delay / rejected local policy |

This repairs automatic recovery, not DERP latency, packet loss or network policy.

## Troubleshooting `Reconnecting... waiting for network`

Run these checks in order:

```powershell
tailscale status
& $Client desktop-status
& $Client desktop-restart
& $Client desktop-doctor --api
```

Also verify the desktop provider has an `http://127.0.0.1:.../v1` base URL and
`requires_openai_auth = false`. Do not replace the approved port, SSH key, host,
or fingerprints by hand. Re-enroll with a newly approved profile when those
values change.

The client will reuse or terminate a listener only when its process is `ssh.exe`
and its complete command line matches the approved key, local and remote ports,
restricted SSH options, and approved `user@host`. A program that merely returns
a valid-looking `/v1/models` response is never treated as project-owned.
Startup reuse and stop cleanup also find exactly matching SSH processes before
they bind a listener. Cleanup still revalidates birth time, the complete SSH
contract, and the absence of an unrelated port owner before termination.

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
