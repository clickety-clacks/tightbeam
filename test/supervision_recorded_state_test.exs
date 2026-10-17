defmodule Tightbeam.SupervisionRecordedStateTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Schema}

  setup do
    tmp = Path.join(System.tmp_dir!(), "recorded-state-#{System.unique_integer([:positive])}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "schema_shape_runtime.exs")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{payload: prepared.payload}
  end

  test "0.1.8 operator-decision predecessor upgrades through the existing migrations", %{
    payload: payload
  } do
    path =
      Path.join(
        System.tmp_dir!(),
        "recorded-predecessor-#{System.unique_integer([:positive])}/state.db"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(path, payload)
    name = String.to_atom("recorded_predecessor_#{System.unique_integer([:positive])}")
    manifest = File.read!(Path.join(payload, "build-manifest.json")) |> JSON.decode!()

    transition =
      JSON.encode!(%{
        "base" => Path.dirname(path),
        "source" => "unmarked",
        "target" => manifest["buildIdentity"],
        "expectedSchema" => "operator-decision-requests-v1"
      })

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           name: name, path: path, guard_inputs: [transition: transition], payload_root: payload},
          id: name
        )
      )

    assert {:ok, [["operator-decision-requests-v1"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert :ok = Schema.ensure_all(db)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "an operator-decision predecessor starts through a symlinked base", %{payload: payload} do
    tmp = Path.join(System.tmp_dir!(), "linked-state-#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    alias_parent = Path.join(tmp, "alias")
    File.mkdir_p!(base)
    File.ln_s!(".", alias_parent)
    linked_base = Path.join(alias_parent, "base")
    on_exit(fn -> File.rm_rf!(tmp) end)

    Tightbeam.SchemaShapeRuntimeFixture.seed_operator_predecessor!(
      Path.join(base, "state.db"),
      payload
    )

    manifest = File.read!(Path.join(payload, "build-manifest.json")) |> JSON.decode!()

    transition =
      JSON.encode!(%{
        "base" => linked_base,
        "source" => "unmarked",
        "target" => manifest["buildIdentity"],
        "expectedSchema" => "operator-decision-requests-v1"
      })

    name = String.to_atom("linked_predecessor_#{System.unique_integer([:positive])}")

    db =
      start_supervised!(
        Supervisor.child_spec(
          {DB,
           name: name,
           path: Path.join(linked_base, "state.db"),
           guard_inputs: [transition: transition],
           payload_root: payload},
          id: name
        )
      )

    assert :ok = DB.assert_base_admitted!(db, linked_base)
    assert :ok = DB.assert_base_admitted!(db, base)
    assert :ok = Schema.ensure_all(db)
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end
end
