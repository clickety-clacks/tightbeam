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
end
