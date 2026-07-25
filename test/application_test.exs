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

  test "harness projection publication never exposes truncated bytes" do
    base =
      Path.join(System.tmp_dir!(), "tb_boot_atomic_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    first = JSON.encode!([%{"id" => "first", "padding" => String.duplicate("a", 1_000_000)}])
    second = JSON.encode!([%{"id" => "second", "padding" => String.duplicate("b", 1_000_000)}])
    Tightbeam.Boot.write_harnesses!(base, first)

    writer =
      Task.async(fn ->
        for encoded <- List.duplicate([second, first], 25) |> List.flatten() do
          Tightbeam.Boot.write_harnesses!(base, encoded)
        end
      end)

    path = Path.join(base, "harnesses.json")

    Stream.repeatedly(fn -> File.read!(path) end)
    |> Enum.reduce_while(:ok, fn observed, :ok ->
      assert observed in [first, second]

      case Task.yield(writer, 0) do
        nil -> {:cont, :ok}
        {:ok, _writes} -> {:halt, :ok}
      end
    end)
  end
end
