## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | yes | — | OpenAI key for models + embeddings. |
| `RUNTIME_ENV` | no | `prd` | `dev` disables JWT. Compose sets this to `dev` for local — never put `dev` in an env file that `env-sync.sh` pushes to the task definition, or production serves unauthenticated. |
| `JWT_VERIFICATION_KEY` | prd | — | Public key from os.agno.com. Required when `RUNTIME_ENV=prd` and `authorization=True`, unless `JWT_JWKS_FILE` is set. |
| `JWT_JWKS_FILE` | prd | — | Path to a JWKS file; alternative to `JWT_VERIFICATION_KEY` for production JWT verification. |
| `AGENTOS_URL` | no | `http://127.0.0.1:8000` | Scheduler base URL — cron triggers reach AgentOS over this. `scripts/aws/up.sh` sets it to the Express service URL (generated per service; up.sh reads it after create and rolls a correcting task-definition revision) and writes it back into your env file. Left at the localhost default in prod, scheduled jobs silently never fire. Also the public origin OAuth metadata derives from when `MCP_CONNECT_SECRET` is set. |
| `MCP_CONNECT_SECRET` | no | — | If set (≥16 chars, e.g. `openssl rand -base64 32`), `/mcp` becomes its own OAuth 2.1 authorization server (built-in tier) so claude.ai and ChatGPT (web) can connect; connecting asks for this secret on a consent page. Requires `AGENTOS_URL`. PAT and JWT bearers keep working alongside. `scripts/aws/up.sh` auto-generates it into your env file on deploy and stores it in Secrets Manager. |
| `AGENTOS_MCP_SIGNING_KEY` | no | — | Optional high-entropy signing-key material (≥32 chars) for OAuth tokens. Unset, a strong key is generated and persisted in the database. Rotating it invalidates outstanding tokens. |
| `ENABLE_DEPLOY_CHECK` | no | `True` | The reference deployment-check cron (`app/schedules.py`) runs daily by default. This env var owns the schedule's toggle and re-asserts it on every boot, both directions — so flip the cron here, not in the UI. The workflow stays runnable on demand regardless. |
| `EVALS_TAG` | no | `smoke` | Eval tag run by the run-evals workflow. |
| `EVALS_CASE_TIMEOUT_SECONDS` | no | `90` | Default per-case timeout for run-evals runs; applies only to cases that don't set their own `timeout_seconds`. |
| `EVALS_SUITE_TIMEOUT_SECONDS` | no | derived | Whole-suite timeout for run-evals runs; per-case timeouts are the granular limit. Unset, it is derived from the cases the tag actually selects (their ceilings plus hook margin), so adding a case never silently outgrows the budget. Set it to override. |
| `PARALLEL_API_KEY` | no | — | Authenticates Agno's and the Studio registry's web search tools (Parallel SDK when set; keyless MCP fallback with a lower rate ceiling). |
| `SLACK_BOT_TOKEN` | no | — | Bot token. Set with signing secret to enable the Slack interface. Also lights up the registry's send-only Slack toolkit (post + list channels), so built agents can be wired to post to Slack. |
| `SLACK_SIGNING_SECRET` | no | — | Signing secret. Both it and the bot token must be set for the interface to load. |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASS` / `DB_DATABASE` | no | matches compose | Postgres connection. |
| `DB_DRIVER` | no | `postgresql+psycopg` | SQLAlchemy driver. |
| `AGNO_DEBUG` | no | `False` | If `True`, agno emits verbose debug logs. Compose sets this for dev. |
| `WAIT_FOR_DB` | no | `False` | If `True`, the entrypoint blocks on the DB before starting. Compose sets this. |


## Scheduler

`scheduler=True` is on in [`app/main.py`](app/main.py). A schedule is a cron expression + an HTTP endpoint (a workflow or agent run); the poller fires due jobs in the background. Registration lives in [`app/schedules.py`](app/schedules.py)'s `register_schedules()`, called from the lifespan — idempotent (`if_exists="update"`, safe on every boot) and fail-soft (a bad schedule logs a warning rather than crashing startup).

**Reference examples.** [`workflows/deployment_check.py`](workflows/deployment_check.py) is a one-step, **deterministic** workflow — no LLM, no token cost — that returns a deployment readiness report. It checks DB connectivity and tables, JWT config, the OpenAI key, scheduler URL, MCP endpoint reachability, Slack env consistency, reference component imports, the registry names built components resolve by, schedule state, and whether the scheduler poller is actually firing. [`app/schedules.py`](app/schedules.py) registers a daily cron that hits its endpoint (`POST /workflows/deployment-check/runs`). Because it's deterministic and free, the cron runs **on** by default (daily at 13:00 UTC); disable it with `ENABLE_DEPLOY_CHECK=False` — the env var owns this toggle and re-asserts it on every boot, so a UI flip lasts only until the next restart.

[`workflows/run_evals.py`](workflows/run_evals.py) runs a tagged subset of the eval suite and returns a compact report. Its daily 14:00 UTC schedule is always registered but ships **disabled** because it uses model calls — enable it from the AgentOS UI (or `POST /schedules/{id}/enable`) to run the smoke-tagged cases daily. The enabled toggle is yours after that: boot-time registration refreshes the schedule's definition but never overrides it. Enable it with the Evals section's only-writer rule in mind: smoke includes learning-store cases whose teardown sweeps anything written to the shared stores during the case window, so a scheduled run while the team is talking to Agno can delete their filings — pick an hour nobody is, or leave the schedule off on a busy platform and run the suite deliberately instead.

To add your own: define a `Workflow` in `workflows/`, import it into [`app/main.py`](app/main.py) and add it to `AgentOS(workflows=[...])`, and register a schedule for it in `register_schedules()`. Other common uses: **maintenance** (purge old sessions, vacuum tables), **periodic re-evaluation** (run `python -m evals` weekly to catch regressions).

See [agno scheduler docs](https://docs.agno.com/agent-os/scheduler) for the cron API.

