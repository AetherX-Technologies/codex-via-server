# Trusted administrator commands

Windows administrators can use the single-file setup application's **管理员审批**
button (or `--admin`). It validates the same server fingerprints, uses an existing
administrator identity, and invokes this repository's fixed server device tool.
See [Windows setup instructions](../windows/setup/README.zh-CN.md#管理员审批入口).
The application does not include administrator credentials or a request-delivery
service. An existing administrator identity is required; a restricted tunnel key
cannot approve devices.

`codex-via-server-admin` runs on a trusted administrator Mac. It uses the
existing administrator SSH identity to invoke only the fixed server device
tool. It never sends an arbitrary shell command and never reads the CLIProxyAPI
key.

On macOS, double-click `approve-device.command` beside the CLI. It reuses
`~/.config/codex-via-server/admin.json` (or asks you to select an existing
configuration), lets you select a request, and asks you to confirm the device,
platform and public-key fingerprint before approval. It requires `jq` and the
system OpenSSH client. Administrator credentials stay on the Mac. Requests and
approved connection files must be transferred privately; this is not an automatic
request-delivery service.

Create a mode-`0600` configuration from `admin.example.json` and set:

- Administrator SSH host, port, user, identity path, and verified fingerprints.
- Restricted tunnel host and port.
- Loopback gateway destination.
- Client profile defaults and minimum versions.

The administrator and restricted tunnel must use the same SSH host and port,
because the exported profile pins the verified administrator host keys. A
non-root administrator must already have passwordless permission for
`sudo -n /usr/local/sbin/codex-via-server-devices`; this tool does not grant it.

Approve an enrollment request and create a non-secret connection profile:

```bash
CODEX_VIA_SERVER_ADMIN_CONFIG="$HOME/.config/codex-via-server/admin.json" \
  ./admin/codex-via-server-admin \
    approve /path/to/enrollment-request.json \
    --output /absolute/path/to/connection-profile.json
```

Existing output files are never overwritten. If approval succeeded but the
response or output was lost, retry the original request with a new output path.
The tool exports only when the saved device ID, platform and public-key
fingerprint match. A conflicting identity is rejected. Exported files use mode
`0600`; no administrator key or API key is included.

List and revoke devices:

```bash
./admin/codex-via-server-admin list
./admin/codex-via-server-admin revoke <device-id>
```

Revocation removes only the exact device record. It does not rotate the
server-owned CLIProxyAPI key because that key never leaves the server.
