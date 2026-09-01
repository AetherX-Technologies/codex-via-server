# Implementation Plan: v0.2 hardened enrollment

## Overview

Version 0.2 replaces client-side CLIProxyAPI key retrieval with a loopback-only
server gateway and per-device restricted SSH forwarding. It adds a shared
enrollment schema, macOS and Windows clients, administrator approval and
revocation, compatibility diagnostics, transactional server upgrades, and a
side-by-side migration from v0.1.

No task may remove the v0.1 path until the v0.2 path passes the same real Codex
request and rollback checks.

## Architecture decisions

- The CLIProxyAPI bearer key remains on the server and is injected by Nginx.
- Clients authenticate with independent SSH keys and receive no provider secret.
- The restricted SSH account can forward only to one loopback gateway port.
- macOS Bash and Windows PowerShell consume the same versioned JSON schemas.
- Codex uses a minimal custom provider without `env_key`, model catalog, or
  `requires_openai_auth`.
- `doctor` is read-only; `update` is explicit and server upgrades are
  transactional.
- Compatibility support is declared only after CI and one private live canary.
- Production migration is additive and gated by explicit human checkpoints.

## Dependency graph

```text
JSON schemas + compatibility contract
  ├── server gateway + restricted SSH
  │   ├── administrator device lifecycle
  │   ├── server doctor and canary
  │   └── transactional CLIProxyAPI update
  ├── macOS client
  └── Windows client
       └── cross-platform integration CI
            └── server side-by-side deployment
                 └── Mac pilot
                      └── Windows pilot
                           └── loopback-only cutover
                                └── v0.2 release
```

## Phase 1: Contracts and test foundations

### Task 1: Define versioned enrollment schemas

**Description:** Define enrollment-request, connection-profile, and
compatibility-manifest JSON Schemas before writing platform implementations.

**Acceptance criteria:**

- [ ] Every schema rejects unknown fields and malformed device identifiers.
- [ ] Private keys, API keys, OAuth data, and arbitrary command fields cannot be represented.
- [ ] Golden valid and invalid fixtures cover macOS and Windows.

**Verification:**

- [ ] Schema tests pass on macOS and Windows runners.
- [ ] Secret-pattern scan passes over every fixture.

**Dependencies:** None.

**Files likely touched:**

- `schemas/enrollment-request.schema.json`
- `schemas/connection-profile.schema.json`
- `schemas/compatibility.schema.json`
- `tests/fixtures/`

**Estimated scope:** Medium, 4 files or fixture groups.

### Task 2: Add the initial compatibility manifest

**Description:** Add the machine-readable compatibility contract and a validator
that distinguishes candidate, tested, and supported versions.

**Acceptance criteria:**

- [ ] The manifest records schema versions, Codex candidates, CLIProxyAPI baseline, HTTP paths, and transport flags.
- [ ] Unsupported or malformed version ranges fail closed.
- [ ] No Codex minimum is published until the compatibility suite selects one.

**Verification:**

- [ ] Manifest validation tests pass.
- [ ] `VERSION`, changelog target, and manifest schema remain internally consistent.

**Dependencies:** Task 1.

**Files likely touched:**

- `compatibility.json`
- `tests/test-compatibility.sh`
- `tests/fixtures/compatibility/`

**Estimated scope:** Small, 3 files or groups.

### Task 3: Extend CI for macOS and Windows

**Description:** Add separate macOS Bash and Windows PowerShell jobs with pinned
actions and no persisted checkout credentials.

**Acceptance criteria:**

- [ ] macOS and Windows jobs validate schemas and platform scripts.
- [ ] CI uses pinned action SHAs and least-privilege permissions.
- [ ] CI never requires a real Tailnet, API key, Codex account, or server.

**Verification:**

- [ ] Both jobs pass from a public fork-compatible workflow.
- [ ] Repository secret scanning reports no newly introduced secret.

