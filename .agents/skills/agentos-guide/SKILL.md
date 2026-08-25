---
name: agentos-guide
description: Deep dive into AgentOS architecture, agents, MCP, registry, and platform internals. Use when asked about how the platform works, what agents do, how to extend it, or platform configuration.
---

# AgentOS Architecture Guide

This skill provides detailed documentation about this AgentOS platform. Read the relevant reference files based on what you need to understand.

## Reference Files

| Topic | File | When to read |
|-------|------|--------------|
| Architecture | `refs/architecture.md` | Platform structure, registry, shared resources, offloading, CEL |
| Agno team | `refs/agno.md` | Team lead, learning, notes, entities, identity, HITL |
| Platform agents | `refs/platform-agents.md` | Builder, Manager, Engineer — all three agents |
| Interfaces | `refs/interfaces.md` | MCP endpoint, OAuth, Slack, connecting clients |
| Configuration | `refs/configuration.md` | Environment variables, scheduler, cron jobs |
| Development | `refs/development.md` | Local setup, hot-reload, format/validate, common tasks |
| Conventions | `refs/conventions.md` | Agent pattern, database patterns |
| Evals | `refs/evals.md` | Eval suite, hooks, tags |
| Portable core | `refs/portable-core.md` | Deploy family concept, portable vs AWS-specific |

## Instructions

1. Identify which topic the user is asking about
2. Read the relevant reference file(s) from `refs/`
3. Answer grounded in the actual content

For coding-agent tasks (adding features, fixing bugs), route to the appropriate skill instead:
- `/create-agent` — scaffold new agents
- `/extend-agent` — add tools, refine prompts
- `/deploy-platform` — production deployment
