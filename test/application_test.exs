defmodule Tightbeam.ApplicationTest do
  use ExUnit.Case, async: false
  alias Tightbeam.{DB, Ledger, EventLog}

  setup do
    base = Path.join(System.tmp_dir!(), "tb_app_#{System.unique_integer([:positive])}")
    Application.put_env(:tightbeam, :base_dir, base)

    sup =
      start_supervised!(%{
        id: :app_tree,
        start:
          {Supervisor, :start_link, [Tightbeam.Application.children(), [strategy: :rest_for_one]]}
      })

    %{sup: sup}
  end

  test "supervised tree: DB alive, schemas present, boot epoch recorded" do
    assert Process.whereis(DB) |> is_pid()
    assert Process.whereis(Tightbeam.LaneRegistry) |> is_pid()
    assert Process.whereis(Tightbeam.LaneSupervisor) |> is_pid()

    assert {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns")
    assert {:ok, [[n]]} = DB.query(DB, "SELECT COUNT(*) FROM boot_epochs")
    assert n >= 1
    assert is_integer(Application.get_env(:tightbeam, :boot_epoch))
    assert Ledger.pending_sessions(DB) == []
    assert EventLog.events_after(DB, 0, 10) == []

    expected =
      "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"

    assert File.read!(Path.join(Application.fetch_env!(:tightbeam, :base_dir), "harnesses.json")) ==
             expected
  end
end
