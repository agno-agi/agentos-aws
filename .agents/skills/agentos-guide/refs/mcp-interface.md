# MCP Interface

`mcp_server=True` mounts an MCP server (streamable HTTP) at `/mcp`, same port as REST API.

## Tools (8 total)

| Tool | Purpose |
|------|---------|
| `get_agentos_config` | Discover valid agent/team/workflow ids |
| `run_agent` | Run an agent |
| `run_team` | Run a team (Agno is `team_id="agno"`) |
| `run_workflow` | Run a workflow |
| `continue_run` | Resume a paused run |
| `cancel_run` | Cancel a run |
| `get_sessions` | List sessions |
| `get_session_runs` | Get runs for a session |

## Authentication

**Dev mode** (`RUNTIME_ENV=dev`): Open (unless MCP OAuth is on)

**Production**: Same middleware as REST API
- JWTs from os.agno.com
- Service-account PATs (`agno_pat_…`) via `POST /service-accounts`

`uvx agno connect` mints a PAT and registers `/mcp` in Claude Code / Desktop / Codex / Cursor.

## MCP OAuth

Set `MCP_CONNECT_SECRET` (≥16 chars) and `/mcp` becomes its own OAuth 2.1 authorization server.

This is how claude.ai and ChatGPT (web) connect:
1. Paste `https://<domain>/mcp` as custom connector
2. Leave client ID/secret empty (DCR registers the app)
3. Approve consent page with connect secret

Existing PAT/JWT bearers keep working (`MultiAuth`).

## HITL via MCP

A paused run returns `status=PAUSED` with `requirements` dicts.

To resume: **echo each requirement back unchanged** with `confirmation: true` added, through `continue_run(run_id, agent_id, session_id, requirements)`.

**Critical**: Never send bare `{"confirmation": true}` — it matches nothing and silently fails on the agent path.

## Smoke Check

```bash
./scripts/mcp_check.sh
```

Handshake, asserted tool count (8), and one quick `run_agent` call. Auto-handles auth with a probe service account.
