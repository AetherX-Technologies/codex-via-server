# ADR-001: Keep CLIProxyAPI credentials on the server

## Status

Accepted for v0.2 implementation planning.

## Date

2026-08-31

## Context

Version 0.1 retrieves the CLIProxyAPI bearer key over SSH and passes it to the
local Codex process. The generated profile prevents project commands from
inheriting the key, but a compromised desktop user can still inspect the Codex
process. The design must support devices that the server owner does not fully
trust.

## Decision

Add a loopback-only server gateway that overwrites the Authorization header with
the server-owned CLIProxyAPI key. Clients authenticate with independent,
restricted SSH keys and can only establish local forwarding to that gateway.

The Codex client profile contains no API key, `env_key`, or OpenAI-auth flag.

## Alternatives considered

### Continue sending the API key to clients

Rejected because the credential crosses into every client trust domain and a
single compromised device can steal a shared key.

### Build an automated mTLS enrollment service

Rejected for v0.2 because it adds a new authentication service and attack
surface that is not justified by the current device count.

## Consequences

- The real API key remains on the server.
- Every device can be approved and revoked independently.
- The server gains a streaming reverse-proxy dependency and restricted SSH
  account that must be monitored and backed up.
- An approved compromised device can still consume quota until its SSH key is
  revoked.
- v0.1 clients require a documented migration rather than an in-place profile
  edit.

The full design and migration gates are defined in
`docs/superpowers/specs/2026-08-31-v0.2-hardened-enrollment-design.md`.