**Dependencies:** Tasks 1 and 2.

**Files likely touched:**

- `.github/workflows/test.yml`
- `tests/test.sh`
- `windows/tests/Test-CodexViaServer.ps1`

**Estimated scope:** Medium, 3 files.

## Checkpoint A: Contracts

- [ ] Schemas and compatibility manifest validate on macOS and Windows.
- [ ] CI is green without production credentials.
- [ ] Human review confirms no secret-bearing enrollment fields.

## Phase 2: Server foundation in a disposable environment

### Task 4: Create the loopback credential gateway template

**Description:** Add an Nginx configuration that injects the server-owned key and
streams large Responses requests and SSE without buffering.

**Acceptance criteria:**

- [ ] Gateway listens on loopback only and proxies only `/v1/`.
- [ ] Client Authorization is overwritten and management paths are rejected.
- [ ] Authorization headers and request bodies are absent from logs.

**Verification:**

- [ ] `nginx -t` passes in a disposable Linux environment.
- [ ] Mock tests cover large POST, SSE, timeout, upstream 4xx/5xx, and management-path rejection.

**Dependencies:** Task 1.

**Files likely touched:**

- `server/nginx/codex-gateway.conf`
- `server/nginx/codex-gateway-secret.conf.example`
- `server/tests/test-gateway.sh`
- `server/tests/mock-cliproxyapi.py`

**Estimated scope:** Medium, 4 files.

### Task 5: Create the restricted SSH account template

**Description:** Define the `codex-tunnel` account and sshd Match block with
forwarding limited to the gateway destination.

**Acceptance criteria:**

- [ ] Password, shell, command, PTY, agent, X11, user-rc, and arbitrary forwarding attempts fail.
- [ ] Local forwarding to the exact gateway destination succeeds.
- [ ] Authorized keys are root-owned and device identifiers are normalized.

**Verification:**

- [ ] `sshd -t` passes.
- [ ] Disposable-server negative tests cover every prohibited capability.

**Dependencies:** Task 4.

**Files likely touched:**

- `server/sshd/codex-tunnel.conf`
- `server/install-restricted-user.sh`
- `server/tests/test-restricted-ssh.sh`

**Estimated scope:** Medium, 3 files.

### Task 6: Build the idempotent server installer

**Description:** Install gateway and SSH components with backups, validation,
dry-run output, and no CLIProxyAPI listener cutover.

**Acceptance criteria:**

- [ ] Re-running the installer produces no duplicate users, keys, or config blocks.
- [ ] Existing files are backed up before replacement.
- [ ] Failure restores the previous gateway and sshd configuration.

**Verification:**

- [ ] First install, second install, injected failure, and rollback tests pass.
- [ ] Existing administrator SSH session remains unaffected in integration tests.

**Dependencies:** Tasks 4 and 5.

**Files likely touched:**

- `server/install.sh`
- `server/lib/common.sh`
- `server/tests/test-install.sh`
- `server/README.md`

**Estimated scope:** Medium, 4 files.

### Task 7: Implement administrator device lifecycle

**Description:** Add `approve`, `list`, and exact `revoke` operations using the
existing trusted administrator SSH path.

**Acceptance criteria:**

- [ ] Approval validates schema, public key, fingerprint, and unique device ID.
- [ ] Revocation removes only the exact selected key.
- [ ] Every mutation is atomic and preserves a recoverable backup.

**Verification:**

- [ ] Approve, duplicate approve, list, revoke, unknown device, and concurrent-edit tests pass.
- [ ] A revoked key can no longer establish the permitted forward.

**Dependencies:** Tasks 1, 5, and 6.

**Files likely touched:**

- `admin/codex-via-server-admin`
- `admin/lib/devices.sh`
- `admin/tests/test-devices.sh`
- `schemas/connection-profile.schema.json`

**Estimated scope:** Medium, 4 files.

### Task 8: Implement server doctor and private canary

