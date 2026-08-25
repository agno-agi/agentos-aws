# AgentOS Architecture

```
AgentOS  (app/main.py)
├── Agno             (teams/lead.py)      — the team (front door): LearningMachine + notes + web tools + ask_user + studio_runners,
│                                           members = the three agents below; runs Studio-built components on demand
├── Platform Builder (agents/builder.py)  — lane 2: Agno docs MCP + StudioTools over the safe registry; builds end published
├── Platform Manager (agents/manager.py)  — runtime lens: AgentOSTools read-only ops toolkit + deployment-check tools
├── Platform Engineer (agents/engineer.py) — source lens: read-only workspace tools (read/list/search) over the repo
├── DeployCheck      (workflows/deployment_check.py) — deterministic readiness workflow
└── RunEvals         (workflows/run_evals.py) — opt-in eval suite workflow
```

## Shared Resources

- **Database**: PostgreSQL + pgvector for sessions, memory, knowledge
- **Model**: `app.settings.default_model()` returns `OpenAIResponses(id="gpt-5.6")`
- **Learning**: All four reference components wire the LearningMachine's per-user profile and memory stores — one human, one self across every agent. The machine in `app/learning.py` is registered as `shared-learning`.

## Registry (`app/registry.py`)

The safe Studio registry Platform Builder can use. **Buildable tools**:
- `agno_docs` — Agno documentation MCP
- `parallel_tools` — web search and fetch (Parallel SDK or keyless MCP)
- `shared_notes` — scoped FileSystem (read, append, list, search, check_lines)
- `openai_tools` — image and speech generation
- `file_generation` — JSON/CSV/TXT/HTML/code as downloadable artifacts
- `user_feedback_tools` — structured ask-the-user questions (HITL)
- `calculator` — arithmetic operations

**Discovered but not buildable**: `studio`, `filesystem`, `agentos`, `studio_runners`, `workspace`, deployment-check functions. The route to new capability is always a reviewed code change to the registry.

## Tool Result Offloading

Big tool results are offloaded on the four platform agents only. The `ResultStore` in `app/offload.py` writes results past 16,000 chars to a per-session file store. The transcript keeps a preview plus `result_id`; use `search_result` and `read_result` to retrieve. 7-day TTL.

## CEL Expressions

Built workflows branch on CEL (Common Expression Language). The `cel-python` pin enables it. Examples:
- `previous_step_content == ""` — empty result check
- `current_iteration >= max_iterations` — loop bound
- `previous_step_content.startsWith("Error: ")` — step failure branch

## Key Flags

- `scheduler=True` — enabled by default
- `mcp_server=True` — `/mcp` endpoint on
- `authorization=True` — JWT auth when `RUNTIME_ENV != "dev"`
- `user_isolation=False` — off by default (operator template)
