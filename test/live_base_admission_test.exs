defmodule Tightbeam.LiveBaseAdmissionTest do
  use Tightbeam.TestCase, async: false

  @tag :marker_publication
  test "publication requires target schema and refreshes the retained owner", ctx do
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    File.mkdir_p!(ctx.base)
    marker_path = Path.join(ctx.base, "build-owner.json")

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, ~r/current target stamp/, fn ->
      Tightbeam.LiveBaseAdmission.publish_marker!(admission, [["unknown"]])
    end

    refute File.exists?(marker_path)
    rows = [[hd(Tightbeam.Schema.guard_compatible_stamps())]]
    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(ctx.base, "state.db"))

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{hd(hd(rows))}');"
      )

    :ok = Exqlite.Sqlite3.close(conn)
    current = Tightbeam.LiveBaseAdmission.publish_marker!(admission, rows)
    assert current.stamp == rows
    assert current.transition == nil
    assert current.decision.source == ctx.identity
    assert JSON.decode!(File.read!(marker_path)) == current.marker
    assert Tightbeam.LiveBaseAdmission.revalidate!(current) == current
    before = inventory(ctx.base)
    assert Tightbeam.LiveBaseAdmission.publish_marker!(current, rows) == current
    assert inventory(ctx.base) == before
    refute Enum.any?(File.ls!(ctx.base), &String.contains?(&1, ".tmp-"))
  end

  @tag :marker_publication
  test "publication refuses an intervening marker without replacing it", ctx do
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    File.mkdir_p!(ctx.base)
    write_owner(ctx.base, String.duplicate("f", 64))
    before = inventory(ctx.base)

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, ~r/marker changed/, fn ->
      Tightbeam.LiveBaseAdmission.publish_marker!(
        admission,
        [[hd(Tightbeam.Schema.guard_compatible_stamps())]]
      )
    end

    assert inventory(ctx.base) == before
  end

  @tag :prewrite_revalidation
  test "prewrite changed payload refuses without creating the base", ctx do
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    File.write!(Path.join(ctx.payload, "priv/rule"), "changed-before-write")

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, ~r/payload_manifest_mismatch/, fn ->
      Tightbeam.LiveBaseAdmission.revalidate!(admission)
    end

    refute File.exists?(ctx.base)
  end

  @tag :prewrite_revalidation
  test "prewrite changed marker refuses before any SQLite access", ctx do
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    File.mkdir_p!(ctx.base)
    File.write!(Path.join(ctx.base, "state.db"), "must-not-open")
    write_owner(ctx.base, String.duplicate("f", 64))
    before = inventory(ctx.base)

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      Tightbeam.LiveBaseAdmission.revalidate!(admission)
    end

    assert inventory(ctx.base) == before
  end

  @tag :prewrite_revalidation
  test "prewrite rejects a changed but individually compatible schema stamp", ctx do
    [first, second | _] = Tightbeam.Schema.guard_compatible_stamps()
    File.mkdir_p!(ctx.base)
    path = Path.join(ctx.base, "state.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{first}');"
      )

    :ok = Exqlite.Sqlite3.close(conn)
    write_owner(ctx.base, ctx.identity)
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)

    # Deliberate synthetic interposition, not a production migration.
    {:ok, changed} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(changed, "UPDATE schema_stamp SET shape='#{second}'")
    :ok = Exqlite.Sqlite3.close(changed)
    before = inventory(ctx.base)

    assert_raise Tightbeam.LiveBaseAdmission.Refusal, ~r/admission inputs changed/, fn ->
      Tightbeam.LiveBaseAdmission.revalidate!(admission)
    end

    assert inventory(ctx.base) == before
  end

  @tag :ordinary_inspection
  test "ordinary WAL schema refusal preserves protected bytes while allowing SHM", ctx do
    seed = Path.join(Path.dirname(ctx.base), "wal-seed.db")
    {:ok, conn} = Exqlite.Sqlite3.open(seed)

    try do
      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('unknown');"
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE protected_effects(id TEXT PRIMARY KEY, payload TEXT); INSERT INTO protected_effects VALUES ('effect-1', 'committed-only-in-wal'); PRAGMA user_version=42;"
        )

      assert [["effect-1", "committed-only-in-wal"]] =
               Tightbeam.DB.run_query(conn, "SELECT id,payload FROM protected_effects", [])

      File.mkdir_p!(ctx.base)
      # Quiescent synthetic source remains open solely to retain its WAL.
      # No SHM exists initially. The selected contract permits its creation,
      # not changes to the main DB or committed WAL frames.
      File.cp!(seed, Path.join(ctx.base, "state.db"))
      File.cp!(seed <> "-wal", Path.join(ctx.base, "state.db-wal"))

      File.write!(
        Path.join(ctx.base, "build-owner.json"),
        JSON.encode!(%{
          "format" => "tightbeam-build-owner/v1",
          "buildIdentity" => ctx.identity
        })
      )

      before = inventory(ctx.base)

      assert_raise Tightbeam.Schema.ShapeError, ~r/incompatible_schema/, fn ->
        Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
      end

      assert_inspection_preserved(ctx.base, before)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  @tag :ordinary_inspection
  test "ordinary inspection reads WAL-only stamp with absent or existing SHM", ctx do
    stamp = hd(Tightbeam.Schema.guard_compatible_stamps())
    seed = Path.join(Path.dirname(ctx.base), "accepted-wal-seed.db")
    {:ok, conn} = Exqlite.Sqlite3.open(seed)

    try do
      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{stamp}');"
        )

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE protected_effects(id TEXT PRIMARY KEY, payload TEXT); INSERT INTO protected_effects VALUES ('effect-1', 'committed-only-in-wal'); PRAGMA user_version=42;"
        )

      assert [["effect-1", "committed-only-in-wal"]] =
               Tightbeam.DB.run_query(conn, "SELECT id,payload FROM protected_effects", [])

      for shm <- [:absent, :present] do
        base = ctx.base <> "-#{shm}?literal#name"
        File.mkdir_p!(base)
        File.cp!(seed, Path.join(base, "state.db"))
        File.cp!(seed <> "-wal", Path.join(base, "state.db-wal"))
        if shm == :present, do: File.cp!(seed <> "-shm", Path.join(base, "state.db-shm"))
        write_owner(base, ctx.identity)
        before = inventory(base)
        admission = Tightbeam.LiveBaseAdmission.prepare!(base, ctx.options)
        assert admission.stamp == [[stamp]]
        assert_inspection_preserved(base, before)
      end
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  @tag :ordinary_inspection
  test "ordinary inspection after clean checkpoint preserves content", ctx do
    File.mkdir_p!(ctx.base)
    path = Path.join(ctx.base, "state.db")
    stamp = hd(Tightbeam.Schema.guard_compatible_stamps())
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "PRAGMA journal_mode=WAL; CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('#{stamp}');"
      )

    :ok = Exqlite.Sqlite3.close(conn)
    refute File.exists?(path <> "-wal")
    write_owner(ctx.base, ctx.identity)
    before = inventory(ctx.base)
    admission = Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    assert admission.stamp == [[stamp]]
    assert_inspection_preserved(ctx.base, before)
  end

  @tag :ordinary_inspection
  test "ordinary inspection refuses WAL symlink without writing target", ctx do
    File.mkdir_p!(ctx.base)
    path = Path.join(ctx.base, "state.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE schema_stamp(shape TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)
    target = Path.join(Path.dirname(ctx.base), "untouched-target")
    File.write!(target, "do not modify")
    File.ln_s!(target, path <> "-wal")
    write_owner(ctx.base, ctx.identity)
    before = inventory(ctx.base)

    assert_raise RuntimeError, ~r/schema inspection file refused/, fn ->
      Tightbeam.LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    assert File.read!(target) == "do not modify"
    assert File.read_link!(path <> "-wal") == target
    assert inventory(ctx.base) == before
  end

  defp assert_inspection_preserved(base, before) do
    previous = Map.new(before)
    current = Map.new(inventory(base))
    # SHM is coordination state. Existing WAL bytes are NOT exempt: unchanged
    # committed frames and main DB bytes prove no checkpoint/content migration.
    allowed = ["state.db-shm"]

    allowed =
      if not Map.has_key?(previous, "state.db-wal") and Map.has_key?(current, "state.db-wal") do
        assert current["state.db-wal"] == ""
        ["state.db-wal" | allowed]
      else
        allowed
      end

    assert Map.drop(current, allowed) == Map.drop(previous, allowed)

    for name <- allowed, Map.has_key?(current, name) do
      assert File.lstat!(Path.join(base, name)).type == :regular
    end

    protected_hashes = fn values ->
      values
      |> Map.drop(allowed)
      |> Enum.map(fn {name, bytes} ->
        {name, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
      end)
      |> Enum.sort()
    end

    IO.inspect(
      %{
        base: base,
        protected_before: protected_hashes.(previous),
        protected_after: protected_hashes.(current),
        coordination: Map.take(current, allowed) |> Map.keys()
      },
      label: "ordinary-inspection-preservation"
    )
  end

  defp write_owner(base, identity) do
    File.write!(
      Path.join(base, "build-owner.json"),
      JSON.encode!(%{"format" => "tightbeam-build-owner/v1", "buildIdentity" => identity})
    )
  end

  alias Tightbeam.{LiveBaseAdmission, LiveBaseGuard}
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    payload = Path.join(tmp, "payload")
    base = Path.join(tmp, "base")
    File.mkdir_p!(Path.join(payload, "ebin"))
    File.mkdir_p!(Path.join(payload, "priv"))
    files = [{"ebin/fixture.beam", "synthetic code"}, {"priv/rule", "synthetic rule"}]
    Enum.each(files, fn {path, bytes} -> File.write!(Path.join(payload, path), bytes) end)
    {:ok, manifest} = LiveBaseGuard.generate_manifest(files)
    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))

    %{
      base: base,
      payload: payload,
      options: [payload_root: payload],
      identity: manifest["buildIdentity"]
    }
  end

  test "wrong marker refuses before SQLite can open", ctx do
    File.mkdir_p!(ctx.base)
    File.write!(Path.join(ctx.base, "state.db"), "not SQLite: must never be opened")

    File.write!(
      Path.join(ctx.base, "build-owner.json"),
      JSON.encode!(%{
        "format" => "tightbeam-build-owner/v1",
        "buildIdentity" => String.duplicate("f", 64)
      })
    )

    before = inventory(ctx.base)

    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    assert inventory(ctx.base) == before
    # Repeat must reach the same marker refusal, leaving the base untouched.
    assert_raise LiveBaseAdmission.Refusal, ~r/build_transition_required/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    assert inventory(ctx.base) == before
  end

  test "base aliases canonicalize to one base without creating it", ctx do
    alias_parent = Path.join(Path.dirname(ctx.base), "alias")
    File.ln_s!(Path.dirname(ctx.base), alias_parent)
    admission = LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    assert admission.stamp == :fresh
    refute File.exists?(ctx.base)

    aliased = LiveBaseAdmission.prepare!(Path.join(alias_parent, "base"), ctx.options)
    assert aliased.base == admission.base
    refute File.exists?(ctx.base)
  end

  test "changed and extra payload bytes refuse before base creation", ctx do
    File.write!(Path.join(ctx.payload, "priv/rule"), "changed")

    assert_raise LiveBaseAdmission.Refusal, ~r/payload_manifest_mismatch/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    refute File.exists?(ctx.base)
    File.write!(Path.join(ctx.payload, "priv/rule"), "synthetic rule")
    File.write!(Path.join(ctx.payload, "priv/extra"), "extra")

    assert_raise LiveBaseAdmission.Refusal, ~r/payload_manifest_mismatch/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    refute File.exists?(ctx.base)
  end

  test "unknown schema refuses read-only without changing database inventory", ctx do
    File.mkdir_p!(ctx.base)
    path = Path.join(ctx.base, "state.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE schema_stamp(shape TEXT); INSERT INTO schema_stamp VALUES ('unknown');"
      )

    :ok = Exqlite.Sqlite3.close(conn)

    File.write!(
      Path.join(ctx.base, "build-owner.json"),
      JSON.encode!(%{
        "format" => "tightbeam-build-owner/v1",
        "buildIdentity" => ctx.identity
      })
    )

    before = inventory(ctx.base)

    assert_raise Tightbeam.Schema.ShapeError, ~r/incompatible_schema/, fn ->
      LiveBaseAdmission.prepare!(ctx.base, ctx.options)
    end

    assert inventory(ctx.base) == before
  end

  defp inventory(base) do
    base
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn name ->
      {name, File.read!(Path.join(base, name))}
    end)
  end
end