**Description:** Add read-only server diagnostics and a minimal post-change live
canary that records only status, duration, and versions.

**Acceptance criteria:**

- [ ] Doctor verifies listener boundaries, services, gateway, SSH restrictions, and `/models`.
- [ ] Canary verifies a completed minimal Responses stream without logging credentials or body content.
- [ ] Failures identify the exact layer and return nonzero.

**Verification:**

- [ ] Healthy and injected-failure tests pass against the mock upstream.
- [ ] Log scan confirms credentials and response bodies are absent.

**Dependencies:** Tasks 4 through 7.

**Files likely touched:**

- `server/doctor.sh`
- `server/canary.sh`
- `server/systemd/codex-via-server-canary.service`
- `server/tests/test-doctor-canary.sh`

**Estimated scope:** Medium, 4 files.

### Task 9: Implement transactional CLIProxyAPI upgrades

**Description:** Add explicit check, verified download, candidate install, canary,
and automatic rollback without changing OAuth state.

**Acceptance criteria:**

- [ ] Official release checksum is required before extraction.
- [ ] Current binary, config, unit metadata, and version remain recoverable.
- [ ] Failed process, listener, `/models`, SSE, or live canary check restores the previous version.

**Verification:**

- [ ] Successful upgrade and failures at every transaction stage are tested.
- [ ] OAuth/auth directory checksums remain unchanged across upgrade and rollback tests.

**Dependencies:** Tasks 2, 6, and 8.

**Files likely touched:**

- `server/update-cliproxyapi.sh`
- `server/lib/releases.sh`
- `server/tests/test-update-rollback.sh`
- `server/README.md`

**Estimated scope:** Medium, 4 files.

## Checkpoint B: Disposable server

- [ ] Gateway streaming and header injection tests pass.
- [ ] Restricted SSH positive and negative tests pass.
- [ ] Device approval and exact revocation pass.
- [ ] Upgrade rollback drill restores the previous candidate.
- [ ] No production server has been modified.

## Phase 3: macOS client migration

### Task 10: Refactor the macOS launcher into subcommands

**Description:** Preserve normal Codex argument passthrough while adding
`setup`, `enroll`, `doctor`, `update`, and `uninstall` dispatch.

**Acceptance criteria:**

- [ ] Unknown first arguments continue to pass to official Codex.
- [ ] Subcommands have stable help and nonzero error behavior.
- [ ] Existing v0.1 installation remains usable during development.

**Verification:**

- [ ] Dispatch, passthrough, exit-code, and signal cleanup tests pass.
- [ ] Existing v0.1 regression suite remains green.

**Dependencies:** Tasks 1 through 3.

**Files likely touched:**

- `codex-via-server`
- `macos/lib/commands.sh`
- `install.sh`
- `tests/test.sh`

**Estimated scope:** Medium, 4 files.

### Task 11: Implement macOS setup and enrollment requests

**Description:** Generate a dedicated device key and a schema-valid non-secret
enrollment request.

**Acceptance criteria:**

- [ ] Existing keys are never overwritten.
- [ ] Private key and request permissions are correct.
- [ ] Device IDs and public keys are validated before output.

**Verification:**

- [ ] Fresh, repeated, malformed-hostname, existing-key, and permission tests pass.
- [ ] Secret scanner finds no private key in enrollment output.

**Dependencies:** Tasks 1 and 10.

**Files likely touched:**

- `macos/lib/setup.sh`
- `macos/lib/schema.sh`
- `tests/test-macos-setup.sh`

**Estimated scope:** Medium, 3 files.

### Task 12: Implement macOS connection-profile import

**Description:** Validate an approved profile and install a no-secret Codex
provider and client configuration.

**Acceptance criteria:**

- [ ] Unknown schema, unsafe host, wrong fingerprint shape, or unsupported version is rejected.
- [ ] Generated Codex profile contains no `env_key` or OpenAI-auth flag.
- [ ] Existing default Codex configuration remains byte-for-byte unchanged.

