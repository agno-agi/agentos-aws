## Development Setup

### Local with Docker

```bash
cp example.env .env
# Edit .env and set OPENAI_API_KEY

docker compose up -d --build
```

The first boot opens MCP connections to `https://docs.agno.com/mcp` and — unless `PARALLEL_API_KEY` is set — `https://search.parallel.ai/mcp`. AgentOS connects them in its lifespan, so the API does not start if either host is unreachable; behind a proxy or firewall, allow both, or set `PARALLEL_API_KEY` to drop the second.

`compose.yaml` sets `RUNTIME_ENV=dev`, `AGNO_DEBUG=True`, and `WAIT_FOR_DB=True` so JWT is off and the API blocks on the DB before serving. It runs uvicorn with a scoped `--reload` (watching `agents/`, `app/`, `db/`, `evals/`, `teams/`, `workflows/`), so code edits hot-reload in a second or two. Restart `agentos-api` after dependency or env changes, or whenever you want a guaranteed-clean state.

### Format & Validate

The format / validate / eval scripts run on the host, so they need a venv. Set one up once:

```bash
./scripts/venv_setup.sh
source .venv/bin/activate
```

Then:

```bash
./scripts/format.sh     # ruff format + import sort
./scripts/validate.sh   # ruff check + mypy (runs both, summarizes)
```

CI installs the same pinned `requirements.txt` and runs the same `scripts/validate.sh` — local and CI never drift.


## Common Tasks

```bash
# Add a dependency
# 1. Edit pyproject.toml
./scripts/generate_requirements.sh   # keeps existing pins; add `upgrade` to refresh every pin
docker compose up -d --build

# Bump agno (alpha, rc, and final releases are the same flow)
# 1. Edit the agno pin in pyproject.toml
./scripts/generate_requirements.sh agnoctl   # agno follows the pin; agnoctl must be named — agno only floors it at the previous release
docker compose up -d --build
./scripts/validate.sh && python -m evals --tag smoke

# Build a multi-arch image (maintainer-only)
./scripts/build_image.sh

# Tail service logs
aws logs tail /ecs/agent-os --follow --region <region>
```

