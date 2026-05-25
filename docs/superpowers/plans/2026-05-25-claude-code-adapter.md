# Claude Code Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Claude Code CLI as an alternative agent backend to Symphony, selectable via `WORKFLOW.md` config, keeping the existing Codex integration fully functional.

**Architecture:** Create a `ClaudeCode.Adapter` module that mirrors the `Codex.AppServer` interface. The `AgentRunner` selects between them based on `agent.kind` in config. All other modules (orchestrator, dashboard, web) remain unchanged because the adapter emits the same message format.

**Tech Stack:** Elixir/OTP, Claude Code CLI (`claude -p --output-format stream-json`), Port-based stdio communication, Ecto embedded schema for config.

**Spec:** `docs/superpowers/specs/2026-05-25-claude-code-adapter-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/symphony_elixir/claude_code/adapter.ex` | CREATE | Claude Code CLI adapter: start_session, run_turn, stop_turn, JSON parsing |
| `lib/symphony_elixir/config/schema.ex` | MODIFY | Add `ClaudeCode` embedded schema and `agent.kind` field |
| `lib/symphony_elixir/agent_runner.ex` | MODIFY | Add provider selection based on `agent.kind` |
| `test/symphony_elixir/claude_code/adapter_test.exs` | CREATE | Unit tests for adapter |
| `test/support/test_support.exs` | MODIFY | Add claude_code config support to test helpers |
| `elixir/mix.exs` | MODIFY | Add `:elixir_uuid` dependency |

---

### Task 1: Add UUID dependency to mix.exs

**Files:**
- Modify: `elixir/mix.exs:64-79`

- [ ] **Step 1: Add elixir_uuid dependency**

In `elixir/mix.exs`, add the UUID dependency to the `deps/0` function:

```elixir
{:elixir_uuid, "~> 1.2"},
```

Add it alphabetically in the deps list, between `:ecto` and `:credo`:

```elixir
{:ecto, "~> 3.13"},
{:elixir_uuid, "~> 1.2"},
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
```

- [ ] **Step 2: Fetch dependencies**

Run: `cd elixir && mix deps.get`
Expected: Dependency resolution succeeds, elixir_uuid fetched.

---

### Task 2: Add ClaudeCode config schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`

- [ ] **Step 1: Add the ClaudeCode embedded schema module**

Add after the existing `Codex` module (after line 200) and before the `Hooks` module:

```elixir
defmodule ClaudeCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)
    field(:permission_mode, :string, default: "bypassPermissions")
    field(:turn_timeout_ms, :integer, default: 600_000)
    field(:read_timeout_ms, :integer, default: 300_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :model, :permission_mode, :turn_timeout_ms, :read_timeout_ms], empty_values: [])
    |> validate_required([:command])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:read_timeout_ms, greater_than: 0)
  end
end
```

- [ ] **Step 2: Add `kind` field to Agent module**

In the `Agent` embedded schema (line 122-151), add the `kind` field:

```elixir
embedded_schema do
  field(:kind, :string, default: "codex")
  field(:max_concurrent_agents, :integer, default: 10)
  field(:max_turns, :integer, default: 20)
  field(:max_retry_backoff_ms, :integer, default: 300_000)
  field(:max_concurrent_agents_by_state, :map, default: %{})
end
```

Update the `changeset/2` function to include `:kind` in the cast:

```elixir
def changeset(schema, attrs) do
  schema
  |> cast(
    attrs,
    [:kind, :max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
    empty_values: []
  )
  |> validate_inclusion(:kind, ["codex", "claude_code"])
  |> validate_number(:max_concurrent_agents, greater_than: 0)
  |> validate_number(:max_turns, greater_than: 0)
  |> validate_number(:max_retry_backoff_ms, greater_than: 0)
  |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
  |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
end
```

- [ ] **Step 3: Register claude_code embed in top-level schema**

In the top-level `embedded_schema` block (line 264-273), add after the `:codex` line:

```elixir
embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
embeds_one(:claude_code, ClaudeCode, on_replace: :update, defaults_to_struct: true)
```

- [ ] **Step 4: Add cast_embed for claude_code in changeset**

In the `changeset/1` function (line 354-366), add after the `:codex` cast_embed line:

```elixir
|> cast_embed(:codex, with: &Codex.changeset/2)
|> cast_embed(:claude_code, with: &ClaudeCode.changeset/2)
```

