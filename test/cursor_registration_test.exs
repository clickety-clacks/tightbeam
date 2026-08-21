defmodule Tightbeam.CursorRegistrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Harness
  alias Tightbeam.Harness.Cursor

  test "Cursor registers as the only new shim harness" do
    assert Cursor in Harness.all()
    refute Tightbeam.Harness.Opencode in Harness.all()
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

  test "Cursor refuses every unsupported credential before launch planning" do
    target = cursor_target()

    for kind <- [:subscription, :fixture_provider] do
      assert {:error, %{code: "DIV-CURSOR-API-KEY-ONLY"}} =
               Cursor.preflight_launch(target, "/managed", credential_kind: kind)
    end

    for result <- [{:error, :missing}, {:error, :unreadable}, {:ok, ""}, {:ok, "  \n"}] do
      assert {:error, %{code: "DIV-CURSOR-API-KEY-ONLY"}} =
               Cursor.preflight_launch(target, "/managed",
                 credential_kind: :api_key,
                 cursor_api_key_loader: fn _ -> result end
               )
    end
  end

  test "Cursor valid API-key launch selects the pinned memory store" do
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
  end

  test "remote Cursor launch validates the banked file without putting its key in argv" do
    parent = self()
    target = %{cursor_target() | host_config: %{base_dir: "/remote", ssh: "host"}}

    target =
      Map.put(target, :sh, fn argv ->
        send(parent, {:remote_check, argv})
        {"", 0}
      end)

    assert {:ok, checked} =
             Cursor.preflight_launch(target, "/managed", credential_kind: :api_key)

    assert_receive {:remote_check, check_argv}
    assert Enum.join(check_argv, " ") =~ "test -r"

    assert {:ok, plan} =
             Cursor.prepare_launch(
               target,
               "/managed",
               checked ++ [common_env: [], remote_env: [], lineage: "lineage"]
             )

    serialized = Enum.join(plan[:cmd], " ")
    assert serialized =~ "AGENT_CLI_CREDENTIAL_STORE=memory"
    assert serialized =~ "api-key"
    refute serialized =~ "secret"
    refute Enum.any?(plan[:env], fn {name, _} -> name == "CURSOR_API_KEY" end)
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

  test "Cursor owns only its non-secret config and compiled hooks" do
    owned = Cursor.owned_home_entries()
    assert "cli-config.json" in owned
    assert "hooks.json" in owned

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

    assert JSON.decode!(File.read!(Path.join(home, "hooks.json"))) == %{"hooks" => %{}}
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
      end
    }
  end
end
