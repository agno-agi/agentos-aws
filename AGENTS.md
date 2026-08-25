# AgentOS — AWS Template

AgentOS: the agent platform that builds itself. Built on [Agno](https://docs.agno.com), deployed to AWS ECS Express Mode.

## Tech Stack

- **Framework**: Agno 3.0 (`agno[os,mcp,slack,pgvector,psycopg,csv,excel,docx,pdf,website]`)
- **Model**: `gpt-5.6` via `app.settings.default_model()`
- **Database**: PostgreSQL 17 + pgvector
- **Deploy**: AWS ECS Express Mode (`scripts/aws/`)

## Commands

```bash
# Local development
docker compose up -d --build     # Start platform
./scripts/mcp_check.sh           # Verify MCP endpoint (8 tools)

# Code quality (run from host, needs .venv)
source .venv/bin/activate
./scripts/format.sh              # ruff format + import sort
./scripts/validate.sh            # ruff check + mypy

# Evals (run inside container — Python 3.14 pydantic compat)
docker exec agentos-api python -m evals --tag smoke

# Deploy to AWS
./scripts/aws/up.sh              # First deploy (ECR + RDS + ECS Express)
./scripts/aws/redeploy.sh        # Push changes
./scripts/aws/env-sync.sh        # Sync env vars to Secrets Manager
./scripts/aws/down.sh            # Teardown (confirms first)
```

## Architecture

```
AgentOS  (app/main.py)
├── Agno             (teams/lead.py)       — front door team; routes to members, runs built components
├── Platform Builder (agents/builder.py)   — builds agents/teams/workflows via StudioTools
├── Platform Manager (agents/manager.py)   — read-only ops: metrics, runs, schedules, diagnostics
├── Platform Engineer (agents/engineer.py) — source lens: read/list/search over the repo
├── DeployCheck      (workflows/deployment_check.py)
└── RunEvals         (workflows/run_evals.py)
```

## Key Files

| File | Purpose |
|------|---------|
| `app/main.py` | AgentOS entrypoint |
| `app/registry.py` | Safe Studio registry — the membrane between coding agents and runtime builds |
| `app/learning.py` | `shared_learning` — per-user profile/memory across all agents |
| `app/notes.py` | `shared-notes` notebook |
| `teams/lead.py` | Agno team definition |
| `agents/*.py` | Platform Builder, Manager, Engineer |

## Skills

Coding-agent workflows in `.agents/skills/`. Claude loads on demand — only the description is scanned at startup.

| Skill | Purpose |
|-------|---------|
| `/setup-platform` | Fresh clone → running platform with first agent |
| `/create-agent` | Scaffold a new code-defined agent |
| `/extend-agent` | Add tools, refine prompt, fix bugs |
| `/improve-agent` | Self-improvement loop from INSTRUCTIONS + real usage |
| `/create-evals` | Author eval coverage for an agent |
| `/eval-and-improve` | Run evals, diagnose failures, fix |
| `/review-and-improve` | Repo-wide drift sweep (docs vs code) |
| `/deploy-platform` | Deploy to AWS with JWT setup |
| `/agentos-guide` | Deep dive: architecture, agents, MCP, registry |

## Ports

- **API**: 8000
- **Database**: 5432

## Quick Reference

- **Registry**: `app/registry.py` — 7 buildable tools, discovered tools not buildable
- **Env vars**: `example.env` → `.env`, set `OPENAI_API_KEY`
- **MCP**: `/mcp` endpoint, 8 tools, OAuth via `MCP_CONNECT_SECRET`
- **Slack**: Set `SLACK_BOT_TOKEN` + `SLACK_SIGNING_SECRET`, routes to Agno team
- **Schedules**: `deployment-check` on by default, `run-evals` disabled

## Documentation

- [Agno docs](https://docs.agno.com)
- [AgentOS introduction](https://docs.agno.com/agent-os/introduction)
- [Agno tools/toolkits](https://docs.agno.com/tools/toolkits)

For detailed architecture, agent internals, MCP interface, and configuration: run `/agentos-guide`.