- [ ] **Step 5: Verify compilation**

Run: `cd elixir && mix compile`
Expected: Compiles without errors.

---

### Task 3: Create ClaudeCode.Adapter module

**Files:**
- Create: `elixir/lib/symphony_elixir/claude_code/adapter.ex`

- [ ] **Step 1: Write the adapter module**

Create `elixir/lib/symphony_elixir/claude_code/adapter.ex`:

```elixir
defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  Executes a single Linear issue in its workspace with Claude Code CLI.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576

  @type session :: %{
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          model: String.t() | nil,
          turn_count: integer(),
          settings: map()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = Config.settings!().claude_code

    with {:ok, expanded_workspace} <- validate_workspace(workspace, worker_host),
         :ok <- validate_cli_available(settings) do
      session_id = UUID.uuid4()

      {:ok,
       %{
         session_id: session_id,
         workspace: expanded_workspace,
         worker_host: worker_host,
         model: settings.model,
         turn_count: 0,
         settings: settings
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_timeout = session.settings.turn_timeout_ms
    turn_count = session.turn_count + 1

    args = build_cli_args(session, prompt, turn_count)

    case start_port(args, session.workspace, session.worker_host) do
      {:ok, port} ->
        try do
          emit_message(on_message, :session_started, %{
            session_id: "#{session.session_id}-#{turn_count}",
            thread_id: session.session_id,
            turn_id: turn_count
          })

          case await_turn_completion(port, on_message, turn_timeout) do
            {:ok, result_text} ->
              Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{session.session_id}-#{turn_count}")

              {:ok,
               %{
                 result: result_text,
                 session_id: "#{session.session_id}-#{turn_count}",
                 thread_id: session.session_id,
                 turn_id: turn_count
               }}

            {:error, reason} ->
              Logger.warning("Claude Code turn failed for #{issue_context(issue)}: #{inspect(reason)}")
              {:error, reason}
          end
        after
          stop_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # --- CLI arg building ---

  defp build_cli_args(session, prompt, turn_count) do
    base_args = [
      "-p", prompt,
      "--output-format", "stream-json",
      "--verbose",
      "--permission-mode", session.settings.permission_mode,
      "--dangerously-skip-permissions"
    ]

    session_args =
      if turn_count == 1 do
        ["--session-id", session.session_id]
      else
        ["--resume", session.session_id]
      end

    model_args =
      case session.model do
        nil -> []
        model -> ["--model", model]
      end

    base_args ++ session_args ++ model_args
  end

  # --- Port management ---

  defp start_port(args, workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = build_command(args)
      
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(args, workspace, worker_host) when is_binary(worker_host) do
    alias SymphonyElixir.SSH

    command = "cd #{shell_escape(workspace)} && exec #{build_command(args)}"
    SSH.start_port(worker_host, command, line: @port_line_bytes)
  end

  defp build_command(args) do
    escaped_args = Enum.map(args, &shell_escape/1)
    "claude " <> Enum.join(escaped_args, " ")
  end

  # --- Stream reading ---

  defp await_turn_completion(port, on_message, timeout_ms) do
    read_stream(port, on_message, timeout_ms, "")
  end

  defp read_stream(port, on_message, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_stream_line(port, on_message, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        read_stream(port, on_message, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_stream_line(port, on_message, line, timeout_ms) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = payload} ->
        result_text = Map.get(payload, "result", "")
        usage = extract_usage(payload)
        emit_message(on_message, :turn_completed, %{payload: payload, usage: usage})
        {:ok, result_text}

      {:ok, %{"type" => "assistant"} = payload} ->
        usage = extract_usage(payload)
        emit_message(on_message, :notification, %{payload: payload, usage: usage})
        read_stream(port, on_message, timeout_ms, "")

      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        emit_message(on_message, :session_started, %{payload: payload})
        read_stream(port, on_message, timeout_ms, "")

      {:ok, %{"type" => "system"}} ->
        read_stream(port, on_message, timeout_ms, "")

      {:ok, payload} ->
        Logger.debug("Claude Code unhandled event: #{inspect(Map.get(payload, "type"))}")
        read_stream(port, on_message, timeout_ms, "")

      {:error, _reason} ->
        if String.starts_with?(String.trim(line), "{") do
          Logger.warning("Claude Code malformed JSON: #{String.slice(line, 0, 200)}")
        end

        read_stream(port, on_message, timeout_ms, "")
    end
  end

  # --- Usage extraction ---

  defp extract_usage(payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, "modelUsage") || %{}

    input =
      Map.get(usage, "input_tokens") ||
        Map.get(usage, "inputTokens") || 0

    output =
      Map.get(usage, "output_tokens") ||
        Map.get(usage, "outputTokens") || 0

    total =
      Map.get(usage, "total_tokens") ||
        Map.get(usage, "totalTokens") || 0

    %{input_tokens: input, output_tokens: output, total_tokens: total}
  end

  defp extract_usage(_payload), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  # --- Validation ---

  defp validate_workspace(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp validate_cli_available(settings) do
    command = String.split(settings.command, " ", parts: 2) |> List.first()

    if System.find_executable(command) do
      :ok
    else
      {:error, {:claude_cli_not_found, command}}
    end
  end

  # --- Helpers ---

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = Map.put(details, :event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ -> try do
              Port.close(port)
              :ok
            rescue
              ArgumentError -> :ok
            end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown_issue"
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd elixir && mix compile`
Expected: Compiles without errors.

