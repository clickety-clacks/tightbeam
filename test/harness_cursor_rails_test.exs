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

  # A cursor beforeShellExecution stdin payload.
  #
  # PROVENANCE (not hand-invented): the field set and the deny/allow protocol are
  # transcribed from the real cursor-agent binary v2026.08.11-e8db854
  # (~/.local/share/cursor-agent/versions/2026.08.11-e8db854/index.js). The
  # beforeShellExecution input object is built as {command, cwd, sandbox} with the
  # common hook fields (hook_event_name, tool_name, tool_input, ...); the hook's
  # verdict is read from STDOUT as {"permission":"allow"|"ask"|"deny","user_message"}
  # with "deny" throwing/blocking (a nonzero exit is a hook-FAILURE, not a deny).
  #
  # KNOWN GAP (auth-blocked, orchestrator-confirmed no CURSOR_API_KEY): this proves
  # the generated wrapper emits cursor's real verdict shape for a real input shape,
  # but NOT that a live cursor-agent turn accepts it end-to-end. That authenticated
  # rails RE-CAPTURE is the coordinator-owned follow-on, gated on George's key.
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
      assert CursorRails.compile(nil) == %{"version" => 1, "hooks" => %{}}
    end

    test "an empty PreToolUse list compiles to an empty hooks config" do
      assert CursorRails.compile(%{"hooks" => %{"PreToolUse" => []}}) == %{
               "version" => 1,
               "hooks" => %{}
             }
    end

    test "without :path the wrapper does not touch PATH" do
      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "true"}]}
          ]
        }
      }

      %{"hooks" => %{"beforeShellExecution" => [%{"command" => command}]}} =
        CursorRails.compile(pre)

      refute command =~ "PATH="
      assert String.starts_with?(command, "in=$(cat); ")
    end

    test ":path is set inside the wrapper and resolves the helper" do
      # The dedicated Cursor identity runs under a fixed system PATH, so a
      # reserved rail's bare `tightbeam ...` invocation must resolve through the
      # operator-configured helper directory carried in the wrapper itself.
      dir = Path.join(System.tmp_dir!(), "tb-cursor-helper-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      helper = Path.join(dir, "tightbeam")
      File.write!(helper, "#!/bin/sh\necho \"[gate: helper] resolved $1\" >&2\nexit 2\n")
      File.chmod!(helper, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => "Bash",
              "hooks" => [%{"type" => "command", "command" => "tightbeam github-auth-check"}]
            }
          ]
        }
      }

      %{"hooks" => %{"beforeShellExecution" => [hook]}} =
        CursorRails.compile(pre, path: dir)

      assert String.starts_with?(
               hook["command"],
               "PATH='#{dir}':\"$PATH\"; export PATH; in=$(cat); "
             )

      assert %{"permission" => "deny", "user_message" => msg} =
               run_hook(hook, shell_stdin("git ls-remote origin"))

      assert msg =~ "[gate: helper] resolved github-auth-check"
    end

    test ":path containing a single quote is refused rather than mis-quoted" do
      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "true"}]}
          ]
        }
      }

      assert_raise ArgumentError, ~r/single quote/, fn ->
        CursorRails.compile(pre, path: "/tmp/it's")
      end
    end

    test "Bash routes to beforeShellExecution and the wrap is applied" do
      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "true"}]}
          ]
        }
      }

      %{"hooks" => hooks} = CursorRails.compile(pre)

      assert CursorRails.compile(pre)["version"] == 1

      assert Map.keys(hooks) == ["beforeShellExecution"]
      assert [%{"command" => shell_cmd}] = hooks["beforeShellExecution"]
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
    # MCP is refused, not routed: Cursor's beforeMCPExecution fires for every MCP
    # tool, so an mcp__server__tool_a rail cannot be enforced tool-faithfully.
    for matcher <- [
          "Edit",
          "Write",
          "Read",
          "WebFetch",
          "Glob",
          "mcp__server__tool",
          "unknown-tool"
        ] do
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

    test "a MULTILINE gate reason still yields valid deny JSON (no bypass)" do
      # A Tightbeam-shaped command whose block message spans two lines. Without
      # control-byte flattening this emits a literal newline inside the JSON string
      # -> invalid JSON -> Cursor reads a hook FAILURE, not a deny (a bypass).
      tb = ~S[sh -c 'grep -qE "trip" - || exit 0; printf "line one\nline two\n" >&2; exit 2']

      pre = %{
        "hooks" => %{
          "PreToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => tb}]}
          ]
        }
      }

      %{"hooks" => %{"beforeShellExecution" => [hook]}} = CursorRails.compile(pre)

      # If the verdict were invalid JSON, JSON.decode! in run_hook would raise.
      verdict = run_hook(hook, shell_stdin("trip wire"))
      assert verdict["permission"] == "deny"
      # The reason is preserved (flattened to one line), not dropped.
      assert verdict["user_message"] =~ "line one"
      assert verdict["user_message"] =~ "line two"
      refute verdict["user_message"] =~ "\n"
    end
  end
end
