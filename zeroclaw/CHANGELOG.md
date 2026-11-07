# 4.0.0.0 — Native architecture overhaul

- Upgrade the packaged runtime to verified official ZeroClaw 0.8.7.
- Replace custom provider/HA/Telegram brokers, watchers, tickets and schedulers
  with one unprivileged native daemon.
- Connect directly to Home Assistant 2026.11 native MCP, disabled until a new
  account credential is configured, with read-only Device control qualification.
- Use one numeric Telegram owner, native model profiles, explicit reasoning
  selection and optional native automatic routing. Keep Fusion's budget preset.
- Preserve memory through checked SQLite migration and the stable default agent.
  Archive opaque legacy conversations and preserve a tested rollback route.
- Use native approval/cost controls under the selected native trust model;
  retire independent spending reservations, action tickets and undo guarantees.
- Remove Supervisor API grants, host configuration mounts and implicit fallback
  routes. Keep native state private and the legacy workspace inaccessible.
- Use Supervisor cold backups, pinned artifact/image inputs, isolated real-client
  compatibility tests and emulated arm64 startup/restart qualification.

This is a breaking update. Read [UPGRADE.md](UPGRADE.md) before installation.
Local qualification is distinct from CI, signed publication and production use.
Previous release history remains in Git history and the retained recovery archive.
