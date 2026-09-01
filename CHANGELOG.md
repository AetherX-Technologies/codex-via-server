# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add Windows PowerShell 7 enrollment, doctor, update, and uninstall commands.
- Add a current-user Scheduled Task for an optional persistent Codex desktop
  tunnel, including status, restart, and rollback commands.
- Add English and Simplified Chinese Windows desktop deployment and recovery
  documentation.

### Security

- Reuse or terminate a Windows loopback listener only after its owning
  `ssh.exe` command line exactly matches the approved device key, forwarding
  ports, restricted SSH options, and server identity.
- Configure the managed desktop provider with loopback HTTP and
  `requires_openai_auth = false`, while preserving a one-time backup for exact
  rollback.
- Accept Tailscale DERP reachability without weakening SSH host-key pinning.

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
