# Scheduler

`scheduler=True` is on in `app/main.py`. Registration lives in `app/schedules.py`.

## Reference Schedules

| Schedule | Default | Purpose |
|----------|---------|---------|
| `deployment-check` | **Enabled** (daily 13:00 UTC) | Deterministic readiness check — no LLM, no cost |
| `run-evals` | **Disabled** | Runs smoke-tagged evals — uses model calls |

`ENABLE_DEPLOY_CHECK=False` disables deployment-check. The env var owns this toggle and re-asserts on every boot.

Enable run-evals from AgentOS UI when you want scheduled eval runs.

## Deployment Check

`workflows/deployment_check.py` is a one-step, deterministic workflow. It checks:
- DB connectivity and tables
- JWT config
- OpenAI key
- Scheduler URL
- MCP endpoint reachability
- Slack env consistency
- Reference component imports
- Registry names
- Schedule state
- Poller liveness

## Adding Your Own

1. Define a `Workflow` in `workflows/`
2. Import into `app/main.py`, add to `AgentOS(workflows=[...])`
3. Register in `register_schedules()`

Common uses:
- Maintenance (purge old sessions, vacuum tables)
- Periodic re-evaluation (weekly eval runs)

## API

See [agno scheduler docs](https://docs.agno.com/agent-os/scheduler) for the cron API.
