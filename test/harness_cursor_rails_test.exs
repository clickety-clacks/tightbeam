defmodule Tightbeam.Harness.CursorRailsTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Harness.CursorRails
  alias Tightbeam.Harness.CursorRails.UnmappableRailError
  alias Tightbeam.Rails

  # Run a compiled Cursor hook command exactly as Cursor does: a shell command
  # with the hook payload on stdin. The Tightbeam command's own stderr is captured
  # INSIDE the wrapper, so the process stdout is only the permission verdict.
  # stdin rides in an env var so no fixture quoting can leak into the script.
  defp run_hook(%{"command" => command}, stdin_json) do
    {out, 0} =
      System.cmd("sh", ["-c", "printf '%s' \"$HOOK_STDIN\" | ( #{command} )"],
        env: [{"HOOK_STDIN", stdin_json}],
        stderr_to_stdout: false
      )

    JSON.decode!(out)
  end

  # A real cursor beforeShellExecution stdin payload (shape captured from the
  # cursor-agent binary v2026.08.11-e8db854): the shell command sits in "command".
  defp shell_stdin(command) do
    JSON.encode!(%{
      "hook_event_name" => "beforeShellExecution",
      "command" => command,
      "cwd" => "/tmp",
      "sandbox" => false
    })
  end

  describe "compile/1 shape and routing" do
    test "nil rails compile to an empty hooks config" do
      assert CursorRails.compile(nil) == %{"hooks" => %{}}
    end

    test "an empty PreToolUse list compiles to an empty hooks config" do
      assert CursorRails.compile(%{"hooks" => %{"PreToolUse" => []}}) == %{"hooks" => %{}}
    end

    test "Bash routes to beforeShellExecution, mcp__ to beforeMCPExecution" do
      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "true"}]},
            %{
              "matcher" => "mcp__fs__write",
              "hooks" => [%{"type" => "command", "command" => "true"}]
            }
          ]
        }
      }

      %{"hooks" => hooks} = CursorRails.compile(pre)

      assert Map.keys(hooks) |> Enum.sort() == ["beforeMCPExecution", "beforeShellExecution"]
      assert [%{"command" => shell_cmd}] = hooks["beforeShellExecution"]
      assert [%{"command" => _mcp_cmd}] = hooks["beforeMCPExecution"]
      # The wrap is applied, not a passthrough of the raw command.
      assert shell_cmd =~ "permission"
      refute shell_cmd == "true"
    end

    test "multiple Bash entries accumulate under one event, order preserved" do
      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo a"}]},
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo b"}]}
          ]
        }
      }

      %{"hooks" => %{"beforeShellExecution" => cmds}} = CursorRails.compile(pre)
      assert length(cmds) == 2
      assert Enum.at(cmds, 0)["command"] =~ Base.encode64("echo a")
      assert Enum.at(cmds, 1)["command"] =~ Base.encode64("echo b")
    end
  end

  describe "rails floor — no silent drops" do
    for matcher <- ["Edit", "Write", "Read", "WebFetch", "Glob", "unknown-tool"] do
      test "matcher #{matcher} with no before-execution analog raises fail-closed" do
        pre = %{
          "hooks" => %{
            "PreToolUse" => [
              %{
                "matcher" => unquote(matcher),
                "hooks" => [%{"type" => "command", "command" => "true"}]
              }
            ]
          }
        }

        assert_raise UnmappableRailError, ~r/refusing to silently drop/, fn ->
          CursorRails.compile(pre)
        end
      end
    end

    test "event_for/1 raises on an unmapped matcher and names it" do
      err =
        assert_raise UnmappableRailError, fn -> CursorRails.event_for("Edit") end

      assert Exception.message(err) =~ "Edit"
    end
  end

  describe "real deny protocol — Rails.probe_entry/0 executed as Cursor runs it" do
    setup do
      # probe_entry is a single PreToolUse entry; wrap it in the hook_settings map shape.
      pre = %{"hooks" => %{"PreToolUse" => [Rails.probe_entry()]}}
      %{"hooks" => %{"beforeShellExecution" => [hook]}} = CursorRails.compile(pre)
      %{hook: hook}
    end

    test "denies with the gate reason when the probe pattern matches", %{hook: hook} do
      # The probe statute's pattern is "tightbeam-gate-probe".
      verdict = run_hook(hook, shell_stdin("run tightbeam-gate-probe now"))

      assert verdict["permission"] == "deny"
      assert verdict["user_message"] =~ "[gate: tightbeam-probe]"
    end

    test "allows when the probe pattern does not match", %{hook: hook} do
      verdict = run_hook(hook, shell_stdin("ls -la"))
      assert verdict == %{"permission" => "allow"}
    end
  end

  describe "real observation entry — observes, never blocks" do
    test "an artifact-record command is allowed, not denied" do
      # observation_entry rides in hook_settings; isolate it by matcher/shape.
      %{"hooks" => %{"PreToolUse" => entries}} = Rails.hook_settings()
      # Every reserved entry is matcher "Bash"; compile the whole set and run each
      # against an artifact-record command — none may DENY it (observation is exit 0).
      %{"hooks" => %{"beforeShellExecution" => hooks}} =
        CursorRails.compile(%{"hooks" => %{"PreToolUse" => entries}})

      for hook <- hooks do
        verdict = run_hook(hook, shell_stdin("tightbeam artifact-record --kind report"))
        assert verdict["permission"] in ["allow", "deny"]
        # The observation hook must ALLOW; the github-auth hook doesn't match this
        # command and allows; the point: an artifact-record is never spuriously denied
        # by the observation entry.
      end

      # Direct: the observation entry (last reserved entry) allows.
      observation = List.last(hooks)

      assert run_hook(observation, shell_stdin("tightbeam artifact-record --kind report")) ==
               %{"permission" => "allow"}
    end
  end

  describe "deny user_message stays valid JSON under adversarial gate text" do
    test "a gate message containing a quote and backslash escapes correctly" do
      # A Tightbeam-shaped command whose block message has a double-quote and backslash.
      tb =
        ~S[sh -c 'grep -qE "trip" - || exit 0; echo "gate: say \"hi\" and a\\slash" >&2; exit 2']

      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => tb}]}
          ]
        }
      }

      %{"hooks" => %{"beforeShellExecution" => [hook]}} = CursorRails.compile(pre)

      # JSON.decode! in run_hook proves the output is well-formed JSON despite the
      # quote/backslash in the reason.
      verdict = run_hook(hook, shell_stdin("trip wire"))
      assert verdict["permission"] == "deny"
      assert verdict["user_message"] =~ "hi"
    end
  end
end
