# Server foundation

The v0.2 server foundation is not yet a production migration command. It
installs and validates the loopback Nginx credential gateway and the restricted
`codex-tunnel` SSH account. It does not change the existing CLIProxyAPI listener.

Preview the target paths without changing state:

```bash
sudo ./server/install.sh \
  --api-key-file /root/cliproxyapi-client.env \
  --dry-run
```

Install and reload Nginx and OpenSSH:

```bash
sudo ./server/install.sh \
  --api-key-file /root/cliproxyapi-client.env
```

The key file must be a root-owned regular file with mode `0400` or `0600` and
contain exactly one `CLIPROXY_API_KEY=<value>` line. The installer does not
accept the key on the command line or print it.

Every non-dry-run installation writes a root-only backup under
`/var/backups/codex-via-server/`. Nginx and sshd configuration are validated
before reload. A failed validation or reload restores the previous files.

Use `--no-reload` only in an isolated test or when another controlled process
will reload both services after inspecting the validated files.

The installer also places the root-only device lifecycle command at:

```text
/usr/local/sbin/codex-via-server-devices
```

It accepts schema-version-1 enrollment JSON through a regular file or stdin and
supports `approve`, `list`, and exact `revoke` operations. Normal users should
use the trusted administrator wrapper in `admin/` instead of invoking the
server tool directly.

## Diagnostics and upgrades

Run the read-only foundation doctor before production cutover:

```bash
sudo /usr/local/sbin/codex-via-server-doctor --foundation
```

After CLIProxyAPI moves to loopback-only, use `--cutover` to enforce both
listener boundaries. The private canary sends one fixed low-output Responses
request through the gateway and prints only status, duration, and model.

CLIProxyAPI upgrades are explicit:

```bash
sudo ./server/update-cliproxyapi.sh \
  --version <VERSION> \
  --model <CANARY_MODEL>
```

The updater requires official release checksums, refuses versions below the
declared minimum, preserves OAuth state, runs doctor and canary, and restores
the previous binary, config, and unit if any gate fails.
