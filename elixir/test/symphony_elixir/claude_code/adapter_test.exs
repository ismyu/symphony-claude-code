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
        # PathSafety.canonicalize resolves symlinks (/var → /private/var on macOS)
        assert String.ends_with?(session.workspace, "/workspaces/MT-100")

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
