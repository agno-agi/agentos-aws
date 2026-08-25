---
name: agentos-guide
description: Deep dive into AgentOS architecture, agents, MCP, registry, and platform internals. Use when asked about how the platform works, what agents do, how to extend it, or platform configuration.
---

# AgentOS Architecture Guide

This skill provides detailed documentation about this AgentOS platform. Read the relevant reference files based on what you need to understand.

## Reference Files

| Topic | File | When to read |
|-------|------|--------------|
| Architecture overview | `refs/architecture.md` | Understanding the platform structure, registry, shared resources |
| Agno team | `refs/agno.md` | How the front door team works, learning, notes, entities |
| Platform Builder | `refs/platform-builder.md` | Runtime agent building via Studio |
| Platform Manager | `refs/platform-manager.md` | Ops toolkit, metrics, diagnostics |
| Platform Engineer | `refs/platform-engineer.md` | Source lens, workspace tools |
| MCP interface | `refs/mcp-interface.md` | /mcp endpoint, OAuth, HITL, tools |
| Scheduler | `refs/scheduler.md` | Cron jobs, deployment-check, run-evals |
| Environment variables | `refs/env-vars.md` | All env var configuration |
| Slack interface | `refs/slack.md` | Bot setup, routing, identity |

## Instructions

1. Identify which topic the user is asking about
2. Read the relevant reference file(s) from `refs/`
3. Answer grounded in the actual content

For coding-agent tasks (adding features, fixing bugs), route to the appropriate skill instead:
- `/create-agent` — scaffold new agents
- `/extend-agent` — add tools, refine prompts
- `/deploy-platform` — production deployment
