# ZeroClaw Agent

This app runs one native ZeroClaw daemon. It uses OpenRouter for models, native
Telegram for owner conversations, and Home Assistant's native HTTP MCP endpoint
for read-only home context. Home Assistant 2026.11 or newer and aarch64 are
required by this release.

## Start with Telegram

1. Set `openrouter_api_key`.
2. Set `telegram_bot_token` and your numeric `telegram_owner_id`. A username is
   not an owner ID. Keep the token private.
3. In BotFather, disable the bot's ability to join groups. Use a private chat
   with the bot, then start the app.

Telegram is optional: an empty bot token disables it. A configured bot without
a numeric owner fails startup. Only the configured sender is authorized; there
is no automatic first-user enrollment. The pinned ZeroClaw release does not
enforce a blanket private-chat restriction, so keep the bot out of groups.

The default model is `~deepseek/deepseek-v4-flash-latest`. The reasoning profile
uses `openrouter/fusion` with the `general-budget` preset. Use `/model reasoning`
in Telegram for the reasoning route and `/model fast` to return to the primary
route. These names select native model routes. Cross-provider and free-model
fallback are not enabled implicitly.

`automatic_model_routing` is off by default. When enabled, native ZeroClaw
selects the reasoning route for requests it classifies as complex; `/model auto`
returns a Telegram conversation to automatic selection after a manual override.
Its heuristic is coarse: more than 200 UTF-8 bytes, a code fence, or two native
English reasoning keywords can trigger escalation. This may select Fusion for
an ordinary long message. There is no additional classifier model or custom
app routing service.

## Connect Home Assistant

Home access is disabled by default. Configure it deliberately:

1. Add Home Assistant's **Model Context Protocol Server** integration.
2. Configure the main endpoint with **Device control** only, **Expose all AI
   tools** off, and **Read-only** on. Permit a dedicated non-administrator user
   to use the main endpoint.
3. Review which entities are exposed to Assist. That set determines the home
   context available to ZeroClaw.
4. Create a new long-lived access token for that user. Set `ha_mcp_url` to the
   reachable main endpoint, for example `http://homeassistant:8123/api/mcp`,
   set `ha_mcp_token`, and enable `ha_mcp_enabled`.

Use HTTPS across untrusted networks. The app rejects individual API paths,
credentials embedded in URLs, and redirects during its startup check. It never
imports the old `ha_token` or uses the Supervisor's administrator token.

Startup checks authentication and discovers tools without calling them. It
requires the reviewed read-only Device control contract. Broader toolsets,
missing read-only annotations and action tools stop startup. The check is a
short-lived compatibility check; ZeroClaw then talks directly to Home Assistant.
It is not a second enforcement service or a continuous monitor. Keep Home
Assistant's MCP configuration read-only while this app runs.

The agent can recall memory and read the reviewed home-context/time tools.
Shell commands, general web access, file-editing tools, delegation and the old custom
skills are disabled. Device writes and the former undo/ticket system are not
part of this release. Put recurring automations and reports in Home Assistant.

See the [Home Assistant MCP documentation](https://www.home-assistant.io/integrations/mcp_server/)
for server setup and [MCP-COMPATIBILITY.md](MCP-COMPATIBILITY.md) for qualification.

## Costs and options

Native ZeroClaw cost accounting uses `block` mode, with daily and monthly
limits of USD 10 and USD 40 by default. The generated rate table uses a
conservative USD 100 per million input and output tokens for both configured
models, including Fusion. These are protective accounting estimates, not
provider prices. Actual billing and native usage accounting can differ; set
an account limit at the provider when you need an independent spending limit.

`provider_max_tokens`, context/history limits and tool iterations bound ordinary
turns. `max_actions_per_hour` is a native runtime control. These controls are
trusted to ZeroClaw; they are not the former broker's durable reservations.

App options generate the native configuration on first start and whenever the
saved options change. Ordinary restarts preserve native pairing and runtime
configuration. Editing app options regenerates the app-managed configuration;
do not expect arbitrary manual native configuration edits to survive that reset.
Credentials are stored in this private file as plaintext. Same-user native
secret-file encryption is disabled so startup can check the effective MCP
configuration. Protect app data and backups; the daemon is trusted with these
credentials under the selected native assurance model.
If an unsupported manual change encrypts MCP header values, startup stops.
Change an app option value and restart to regenerate the managed configuration;
saving the same values preserves the existing file and does not reset it.

## State, backup and health

The native configuration is `/data/native/config.toml`. Native memory and
sessions live below `/data/native/data`; the default agent workspace is
`/data/native/agents/default/workspace`. The daemon runs as an unprivileged user.
Supervisor options, migration snapshots and legacy state remain outside its
writable directory.

Supervisor uses a cold backup: it stops the app while capturing data so SQLite
files have a consistent backup. Back up the app before upgrading. See
[UPGRADE.md](UPGRADE.md) for migration details and recovery limits.

The daemon's health endpoint listens only inside the container. There is no
published port, ingress UI, Supervisor API grant, host configuration mount or
Docker socket. A failed MCP preflight is reported in the app log; correct the
HA account, URL and tool settings, then restart.
