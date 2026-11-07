# Upgrading to the native 4.0 app

This is a major architecture change. The 4.0 release uses native ZeroClaw
0.8.7 instead of the old broker, watcher, custom policy and ticket framework.
It requires Home Assistant 2026.11 or newer and aarch64. Automatic upgrades
must not cross this breaking version without operator attention.

## Before upgrading

1. Make a full Supervisor backup including this app. Retain the installed old
   version's options and image identity with the backup.
2. Review the changed assurance model in [ARCHITECTURE.md](ARCHITECTURE.md).
   The daemon now holds its provider/MCP credentials and enforces its own
   approvals and cost accounting. The old independent key isolation, spending
   reservations, action tickets and undo service are retired.
3. Record the numeric Telegram owner. The first legacy `telegram_allowed_users`
   entry is a compatibility fallback; additional users are no longer authorized.
   Set `telegram_owner_id` explicitly and disable bot group joining.
4. Configure Home Assistant MCP separately if needed. Home access starts off;
   the old `ha_token` and Supervisor credentials are not reused. Follow
   [DOCS.md](DOCS.md) for the read-only Device control setup.

## What startup migrates

The old runtime must be stopped; Supervisor replaces the container during an
app update. The startup helper takes a process lock and prepares the new native
subtree atomically. Its layout marker and snapshot checksums permit recovery
if startup is interrupted.

The verified old memory location is `/data/workspace/memory/brain.db`. Startup
archives that memory directory, its SQLite sidecars and legacy session paths
under a private `/data/migrations/runtime-layout-v2-to-v3-...` directory. It
copies known SQLite databases with SQLite's backup API and checks integrity.
ZeroClaw itself performs its database schema upgrade. The stable `default`
agent alias preserves the native namespace for migrated memory.

The active layout is:

| State | Location |
| --- | --- |
| Native configuration | `/data/native/config.toml` |
| Native memory | `/data/native/data/memory/brain.db` |
| Native sessions | `/data/native/data/sessions/sessions.db` |
| Default workspace | `/data/native/agents/default/workspace` |
| App options | `/data/options.json` |
| Layout receipt | `/data/.runtime-layout` |

Legacy files remain in place. The old workspace is not activated because its
prompts and skills refer to removed tools. Root audit, quota and policy history
remain historical data. Hash-keyed Telegram JSON conversations are preserved
without guessing sender ownership; a fresh native Telegram conversation may
start. A compatible legacy SQLite sessions database is copied when present.

Native cost accounting starts its own ledger. Legacy broker spending totals
and reservations are not imported into the native daily/monthly totals. Set
the new limits to reflect any remaining allowance and use the provider's
account limit when the total across both versions must be independently capped.

The app inventory schema, native TOML schema and runtime layout version are
separate. No custom SQL namespace rewrite is applied. Unsafe links, conflicting
state, a corrupt database or insufficient free space stop migration. The helper
does not silently discard those files.

## Confirm the upgrade

Check the app log and health, talk to the bot as the owner, and ask it to recall
one known memory fact. If MCP is enabled, confirm that the expected exposed
entity is available and an unexposed entity is absent. Confirm `/model reasoning`
and `/model fast` select the intended native routes.

Normal restarts preserve native configuration. Saving changed app options
regenerates its managed graph; keep manual native changes out of that workflow.
Supervisor cold backups stop the app for a consistent SQLite snapshot. Retain
both the pre-upgrade backup and native backups until the new deployment has
been accepted.

## Recovering

For a complete downgrade, stop the native app and restore the pre-upgrade
Supervisor backup and its old app image/options. Native-era memory and sessions
are not backward-migrated to 0.7.5. Export or retain a native backup before
restoring older state.

The native helper also supports an operator-run `rollback /data` command while
the daemon is stopped. It verifies its migration snapshot, restores missing
legacy memory/session files, refuses to overwrite changed legacy files, and
marks the native layout rolled back. It retains native data. This is a state
recovery operation, not an image downgrade or a full Supervisor backup restore.
After that marker is written, the native entrypoint intentionally refuses to
start; use the matching old deployment or restore a known backup rather than
editing markers to bypass recovery.

A successful migration no longer needs to re-read its original snapshot on each
normal startup. Keep snapshots while rollback is needed; never prune an
unfinished transaction. Recovery involving corrupt or changed legacy state
requires deliberate inspection or a known Supervisor backup.
