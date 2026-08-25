## Conventions

### Agent pattern

Every agent file has the same shape:

```python
"""
<Title> Agent
=============
"""

from agno.agent import Agent

from app.settings import default_model
from db import get_postgres_db

INSTRUCTIONS = """\
You are <Name>: <what the agent does, in one line>.

How you speak:
- <one rule per line>

How you <work>:
- <one rule per line; a sequence is a numbered list>\
"""

my_agent = Agent(
    id="my-agent",
    name="My Agent",
    model=default_model(),
    db=get_postgres_db(),
    tools=[...],
    instructions=INSTRUCTIONS,
    add_datetime_to_context=True,
    add_history_to_context=True,
    num_history_runs=5,
)
```

Three patterns to copy from:

- **Learning team lead** — see [`teams/lead.py`](teams/lead.py). Agno is a `Team`: direct tools (the notes toolkit — the leader sees each tool individually) plus `learning=` (the LearningMachine attaches its stores' tools, guidance, and recall automatically), static reference members, and a **StudioRunnerTools** mount (`studio_runners`) that lists and runs every Studio-built component on demand. The same tools+learning shape works unchanged on a plain `Agent` when nothing needs delegating; use `learning=` whenever the component should accumulate durable state across sessions.
- **Context provider** — see [`agents/engineer.py`](agents/engineer.py). A `WorkspaceContextProvider` scopes an agent to a source. Platform Engineer uses `mode=ContextMode.tools` — the read tools (`read_file`, `list_files`, `search_content`) mount directly, so the agent orchestrates its own multi-file reads and cites real paths. The default mode instead exposes one `query_<thing>` tool delegating to a sub-agent — best when collapsing many tools into one keeps the model focused.
- **Studio builder** — see [`agents/builder.py`](agents/builder.py). The agent sees StudioTools, a safe `Registry`, Agno docs MCP, and a HITL gate on the consequential ops: create/edit/publish execute immediately (every mutation lands in the DB as a versioned draft or published component — inspectable, reversible, and inert until published), while archive_component, delete_version, and delete_schedule pause for human approval. Best when the user should create or refine components from the AgentOS UI, Slack, or an MCP frontend.

### Database

```python
# Plain agent — sessions, memory, agentic memory live here
from db import get_postgres_db
agent_db = get_postgres_db()

# Agent with a Knowledge base (RAG) — pass through `knowledge=`
from db import create_knowledge
my_kb = create_knowledge("My Knowledge", "my_vectors")
```

Knowledge bases use PgVector with `SearchType.hybrid` and `text-embedding-3-small`. Document contents go into `<table_name>_contents`.

