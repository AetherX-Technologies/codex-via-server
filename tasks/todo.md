# v0.2 hardened enrollment checklist

## Phase 1: Contracts

- [x] Task 1: Define versioned enrollment schemas
- [x] Task 2: Add the initial compatibility manifest
- [x] Task 3: Extend CI for macOS and Windows
- [x] Checkpoint A: Contracts reviewed and CI green

## Phase 2: Disposable server

- [x] Task 4: Create the loopback credential gateway template
- [x] Task 5: Create the restricted SSH account template
- [x] Task 6: Build the idempotent server installer
- [x] Task 7: Implement administrator device lifecycle
- [x] Task 8: Implement server doctor and private canary
- [x] Task 9: Implement transactional CLIProxyAPI upgrades
- [x] Checkpoint B: Disposable server security and rollback tests pass

## Phase 3: macOS

- [x] Task 10: Refactor the macOS launcher into subcommands
- [x] Task 11: Implement macOS setup and enrollment requests
- [x] Task 12: Implement macOS connection-profile import
- [x] Task 13: Implement macOS doctor and no-secret launcher
- [ ] Task 14: Implement macOS update, uninstall, and v0.1 migration
- [ ] Checkpoint C: macOS tests and human migration review pass

## Phase 4: Windows

- [ ] Task 15: Implement Windows setup and enrollment
- [ ] Task 16: Implement Windows doctor and launcher
- [ ] Task 17: Implement Windows update and uninstall
- [ ] Checkpoint D: Cross-platform client CI passes

## Phase 5: Integration

- [ ] Task 18: Add disposable end-to-end integration tests
- [ ] Task 19: Add Codex and CLIProxyAPI compatibility jobs
- [ ] Checkpoint E: Pre-production security and rollback review passes

## Phase 6: Production migration

- [ ] Task 20: Deploy v0.2 server components without cutover
- [ ] Task 21: Enroll and pilot the current Mac
- [ ] Task 22: Enroll and pilot a Windows device
- [ ] Task 23: Cut over to loopback-only CLIProxyAPI
- [ ] Checkpoint F: Production cutover and rollback drill pass

## Phase 7: Release

- [ ] Task 24: Publish migration and administration documentation
- [ ] Task 25: Prepare and release v0.2.0
- [ ] Final Definition of Done and explicit release approval
