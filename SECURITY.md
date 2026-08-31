# Security Policy

## Supported versions

Security fixes are applied to the latest published release.

## Reporting a vulnerability

Use the repository's **Security** tab to open a private GitHub security advisory.
Do not report vulnerabilities in a public issue.

Include:

- The affected version.
- A concise description of the impact.
- Reproduction steps using placeholder addresses and credentials.
- The expected and observed behavior.
- A suggested fix, if available.

Do not include real API keys, OAuth files, SSH private keys, server addresses,
email addresses, VPN subscription data, or production logs. If a credential was
exposed while testing, revoke and rotate it before sending the report.

## Security boundaries

This project protects credentials from accidental local persistence and public
network exposure. It does not protect against a malicious process already
running as the same local user, a compromised server root account, or a
compromised Tailscale account.

The generated Codex profile explicitly removes `SERVER_CODEX_API_KEY` from the
environment inherited by project commands. Removing that filter would allow an
untrusted project command to read the provider credential.
