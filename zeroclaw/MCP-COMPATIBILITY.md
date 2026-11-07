# Home Assistant native MCP compatibility

## Tested boundary

`tests/ha_native_mcp_smoke.py` uses the official Home Assistant Core 2026.11.0
linux/amd64 image pinned at
`sha256:078222f9ea47cf47b172a301c2c45a1d2344b9d666827729b71fc3f7d7a57592`.
Every run starts it with `--network none`, publishes no ports, mounts a fresh
temporary `/config`, creates synthetic users and sensor states, and removes the
container and temporary files on exit. It never reads the host Home Assistant
configuration, uses a live Home Assistant instance, or contacts an external provider.

The basic server and startup-preflight fixture runs with:

```sh
python3 tests/ha_native_mcp_smoke.py --pull
python3 tests/ha_native_mcp_smoke.py --preflight-only
```

The actual ZeroClaw client fixture also verifies the official 0.8.7 Linux
archive against SHA-256
`3cc7f1c859a67524d5496260d29806190bc7127d2877a479a5496ce34b9b401a`:

```sh
python3 tests/ha_native_mcp_smoke.py --native-interop --zeroclaw-archive PATH
```

It requires Docker with linux/amd64 support and the pinned ZeroClaw 0.8.7
archive. The fake OpenRouter service, TLS certificate authority, and proxy run
only inside the isolated Home Assistant container. No external network route is
available.

## Recorded results

- Unauthenticated `POST /api/mcp` was rejected with HTTP 401. MCP negotiated
  protocol `2025-03-26`.
- With only the Home Assistant API selected and `read_only: true`, the observed
  server tools were `config__get_config_entries`,
  `config__search_integrations`, `homeassistant__render_template`,
  `homeassistant__search_actions`, `llm__GetDateTime`, `search__search`,
  `system_health__get_system_info`, `system_log__get_entries`, and
  `system_log__get_logs`. The mutating `homeassistant__call_action` tool was
  absent, and a call to its exact name was rejected as not found. The action
  supplied to the fixture was invalid, so no real action was requested.
- With only the Assist API selected and `read_only: true`, Home Assistant
  returned `homeassistant__GetLiveContext` and `llm__GetDateTime`, each with
  `readOnlyHint: true`. A live-context call included the synthetic exposed
  temperature sensor and omitted the synthetic unexposed sensor.
- The effective-config preflight was run against the generated native TOML and
  the same synthetic nonadmin bearer token used by ZeroClaw. It resolved the
  default agent's MCP bundle and verified the actual URL, credential, protocol
  handshake, read-only annotations, and exact Assist tool set. It performed no
  `tools/call` and read no entity context.
- The pinned ZeroClaw 0.8.7 binary completed the native MCP handshake and called
  exactly `ha__homeassistant__GetLiveContext` as a non-owner user against the
  configured main endpoint with `require_admin: false`, `read_only: true`, and
  only the Assist API selected. ZeroClaw registered exactly
  `ha__homeassistant__GetLiveContext`, `ha__llm__GetDateTime`, and
  `memory_recall`. The exposed marker reached the fake model in the tool result;
  the unexposed marker did not.
- The test kept the production typed `openrouter` provider family. ZeroClaw
  0.8.7 fixes that family's HTTPS endpoint to `openrouter.ai`; the fixture
  therefore routed the client's real HTTPS request through a loopback HTTP
  CONNECT proxy to a local TLS server presenting a temporary `openrouter.ai`
  certificate. `SSL_CERT_FILE` trusted only the fixture CA. The proxy observed
  four loopback CONNECTs for five provider requests. The fake provider verified
  the synthetic bearer credential, requested model, and exact registered tool
  list on every call.
- With the optional native `automatic_model_routing` setting enabled in a
  second generated test config, a short simple message selected `test-primary`
  and a long complex message selected `openrouter/fusion`. The Fusion request
  contained `plugins = [{id = "fusion", preset = "general-budget"}]`. An
  explicit CLI provider/model override also selected the reasoning profile and
  the same Fusion plugin payload. The default generated config leaves automatic
  routing off. The native Telegram source maps its model picker to `/model
  <hint>`; this fixture did not connect to Telegram.