**Verification:**

- [ ] Valid and invalid profile fixtures pass.
- [ ] Installed-file and generated-log secret scans pass.

**Dependencies:** Tasks 1, 2, 10, and 11.

**Files likely touched:**

- `macos/lib/enroll.sh`
- `macos/lib/codex-profile.sh`
- `tests/test-macos-enroll.sh`

**Estimated scope:** Medium, 3 files.

### Task 13: Implement macOS doctor and no-secret launcher

**Description:** Establish the restricted tunnel, validate every client layer,
and launch Codex without retrieving a bearer key.

**Acceptance criteria:**

- [ ] Mandatory doctor checks are read-only and layer-specific.
- [ ] Launcher never invokes a remote command or reads a remote credential file.
- [ ] Exit and signals remove the tunnel, local port, control socket, and temporary files.

**Verification:**

- [ ] Mock doctor, large POST, SSE, wrong fingerprint, timeout, and cleanup tests pass.
- [ ] `doctor --live` requires explicit confirmation and minimizes output.

**Dependencies:** Tasks 4, 5, 10, and 12.

**Files likely touched:**

- `macos/lib/doctor.sh`
- `macos/lib/tunnel.sh`
- `codex-via-server`
- `tests/test-macos-doctor.sh`

**Estimated scope:** Medium, 4 files.

### Task 14: Implement macOS update, uninstall, and v0.1 migration

**Description:** Add once-per-day release checking, explicit verified updates,
rollback-safe installation, and reversible migration metadata.

**Acceptance criteria:**

- [ ] Update checks never install automatically.
- [ ] Release artifacts require a published checksum.
- [ ] v0.1 files remain restorable until the migration observation window closes.

**Verification:**

- [ ] No-update, valid update, bad checksum, interrupted update, rollback, and uninstall tests pass.
- [ ] Default Codex configuration and unrelated SSH keys remain untouched.

**Dependencies:** Tasks 2, 10, 12, and 13.

**Files likely touched:**

- `macos/lib/update.sh`
- `macos/lib/uninstall.sh`
- `install.sh`
- `tests/test-macos-update.sh`

**Estimated scope:** Medium, 4 files.

## Checkpoint C: macOS client

- [ ] All existing and new macOS tests pass.
- [ ] Client contains no CLIProxyAPI credential path or remote key-read command.
- [ ] Mock large Responses and SSE flows pass.
- [ ] Human review approves the migration behavior before touching production.

## Phase 4: Windows client

### Task 15: Implement Windows setup and enrollment

**Description:** Provide PowerShell installation, dedicated Ed25519 key creation,
enrollment request generation, and profile import using Windows OpenSSH.

**Acceptance criteria:**

- [ ] Setup works in a normal user PowerShell session without administrator rights.
- [ ] Private key ACL grants only the current user.
- [ ] Generated request and imported profile match the shared schemas.

**Verification:**

- [ ] Pester tests cover fresh, repeated, invalid, and permission cases.
- [ ] Windows CI passes without a real server.

**Dependencies:** Tasks 1 through 3 and macOS contract lessons from Tasks 11 and 12.

**Files likely touched:**

- `windows/install.ps1`
- `windows/CodexViaServer.psm1`
- `windows/codex-via-server.ps1`
- `windows/tests/Setup.Tests.ps1`

**Estimated scope:** Medium, 4 files.

### Task 16: Implement Windows doctor and launcher

**Description:** Add route, host-key, restricted tunnel, `/models`, optional live
Responses, process cleanup, and Codex passthrough behavior.

**Acceptance criteria:**

- [ ] Uses Windows OpenSSH with no password, proxy, or extra identity fallback.
- [ ] Cleanup works after success, failure, Ctrl+C, and terminal close.
- [ ] Codex receives no API key or server credential.

**Verification:**

