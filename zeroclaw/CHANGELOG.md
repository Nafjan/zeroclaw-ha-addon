# Changelog

## 3.1.3.1 (May 2026) — Lessons-loop hotfix

Live trace from a real Telegram correction showed v3.1.3 didn't fire the
loop. Root causes (both small):

1. **`zc-set-outcome` was a shell-only helper, not a registered tool.** SOUL.md
   instructed the agent to "call `zc-set-outcome ...`", but the agent's tool
   layer only exposes registered `[[tools]]` entries (e.g. `ha.action_guarded`,
   `memory_recall`). The agent emitted `zc.set_outcome` as a tool call — a name
   that didn't resolve — so `/data/.last_outcome` was never written and the
   correction branch could never fire on the next message.
2. **Correction regex was too narrow.** Real corrections often don't open with
   "no" / "wrong". The user said "they're not on" after a failed light command,
   which the case pattern missed.

### Fixes

- Register `zc.set_outcome` and `zc.lesson_add` as proper `[[tools]]` in the
  `ha` skill manifest. The shell helpers are unchanged; only the wiring is new.
- Rewrite the SOUL.md "Outcome tracking" section to call out that
  `zc.set_outcome` is a real tool (with a concrete example) and that skipping
  it is a SOUL violation.
- Widen the case pattern in `tg-callback-watcher.handle_message` to cover
  negation phrasings: "they're not", "it's not", "isn't", "didn't",
  "still off / on / not / nothing", "nothing happened", "doesn't work",
  "not working", "didn't work". Arabic: "ما اشتغل", "مو شغال", "لسه".
- Pre-lowercase + trim the message before matching (case-insensitive without
  exploding the case statement).
- The `/data/.last_outcome` gate still prevents false-positive corrections on
  bare "no" answers to questions.

No version bump to dependencies, no schema changes, no migration. Drop-in
restart.

## 3.1.3 (May 2026) — Lessons loop, model routing, musl-safe ha-logbook

**Self-improvement primitives.** v3.1.2 had `LESSONS.md` auto-prepended to every
prompt but no mechanism to populate it. The agent never learned from corrections.
v3.1.3 wires the loop end-to-end with three targeted fixes (~130 lines net,
single PR, no runtime rebuild).

### Fixes

1. **Lessons loop (the missing 50 lines).**
   - New helper `zc-set-outcome` — agent calls it after every real action with
     the same one-line outcome it wrote to the user. Persists to
     `/data/.last_outcome`.
   - New helper `zc-lesson-add` — appends a deduped, 80-char-capped line to
     `${WS}/LESSONS.md`. FIFO-capped at 50 lessons so prompt overhead stays
     bounded.
   - `tg-callback-watcher` `handle_message` now detects correction markers in
     incoming text (`no`, `wrong`, `actually`, `I meant`, `لا`, `غلط`, …). When
     `/data/.last_outcome` exists AND the user replies with a correction, the
     watcher fires a synthetic background prompt to the gateway asking the
     agent to generate one lesson and call `zc-lesson-add`. The user's normal
     reply is still forwarded; the learning hook runs silently in parallel.

2. **Model routing directive in `SOUL.md`.** New `## Model routing` section
   tells the agent when to switch from the fast model (gemini-flash-lite) to
   the reasoning model (claude-sonnet-4.6). Trigger keywords (`create`,
   `automate`, `schedule`, `why`, `debug`, `plan`, `every`, `all of`),
   ≥3 tool calls already used, mixed Arabic+English with technical terms, or
   drafting a scene/automation/routine. Switch is signalled with the in-band
   token `[[reasoning]]` on the first scratch line. Pairs with the existing
   `[[model_routes]]` config in `config.toml`.

3. **`ha-logbook` musl-safe date math.** The previous version used
   `date -u -d @<epoch>`, a GNU coreutils extension that is not available on
   Alpine/musl. The script silently fell back to `$NOW`, returning empty 24-hour
   windows — so the agent saw no logbook history and concluded "nothing to learn
   from." Replaced with `awk strftime` which works on BusyBox.

### What this changes for the agent's behavior

- After a correction, the next turn's prompt opens with a freshly-saved lesson.
  Repeating the same mistake costs more than learning from it.
- Complex turns route to the reasoning model only when warranted. Simple
  status queries stay on the cheap model. Cost stays flat.
- `ha-logbook climate.bedroom` and `ha-logbook` (no args) actually return data,
  so the daily review can spot HA-side anomalies.

### Files touched

- `zeroclaw/run.sh` — `ha-logbook` heredoc; new `zc-set-outcome` and
  `zc-lesson-add` helpers; `handle_message` correction-detection branch;
  SOUL.md `## Model routing` and `## Outcome tracking` blocks; `allowed_commands`
  registers the two new helpers; `ADDON_VERSION` bump.
- `zeroclaw/config.yaml` — version bump.
- `docs/runbooks/lessons-loop.md` — new runbook covering correction triggers,
  manual verification, and rollback if the loop misfires.

### Verification

72-hour soak window with explicit metric: ≥3 distinct lessons logged from real
corrections AND ≥1 case of NOT repeating a previously-corrected mistake. If the
metric fails after 72h+48h extension, evaluate Hermes Agent migration as
documented in the project plan.

## 3.1.2 (May 2026) — Single-owner Telegram socket (fixes 409 polling conflict)

**Bug fix.** v3.1.1 introduced a `tg-callback-watcher` sidecar that
long-polled `getUpdates`, but ZeroClaw's built-in Telegram channel was
*also* polling — Telegram only allows one `getUpdates` client per bot,
so the two were fighting and the logs were spammed with
`Conflict: terminated by other getUpdates request` warnings.

