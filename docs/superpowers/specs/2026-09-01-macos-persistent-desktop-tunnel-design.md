# macOS persistent desktop tunnel design

Date: 2026-09-01

Status: approved design, pending implementation

Target release: `v0.2.0`

## Problem

The v0.2 restricted SSH tunnel currently exists only while
`codex-via-server` is running. The Codex desktop app starts independently, so
its configured endpoint `http://127.0.0.1:18319/v1` has no listener and reports
repeated connection failures.

The fix must keep the real CLIProxyAPI key on the server, survive login and
network changes, work with Tailscale and Shadowrocket enabled, and preserve the
existing CLI and rollback paths.

## Decision

Install a per-user macOS LaunchAgent that maintains the restricted SSH local
forward:

```text
Codex desktop
  -> 127.0.0.1:18319
  -> launchd-managed restricted SSH tunnel over Tailscale
  -> server 127.0.0.1:18319 gateway
  -> CLIProxyAPI
```

The LaunchAgent runs the system `ssh` binary directly. It uses the enrolled
per-device key, strict host-key checking, local forwarding only, no shell, no
agent forwarding, and SSH keepalives. `launchd` starts it at login and restarts
it after failures. No third-party daemon such as `autossh` is required.

## Components

### Persistent tunnel command

A generated local script reads and validates `connection-profile.json`, builds
a temporary verified `known_hosts` file from the approved fingerprints, and
executes:

```text
ssh -N -T -L 127.0.0.1:<local-port>:127.0.0.1:<gateway-port> ...
```

It refuses public or arbitrary forwarding destinations. It does not read,
store, or transmit the CLIProxyAPI bearer key.

### LaunchAgent

`~/Library/LaunchAgents/com.aetherx.codex-via-server-tunnel.plist` will use:

- `RunAtLoad` for login startup.
- `KeepAlive` for automatic recovery.
- a restart throttle to avoid tight failure loops.
- private log files under `~/.local/state/codex-via-server/`.
- the system SSH client and the enrolled device key.

Installation is idempotent. Existing files are backed up before replacement.

### Desktop Codex configuration

The installer backs up `~/.codex/config.toml`, then configures the desktop app's
active provider to use:

```text
http://127.0.0.1:18319/v1
```

The provider requires no real client-side API key. If Codex requires an API-key
environment variable syntactically, the LaunchAgent/app configuration uses a
non-secret fixed placeholder; the server gateway overwrites Authorization.

The existing `codex-via-server-v2` profile remains available for CLI use.

### CLI coexistence

`codex-via-server` first probes an existing healthy persistent tunnel. When it
is available, the CLI reuses it instead of failing because the local port is in
use. If no persistent tunnel exists, the current temporary-tunnel behavior
remains available.

### Management commands

The macOS client adds:

- `desktop-install`: install configuration and LaunchAgent.
- `desktop-status`: verify launchd state, listener, models endpoint, and profile.
- `desktop-restart`: reload the LaunchAgent and verify recovery.
- `desktop-uninstall`: unload it and restore the backed-up desktop configuration.

Uninstalling the desktop integration does not revoke the device. Device
revocation remains a separate administrator operation.

## Failure handling

- Tailscale unavailable: SSH exits; launchd retries with throttling.
- Network changes: SSH keepalive detects the dead session; launchd reconnects.
- Port occupied by an unrelated process: startup fails clearly and logs the
  owning process; it never kills arbitrary processes.
- Host fingerprint mismatch: tunnel refuses to connect.
- Invalid enrollment profile or unsafe file permissions: installation aborts
  before changing launchd or Codex configuration.
- Failed post-install health check: unload the new LaunchAgent and restore the
  previous Codex configuration.

## Verification

Automated tests must prove:

1. The generated SSH command permits only the enrolled loopback gateway.
2. The LaunchAgent starts at login and restarts after a simulated failure.
3. A running persistent tunnel is reused by the CLI.
4. `127.0.0.1:18319/v1/models` stays available after the invoking shell exits.
5. No real API key appears in client files, environment, logs, or process args.
6. Uninstall restores the previous desktop configuration.

The production acceptance check is the exact desktop failure signal: with no
interactive CLI running, port `18319` remains listening and a real low-volume
Responses request completes through the desktop endpoint.

## Rollback

Rollback unloads and removes the LaunchAgent, stops only its verified SSH
process, restores the timestamped `~/.codex/config.toml` backup, and leaves the
v0.1 launcher, server gateway, CLIProxyAPI, VPN, and enrolled device untouched.