- [ ] Pester tests cover route, fingerprint, tunnel, SSE, timeout, and cleanup.
- [ ] A Windows GitHub runner completes the mock end-to-end flow.

**Dependencies:** Tasks 4, 5, and 15.

**Files likely touched:**

- `windows/CodexViaServer.psm1`
- `windows/codex-via-server.ps1`
- `windows/tests/Doctor.Tests.ps1`
- `.github/workflows/test.yml`

**Estimated scope:** Medium, 4 files.

### Task 17: Implement Windows update and uninstall

**Description:** Add explicit checksum-verified updates, daily check throttling,
and scoped removal with rollback metadata.

**Acceptance criteria:**

- [ ] Update never installs without an explicit command.
- [ ] Bad checksum or interrupted replacement preserves the old launcher.
- [ ] Uninstall removes only project-owned files and keys.

**Verification:**

- [ ] Pester tests cover update, rollback, and uninstall cases.
- [ ] User Codex configuration outside the dedicated profile remains unchanged.

**Dependencies:** Tasks 2, 15, and 16.

**Files likely touched:**

- `windows/CodexViaServer.psm1`
- `windows/tests/Update.Tests.ps1`
- `windows/install.ps1`

**Estimated scope:** Medium, 3 files.

## Checkpoint D: Cross-platform clients

- [ ] macOS and Windows CI jobs pass.
- [ ] Both clients consume the same schema fixtures.
- [ ] Both clients pass mock large POST and SSE flows.
- [ ] Release artifacts are checksummed and contain no environment-specific values.

## Phase 5: Integration and compatibility gates

### Task 18: Add disposable end-to-end integration tests

**Description:** Exercise a real SSH daemon, restricted account, Nginx gateway,
and mock CLIProxyAPI in an isolated environment.

**Acceptance criteria:**

- [ ] Approved key completes `/models`, large POST, and SSE.
- [ ] Revoked key, shell, command, wrong destination, and direct API access fail.
- [ ] Real upstream bearer key remains absent from the client and test output.

**Verification:**

- [ ] Integration suite passes from a clean environment twice consecutively.
- [ ] Failure diagnostics identify the broken layer.

**Dependencies:** Tasks 4 through 17.

**Files likely touched:**

- `integration/docker-compose.yml`
- `integration/run.sh`
- `integration/tests/`
- `.github/workflows/integration.yml`

**Estimated scope:** Medium, 4 groups.

### Task 19: Add Codex and CLIProxyAPI compatibility jobs

**Description:** Test candidate Codex versions, current stable Codex, profile
parsing, mock Responses, and CLIProxyAPI release metadata without production
credentials.

**Acceptance criteria:**

- [ ] CI selects and records the earliest passing Codex candidate.
- [ ] Upstream version changes produce a report, not an automatic manifest edit.
- [ ] Project releases are blocked when the declared supported matrix fails.

**Verification:**

- [ ] Known incompatible fixtures fail for the expected reason.
- [ ] Current declared matrix passes before the manifest is updated.

**Dependencies:** Tasks 2, 3, 13, 16, and 18.

**Files likely touched:**

- `.github/workflows/compatibility.yml`
- `tests/test-codex-compatibility.sh`
- `tests/Test-CodexCompatibility.ps1`
- `compatibility.json`

**Estimated scope:** Medium, 4 files.

## Checkpoint E: Pre-production

- [ ] Unit, platform, integration, compatibility, and secret scans pass.
- [ ] Independent security review has no open P0/P1 findings.
- [ ] Rollback procedures pass in a disposable server.
- [ ] Human explicitly approves production side-by-side deployment.

## Phase 6: Production side-by-side migration

### Task 20: Deploy v0.2 server components without cutover

**Description:** Back up production state, install the gateway and restricted
account on unused ports, and keep all v0.1 listeners and clients unchanged.

**Acceptance criteria:**

