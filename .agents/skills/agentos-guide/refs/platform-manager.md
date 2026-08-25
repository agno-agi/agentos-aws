# Platform Manager

Platform Manager (`agents/manager.py`) — read-only ops surface, scoped to the runtime lens.

## Tools

- `AgentOSTools` toolkit over Postgres
- Deployment-check tools (reports + on-demand diagnostic)

## Key Operations

| Tool | Purpose |
|------|---------|
| `get_platform_metrics` | Runs, sessions, users, token spend, model mix per day |
| `get_run_activity` | Per-component run counts, latency (avg, p95, slowest), failures |
| `get_tool_activity` | Which tools called most, slowest, model call behavior |
| `list_pending_approvals` | Paused runs awaiting human approval |
| `run_deployment_check` | On-demand readiness check |

## Read-Only Boundary

Least privilege is the point. An ops surface that only reads:
- Can't misfire
- Needs no confirmation gates
- Stays safe to expose from any frontend

**Visibility caveat**: `AgentOSTools` reads Postgres directly, so REST endpoint scopes never apply — anyone who can chat with the agent sees platform-wide aggregates.

## Sanctioned Diagnostics

Platform Manager may run observations that are:
- Deterministic
- Free (no model calls)
- Idempotent
- Non-mutating

`run_deployment_check` qualifies. Run-evals does not (model spend).

## Handoffs

- Source questions → Platform Engineer
- Component changes → Platform Builder
- Code fixes → coding agents through git
