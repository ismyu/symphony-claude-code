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
         :ok <- validate_cli_available(settings, worker_host) do
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
    read_timeout = session.settings.read_timeout_ms
    turn_count = session.turn_count + 1

    args = build_cli_args(session, prompt, turn_count)

    case start_port(args, session.workspace, session.worker_host) do
      {:ok, port} ->
        metadata = port_metadata(port, session.worker_host)
        session_id = "#{session.session_id}-#{turn_count}"

        try do
          emit_message(
            on_message,
            :session_started,
            %{
              session_id: session_id,
              thread_id: session.session_id,
              turn_id: turn_count
            },
            metadata
          )

          case await_turn_completion(port, on_message, read_timeout, turn_timeout, metadata) do
            {:ok, result_text} ->
              Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{session_id}")

              {:ok,
               %{
                 result: result_text,
                 session_id: session_id,
                 thread_id: session.session_id,
                 turn_id: turn_count
               }}

            {:error, reason} ->
              Logger.warning("Claude Code turn failed for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

              emit_message(
                on_message,
                :turn_ended_with_error,
                %{
                  session_id: session_id,
                  reason: reason
                },
                metadata
              )

              {:error, reason}
          end
        after
          stop_port(port)
        end

      {:error, reason} ->
        Logger.error("Claude Code startup failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # --- CLI arg building ---

  defp build_cli_args(session, prompt, turn_count) do
    base_args = [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      session.settings.permission_mode,
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

  defp await_turn_completion(port, on_message, read_timeout_ms, turn_timeout_ms, metadata) do
    deadline = System.monotonic_time(:millisecond) + turn_timeout_ms
    read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")
  end

  defp read_stream(port, on_message, read_timeout_ms, deadline, metadata, pending_line) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    effective_timeout = min(read_timeout_ms, remaining)

    if effective_timeout <= 0 do
      {:error, :turn_timeout}
    else
      receive do
        {^port, {:data, {:eol, chunk}}} ->
          complete_line = pending_line <> to_string(chunk)
          handle_stream_line(port, on_message, complete_line, read_timeout_ms, deadline, metadata)

        {^port, {:data, {:noeol, chunk}}} ->
          read_stream(port, on_message, read_timeout_ms, deadline, metadata, pending_line <> to_string(chunk))

        {^port, {:exit_status, status}} ->
          {:error, {:port_exit, status}}
      after
        effective_timeout ->
          {:error, :turn_timeout}
      end
    end
  end

  defp handle_stream_line(port, on_message, line, read_timeout_ms, deadline, metadata) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = payload} ->
        result_text = Map.get(payload, "result", "")
        usage = extract_usage(payload)
        emit_message(on_message, :turn_completed, %{payload: payload, usage: usage, details: payload}, metadata)
        {:ok, result_text}

      {:ok, %{"type" => "assistant"} = payload} ->
        usage = extract_usage(payload)
        emit_message(on_message, :notification, %{payload: payload, usage: usage, raw: line}, metadata)
        read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")

      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        emit_message(on_message, :session_started, %{payload: payload}, metadata)
        read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")

      {:ok, %{"type" => "system"}} ->
        read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")

      {:ok, payload} ->
        Logger.debug("Claude Code unhandled event: #{inspect(Map.get(payload, "type"))}")
        read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")

      {:error, _reason} ->
        if String.starts_with?(String.trim(line), "{") do
          Logger.warning("Claude Code malformed JSON: #{String.slice(line, 0, 200)}")
        end

        read_stream(port, on_message, read_timeout_ms, deadline, metadata, "")
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
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

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

  defp validate_cli_available(settings, nil) do
    command = String.split(settings.command, " ", parts: 2) |> List.first()

    if System.find_executable(command) do
      :ok
    else
      {:error, {:claude_cli_not_found, command}}
    end
  end

  defp validate_cli_available(_settings, _worker_host) do
    :ok
  end

  # --- Helpers ---

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{claude_code_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp default_on_message(_message), do: :ok

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
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
