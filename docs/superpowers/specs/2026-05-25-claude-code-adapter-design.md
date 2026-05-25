# Claude Code Adapter for Symphony

Date: 2026-05-25
Status: Draft

## Summary

Add Claude Code CLI as an alternative agent backend to Symphony, selectable via `WORKFLOW.md` config. The existing Codex AppServer integration remains fully functional.

## Problem

Symphony only supports OpenAI Codex as its coding agent. Users who prefer Claude Code cannot use Symphony's orchestration (Linear polling, workspace isolation, TUI/Web dashboard, retry logic) with Claude Code.

## Approach

Create a `ClaudeCode.Adapter` module with the same interface as `Codex.AppServer`. The agent runner selects the provider based on `agent.kind` in `WORKFLOW.md`. All other modules (orchestrator, dashboard, API) remain unchanged.

## Architecture

```
Orchestrator (unchanged)
    │
    ▼
AgentRunner (small change: provider selection)
    │
    ▼
┌──────────────────────────────┐
│  agent.kind config switch    │
│  ├─ claude_code → Adapter    │
│  └─ codex (default) → AppServer │
└──────────────────────────────┘
```

## Claude Code CLI Integration

### Command

Primary mode uses `stream-json` for real-time event streaming. `--output-format json` is a fallback that returns a single JSON result but does not emit real-time events.

```
claude -p "<prompt>" \
  --output-format stream-json \
  --verbose \
  --session-id <uuid> \
  --permission-mode bypassPermissions \
  --dangerously-skip-permissions
```

Key flags:
- `--output-format stream-json --verbose`: Required together. Streams newline-delimited JSON events. **This is the primary mode.**
- `--session-id <uuid>`: Sets a deterministic session ID for the first turn.
- `--resume`: Resumes a previous session for continuation turns.
- `--permission-mode bypassPermissions --dangerously-skip-permissions`: Auto-approves all tool calls (required for unattended execution).
- `--model <model>`: Optional model override (e.g., "sonnet", "opus").
- `--max-turns <n>`: Optional turn limit per invocation.

### stream-json Event Types

Each line is a JSON object with a `type` field:

| type | Purpose | Key Fields |
|------|---------|------------|
| `system` | Hooks, init | `subtype`, `session_id`, `tools`, `model` |
| `assistant` | Model response | `message.content[]`, `message.usage` |
| `result` | Final output | `result`, `usage`, `total_cost_usd`, `num_turns`, `session_id` |

### Session Continuation

First turn uses `--session-id <uuidv4>` to create a new session. Subsequent turns use `--resume <uuidv4>` (session ID is **required** in `-p` mode; bare `--resume` without an ID is rejected).

## Module: ClaudeCode.Adapter

### Interface

```elixir
defmodule SymphonyElixir.ClaudeCode.Adapter do
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @spec stop_session(session()) :: :ok
end
```

### Session struct

```elixir
%{
  session_id: String.t(),      # UUID for --session-id / --resume
  workspace: Path.t(),         # Working directory
  worker_host: String.t() | nil,
  model: String.t() | nil,
  turn_count: integer()
}
```

### start_session/2

1. Generate a **UUIDv4** for `session_id` (required by Claude Code CLI; arbitrary strings are rejected). Use `elixir_uuid` or equivalent library.
2. Validate that `claude` CLI is available via `System.find_executable/1`.
3. Return `{:ok, session}` without spawning a process (sessions are per-turn).

### run_turn/4

1. Build CLI args based on turn number:
   - Turn 1: `claude -p "<prompt>" --session-id <uuidv4> ...`
   - Turn 2+: `claude -p "<prompt>" --resume <uuidv4> ...` (the session ID is **required** in `-p` mode; bare `--resume` is rejected by the CLI)
2. Spawn a Port with the command, cd into the workspace.
3. Read newline-delimited JSON from stdout.
4. Parse each line, emit messages to `on_message` callback:
   - `system` with subtype `init` → emit `:session_started`
   - `assistant` → emit `:notification` with usage delta
   - `result` → emit `:turn_completed`, extract usage