- [ ] Backups include binaries, config, units, gateway, sshd, and device records.
- [ ] New components pass server doctor and mock checks.
- [ ] Existing v0.1 Codex and VPN services continue working.

**Verification:**

- [ ] Service, listener, firewall, route, and resource snapshots are recorded.
- [ ] Existing client completes a v0.1 real request after deployment.

**Dependencies:** Checkpoint E and explicit human approval.

**Files likely touched:** Production server state only; no unreviewed repository edits.

**Estimated scope:** Medium operational task.

### Task 21: Enroll and pilot the current Mac

**Description:** Approve the current Mac with a new restricted device key and run
the complete v0.2 acceptance flow while v0.1 remains available.

**Acceptance criteria:**

- [ ] Mac receives no API key and uses no administrator root key for Codex.
- [ ] Interactive Codex, large POST, SSE, sleep/wake, network switch, Tailscale reconnect, and cleanup pass.
- [ ] v0.1 rollback remains documented and tested.

**Verification:**

- [ ] `doctor --live` and a real local project task pass.
- [ ] Client process, files, child environment, and logs contain no provider key.

**Dependencies:** Task 20.

**Files likely touched:** Current Mac installation state and migration record.

**Estimated scope:** Medium operational task.

### Task 22: Enroll and pilot a Windows device

**Description:** Run the public Windows quick start on a real Windows machine and
validate the same security and transport contract.

**Acceptance criteria:**

- [ ] Normal-user setup, approval, enrollment, doctor, and Codex use pass.
- [ ] Reboot, sleep, network switch, Ctrl+C, and process cleanup pass.
- [ ] Revocation and re-approval affect only the Windows device.

**Verification:**

- [ ] `doctor --live` and a real local project task pass.
- [ ] No API key or administrator credential appears on Windows.

**Dependencies:** Tasks 20 and 21.

**Files likely touched:** Test Windows installation state and migration record.

**Estimated scope:** Medium operational task.

### Task 23: Cut over to loopback-only CLIProxyAPI

**Description:** After both pilots pass, move CLIProxyAPI to loopback, restrict
Tailnet access to SSH, make v0.2 default, and retire client-side key retrieval.

**Acceptance criteria:**

- [ ] CLIProxyAPI and gateway are unreachable directly from client devices.
- [ ] Approved Mac and Windows devices continue working through restricted SSH.
- [ ] v0.1 client credential retrieval and root-key use are removed after the observation window.

**Verification:**

- [ ] Positive v0.2 and negative direct-access tests pass from both devices.
- [ ] Server reboot and rollback drill pass before old rollback artifacts are deleted.

**Dependencies:** Tasks 21 and 22 plus explicit human cutover approval.

**Files likely touched:** Production CLIProxyAPI, gateway, sshd, Tailscale ACL, and client defaults.

**Estimated scope:** Medium operational task.

## Checkpoint F: Production cutover

- [ ] Mac and Windows real acceptance suites pass after server reboot.
- [ ] Direct API access fails and restricted SSH access succeeds.
- [ ] Device list and exact revocation work.
- [ ] Rollback drill is recorded before removing v0.1 artifacts.

## Phase 7: Documentation and release

### Task 24: Publish migration and administration documentation

**Description:** Update all public user, migration, administrator, compatibility,
and security documentation in English and Chinese.

**Acceptance criteria:**

- [ ] Fresh-device instructions require no knowledge from this private conversation.
- [ ] `MIGRATION.md` identifies every rollback point and deletion gate.
- [ ] Documentation states that approved compromised devices can consume quota until revoked.

**Verification:**

- [ ] Fresh-context reader tests answer installation, approval, update, revoke, and recovery questions correctly.
- [ ] Every command in quick starts is run on its target platform.

**Dependencies:** Tasks 20 through 23.

**Files likely touched:**

- `README.md`
- `README.zh-CN.md`
- `MIGRATION.md`
- `server/README.md`

