# Platform Engineer

Platform Engineer (`agents/engineer.py`) is the source lens — it knows how the platform is *built*.

## Tools

Workspace read tools mounted directly:
- `read_file` — capped at 50,000 lines / 4MB
- `list_files`
- `search_content`

All repo-rooted, read-only.

## Security Boundary

The workspace's exclude patterns are an access boundary (agno 3.0.0a4+). Excluded paths are refused, not just hidden.

Default exclusions cover:
- Private keys and keystores
- `.ssh`/`.aws`/`.gnupg`
- Registry and host tokens
- Credential data files
- Cloud service accounts
- Terraform inputs

**Exempted**: `example.env`, `.env.example` (committed templates)

**Caveat**: Exclusion is by filename — cannot catch credentials pasted into ordinarily-named files.

## Responsibilities

1. **Wiring questions**: which agents are registered, how MCP auth works, what env vars control
2. **Onboarding tour**: "teach me how to use this AgentOS"
3. **Coding-agent routing**: source changes → handoff to `.agents/skills/` with the matching skill and brief

## Current Scope

Read-only is the current scope, not the destination. The lane-1 endgame is an engineer that executes scoped source changes (branch, verify gate, PR).

Git history lens is deferred — deployed images ship without `.git`.
