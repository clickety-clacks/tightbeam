defmodule Tightbeam.ReadMarkersTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ReadMarkers}

  setup do
    db = :read_markers_test_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    %{db: db}
  end

  test "set, conditional write, and clear preserve a monotonic public row", %{db: db} do
    assert {:ok, true, first} = ReadMarkers.set(db, "flynn", "work:one", "s_1")
    assert first.marker == "s_1"

    assert {:ok, false, ^first} = ReadMarkers.set(db, "flynn", "work:one", "s_1")

    assert {:error, %{code: "read_marker_conflict"}} =
             ReadMarkers.set(db, "flynn", "work:one", "s_2",
               expected?: true,
               expected: "stale"
             )

    assert {:ok, true, cleared} =
             ReadMarkers.set(db, "flynn", "work:one", nil,
               expected?: true,
               expected: "s_1"
             )

    assert cleared.marker == nil
    assert cleared.updated_at > first.updated_at
  end
end