5. On port exit or timeout, return `{:ok, result}` or `{:error, reason}`.
6. Map result fields to match `Codex.AppServer.run_turn` return format:
   ```elixir
   %{
     result: result,
     session_id: "#{session_id}-#{turn_count}",
     thread_id: session_id,
     turn_id: turn_count
   }
   ```

### stop_session/1

No-op. Each turn manages its own Port lifecycle.

## Message Format Mapping

Adapter converts Claude Code events to the same `{:codex_worker_update, issue_id, message}` format that the orchestrator expects:

| Claude Code Event | Orchestrator Message |
|-------------------|---------------------|
| `system/init` | `{:codex_worker_update, id, %{event: :session_started, session_id: ...}}` |
| `assistant` | `{:codex_worker_update, id, %{event: :notification, usage: %{...}}}` |
| `result` (success) | `{:codex_worker_update, id, %{event: :turn_completed, usage: %{...}}}` |
| Port exit (error) | `{:codex_worker_update, id, %{event: :turn_ended_with_error, reason: ...}}` |

## Config Changes

### WORKFLOW.md

```yaml
agent:
  kind: claude_code    # "codex" (default) or "claude_code"
  # ... existing fields unchanged

claude_code:
  command: "claude"
  model: "sonnet"
  permission_mode: "bypassPermissions"
  read_timeout_ms: 300000
  turn_timeout_ms: 600000
```

### config/schema.ex

Add `claude_code` section with defaults:

```elixir
%{
  command: "claude",
  model: nil,
  permission_mode: "bypassPermissions",
  read_timeout_ms: 300_000,
  turn_timeout_ms: 600_000
}
```

Add `agent.kind` field with default `"codex"`.

## File Changes

| File | Change | Description |
|------|--------|-------------|
| `lib/symphony_elixir/claude_code/adapter.ex` | NEW | Claude Code CLI adapter |
| `lib/symphony_elixir/agent_runner.ex` | SMALL | Provider selection by `agent.kind` |
| `lib/symphony_elixir/config/schema.ex` | SMALL | Add `claude_code` config and `agent.kind` |
| `WORKFLOW.md` | EDIT | Add `agent.kind` and `claude_code` section |

Unchanged: orchestrator, dashboard, web, codex/*, dynamic_tool, workspace, tracker, ssh.

## AgentRunner Change

One function modified to select the provider:

```elixir
defp agent_provider do
  case Config.settings!().agent.kind do
    "claude_code" -> SymphonyElixir.ClaudeCode.Adapter
    _ -> SymphonyElixir.Codex.AppServer
  end
end
```

Used in `run_codex_turns`:

```elixir
provider = agent_provider()
with {:ok, session} <- provider.start_session(workspace, worker_host: worker_host) do
```

## Error Handling

All errors follow the existing Codex error patterns:

| Scenario | Error | Orchestrator Action |
|----------|-------|---------------------|
| CLI not found | `{:error, :claude_cli_not_found}` | Retry with backoff |
| Turn timeout | `{:error, :turn_timeout}` | Retry with backoff |
| Port exit | `{:error, {:port_exit, status}}` | Retry with backoff |
| JSON parse failure | Skip line, continue | Log warning |
| Session resume fails | Start fresh session | Log warning, continue |

## Dynamic Tools (Linear GraphQL)

Phase 1: The `linear_graphql` dynamic tool from Codex is not available in Claude Code mode. The workflow prompt should instruct Claude Code to use its built-in tools and the Linear API directly.

Phase 2 (future): Integrate via MCP server or `--append-system-prompt` with tool instructions.

## Prerequisites

- Claude Code CLI installed and authenticated (`claude auth`)
- `ANTHROPIC_API_KEY` environment variable or active Claude subscription
- `--dangerously-skip-permissions` accepted for unattended execution

## Testing

- Unit: Test CLI arg building, JSON parsing, message mapping
- Integration: Mock Port with sample stream-json output
- E2E: Run against a real Linear issue with Claude Code CLI

## Out of Scope

- Web UI changes
- New dashboard metrics specific to Claude Code
- MCP tool integration for Linear GraphQL
- Multi-model routing
- Cost tracking beyond what stream-json provides
