## Portable core vs. deploy layer

This repo is the AWS sibling of the `agentos-*` deployment family ([agentos-railway](https://github.com/agno-agi/agentos-railway) is the reference). Everything that defines the platform is **portable core — identical across the family**: `agents/`, `app/`, `db/`, `evals/`, `teams/`, `workflows/`, the MCP server wiring, the interfaces, and the coding-agent skills in `.agents/skills/`. `Dockerfile`, `compose.yaml`, and `scripts/entrypoint.sh` are shared local-dev/runtime infra, also not deployment-specific.

The **AWS-specific deploy layer** — what a sibling template swaps out — is exactly:

- [`scripts/aws/`](scripts/aws/) (`up.sh`, `env-sync.sh`, `redeploy.sh`, `down.sh`, `task-def.json`)
- the "Deploying to AWS" prose here and in the README

When editing, keep that boundary crisp: platform behavior belongs in the core, AWS mechanics belong in the deploy layer, and nothing in the core should import from or depend on it.

