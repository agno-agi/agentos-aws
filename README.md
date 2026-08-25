# AgentOS: The Agent Platform That Builds Itself

AgentOS is a durable runtime for your agents. Build your own agents, multi-agent teams, and multi-step workflows. Trace every action. Enforce agent- and tool-level governance.

**Three ways to build agents, teams and workflows.**

1. **Coding agent.** Point a coding agent at the skills in [`.agents/skills/`](.agents/skills/) and it runs the whole lifecycle for you: create, extend, improve, eval, review, deploy.
2. **Natural language.** Ask the built-in Platform Builder and it builds the agent for you.
3. **No-code Studio.** Build agents visually using the no-code AgentOS Studio.

**Five ways to use what you build.**

1. **AgentOS UI.** Chat with your agents and inspect sessions, traces, memory, and evals at [os.agno.com](https://os.agno.com?utm_source=github&utm_medium=example-repo&utm_campaign=agentos-aws&utm_content=agentos-aws&utm_term=aws).
2. **AI apps.** Reach your agents from Claude and ChatGPT: paste your `/mcp` URL as a custom connector and approve it with your connect secret.
3. **Chat interfaces.** Use your agents from Slack, WhatsApp, Telegram, and Discord.
4. **Your product.** Call the REST API from your product: run agents, stream responses, and manage sessions, memory, and knowledge.
5. **Your coding agents.** Work with your agents from Claude Code, Codex, or Cursor: `uvx agno connect` mints a token and registers `/mcp` in each of them for you.

<img width="3298" height="2412" alt="AgentOS" src="https://github.com/user-attachments/assets/40a53a42-d4d2-402b-8e92-742609207957" />

<p align="center"><em>Built on <a href="https://docs.agno.com">Agno</a>, everything runs in your cloud, your data lives in your database.</em></p>

## Get Started

Copy this prompt into your favorite coding agent. It sets up the platform and builds your first agent with you:

```text
Help me set up my agent platform and build my first agent.

Clone https://github.com/agno-agi/agentos-aws into a folder called agent-platform, cd in, and run the setup-platform skill (in .agents/skills/).
```

Your coding agent drives the whole flow: it checks Docker, sets up `.env`, boots the platform, verifies the MCP endpoint, connects the AgentOS UI, and builds your first agent with you. Prefer to drive yourself? See [Manual Setup](#manual-setup).

## Manual Setup

### Step 1: Run locally

> **Prerequisite:** [Docker](https://www.docker.com/get-started/) installed and running.

```sh
git clone https://github.com/agno-agi/agentos-aws agentos
cd agentos

# Configure credentials
cp example.env .env
# Open .env and set OPENAI_API_KEY

# Run the platform on docker
docker compose up -d --build
```

Confirm your AgentOS is running at [http://localhost:8000/docs](http://localhost:8000/docs).

### Step 2: Connect the AgentOS UI

1. Open [os.agno.com](https://os.agno.com?utm_source=github&utm_medium=example-repo&utm_campaign=agentos-aws&utm_content=agentos-aws&utm_term=aws) and sign in.
2. Click **Connect OS**, enter `http://localhost:8000` as the URL, name it **Local AgentOS**, and connect.

### Step 3: Meet Agno — and build your first agent through it

1. Click **Chat** under the **Agno** team and tell it what you're working on: "Hey Agno — I'm building a support bot".
2. Now ask it to build: "Build an agent that tracks AI news and writes a daily brief".
3. Click the **Refresh** button on the top right. You should now see the "Daily AI News Brief" agent in the **Agents** dropdown — chat with it directly, or just tell Agno: "Have the news agent brief me."

### Step 4: Check platform health

Click **Chat** under **Platform Manager** and ask: "Is the platform healthy?" It answers from runtime data — eval history, deployment checks, schedules, and the run activity of the agent you just built.

### Step 5: See how it's built

Click **Chat** under **Platform Engineer** and ask: "Tell me about this AgentOS." It reads the repo and gives you the tour — the agents, the skills, the wiring — grounded in real files. Any time you wonder how something works, this is the agent that knows.

### Step 6: Make it yours

Your cloned repo points at this public template. Make it your own:

```sh
git remote rename origin upstream    # keep the template connected for updates
git remote add origin <your-private-repo-url>
git push -u origin main
```

Create the private repo first ([github.com/new](https://github.com/new), or `gh repo create <name> --private`). `upstream` stays connected, so `git pull upstream main` brings in template updates whenever you want them.

## Run in production

You can run the platform anywhere that supports containerized images. This codebase comes with scripts to deploy the platform to AWS with ECS Express Mode and RDS Postgres — and a coding-agent skill, [`/deploy-platform`](.agents/skills/deploy-platform/SKILL.md), that drives them for you and verifies the live platform at the end.

> **Prerequisite:** AWS CLI v2 recent enough for ECS Express Mode (the script checks — upgrade until `aws ecs create-express-gateway-service help` works), credentials configured (`aws sts get-caller-identity` succeeds), and Docker running (the image is built locally and pushed to ECR).

### 1. Set up your production env

Create a new `.env.production` file for production credentials.

```sh
cp .env .env.production          # or cp example.env .env.production
# Edit .env.production with production values
```

Keeping a separate `.env.production` lets us use different values for local and production: different OpenAI keys, production-only credentials, a different Slack workspace.

### 2. Deploy

```sh
./scripts/aws/up.sh
```

This provisions an ECR repo, a private RDS PostgreSQL 17 instance, and Secrets Manager secrets, then makes one `aws ecs create-express-gateway-service` call — which brings the Fargate service, an ALB with HTTPS, security groups, autoscaling (pinned to a single always-on task — the in-process scheduler must not run in replicas), CloudWatch logs and alarms, and a public HTTPS URL (`https://ag-<id>.ecs.<region>.on.aws`, generated per service). The script pauses and asks for a JWT verification key for authentication (see next section). The first run takes ~30-45 minutes end to end — the Express gateway's certificate + DNS provisioning (~10-25 min, measured) and RDS (~8 min) are the long poles; the script waits until the gateway actually answers before declaring success, and watches for (and self-heals) the known first-run IAM-propagation wedge. Redeploys take minutes. Region comes from `AWS_REGION` (default `us-east-1`).

> **Cost note.** This stack idles at roughly **$100-110/month**: ≈$70/mo Fargate (2 vCPU/4 GB x86; ARM would be ≈$57 — edit `runtimePlatform` in [`scripts/aws/task-def.json`](scripts/aws/task-def.json) *and* change the `docker build --platform linux/amd64` in `up.sh` and `redeploy.sh` to `linux/arm64`), ≈$17-25/mo for the ALB (shared across up to 25 Express services), and ≈$14/mo for the RDS db.t4g.micro. AWS bills idle resources — tear down what you don't use with `./scripts/aws/down.sh`.

### 3. Production Auth

Token-Based Authorization is on by default. Without a `JWT_VERIFICATION_KEY` or `JWT_JWKS_FILE`, the app refuses to serve traffic in production. The platform's job is to keep your data private, so the safe default is "refuse to start" without an authentication token.

Token-Based Auth gives you three things:

1. **No public access.** The server rejects requests without a valid token.
2. **Per-request identity.** Middleware parses the token and extracts the `user_id`, `session_id`, and custom claims. Each request is tied to a user and session, giving you auditability and traceability.
3. **Granular permissions.** Scopes on the token decide what each caller can do — run agents, read sessions, manage the platform. Admin tokens can do everything; scoped tokens get exactly what their claims grant.

During `./scripts/aws/up.sh`, the script creates your Express service URL and pauses so you can mint the key before the app serves traffic. (Only `/health` stays open — AgentOS serves it unauthenticated even in production, so the ALB health checks pass.)

1. Open [os.agno.com](https://os.agno.com?utm_source=github&utm_medium=example-repo&utm_campaign=agentos-aws&utm_content=agentos-aws&utm_term=aws), click **Connect OS** → **Live**, and enter your service URL.
2. Name it **Live AgentOS**, flip **Token-Based Authorization (JWT)** on — the toggle is right on the connect panel — and connect. The UI generates your public key. (Already connected without it? **Settings** → **OS & Security** → **Token-Based Authorization (JWT)**.)
3. Copy the public key.
4. Paste the full public key into the `up.sh` prompt. The script saves it into your env file for future syncs and pushes it to Secrets Manager:

```sh
JWT_VERIFICATION_KEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkq...
-----END PUBLIC KEY-----"
```

> **Heads up.** Live AgentOS Connections are a paid feature. Use `PLATFORM30` to get 1 month off. We are working on a free trial so you don't have to pay to try.

If you run non-interactively or skip the prompt, you can sync environment variables later with `./scripts/aws/env-sync.sh`.

### 4. Register your production AgentOS to MCP clients

Re-run `uvx agno connect`, this time pointed at your deployed domain, to register your production MCP endpoint:

```sh
uvx agno connect --url https://<your-service-url>
```

Then **restart Claude Code** (or run `/mcp` inside a session) so it picks up the new server. Because production uses OAuth, complete the one-time sign-in:

```sh
claude mcp login agentos
```

A browser opens, you enter the `MCP_CONNECT_SECRET` (from `.env.production`), and the CLI captures the token. After that, the connection is permanent.

For **claude.ai and ChatGPT (web)**: add `https://<your-service-url>/mcp` as a custom connector. Leave OAuth fields empty, click **Connect**, and enter the `MCP_CONNECT_SECRET` on the consent page.

### 5. Verify

You can check the logs in the CloudWatch console, or tail them from your machine:

```sh
aws logs tail /ecs/agent-os --follow --region <region>
```

### 6. Redeploy after code changes

For updates from your machine, run the following command:

```sh
./scripts/aws/redeploy.sh
```

It rebuilds the image, pushes it to ECR, and rolls the Express service to the new build.

### 7. Sync environment variables

To re-sync environment variables, run the following command:

```sh
./scripts/aws/env-sync.sh
```

Secret-shaped keys (API keys, `DB_PASS`, the JWT key, Slack credentials, the MCP OAuth secrets) go to Secrets Manager; everything else rides as plain task-definition env vars, and the service rolls once.

### Tear down

```sh
./scripts/aws/down.sh
```

Deletes the Express service (its ALB wiring, security groups, and autoscaling with it), the RDS instance (all data), the ECR repo, the secrets, and the log group. AWS bills idle resources, so tear down what you don't use.

### Opting out of JWT (not recommended)

Change `authorization=runtime_env != "dev"` to `authorization=False` in [`app/main.py`](app/main.py) and redeploy. Use this only inside a private VPC behind another auth layer. Without it, anyone who guesses your service URL can access your platform.

## Using the platform

This platform is designed so that coding agents can drive the entire **create → improve → evaluate → maintain** lifecycle for you.

### Create

Open your coding agent of choice (Claude Code, Codex, Cursor) and run:

```
/create-agent
```

It asks a few questions, generates the agent file in `agents/`, registers it in `app/main.py`, adds its description and quick prompts to `app/config.yaml`, restarts the container, and smoke-tests it live.

### Improve

Improve your agents by running the following skills:

- **`/extend-agent`** — Add a tool, add a capability, refine the instructions, fix a known bug.
- **`/improve-agent`** — Claude simulates scenarios from the agent's `INSTRUCTIONS` and its real usage recorded in the database, runs them against the live container, judges the responses, and edits until they pass.

### Evaluate

Run the eval suite to check for regressions. The evals live in [`evals/cases.py`](evals/cases.py), and run history shows up at os.agno.com next to your sessions and traces.

The evals run on the host machine, so set up the venv with `./scripts/venv_setup.sh && source .venv/bin/activate`, then:

```sh
python -m evals --tag smoke      # fast checks of the self-driving surfaces
python -m evals --tag release    # broader pre-release confidence
python -m evals --name <case>    # one case while iterating
python -m evals -v               # stream the full run with rich panels
```

If a case fails, run **`/eval-and-improve`** — it diagnoses each failure, fixes what's in scope, and loops until green. And when you build an agent of your own, **`/create-evals`** writes its coverage: it mines your real sessions for scenarios and adds cases tagged `smoke`, which the daily run-evals schedule picks up. That schedule ships **disabled** because it spends model calls — enable it from the AgentOS UI when you want the nightly watch.

### Maintain

Because the repo is managed by coding agents, it moves fast. Run `/review-and-improve` before a release or after a refactor: it sweeps for drift between docs, code, and config, auto-fixes mechanical drift like stale paths and missing env vars, and flags anything bigger.

## Connect more frontends (optional)

AgentOS comes with an MCP server at `/mcp` (enabled by setting `mcp_server=True` in [`app/main.py`](app/main.py)), so any MCP client can call your agents, teams, and workflows through tools like `run_agent`, `run_team`, and `run_workflow`.

Register your AgentOS with the MCP clients on your machine:

```sh
uvx agno connect
```

It auto-detects Claude Code, Claude Desktop, Codex, and Cursor and registers `http://localhost:8000/mcp`. After a successful connection, open one of these apps and ask:

```text
can you access my agentos mcp?
```

**claude.ai and ChatGPT (web).** Hosted AI apps reach your platform over the internet and need an OAuth login. Deploy to production (above), add `https://<domain>/mcp` as a remote connector, and approve the consent page with your connect secret.

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | yes | none | OpenAI key for models and embeddings. |
| `RUNTIME_ENV` | no | `prd` | `dev` disables JWT. Compose sets this to `dev` for local — never put `dev` in an env file that `env-sync.sh` pushes to the task definition, or production serves unauthenticated. |
| `JWT_VERIFICATION_KEY` | prd | none | Public key from os.agno.com. Required when `RUNTIME_ENV=prd`, unless `JWT_JWKS_FILE` is set. |
| `JWT_JWKS_FILE` | prd | none | Path to a JWKS file; alternative to `JWT_VERIFICATION_KEY` for production JWT verification. |
| `AGENTOS_URL` | no | `http://127.0.0.1:8000` | Scheduler base URL. `scripts/aws/up.sh` sets it to the Express service URL and writes it back into your env file; set by hand only for a custom domain. Left at the localhost default in prod, scheduled jobs silently never fire. Also the public origin OAuth metadata derives from when `MCP_CONNECT_SECRET` is set. |
| `MCP_CONNECT_SECRET` | no | none | If set (≥16 chars, e.g. `openssl rand -base64 32`), `/mcp` becomes its own OAuth 2.1 authorization server so claude.ai and ChatGPT (web) can connect; connecting asks for this secret on a consent page. Requires `AGENTOS_URL`. `scripts/aws/up.sh` auto-generates it on deploy. PAT and JWT bearers keep working alongside. |
| `AGENTOS_MCP_SIGNING_KEY` | no | none | Optional high-entropy signing-key material (≥32 chars) for OAuth tokens. Unset, a strong key is generated and persisted in the database. Rotating it invalidates outstanding tokens. |
| `ENABLE_DEPLOY_CHECK` | no | `True` | The reference deployment-check cron runs daily by default. This env var owns the schedule's toggle (re-asserted on every boot); the workflow is runnable on demand regardless. |
| `EVALS_TAG` | no | `smoke` | Eval tag run by the run-evals workflow. |
| `EVALS_CASE_TIMEOUT_SECONDS` | no | `90` | Default per-case timeout for run-evals runs; applies only to cases that don't set their own `timeout_seconds`. |
| `EVALS_SUITE_TIMEOUT_SECONDS` | no | derived | Whole-suite timeout for run-evals runs; per-case timeouts are the granular limit. Unset, it is derived from the cases the tag selects. Set it to override. |
| `PARALLEL_API_KEY` | no | none | Authenticates Agno's and the Studio registry's web search tools (Parallel SDK when set; keyless MCP fallback). |
| `SLACK_BOT_TOKEN` / `SLACK_SIGNING_SECRET` | no | none | Both must be set to enable the Slack interface. The bot token also lights up the registry's send-only Slack toolkit for built agents. |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASS` / `DB_DATABASE` | no | matches compose | Postgres connection. |
| `DB_DRIVER` | no | `postgresql+psycopg` | SQLAlchemy driver. |
| `AGNO_DEBUG` | no | `False` | If `True`, Agno emits verbose debug logs. Compose sets this for dev. |
| `WAIT_FOR_DB` | no | `False` | If `True`, the entrypoint blocks on the DB before starting. Compose sets this. |

## Learn more

- [Agno documentation](https://docs.agno.com?utm_source=github&utm_medium=example-repo&utm_campaign=agentos-aws&utm_content=agentos-aws&utm_term=aws)
- [AgentOS introduction](https://docs.agno.com/agent-os/introduction?utm_source=github&utm_medium=example-repo&utm_campaign=agentos-aws&utm_content=agentos-aws&utm_term=aws)
- [Agno on GitHub](https://github.com/agno-agi/agno). Drop a star if this is useful.
