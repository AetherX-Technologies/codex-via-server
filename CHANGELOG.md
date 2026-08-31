# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
