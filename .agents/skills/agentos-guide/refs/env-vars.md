# Environment Variables

## Required

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | OpenAI key for models + embeddings |

## Runtime

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNTIME_ENV` | `prd` | `dev` disables JWT. Compose sets to `dev` locally. |
| `AGNO_DEBUG` | `False` | Verbose debug logs when `True` |
| `WAIT_FOR_DB` | `False` | Block on DB before serving when `True` |

## Authentication

| Variable | When Required | Description |
|----------|---------------|-------------|
| `JWT_VERIFICATION_KEY` | prd | Public key from os.agno.com |
| `JWT_JWKS_FILE` | prd (alt) | Path to JWKS file (alternative to key) |
| `MCP_CONNECT_SECRET` | MCP OAuth | ≥16 chars; enables built-in OAuth for claude.ai/ChatGPT |
| `AGENTOS_MCP_SIGNING_KEY` | optional | High-entropy signing key for OAuth tokens |

## Platform URL

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTOS_URL` | `http://127.0.0.1:8000` | Scheduler base URL; must be set correctly in prod |

## Features

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_DEPLOY_CHECK` | `True` | Daily deployment-check cron |
| `EVALS_TAG` | `smoke` | Tag for run-evals workflow |
| `EVALS_CASE_TIMEOUT_SECONDS` | `90` | Per-case timeout |
| `EVALS_SUITE_TIMEOUT_SECONDS` | derived | Whole-suite timeout |

## Integrations

| Variable | Description |
|----------|-------------|
| `PARALLEL_API_KEY` | Web search auth (Parallel SDK when set; keyless MCP fallback) |
| `SLACK_BOT_TOKEN` | Bot token — both required for Slack interface |
| `SLACK_SIGNING_SECRET` | Signing secret |

## Database

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | matches compose | Postgres host |
| `DB_PORT` | matches compose | Postgres port |
| `DB_USER` | matches compose | Database user |
| `DB_PASS` | matches compose | Database password |
| `DB_DATABASE` | matches compose | Database name |
| `DB_DRIVER` | `postgresql+psycopg` | SQLAlchemy driver |
