# Platform Builder

Platform Builder (`agents/builder.py`) is lane 2's engine — the agent that makes "builds itself" a thing the platform does.

## Tools

- `StudioTools` over the safe registry
- Agno docs MCP

Everything it can hand a new component comes from `app/registry.py`.

## Build Behavior

**Builds come out published.** `create_agent`, `create_team`, `create_workflow` all take `publish=true`. A bad tool/model/knowledge/learning name fails the create instead of producing something broken.

**Drafts, versions, archive, restore.** Every mutation lands in Postgres as a versioned row, inspectable and reversible, inert until published.

## HITL Gates

Three operations pause for human approval:
- `archive_component`
- `delete_version`
- `delete_schedule`

The gate resolves in: AgentOS UI, Slack approve button, or `continue_run` over MCP.

## Refusals

It refuses unsafe capability:
- Secret exfiltration, reading `.env`
- Unrestricted writes, shell execution
- Discovered toolkits (not buildable)
- Composing the Agno team or Platform Builder itself

## Scheduling

It can schedule what it builds, always naming:
- The cost of recurring model spend
- How to turn it off

It never schedules a component that can pause for a human (has `user_feedback_tools`).
