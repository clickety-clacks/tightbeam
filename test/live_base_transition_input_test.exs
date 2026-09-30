defmodule Tightbeam.LiveBaseTransitionInputTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{LiveBaseAdmission, LiveBaseGuard, Schema}
  alias Exqlite.Sqlite3

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    payload = Path.join(tmp, "payload")
    base = Path.join(tmp, "base")
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    File.write!(Path.join(payload, "ebin/fixture.beam"), "synthetic packaged payload")
    File.write!(Path.join(payload, "priv/fixture.rule"), "synthetic packaged rule")

    files = [
      {"ebin/fixture.beam", "synthetic packaged payload"},
      {"priv/fixture.rule", "synthetic packaged rule"}
    ]

    {:ok, manifest} = LiveBaseGuard.generate_manifest(files)
    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    expected_schema = List.last(Schema.guard_compatible_stamps())
    File.mkdir_p!(base)
    {:ok, conn} = Sqlite3.open(Path.join(base, "state.db"))

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{expected_schema}');"
      )

    :ok = Sqlite3.close(conn)

    %{
      base: base,
      expected_schema: expected_schema,
      identity: manifest["buildIdentity"],
      payload: payload
    }
  end

  test "the packaged exact transition admits an unmarked synthetic base", ctx do
    transition = transition_json(ctx)
    guard_inputs = runtime_guard_inputs(transition)

    assert [transition: ^transition] = guard_inputs

    admission =
      LiveBaseAdmission.prepare!(ctx.base, [payload_root: ctx.payload] ++ guard_inputs)

    assert admission.marker == :absent
    assert admission.stamp == [[ctx.expected_schema]]
    assert admission.decision.source == "unmarked"
    assert admission.decision.target == ctx.identity
    assert admission.decision.expected_schema == ctx.expected_schema
  end

  test "absent, malformed, and mismatched packaged input still refuses", ctx do
    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, [payload_root: ctx.payload] ++ runtime_guard_inputs())
    end

    assert_raise LiveBaseAdmission.Refusal, ~r/invalid_build_transition/, fn ->
      LiveBaseAdmission.prepare!(
        ctx.base,
        [payload_root: ctx.payload] ++ runtime_guard_inputs("{")
      )
    end

    mismatched =
      ctx
      |> transition_json()
      |> JSON.decode!()
      |> Map.put("target", String.duplicate("f", 64))
      |> JSON.encode!()

    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_mismatch/, fn ->
      LiveBaseAdmission.prepare!(
        ctx.base,
        [payload_root: ctx.payload] ++ runtime_guard_inputs(mismatched)
      )
    end
  end

  test "a schema stamp outside the transition still refuses", ctx do
    other_schema = "synthetic-incompatible-schema"
    path = Path.join(ctx.base, "state.db")
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "UPDATE schema_stamp SET shape='#{other_schema}'")
    :ok = Sqlite3.close(conn)

    assert_raise Schema.ShapeError, ~r/incompatible_schema/, fn ->
      LiveBaseAdmission.prepare!(
        ctx.base,
        [payload_root: ctx.payload] ++ runtime_guard_inputs(transition_json(ctx))
      )
    end
  end

  defp transition_json(ctx) do
    JSON.encode!(%{
      "base" => LiveBaseAdmission.canonical!(ctx.base),
      "expectedSchema" => ctx.expected_schema,
      "source" => "unmarked",
      "target" => ctx.identity
    })
  end

  defp runtime_guard_inputs(value \\ nil) do
    variable = "TIGHTBEAM_LIVE_BASE_TRANSITION"
    previous = System.get_env(variable)

    if is_nil(value), do: System.delete_env(variable), else: System.put_env(variable, value)

    try do
      config = Config.Reader.read!("config/runtime.exs", env: :prod)
      Keyword.get(Keyword.fetch!(config, :tightbeam), :live_base_guard, [])
    after
      if is_nil(previous),
        do: System.delete_env(variable),
        else: System.put_env(variable, previous)
    end
  end
end
