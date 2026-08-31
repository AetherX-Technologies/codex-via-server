# Contributing

Thanks for improving Codex via Server.

## Before opening a change

1. Keep the project focused on local Codex access through a short-lived private
   SSH tunnel.
2. Do not add real server addresses, API keys, OAuth files, SSH keys, email
   addresses, VPN subscription data, or copied production logs.
3. Open an issue before proposing a new platform, authentication mechanism, or
   long-running background service.

## Local checks

Run the complete test suite on macOS:

```bash
bash tests/test.sh
```

The test must pass before a pull request is opened. New behavior should include
an isolated test that does not require a real Tailscale network, server, API
key, or Codex account.

## Pull requests

- Keep each pull request focused on one problem.
- Explain the user-visible behavior and failure mode.
- Update both `README.md` and `README.zh-CN.md` when instructions change.
- Update `CHANGELOG.md` for user-visible changes.
- Never include credentials in screenshots or copied command output.

Security vulnerabilities belong in a private GitHub security advisory, not a
public issue or pull request. See [SECURITY.md](SECURITY.md).