---

### Task 4: Update AgentRunner for provider selection

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: Add provider selection function**

Add after the module attributes and aliases (after line 9):

```elixir
defp agent_provider do
  case Config.settings!().agent.kind do
    "claude_code" -> SymphonyElixir.ClaudeCode.Adapter
    _ -> SymphonyElixir.Codex.AppServer
  end
end
```

- [ ] **Step 2: Modify run_codex_turns to use provider**

Replace the `run_codex_turns/5` function (starting at line 79) to use the provider:

```elixir
defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
  provider = agent_provider()

  with {:ok, session} <- provider.start_session(workspace, worker_host: worker_host) do
    try do
      do_run_codex_turns(provider, session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
    after
      provider.stop_session(session)
    end
  end
end
```

- [ ] **Step 3: Update do_run_codex_turns to accept provider**

Update the `do_run_codex_turns` function signature to include provider as first arg:

```elixir
defp do_run_codex_turns(provider, app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
  prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

  with {:ok, turn_session} <-
         provider.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
    Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          provider,
          app_session,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Verify compilation**

Run: `cd elixir && mix compile`
Expected: Compiles without errors.

---

### Task 5: Update test support for claude_code config

**Files:**
- Modify: `elixir/test/support/test_support.exs`

- [ ] **Step 1: Add claude_code defaults to workflow_content**

In the `workflow_content/1` function's default Keyword.merge list (around line 94-128), add these entries:

```elixir
agent_kind: "codex",
claude_code_command: "claude",
claude_code_model: nil,
claude_code_permission_mode: "bypassPermissions",
claude_code_turn_timeout_ms: 600_000,
claude_code_read_timeout_ms: 300_000,
```

- [ ] **Step 2: Extract claude_code values and add YAML sections**

After the `codex_` variable extractions (around line 147-153), add:

```elixir
agent_kind = Keyword.get(config, :agent_kind)
claude_code_command = Keyword.get(config, :claude_code_command)
claude_code_model = Keyword.get(config, :claude_code_model)
claude_code_permission_mode = Keyword.get(config, :claude_code_permission_mode)
claude_code_turn_timeout_ms = Keyword.get(config, :claude_code_turn_timeout_ms)
claude_code_read_timeout_ms = Keyword.get(config, :claude_code_read_timeout_ms)
```

In the YAML sections list (around line 167-199), update the `agent:` section and add `claude_code:`:

```elixir
"agent:",
"  kind: #{yaml_value(agent_kind)}",
"  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
"  max_turns: #{yaml_value(max_turns)}",
"  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
"  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
```

And add after the codex section:

```elixir
"claude_code:",
"  command: #{yaml_value(claude_code_command)}",
"  model: #{yaml_value(claude_code_model)}",
"  permission_mode: #{yaml_value(claude_code_permission_mode)}",
"  turn_timeout_ms: #{yaml_value(claude_code_turn_timeout_ms)}",
"  read_timeout_ms: #{yaml_value(claude_code_read_timeout_ms)}",
```

- [ ] **Step 3: Verify tests still pass with default config**

Run: `cd elixir && mix test`
Expected: All existing tests pass (no regressions from new default `agent.kind: codex`).

---

### Task 6: Write adapter unit tests

**Files:**
- Create: `elixir/test/symphony_elixir/claude_code/adapter_test.exs`

- [ ] **Step 1: Write tests for start_session validation**

Create `elixir/test/symphony_elixir/claude_code/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.ClaudeCode.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Adapter

  describe "start_session/2" do
    test "rejects the workspace root path" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-code-cwd-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code"
        )

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
                 Adapter.start_session(workspace_root)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects paths outside workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-code-outside-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code"
        )

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
                 Adapter.start_session(outside_workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "returns ok with valid workspace" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-code-valid-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        issue_workspace = Path.join(workspace_root, "MT-100")
        File.mkdir_p!(issue_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code"
        )

        assert {:ok, session} = Adapter.start_session(issue_workspace)
        assert session.session_id != nil
        assert session.turn_count == 0
        assert session.workspace == issue_workspace

        # session_id must be a valid UUID format
        assert String.match?(session.session_id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when claude CLI is not found" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-code-no-cli-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        issue_workspace = Path.join(workspace_root, "MT-101")
        File.mkdir_p!(issue_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude_code",
          claude_code_command: "nonexistent-cli-command-xyz"
        )

        assert {:error, {:claude_cli_not_found, "nonexistent-cli-command-xyz"}} =
                 Adapter.start_session(issue_workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "stop_session/1" do
    test "returns ok without error" do
      assert :ok = Adapter.stop_session(%{session_id: "test"})
    end
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/claude_code/adapter_test.exs`
Expected: All 4 tests pass.

---

### Task 7: Write config tests for claude_code schema

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Add claude_code config tests**

Add at the end of the existing `SymphonyElixir.CoreTest` module, before the final `end`:

```elixir
test "claude_code config defaults and validation" do
  write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)

  config = Config.settings!()
  assert config.agent.kind == "codex"
  assert config.claude_code.command == "claude"
  assert config.claude_code.model == nil
  assert config.claude_code.permission_mode == "bypassPermissions"
  assert config.claude_code.turn_timeout_ms == 600_000
  assert config.claude_code.read_timeout_ms == 300_000
end

test "claude_code config with custom values" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agent_kind: "claude_code",
    claude_code_command: "claude",
    claude_code_model: "opus",
    claude_code_turn_timeout_ms: 120_000
  )

  config = Config.settings!()
  assert config.agent.kind == "claude_code"
  assert config.claude_code.model == "opus"
  assert config.claude_code.turn_timeout_ms == 120_000
end

test "agent.kind rejects invalid values" do
  write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "invalid_agent")

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agent.kind"
end
```

- [ ] **Step 2: Run tests**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs`
Expected: All tests pass including the new config tests.

