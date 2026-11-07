# ZeroClaw for Home Assistant

A small Home Assistant app that runs native ZeroClaw. Telegram conversations,
model selection, tool approvals, memory and sessions belong to ZeroClaw. Home
Assistant supplies its native MCP endpoint and controls exposed entities.

The 4.0 overhaul targets ZeroClaw 0.8.7, Home Assistant 2026.11 and aarch64.
It replaces the previous custom broker, Telegram watcher and policy framework.
Home access starts disabled; the supported MCP setup is read-only.

- [Setup and operation](zeroclaw/DOCS.md)
- [Architecture and assurance](zeroclaw/ARCHITECTURE.md)
- [Upgrade and recovery](zeroclaw/UPGRADE.md)
- [MCP compatibility evidence](zeroclaw/MCP-COMPATIBILITY.md)
- [Independent architecture reviews](zeroclaw/ARCHITECTURE-REVIEWS.md)
- [Local qualification results](zeroclaw/QUALIFICATION.md)
- [Isolated HA canary preparation](zeroclaw/CANARY.md)

The native overhaul passed local qualification. A published, signed image and a live
Home Assistant installation are separate release steps; source changes alone
do not establish either.