## Native Home Assistant controls

For the tested narrow profile, use the configured main `/api/mcp` URL, turn
“All LLM APIs” off, select only the Assist API, and enable read-only. This
profile passed with a synthetic non-owner, non-administrator account and
`require_admin: false`. The separate admin-only API fixture used the owner
account during setup and independently checked the Home Assistant API's
`call_action` filter; it is not the identity used by the native ZeroClaw client.

Home Assistant's main endpoint applies `require_admin` and filters selected API
instances by their read-only annotations. The separate `/api/mcp/<api_id>` route
sets `read_only=False`, so it is not interchangeable with the configured main
URL. The integration defaults to all APIs, administrator required, and
read-only disabled; narrow those options explicitly.

`GetLiveContext` uses Assist entity exposure and returns a live-context summary.
Other read-only tools do not necessarily apply the same entity filter. In
particular, `homeassistant__render_template` is marked read-only but can read
Home Assistant state and attributes broadly. Read-only controls mutation; it
does not make every returned value private.

ZeroClaw 0.8.7's MCP bundle grants servers and supports exclusions; it has no
per-tool include list. Its MCP wrapper does not preserve Home Assistant's
`readOnlyHint` annotations. The HA read-only endpoint is therefore the primary
mutation control. The native config excludes the exact observed
`ha__homeassistant__call_action` wrapper as an additional guard. This is not a
general per-tool whitelist. Other MCP tools remain supervised and require
approval under the generated risk profile.

The native config sets `secrets.encrypt = false` so startup preflight can inspect
the effective MCP URL and bearer header after native config edits. The config
file is atomically written with mode 0600 in the private `/data/native`
directory. This protects it from other container users; the service account
itself can read the bearer token.

## Primary sources

- [Home Assistant MCP Server integration documentation](https://www.home-assistant.io/integrations/mcp_server/)
- [Core 2026.11.0 MCP HTTP routes and auth/read-only dispatch](https://github.com/home-assistant/core/blob/2026.11.0/homeassistant/components/mcp_server/http.py)
- [Core 2026.11.0 MCP server tool filtering and annotations](https://github.com/home-assistant/core/blob/2026.11.0/homeassistant/components/mcp_server/server.py)
- [Core 2026.11.0 Home Assistant Assist tools](https://github.com/home-assistant/core/blob/2026.11.0/homeassistant/components/homeassistant/llm.py)
- [Core 2026.11.0 Assist entity exposure policy](https://github.com/home-assistant/core/blob/2026.11.0/homeassistant/components/homeassistant/exposed_entities.py)
- [ZeroClaw 0.8.7 MCP client and wrapper](https://github.com/zeroclaw-labs/zeroclaw/blob/99bd353/crates/zeroclaw-tools/src/mcp_client.rs)
- [ZeroClaw 0.8.7 MCP bundle and risk config schema](https://github.com/zeroclaw-labs/zeroclaw/blob/99bd353/crates/zeroclaw-config/src/schema.rs)
- [ZeroClaw 0.8.7 Telegram model picker](https://github.com/zeroclaw-labs/zeroclaw/blob/99bd353/crates/zeroclaw-channels/src/telegram.rs)
- [ZeroClaw 0.8.7 OpenRouter provider](https://github.com/zeroclaw-labs/zeroclaw/blob/99bd353/crates/zeroclaw-providers/src/openrouter.rs)
- [ZeroClaw 0.8.7 provider endpoint factory](https://github.com/zeroclaw-labs/zeroclaw/blob/99bd353/crates/zeroclaw-providers/src/factory.rs)

These fixtures establish behavior for the pinned Home Assistant image and
ZeroClaw binary. They do not establish the effective options, entity exposure,
account roles, or access policy of a particular Home Assistant installation.
