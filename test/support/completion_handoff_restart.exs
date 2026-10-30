defmodule Tightbeam.CompletionHandoffRestart do
  import ExUnit.Assertions

  alias Tightbeam.{Assignments, DB, Gateway, Model, Org, Placement, Wakes, WorkItems}

  @owner "handoff-admin"
  @parent "agent:handoff:parent"
  @holder "agent:handoff:holder"

  # Stores a child's finish notice to its opener and commits that notice's
  # delivery. The process then halts before the delivery step's post-commit
  # source action can run.
  def deliver!(evidence) do
    for key <- [@parent, @holder] do
      Org.create(DB, %{
        session_key: key,
        display_name: key,
        owner_user_id: @owner,
        origin: "user:#{@owner}",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture-model")
      })
    end

    # The scheduler would deliver the stored notice and run its follow-through
    # itself. Holding it leaves delivery to the transaction below; process
    # death removes the suspension.
    :ok = :sys.suspend(Tightbeam.WakeScheduler)

    %{id: item_id} =
      WorkItems.__handle__(
        DB,
        "work-item-create",
        call("work-item-create", {:user, @owner}, nil, %{title: "completion handoff restart"})
      )

    %{id: _parent_id, state: "open"} = assign!(@parent, @parent, "parent coordination", item_id)
    %{id: child_id, state: "open"} = assign!(@parent, @holder, "child task", item_id)

    %{assignment: %{state: "closed"}} =
      Assignments.__handle__(
        DB,
        "attest",
        call("attest", {:session, @holder}, nil, %{assignment_id: child_id, kind: "completion"})
      )

    assert [root] = terminal_notices()
    assert root.session_key == @parent
    assert root.state == "pending"

    assert {:ok, {:appended, @parent, _message, _opts}} =
             DB.transaction(DB, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 root.session_key,
                 root.origin,
                 root.prompt,
                 wake_id: root.wake_id,
                 sender: root.origin,
                 target_gate: root,
                 fire_wake_in_txn: true
               )
             end)

    %{state: "fired", delivered_turn_seq: seq} = Wakes.get(DB, root.wake_id)
    assert is_integer(seq)
    assert [["queued", wake_id]] = rows("SELECT status,wakeId FROM turns WHERE seq=?1", [seq])
    assert wake_id == root.wake_id
    assert reminders(root.wake_id) == []

    File.write!(evidence, JSON.encode!(%{root: root.wake_id, seq: seq}))
  end

  # After an ordinary boot the parent's queued turn runs and ends; the
  # turn-end sweeper then stores the reminder from the delivered record.
  def restarted!(evidence, booted_at) do
    %{"root" => root_id, "seq" => seq} = JSON.decode!(File.read!(evidence))

    await!(
      fn ->
        ended?(seq) and pending_reminders(root_id) != [] and sweeper_cursor() >= seq
      end,
      fn ->
        %{
          turns: rows("SELECT seq,wakeId,status,startedAt,endedAt FROM turns ORDER BY seq"),
          reminders: Enum.map(reminders(root_id), &Map.take(&1, [:wake_id, :state])),
          cursor: sweeper_cursor()
        }
      end
    )

    [[status, started_at]] = rows("SELECT status,startedAt FROM turns WHERE seq=?1", [seq])
    assert status in ["delivered", "failed", "failed_unknown"]
    assert started_at >= booted_at
    assert rows("SELECT COUNT(*) FROM turns WHERE wakeId=?1", [root_id]) == [[1]]

    assert [reminder] = pending_reminders(root_id)
    assert reminder.session_key == @parent
    assert String.starts_with?(reminder.condition_kind, "terminal-child-owner-action-")
    assert reminder.condition_scope == root_id
    reminder
  end

  defp assign!(opener, holder, subject, item_id) do
    Assignments.__handle__(
      DB,
      "assign",
      call("assign", {:session, opener}, holder, %{
        subject: subject,
        idempotency_key: nil,
        work_item_id: item_id,
        effect_kind: "coordination"
      })
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 3_600_000})
    )
  end

  defp call(verb, principal, target, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      params: params
    }
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user_id}), do: "user:#{user_id}"

  defp ended?(seq) do
    rows("SELECT 1 FROM turns WHERE seq=?1 AND endedAt IS NOT NULL", [seq]) == [[1]]
  end

  defp terminal_notices do
    rows("SELECT wakeId FROM wakes WHERE obligationRef LIKE ?1", [
      "terminal-child-owner-notification:%"
    ])
    |> Enum.map(fn [wake_id] -> Wakes.get(DB, wake_id) end)
  end

  defp reminders(root_id) do
    rows("SELECT wakeId FROM wakes WHERE obligationRef=?1 ORDER BY rowid", [
      "terminal-child-owner-action-reminder:" <> root_id
    ])
    |> Enum.map(fn [wake_id] -> Wakes.get(DB, wake_id) end)
  end

  defp pending_reminders(root_id), do: Enum.filter(reminders(root_id), &(&1.state == "pending"))

  defp sweeper_cursor do
    case rows("SELECT seq FROM production_cursors WHERE name='bubble'") do
      [[cursor]] -> cursor
      [] -> 0
    end
  end

  defp rows(sql, params \\ []) do
    {:ok, rows} = DB.query(DB, sql, params)
    rows
  end

  defp await!(predicate, diagnostic, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 90_000

    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "completion handoff restart timed out: #{inspect(diagnostic.(), limit: :infinity)}"

      true ->
        receive do
        after
          50 -> await!(predicate, diagnostic, deadline)
        end
    end
  end
end

# Both phases boot the same assembled payload through ordinary Application
# startup against one base directory.
[payload, base, phase] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
true = phase in ["deliver", "restart"]
evidence = Path.join(Path.dirname(base), "completion-handoff-restart.json")

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")

if phase == "deliver" do
  false = File.exists?(base)

  path = Path.join(base, "state.db")
  {:ok, db} = Tightbeam.DB.start_link(path: path, name: Tightbeam.DB, guard_inputs: [])

  :ignore = Tightbeam.Boot.start_link(%{base_dir: base})
  :ok = GenServer.stop(db)

  # Elect the engineering terminal rules in this isolated recovery fixture.
  rules = Path.join(base, "identity/rules")
  File.mkdir_p!(rules)

  for name <- ~w(row-reaction-handoff.toml row-reaction-terminal-action.toml) do
    File.cp!(
      Path.join([:code.priv_dir(:tightbeam), "kungfu/agentic-engineering/rules", name]),
      Path.join(rules, name)
    )
  end

  File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
  Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
else
  true = File.regular?(evidence)
end

tripwire = Path.join(base, "forbidden-execution.log")
bin = Path.join(base, "fixture-bin")
File.mkdir_p!(bin)
# These are synthetic CLI probes, never harness adapters or provider clients.
for name <- ["claude", "codex", "fixture"] do
  path = Path.join(bin, name)

  File.write!(path, """
  #!/bin/sh
  if [ '#{name}' = codex ] && [ "$#" = 2 ] && [ "$1" = --dangerously-bypass-hook-trust ] && [ "$2" = --version ]; then
    shift
  fi
  if [ "$#" = 1 ] && [ "$1" = --version ]; then
    echo '#{name} fixture-only 0.0.0'
    exit 0
  fi
  echo '#{name}: forbidden non-probe' >> "$GUARD_TRIPWIRE"
  exit 64
  """)

  File.chmod!(path, 0o755)
end

for name <- ["npm", "ssh"] do
  path = Path.join(bin, name)
  File.write!(path, "#!/bin/sh\necho '#{name}: forbidden' >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
  File.chmod!(path, 0o755)
end

System.put_env("GUARD_TRIPWIRE", tripwire)
System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

for module <- Tightbeam.Harness.all(),
    key <- module.credential_env_vars(),
    do: System.delete_env(key)

Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
Application.put_env(:tightbeam, :cwd, Path.join(base, "work"))
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Tightbeam.Model.new("fixture-model"))
Application.put_env(:tightbeam, :autostart, true)
File.mkdir_p!(Path.join(base, "work"))
base_tmp = Path.join(base, "tmp")
File.mkdir_p!(base_tmp)
System.put_env("TMPDIR", base_tmp)

booted_at = System.system_time(:millisecond)
{:ok, _apps} = Application.ensure_all_started(:tightbeam)

if phase == "deliver" do
  # Use the existing synthetic provider onboarding lifecycle, not live auth files.
  %{user_id: "handoff-admin", is_admin: true} =
    Tightbeam.Devices.add_user(Tightbeam.DB, "handoff-admin", false)

  onboard =
    Tightbeam.Gateway.handlers(%{
      base_dir: base,
      db: Tightbeam.DB,
      onboarding_lease_ms: 1_800_000
    })["onboard"]

  call = %{origin: "user:handoff-admin", params: %{provider: "fixture-provider"}}

  %{provider: :fixture_provider, status: "ready", staging_path: staging, lease_id: lease} =
    onboard.(put_in(call.params[:phase], "begin"))

  File.write!(Path.join(staging, "fixture.json"), "fixture-provider-credential")

  %{provider: :fixture_provider, status: "onboarded"} =
    onboard.(call |> put_in([:params, :phase], "finish") |> put_in([:params, :lease_id], lease))
end

:onboarded = Tightbeam.Credentials.status(:fixture_provider)

if phase == "deliver" do
  Tightbeam.CompletionHandoffRestart.deliver!(evidence)
  false = File.exists?(tripwire)
  IO.puts("completion-handoff-restart: deliver ok")
  # An abrupt stop: no application shutdown, no drain, no queued casts.
  System.halt(0)
else
  reminder = Tightbeam.CompletionHandoffRestart.restarted!(evidence, booted_at)
  false = File.exists?(tripwire)
  IO.puts("completion-handoff-restart: restart ok reminder=#{reminder.wake_id}")
end