**Estimated scope:** Medium, 4 files.

### Task 25: Prepare and release v0.2.0

**Description:** Finalize version, changelog, release artifacts, checksums, public
security review, CI, and GitHub release only after every gate passes.

**Acceptance criteria:**

- [ ] All task acceptance criteria and Definition of Done items are satisfied.
- [ ] macOS and Windows artifacts match the tested commit and published checksums.
- [ ] Public release contains no credentials, private addresses, or production logs.

**Verification:**

- [ ] Public anonymous clone and install tests pass on macOS and Windows.
- [ ] GitHub Actions, integration, compatibility, reader, and security reviews pass.
- [ ] Release tag, `VERSION`, changelog, manifest, and artifact versions match `0.2.0`.

**Dependencies:** Tasks 1 through 24 and explicit release approval.

**Files likely touched:**

- `VERSION`
- `CHANGELOG.md`
- `compatibility.json`
- `.github/workflows/release.yml`

**Estimated scope:** Medium, 4 files.

## Definition of Done

Every task must meet its acceptance criteria and the following standing bar:

- [ ] Runtime behavior is verified, not inferred from syntax checks.
- [ ] New behavior has tests that fail without it and pass with it.
- [ ] Existing tests pass with no unrelated changes.
- [ ] Error paths, cleanup, and rollback are tested.
- [ ] Formatting and static checks pass.
- [ ] Public behavior and architectural decisions are documented.
- [ ] Authentication, secret handling, logs, and untrusted input are reviewed.
- [ ] Critical paths expose safe status and version diagnostics.
- [ ] A human approves each production or release gate.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Nginx buffers or truncates Responses streams | High | Disable buffering and test large POST plus SSE with a mock and live canary |
| Restricted account accidentally gets shell access | Critical | Disposable negative tests for shell, command, PTY, agent, X11, and arbitrary forwarding |
| Codex profile format changes | High | Minimum/current version matrix, profile parse test, doctor fail-closed behavior |
| CLIProxyAPI accepts `/models` but breaks inference | High | Real low-output Responses canary after every upstream change |
| Upgrade destroys working state | Critical | Backup-first transaction and injected-failure rollback tests |
| A compromised approved device consumes quota | Medium | Per-device SSH key, global gateway limits, audit log, immediate exact revocation |
| Windows cleanup leaves an SSH process | Medium | Pester signal/process lifecycle tests and real reboot/network-switch pilot |
| Public release leaks private data | Critical | Working-tree, history, artifact, log, and GitHub push-protection scans |

## Parallelization opportunities

- After Tasks 1 through 3, disposable server work and macOS command refactoring can proceed independently.
- Windows Tasks 15 through 17 can begin after schemas stabilize and reuse macOS fixtures.
- Public documentation can be drafted while production pilots run, but commands cannot be finalized until pilots pass.
- Production Tasks 20 through 23 remain strictly sequential.

## Open questions

There are no unresolved architecture decisions blocking implementation. Port
numbers, server addresses, device names, and live maintenance windows are
deployment inputs and are not stored in the public repository.

## macOS 桌面端常驻隧道补充计划

### Task 26：实现常驻受限隧道

**验收标准：** 登录后自动启动；断线自动重连；只转发到登记的 loopback 网关；不接触真实 API Key。

**验证：** 退出安装终端后，`127.0.0.1:18319/v1/models` 仍返回有效模型列表。

### Task 27：增加桌面端管理与回滚

**验收标准：** 支持 install/status/restart/uninstall；修改前备份 Codex 主配置；失败时自动恢复。

**验证：** LaunchAgent 状态、配置、端口和卸载恢复测试通过。

### Task 28：兼容 CLI 并完成真实验收

**验收标准：** CLI 复用健康常驻隧道；桌面端本地 URL 完成低用量真实 Responses 请求。

**验证：** 原始故障检查从 `http=000` 变为 `http=200`，且真实 canary 完成。
