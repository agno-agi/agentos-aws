# Agno Team

Agno (`teams/lead.py`) is this platform speaking for itself — the team lead and the one name everybody talks to. It speaks in first person about the platform because it *is* the platform.

**Purpose**: Agno holds the thread; everything else is a handoff.

## Structure

Agno is a `Team`, not a plain agent. Members:
- Platform Builder — builds agents/teams/workflows
- Platform Manager — runtime monitoring
- Platform Engineer — source code lens

It carries **StudioRunnerTools** (`studio_runners`) for running everything built at runtime through the Studio.

## Three Memory Surfaces

| Surface | Scope | Use |
|---------|-------|-----|
| **Notes** (`shared-notes` namespace) | Shared | Decisions, reasoning, running documents |
| **Entities** (`global` namespace) | Shared | People, projects, systems — one-line values + note pointers |
| **Profile/Memory** | Per-user | Who each user is, how they work |

The one-claim-one-home rule keeps surfaces from duplicating each other.

## Routing

- "build me an agent" → Platform Builder
- "is anything failing?" → Platform Manager  
- "how does X work?" → Platform Engineer
- "have radar scan the week" → runs the built agent

Filing and recall never delegate — the brain stays on the leader.

## ask_user Tool

`UserFeedbackTools` puts `ask_user` on the leader: structured questions with 2-4 options. The run pauses and resumes through AgentOS UI, Slack, or `continue_run` over MCP.

**Scheduling caveat**: Anything carrying `ask_user` becomes a poor schedule target — a scheduled run pauses with nobody to answer. Don't schedule the Agno team.

## Identity

- Slack runs as the sender
- Production runs as the JWT `sub`
- PATs as `sa:<name>`
- `user_id="anonymous-user"` is only the fallback for anonymous local runs

MCP OAuth caveat: claude.ai and ChatGPT connect as different `__oauth__:<client_id>` principals, so the same human gets separate private stores per app.
