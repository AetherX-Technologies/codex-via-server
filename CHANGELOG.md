# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add Windows PowerShell 7 enrollment, doctor, update, and uninstall commands.
- Add a current-user Scheduled Task for an optional persistent Codex desktop
  tunnel, including status, restart, and rollback commands.
- Add explicit start and stop commands for an installed Windows desktop tunnel.
- Add English and Simplified Chinese Windows desktop deployment and recovery
  documentation.
- Add a self-contained Windows x64 setup EXE builder with portable official
  runtimes, approved-device enrollment and real isolated installation tests.

### Security

- Reuse or terminate a Windows loopback listener only after its owning
  `ssh.exe` command line exactly matches the approved device key, forwarding
  ports, restricted SSH options, and server identity.
- Configure the managed desktop provider with loopback HTTP and
  `requires_openai_auth = false`, while preserving a one-time backup for exact
  rollback.
- Accept Tailscale DERP reachability without weakening SSH host-key pinning.
- Harden Windows persistence with `-N -T`, `TCPKeepAlive=yes`, duplicate-task
  suppression, and protected current-user ACLs for installed scripts and logs.

### Fixed

- Wake the Windows reconnect loop when new or reused SSH exits, retaining its
  PID and exit code instead of waiting out the next health-check interval.
- Protect active clients during failed health probes; verify a separate pinned
  SSH/API path before replacing an idle tunnel, keeping the old path if the
  candidate is unavailable.
- Retain bounded, fixed-category SSH stderr evidence for Windows reconnects;
  enable keepalive timeout messages while preserving existing managed sessions.
- Compress Windows SSH forwarding traffic to reduce shared DERP congestion
  during large Codex uploads; preserve exact ownership checks for existing
  uncompressed connections during upgrades.
- Recheck listener ownership when SSH binds between snapshots, and check new
  connections every second within the existing startup budget.
- Attempt pinned SSH directly instead of rejecting startup on a failed
  Tailscale ping while TCP forwarding can still be available.
- Let interactive installation and startup wait for a bounded automatic retry
  instead of rolling back a scheduled connection that is still starting.
- Persist explicit client, Codex and key directories in scheduled actions, and
  isolate task names for custom client homes without changing the default name.
- Resume a stopped tunnel on new task activation without letting duplicate
  supervisors clear a pending stop.
- Reuse and clean up an exactly matching SSH during startup, before it owns a
  listener, so interrupted setup cannot leave a delayed orphan tunnel.
- Confirm API responsiveness before recycling SSH after sustained health probe
  failures, preserving connections when only the health endpoint fails.
- Monitor new and reused Windows SSH tunnels with serialized, no-proxy `/healthz`
  probes rather than model-list downloads or process liveness alone. Recover
  sustained zero-byte stalls with conservative grace, cooldown and capped retry.
- Revalidate PID birth time and the approved restricted SSH contract before
  recovering reused listeners. Manual stop takes precedence over reconnect.
- Separate read-only `TunnelHealth` from optional `UpstreamAPI` diagnostics;
  desktop diagnostics no longer require `codex.exe`. Add bounded private JSONL
  logs and validated optional `config/runtime-policy.json` overrides.

## [0.1.0] - 2026-08-31

### Added

- Run the official Codex CLI locally through a short-lived SSH tunnel over
  Tailscale to a private CLIProxyAPI server.
- Verify the server SSH host key with a pinned SHA256 fingerprint.
- Fetch the CLIProxyAPI key into memory without storing it on the client.
- Prevent Codex-spawned project commands from inheriting the provider API key.
- Install an isolated Codex profile without changing the default provider.
- Provide English and Simplified Chinese documentation.

[0.1.0]: https://github.com/AetherX-Technologies/codex-via-server/releases/tag/v0.1.0
