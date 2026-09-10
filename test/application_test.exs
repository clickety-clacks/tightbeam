defmodule Tightbeam.ApplicationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Escalation,
    EventLog,
    Identity,
    Ledger,
    Model,
    Org,
    RuleRuntime,
    Rules,
    Wakes
  }

  setup context do
    base = Path.join(System.tmp_dir!(), "tb_app_#{System.unique_integer([:positive])}")
    Application.put_env(:tightbeam, :base_dir, base)
    :initialized = Identity.init!(base)

    seeded =
      if context[:retired_decision_notice] do
        seed_retired_decision!(base)
      else
        %{}
      end

    :persistent_term.erase(RuleRuntime)

    sup =
      start_supervised!(%{
        id: :app_tree,
        start:
          {Supervisor, :start_link, [Tightbeam.Application.children(), [strategy: :rest_for_one]]}
      })

    Map.put(seeded, :sup, sup)
  end

  test "boot on a fresh database creates every schema before recovery" do
    assert Process.whereis(DB) |> is_pid()
    assert Process.whereis(Tightbeam.LaneRegistry) |> is_pid()
    assert Process.whereis(Tightbeam.LaneSupervisor) |> is_pid()

    assert {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns")
    assert {:ok, [[n]]} = DB.query(DB, "SELECT COUNT(*) FROM boot_epochs")
    assert n >= 1
    assert {:ok, [[1]]} = DB.query(DB, "PRAGMA foreign_keys")
    assert is_integer(Application.get_env(:tightbeam, :boot_epoch))
    assert Ledger.pending_sessions(DB) == []
    assert Escalation.recover_retired(DB) == :ok
    assert EventLog.events_after(DB, 0, 10) == []

    assert {:ok, [[1]]} =
             DB.query(
               DB,
               "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'"
             )

    assert {:ok, [[1]]} =
             DB.query(
               DB,
               "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'harness_processes'"
             )

    expected =
      "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"

    assert File.read!(Path.join(Application.fetch_env!(:tightbeam, :base_dir), "harnesses.json")) ==
             expected
  end

  @tag retired_decision_notice: true
  test "production child sequence installs row recognition before Boot recovery", ctx do
    assert {:ok, [["withdrawn"]]} =
             DB.query(DB, "SELECT status FROM decision_requests WHERE id=?1", [
               ctx.decision_request_id
             ])

    assert [wake] =
             DB
             |> Wakes.list_pending()
             |> Enum.filter(&(&1.prompt == "boot recovered retired decision"))

    assert wake.session_key == "agent:boot-target:app"
  end

  test "row commits refuse when recognition has not been installed" do
    :persistent_term.erase(RuleRuntime)

    assert_raise RuntimeError, "row rule recognition is not loaded", fn ->
      RuleRuntime.row_commit_effects_in_txn(%DB.Txn{conn: nil}, [])
    end
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

  # The no-harness first-run refusal is proven in test/application_refusal_test.exs, by
  # booting the application in a SUBPROCESS. It cannot be tested here: this file calls
  # `Tightbeam.Application.start/2` in-process, and that refusal really does
  # `System.halt(1)` — the whole point of it — so an in-process version took the suite
  # VM down with it. It previously passed only because of a `:refusal_exit` config seam
  # that let production return instead of halting; the seam is gone, and every assertion
  # that test made (message text, no stacktrace, no crash dump, no base dir created)
  # moved to the subprocess test, where it is checked against the real exit.

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

  defp seed_retired_decision!(base) do
    # Fixture writes happen before the production boot under test, so give the
    # writer a valid empty evaluator and erase it before Application.children/0.
    Rules.load!(base, ["attest"])

    db = :"application_seed_db_#{System.unique_integer([:positive])}"
    path = Path.join(base, "state.db")
    {:ok, pid} = DB.start_link(path: path, name: db)
    :ok = Tightbeam.Schema.ensure_all(db)

    raiser =
      Org.create(db, %{
        session_key: "agent:boot-raiser:app",
        display_name: "boot raiser",
        owner_user_id: "boot-owner",
        origin: "user:boot-owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    _target =
      Org.create(db, %{
        session_key: "agent:boot-target:app",
        display_name: "boot target",
        owner_user_id: "boot-owner",
        origin: "user:boot-owner",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    call = %{
      verb: "attest",
      origin: "agent:boot-raiser",
      principal: {:session, raiser.session_key},
      session_key: nil,
      params: %{assignment_id: "asg-boot", kind: "completion"}
    }

    {:decision_pending, request_id} =
      Escalation.escalate(
        db,
        call,
        %{name: "boot-review", text: "boot review required"},
        %{question: "Allow boot action?", options: nil}
      )

    :ok =
      DB.execute(
        db,
        "UPDATE sessions SET state='retired' WHERE sessionKey='agent:boot-raiser:app'"
      )

    GenServer.stop(pid)

    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "boot-decision-recovery.toml"), """
    [[rule]]
    name = "observe-boot-decision-recovery"
    verb = "retire"
    edges = ["row-commit"]
    effect = "notice"
    text = "record recovered decision withdrawal"
    deny_when = [{ fact = "decision_request.status", op = "eq", value = "withdrawn" }]

    [rule.notice]
    target_session = "agent:boot-target:app"
    prompt = "boot recovered retired decision"
    """)

    %{decision_request_id: request_id}
  end
end
