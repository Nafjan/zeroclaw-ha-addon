# Changelog

## 3.0.0 (April 2026) — Foundation: smart, grounded, scheduled, safe

**Breaking changes:** the agent can no longer call `ha-action` directly. All write actions
route through `ha-action-guarded`, which enforces a user-owned policy. Existing flows still
work; new actions may produce a `CONFIRM_PENDING` ticket and ask for approval.

### New features
- **Policy engine.** User-owned `/config/zeroclaw_policy.yaml` plus 9 add-on options control
  what the agent can do without asking. Three verdicts: `allow`, `confirm`, `deny`. Modes:
  `strict` / `balanced` / `permissive` / `custom`. The LLM cannot edit the policy.
- **Approval tickets.** `confirm` verdicts generate a Telegram message with a short ID
  (`YES <id>` / `NO <id>` to apply or reject). Tickets expire after 30 min.
- **World-state injection.** New `zc-world-state` helper builds a compact home-state header
  (time, lights on, ACs running, quiet hours, pending approvals). SOUL.md tells the agent
  to trust it instead of re-fetching.
- **Self-scheduling.** `zc-schedule '<cron>' '<message>'` lets the agent schedule future
  messages to itself via ZeroClaw's `/api/cron`. `zc-schedule-once <minutes> '<msg>'` for
  one-offs.
- **Proactive observer.** Configurable cron (default every 15 min) gives the agent a chance
  to flag anomalies, repeating patterns, or forgotten devices. Outputs `NOOP` if nothing
  notable. Configurable interval.
- **Audit trail.** Every action writes a structured row to `/data/audit/YYYY-MM-DD.jsonl`
  with previous and new state, reason, and policy verdict.
- **Undo.** `zc-undo [N]` reverts up to N most recent actions within a 1-hour window.
  Domain-specific restoration for light, switch, climate, cover, input_boolean.
- **Cost watchdog.** Background poller (every 5 min) flips the agent into cheap-model-only
  mode when today's spend exceeds 80% of the daily limit; user gets a one-shot notification.
- **Cost telemetry.** `zc-cost` exposes `/api/cost` so the agent can answer cost questions
  accurately instead of guessing.
- **LESSONS.md.** Empty file scaffolded; will be auto-prepended to every prompt as the agent
  accumulates user corrections (full self-learning loop ships in v3.2).

### New add-on options (29 total, up from 7)
Cost limits, runtime budgets, home context (location, languages, quiet hours), report and
observer schedules, audit retention, policy mode + extras + trust thresholds. See
`config.yaml` for the full list.

### Removed
- busybox crond and `/etc/crontabs/root`. The daily report is now a ZeroClaw cron entry
  composed by the agent itself, not a shell template.
- Unguarded `ha-action`. Replaced by `ha-action-raw` (internal only) + `ha-action-guarded`
  (the only path the agent can call).

### Architectural notes
- The policy engine's deterministic decision lives in `ha-action-guarded`. The LLM's role
  is limited to *describing* the action and *relaying* user approval; it cannot fabricate
  approvals because `zc-approve` refuses any input that doesn't exactly match
  `^YES <id8>$` from the user.
- Trust promotion (auto-allow after N approvals) is scaffolded in the YAML schema; the
  promotion logic itself ships in v3.1 alongside the SSE-based approve-watcher.

### Phase switches (off by default)
- `enable_creation_skill` — v3.1 creation flow (routines/scenes/automations).
- `enable_learning_loops` — v3.2 reflection + LESSONS.md distillation.

---

## 2.5.1 (April 2026)
- SOUL.md: forbid "Done."; require specific outcome lines per action category
- AC actions must call ha.get_entity first to verify state before acting
- Greeting rule: "hi"/"hello" → "Hi." then stop

## 2.5.0 (April 2026)
- Bumped `provider_max_tokens` to 2048 (was 500, was truncating tool calls)
- Removed undefined `fallback_providers` and `route_down_model` references
- Added auto-restart loop with crash counter (max 10 restarts)
- Switched from `exec` to wrapping loop so a daemon crash doesn't kill the add-on
- Daily report cron + ha-daily-report helper

## 0.1.0 (April 2026)
- Initial release
- ZeroClaw v0.6.8 aarch64 binary
- OpenRouter integration (DeepSeek + Claude Sonnet)
- HA REST API tools (lights, climate, sensors)
- MQTT event listener with debounce and domain filtering
- Telegram transport (long-poll, user allowlist)
- Markdown + SQLite FTS memory system
- Blocked domain safety gate (lock, alarm, cover, siren)
- Confirmation gates (bulk actions, nighttime, large temperature delta)