### Fix
- The watcher is now the **sole owner** of the Telegram bot socket. It
  long-polls *all* update kinds (`message` + `callback_query`) and:
  - **`.message`** → validates `from.id`, forwards the text to the
    gateway `/webhook`, sends the agent's response back via
    `sendMessage` (with a `typing…` action while waiting).
  - **`.callback_query`** → existing chip-tap logic (apply ticket,
    edit message in place, ping agent for audit).
- `[channels_config.telegram]` is removed from the generated
  `config.toml` so ZeroClaw no longer starts its own Telegram channel.

### Trade-offs
- Lost: ZC's streaming/partial-typing-indicator on long replies. The
  shell relay sends the final response in one `sendMessage`. Worth it
  to get rid of the polling race.
- Lost: ZC's per-message ack reaction. The watcher sends a `typing…`
  chat action instead, which is arguably more familiar.
- Kept: chip approval UX, allowlist enforcement, callback validation.

### Files touched
- `zeroclaw/run.sh` — removes `[channels_config.telegram]` block,
  rewrites `tg-callback-watcher` to handle both update kinds.

## 3.1.1 (May 2026) — Telegram inline-keyboard approval chips

**UX upgrade.** Approval tickets now ship with tappable chips instead of
text-only "reply YES <id>".

### What changed
- New `tg-send-approval` helper renders Telegram messages with an
  inline keyboard: **[✅ Approve]** **[❌ Reject]** on row 1, **[💬 Discuss]**
  on row 2. The returned `message_id` is persisted into the ticket so
  the watcher can edit-in-place after the user taps.
- New `tg-callback-watcher` sidecar long-polls
  `getUpdates?allowed_updates=["callback_query"]` and:
  - validates `from.id` against the add-on's `telegram_allowed_users`,
  - applies the ticket directly (action → `ha-action-guarded --apply-ticket`,
    creation → `ha-apply-creation`),
  - calls `answerCallbackQuery` to dismiss the spinner,
  - edits the original message to show "✅ Approved by …: <outcome>"
    or "❌ Rejected by …",
  - pings the agent webhook so the audit trail stays unified.
- Auto-restart loop wraps the watcher (5s back-off on crash).
- Text-only "YES <id>" / "NO <id>" replies still work as a fallback.

### Why
Tapping a chip is one motion, no typing, no copy-paste of the id. Also
removes a class of failures where the LLM tried to fabricate the YES
text (zc-approve still rejects those, but with chips the user just
doesn't see that path).

### Files touched
- `zeroclaw/run.sh` — adds two helpers + watcher background loop;
  `ha-action-guarded`, `ha-create-scene`, `ha-create-automation` now
  send via `tg-send-approval` with curl fallback.

## 3.1.0 (May 2026) — Creation skill, reverse triggers, test coverage

**New behavior:** the agent can now propose new HA scenes and automations through
the existing approval flow. The user owns every persistent change — nothing lands
in `/config/scenes.yaml` or `/config/automations.yaml` until you reply `YES <id>`.

### New features
- **Creation skill (gated by `enable_creation_skill`, off by default).** Three new
  helpers, all approval-gated:
  - `ha-create-scene <id> '<name>' '<json states>'` → drafts a ticket, on approval
    appends to `/config/scenes.yaml` and reloads HA.
  - `ha-create-automation <alias> '<yaml>'` → yq-validated YAML (must include both
    `trigger:` and `action:`), drafts ticket, on approval appends to
    `/config/automations.yaml` and reloads HA.
  - `ha-create-routine <name> '<json steps>'` → agent-side macro stored in
    `/data/routines/`. Each step still routes through `ha-action-guarded` when the
    routine runs, so policy still applies per step.
- **`ha-apply-creation <id>`** — applies an approved creation ticket. Will refuse
  unless the user's `YES <id>` reply already wrote the approval marker.
- **`ha-run-routine <name>`** — invokes a saved routine.
- **Reverse-trigger pattern documented.** `CREATION.md` (auto-generated only when
  the skill is on) explains how to wire HA `rest_command` → ZeroClaw webhook so HA
  automations can wake the agent for conditional reasoning.

### Quality / infrastructure
- **Policy engine extracted.** Decision logic moved out of the run.sh heredoc into
  a pure shell function `lib/policy-decide.sh`. Same verdicts, no embedded
  HA-token side effects, no file writes.
- **36 bats unit tests** (`zeroclaw/tests/policy_decide.bats`) covering domain
  defaults, hard-block deny list, mode tuning, extras precedence, climate delta,
  bulk-action escalation, quiet hours edge cases, and bad input.
- **GitHub Actions CI** (`.github/workflows/test.yml`) runs the bats suite and
  shellcheck on every push and PR.
- **Per-field config translations** (`zeroclaw/translations/en.yaml`). Every
  add-on option now has a clear name and one-paragraph description in the HA
  Configuration tab — directly addresses the "config is not clear" feedback from
  v3.0.0 deployment.

### Bug fixes & robustness
- `policy-decide` now parses `temperature` from the action body via `jq` when
  available and a `sed` fallback otherwise — survives minimal containers and is
  testable without `jq` installed locally.
- Bulk-action count is computed server-side (`jq`-based) and exported as
  `POLICY_BULK_COUNT` rather than re-implementing JSON-array parsing in pure shell.

### Notes
- Creation skill stays **off by default**. Toggle `enable_creation_skill: true`
  in add-on options after you've used v3.0 long enough to trust the policy gate.
- The agent **never deletes** persistent HA objects (scenes, automations). Removal
  is a manual edit of the YAML file or the HA UI — same as before.

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
