defmodule Tightbeam.CursorRegistrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Harness
  alias Tightbeam.Harness.Cursor

  test "Cursor registers as the only new shim harness" do
    assert Cursor in Harness.all()
    refute "opencode" in Enum.map(Harness.all(), & &1.wire_name())
    assert Cursor.adapter_provisioning() == :shim
    assert Harness.requires_zero_listeners?(Cursor)
    refute function_exported?(Cursor, :requires_zero_listeners?, 0)
  end

  test "Cursor pins the binary-native launch and API-key seams" do
    assert Cursor.credential_provider() == :cursor
    assert Cursor.credential_env_vars() == ["CURSOR_API_KEY"]

    assert JSON.decode!(Cursor.wire_projection()) == %{
             "id" => "cursor",
             "wire_name" => "cursor",
             "install_package" => "cursor-agent",
             "cli_binary" => "cursor-agent",
             "process_markers" => ["cursor-agent acp"]
           }
  end

  test "Cursor maps its public auto ref onto the opaque ACP value" do
    config = Cursor.session_config(%{}, "guidance")

    assert config.effort_config == nil
    assert config.model_option_aliases == %{"auto-smart[optimize_for=balanced]" => "auto"}
  end

  test "Cursor refuses every unsupported credential before launch planning" do
    target = cursor_target()

    for kind <- [:subscription, :fixture_provider, :arbitrary_invalid] do
      assert {:error, %{code: "DIV-CURSOR-API-KEY-ONLY"}} =
               Cursor.preflight_launch(target, "/managed",
                 credential_kind: kind,
                 cursor_api_key_loader: fn _ -> flunk("unsupported kind loaded a credential") end
               )
    end

    for result <- [{:error, :missing}, {:error, :unreadable}, {:ok, ""}, {:ok, "  \n"}] do
      assert {:error, %{code: "DIV-CURSOR-API-KEY-ONLY"}} =
               Cursor.preflight_launch(target, "/managed",
                 credential_kind: :api_key,
                 cursor_api_key_loader: fn _ -> result end
               )
    end
  end

  test "Cursor valid API-key worker selects memory store without a Keychain command" do
    target = cursor_target()

    assert {:ok, checked} =
             Cursor.preflight_launch(target, "/managed",
               credential_kind: :api_key,
               cursor_api_key_loader: fn _ -> {:ok, " secret \n"} end
             )

    assert {:ok, plan} =
             Cursor.prepare_launch(
               target,
               "/managed",
               checked ++ [common_env: [], remote_env: [], lineage: "lineage"]
             )

    assert {"CURSOR_API_KEY", "secret"} in plan[:env]
    assert {"AGENT_CLI_CREDENTIAL_STORE", "memory"} in plan[:env]
    refute Enum.join(plan[:cmd], " ") =~ "security"
    refute Enum.join(plan[:cmd], " ") =~ "secret"
  end

  # Runs only where the pinned cursor-agent bundle is installed — see the
  # :cursor_bundle exclusion rule in test_helper.exs for why absence is a
  # declared exclusion here rather than a suite refusal or a silent skip.
  @tag :cursor_bundle
  test "the exact pinned vendor bundle recognizes memory and bypasses the login-Keychain selector" do
    launcher = System.find_executable("cursor-agent")
    assert is_binary(launcher), "the pinned Cursor acceptance fixture is not installed"
    {canonical, 0} = System.cmd("realpath", [launcher])
    canonical = String.trim(canonical)
    bundle_path = Path.join(Path.dirname(canonical), "index.js")
    bundle = File.read!(bundle_path)

    assert Path.basename(Path.dirname(canonical)) == Cursor.adapter_version()
    assert sha256(canonical) == "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"

    assert sha256(bundle_path) ==
             "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0"

    assert bundle =~ ~s("file"===t?"file":"memory"===t?"memory":"default")
    assert bundle =~ ~s("darwin"===e&&t&&!n&&"default"===r)
    assert bundle =~ "process.env.CURSOR_API_KEY"
    assert bundle =~ "/usr/bin/security"

    selector = fn
      "file" -> "file"
      "memory" -> "memory"
      _invalid -> "default"
    end

    assert selector.("memory") == "memory"
    assert selector.("arbitrary-invalid") == "default"
    refute "default" == selector.("memory")
  end

  test "remote Cursor preflight refuses local-only before any credential read" do
    parent = self()

    target =
      cursor_target()
      |> Map.put(:host_config, %{base_dir: "/remote", ssh: "host"})
      |> Map.put(:sh, fn argv ->
        send(parent, {:remote_check, argv})
        {" remote-secret \n", 0}
      end)

    assert {:error, %{code: "DIV-CURSOR-LOCAL-ONLY"}} =
             Cursor.preflight_launch(target, "/managed", credential_kind: :api_key)

    refute_receive {:remote_check, _}
  end

  test "Cursor default model is untiered and matches its catalog shape" do
    default = Cursor.default_model()
    assert default.family == "auto"
    assert default.effort == nil
  end

  test "Cursor advertises only the selectable refs present in authenticated inventory" do
    parent = self()
    target = cursor_target()

    sh = fn argv ->
      send(parent, {:catalog_probe, argv})

      {"Available models\n\nauto - Auto (default)\ngpt-5.3-codex - Codex 5.3\n" <>
         "gpt-5.3-codex-low - Codex 5.3 Low\ncomposer-2.5-fast - Composer 2.5 Fast\n\n" <>
         "Tip: use --model <id> to select a model.\n", 0}
    end

    assert {:ok, entries} =
             Cursor.fetch_catalog(%{
               base_dir: target.host_config.base_dir,
               host_config: target.host_config,
               credential_kind: :api_key,
               options: %{
                 sh: sh,
                 find_executable: target.find_executable,
                 realpath: target.realpath,
                 sha256: target.sha256
               }
             })

    families = Enum.map(entries, & &1.family)

    assert families == ["auto", "gpt-5.3-codex"]
    refute "composer-2.5" in families
    refute "gpt-5.3-codex-low" in families
    refute "composer-2.5-fast" in families

    auto = Enum.find(entries, &(&1.family == "auto"))
    assert auto.display_name == "Auto"

    codex = Enum.find(entries, &(&1.family == "gpt-5.3-codex"))
    assert codex.display_name == "Codex 5.3"

    assert_receive {:catalog_probe, argv}
    serialized = Enum.join(argv, " ")
    assert serialized =~ "AGENT_CLI_CREDENTIAL_STORE=memory"
    assert serialized =~ "CURSOR_API_KEY=\"$(cat "
    assert serialized =~ "cursor-agent' --list-models"
    refute serialized =~ "secret"
  end

  test "Cursor refuses malformed or failed model-list output" do
    target = cursor_target()

    base_state = %{
      base_dir: target.host_config.base_dir,
      host_config: target.host_config,
      credential_kind: :api_key,
      options: %{
        find_executable: target.find_executable,
        realpath: target.realpath,
        sha256: target.sha256
      }
    }

    assert {:error, :malformed_catalog} =
             Cursor.fetch_catalog(
               put_in(base_state, [:options, :sh], fn _ -> {"nonsense", 0} end)
             )

    assert {:error, {:cursor_catalog_probe_failed, 42, "denied"}} =
             Cursor.fetch_catalog(put_in(base_state, [:options, :sh], fn _ -> {"denied", 42} end))
  end

  test "Cursor integrity failures remain typed at probe and launch" do
    target = %{cursor_target() | sha256: fn _ -> "wrong" end}
    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} = Cursor.probe_cli(target)

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Cursor.prepare_launch(target, "/managed",
               cursor_api_key: "secret",
               common_env: [],
               remote_env: [],
               lineage: "lineage"
             )
  end

  test "Cursor refuses a tampered managed shim immediately before launch" do
    base = Path.join(System.tmp_dir!(), "cursor-shim-#{System.unique_integer([:positive])}")
    launcher = Path.join([base, "2026.08.11-e8db854", "cursor-agent"])
    shim = Path.join(base, "cursor-agent-acp")
    File.mkdir_p!(Path.dirname(launcher))
    File.write!(launcher, "launcher")
    File.write!(Path.join(Path.dirname(launcher), "index.js"), "bundle")
    File.write!(shim, "#!/bin/sh\nexec hacked\n")
    File.chmod!(shim, 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    target =
      Map.merge(cursor_target(), %{
        adapter_binary: shim,
        find_executable: fn _ -> launcher end
      })

    target = Map.delete(target, :verify_adapter_shim)

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Cursor.prepare_launch(target, "/managed",
               cursor_api_key: "secret",
               common_env: [],
               remote_env: [],
               lineage: "lineage"
             )
  end

  test "remote preflight refuses local-only before any API-key load attempt" do
    parent = self()
    target = %{cursor_target() | host_config: %{base_dir: "/remote", ssh: "host"}}

    target =
      Map.put(target, :sh, fn argv ->
        send(parent, {:remote_load, argv})
        {"  \n", 0}
      end)

    assert {:error, %{code: "DIV-CURSOR-LOCAL-ONLY"}} =
             Cursor.preflight_launch(target, "/managed", credential_kind: :api_key)

    refute_receive {:remote_load, _}
  end

  test "remote preflight refuses local-only without probing credential bytes" do
    target = %{cursor_target() | host_config: %{base_dir: "/remote", ssh: "host"}}

    for result <- [{"", 1}, {"cat: permission denied", 1}, {"", 0}, {" \n\t", 0}] do
      parent = self()

      target =
        Map.put(target, :sh, fn argv ->
          send(parent, {:remote_load, argv})
          result
        end)

      assert {:error, %{code: "DIV-CURSOR-LOCAL-ONLY"}} =
               Cursor.preflight_launch(target, "/managed", credential_kind: :api_key)

      refute_receive {:remote_load, _}
    end
  end

  test "Harness typed ensure and probe dispatchers preserve Cursor integrity codes" do
    target = %{cursor_target() | sha256: fn _ -> "wrong" end}

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Harness.ensure_adapter(Cursor, target)

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Harness.probe_cli(Cursor, target)
  end

  test "Gateway public refusal projection preserves the stable code without internal detail" do
    assert Tightbeam.Gateway.adapter_launch_refusal(%{
             code: "DIV-CURSOR-API-KEY-ONLY",
             message: "Cursor requires a banked API key",
             details: %{path: "/secret", hash: "hidden"}
           }) == %{
             code: "DIV-CURSOR-API-KEY-ONLY",
             message: "Cursor requires a banked API key"
           }
  end

  test "Cursor integrity guard refuses every pinned launcher and bundle drift class" do
    base = cursor_target()

    cases = [
      %{base | find_executable: fn _ -> nil end},
      %{base | realpath: fn _ -> {:error, :failed} end},
      %{base | find_executable: fn _ -> "/tmp/wrong-version/cursor-agent" end},
      %{base | sha256: fn _ -> "wrong" end},
      %{
        base
        | sha256: fn path ->
            if Path.basename(path) == "index.js",
              do: "wrong",
              else: "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
          end
      }
    ]

    Enum.each(cases, fn target ->
      assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
               Cursor.verify_installed_cli(target)
    end)
  end

  test "every local integrity drift refuses at ensure, probe, and prepare before spawn" do
    base = cursor_target()

    cases = [
      %{base | find_executable: fn _ -> nil end},
      %{base | realpath: fn _ -> {:error, :unreadable} end},
      %{base | find_executable: fn _ -> "/tmp/PATH-fallback/cursor-agent" end},
      %{base | sha256: fn _ -> {:error, :unreadable} end},
      %{base | sha256: fn _ -> "damaged" end},
      %{
        base
        | sha256: fn path ->
            if Path.basename(path) == "index.js",
              do: "damaged-bundle",
              else: "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
          end
      }
    ]

    Enum.each(cases, &assert_integrity_refusal_at_every_seam/1)
  end

  test "remote command, canonicalization, and hash failures refuse at every seam" do
    parent = self()

    for failure <- [:command, :realpath, :launcher_hash, :bundle_hash] do
      target = %{
        base_dir: "/remote",
        host_name: "vector",
        host_config: %{base_dir: "/remote", ssh: "host"},
        sh: fn argv ->
          command = Enum.join(argv, " ")
          send(parent, {:remote_integrity_command, failure, command})

          cond do
            failure == :command and command =~ "command -v" ->
              {"", 127}

            command =~ "command -v" ->
              {"/remote/2026.08.11-e8db854/cursor-agent\n", 0}

            failure == :realpath and command =~ "realpath" ->
              {"", 1}

            command =~ "realpath" ->
              {"/remote/2026.08.11-e8db854/cursor-agent\n", 0}

            failure == :launcher_hash and command =~ "cursor-agent" ->
              {"bad\n", 0}

            failure == :bundle_hash and command =~ "index.js" ->
              {"bad\n", 0}

            command =~ "cursor-agent" ->
              {"eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831\n", 0}

            command =~ "index.js" ->
              {"6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0\n", 0}
          end
        end
      }

      assert_integrity_refusal_at_every_seam(target)
    end

    assert_receive {:remote_integrity_command, _, _}
  end

  test "Cursor owns only its non-secret config and compiled hooks" do
    owned = Cursor.owned_home_entries()
    assert "cli-config.json" in owned
    assert ".cursor/hooks.json" in owned

    base =
      Path.join(System.tmp_dir!(), "cursor-registration-#{System.unique_integer([:positive])}")

    home = Path.join(base, "home")
    auth = Path.join([base, "auth", "cursor"])
    File.mkdir_p!(auth)
    File.write!(Path.join(auth, "cli-config.json"), ~s({"authInfo":{"email":"user@example.com"}}))

    target = %{
      base_dir: base,
      host_name: "vector",
      host_config: %{base_dir: base, ssh: nil},
      sh: &Tightbeam.Harness.Support.system_cmd/1
    }

    on_exit(fn -> File.rm_rf!(base) end)

    assert %{linked_auth_files: ["cli-config.json"]} =
             Cursor.reconcile_home(target, home, %{
               harness: :cursor,
               machine: "vector",
               auth_dir: auth,
               rails: %{"hooks" => %{"PreToolUse" => []}}
             })

    assert JSON.decode!(File.read!(Path.join([home, ".cursor", "hooks.json"]))) == %{
             "hooks" => %{}
           }

    refute File.exists?(Path.join(home, "api-key"))
  end

  defp cursor_target do
    version_dir = "/tmp/2026.08.11-e8db854"

    %{
      base_dir: "/tmp",
      host_name: "vector",
      host_config: %{base_dir: "/tmp", ssh: nil},
      find_executable: fn "cursor-agent" -> Path.join(version_dir, "cursor-agent") end,
      realpath: fn path -> {:ok, path} end,
      sha256: fn path ->
        if Path.basename(path) == "index.js",
          do: "6aceb24b7c7ecddb1993946ebb18a7dd4d025842e6efda955eb0c13255b1e5f0",
          else: "eed61c5224668c9236334c4c68936a16aecc37374b592f59e31eb50433817831"
      end,
      verify_adapter_shim: fn _shim, _launcher -> :ok end
    }
  end

  defp assert_integrity_refusal_at_every_seam(target) do
    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Harness.ensure_adapter(Cursor, target)

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Harness.probe_cli(Cursor, target)

    assert {:error, %{code: "cursor_cli_integrity_mismatch"}} =
             Harness.prepare_launch(Cursor, target, "/managed",
               cursor_api_key: "in-memory-only",
               common_env: [],
               remote_env: [],
               lineage: "lineage"
             )
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