---

### Task 8: Add adapter to test coverage ignore list

**Files:**
- Modify: `elixir/mix.exs`

- [ ] **Step 1: Add Adapter to ignore_modules**

In `mix.exs`, add `SymphonyElixir.ClaudeCode.Adapter` to the `:ignore_modules` list (after `SymphonyElixir.AgentRunner`):

```elixir
SymphonyElixir.AgentRunner,
SymphonyElixir.ClaudeCode.Adapter,
```

This matches the pattern used for `Codex.AppServer` and `AgentRunner` — both interact with external processes and are integration-tested rather than unit-tested for full coverage.

- [ ] **Step 2: Verify full test suite passes**

Run: `cd elixir && mix test`
Expected: All tests pass, no regressions.

---

## Self-Review Checklist

- [x] **Spec coverage:** Every section in the design doc maps to a task (config → T2, adapter → T3, agent_runner → T4, testing → T6/T7)
- [x] **Placeholder scan:** No TBD/TODO/vague steps; all code blocks contain complete implementations
- [x] **Type consistency:** `session` struct fields match between `start_session`, `run_turn`, and `stop_session`; `agent.kind` string values match between schema validation and provider selection
- [x] **UUID constraint:** Captured in spec update and implemented with `UUID.uuid4()` in Task 3

## NOT in Scope

- Web UI changes for Claude Code-specific metrics
- MCP tool integration for Linear GraphQL in Claude Code mode
- Multi-model routing (e.g., task A → sonnet, task B → opus)
- Cost tracking dashboard beyond what stream-json provides
- SSH worker host support testing (follows same pattern as Codex, integration-only)
- `--worktree` / `--tmux` integration with Claude Code sessions
