defmodule Tightbeam.ApplicationTest do
  use Tightbeam.TestCase, async: false
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

  test "production entry refuses a broken harness on PATH without creating any org artifact" do
    base =
      Path.join(System.tmp_dir!(), "tb_app_refused_#{System.unique_integer([:positive])}")

    bin_dir =
      Path.join(System.tmp_dir!(), "tb_app_broken_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    codex = Path.join(bin_dir, "codex")
    File.write!(codex, "#!/bin/sh\necho broken >&2\nexit 1\n")
    File.chmod!(codex, 0o755)

    previous_base = Application.fetch_env!(:tightbeam, :base_dir)
    previous_autostart = Application.fetch_env!(:tightbeam, :autostart)
    previous_path = System.get_env("PATH")

    Application.put_env(:tightbeam, :base_dir, base)
    Application.put_env(:tightbeam, :autostart, true)
    System.put_env("PATH", bin_dir)

    on_exit(fn ->
      Application.put_env(:tightbeam, :base_dir, previous_base)
      Application.put_env(:tightbeam, :autostart, previous_autostart)
      restore_path(previous_path)
      File.rm_rf!(base)
      File.rm_rf!(bin_dir)
    end)

    assert_raise RuntimeError, ~r/no usable harness CLI is installed/, fn ->
      Tightbeam.Application.start(:normal, [])
    end

    refute File.exists?(base)
  end

  test "production entry refuses a broken identity before creating store artifacts" do
    base =
      Path.join(
        System.tmp_dir!(),
        "tb_app_identity_refused_#{System.unique_integer([:positive])}"
      )

    assert :initialized = Tightbeam.Identity.init!(base)
    identity_dir = Path.join(base, "identity")

    {_output, 0} =
      System.cmd("git", ["update-ref", "-d", "refs/heads/tightbeam/live"], cd: identity_dir)

    previous_base = Application.fetch_env!(:tightbeam, :base_dir)
    previous_autostart = Application.fetch_env!(:tightbeam, :autostart)
    previous_path = System.get_env("PATH")
    bin_dir = Path.join(base, "working-cli")
    codex = Path.join(bin_dir, "codex")
    File.mkdir_p!(bin_dir)
    File.write!(codex, "#!/bin/sh\necho 'codex-cli 0.0.0'\n")
    File.chmod!(codex, 0o755)

    Application.put_env(:tightbeam, :base_dir, base)
    Application.put_env(:tightbeam, :autostart, true)
    System.put_env("PATH", Enum.join(Enum.reject([bin_dir, previous_path], &is_nil/1), ":"))

    on_exit(fn ->
      Application.put_env(:tightbeam, :base_dir, previous_base)
      Application.put_env(:tightbeam, :autostart, previous_autostart)
      restore_path(previous_path)
      File.rm_rf!(base)
    end)

    assert_raise ArgumentError, ~r|missing required refs: tightbeam/live|, fn ->
      Tightbeam.Application.start(:normal, [])
    end

    refute File.exists?(Path.join(base, "state.db"))
    refute File.exists?(Path.join(base, "gateway.json"))
    refute File.exists?(Path.join(base, "harnesses.json"))
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
