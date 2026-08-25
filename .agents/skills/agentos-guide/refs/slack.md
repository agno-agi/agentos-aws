# Slack Interface

Set `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` and restart.

## Default Routing

`app/main.py` routes Slack messages to the `agno` team. Because Agno leads Platform Builder, Platform Manager, and Platform Engineer:
- "build me an agent" → works
- "is anything failing?" → works
- "how does X work?" → works

Change the `team=` arg to point at another component.

## Identity

- Each sender keeps their private profile and memory
- Sessions are thread-scoped:
  - New top-level mention → fresh session
  - Replies in thread → shared session
- Notes and entities are shared

## Migration Note (2.8 → 3.0)

Threads started on pre-3.0 platform key sessions to old `chief` id. A run under `agno` won't resume them — start fresh threads.

- Entities and per-user profiles/memories carry over
- Shared notes do NOT — 2.8 used `brain` namespace, 3.0 uses `shared-notes`
- One-off copy needed between namespaces (`fs.agno_fs` table in Postgres)

## Other Interfaces

For Discord, Telegram, WhatsApp, and custom UIs, mirror the Slack conditional pattern with the relevant agno interface.

See [agno interfaces overview](https://docs.agno.com/agent-os/interfaces/overview).
