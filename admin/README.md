# Trusted administrator commands

`codex-via-server-admin` runs on a trusted administrator Mac. It uses the
existing administrator SSH identity to invoke only the fixed server device
tool. It never sends an arbitrary shell command and never reads the CLIProxyAPI
key.

Create a mode-`0600` configuration from `admin.example.json` and set:

- Administrator SSH host, port, user, identity path, and verified fingerprints.
- Restricted tunnel host and port.
- Loopback gateway destination.
- Client profile defaults and minimum versions.

Approve an enrollment request and create a non-secret connection profile:

```bash
CODEX_VIA_SERVER_ADMIN_CONFIG="$HOME/.config/codex-via-server/admin.json" \
  ./admin/codex-via-server-admin \
    approve /path/to/enrollment-request.json \
    --output /absolute/path/to/connection-profile.json
```

List and revoke devices:

```bash
./admin/codex-via-server-admin list
./admin/codex-via-server-admin revoke <device-id>
```

Revocation removes only the exact device record. It does not rotate the
server-owned CLIProxyAPI key because that key never leaves the server.
