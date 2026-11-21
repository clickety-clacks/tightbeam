import ExUnit.Assertions
alias Tightbeam.{Boot, DB, HarklightWakes, Model, Org, Placement}

[payload, base, scenario, phase] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
^base = System.fetch_env!("TIGHTBEAM_BASE_DIR")
root = Path.dirname(base)
handle = "7d737f62-bbd7-4c51-978d-f6ff5b4d8146"
owner = "feed-fixture"
custody = Path.join(base, "harklight-feed-custody")
intent_key = :crypto.hash(:sha256, handle) |> Base.encode16(case: :lower)
intent = Path.join(custody, intent_key <> ".intent")
refused_file = intent <> ".tmp"
calls_path = Path.join(root, "agent-calls")
recovery_time = Path.join(root, "observed-at")

await = fn check ->
  deadline = System.monotonic_time(:millisecond) + 8_000

  Stream.repeatedly(check)
  |> Enum.find(fn satisfied? ->
    if satisfied? do
      true
    else
      assert System.monotonic_time(:millisecond) < deadline, "feed fixture barrier timed out"
      Process.sleep(20)
      false
    end
  end)
end

for {key, value} <- [
      autostart: false,
      base_dir: base,
      cwd: Path.join(base, "work"),
      port: 0,
      fixture_harness: true,
      local_host_name: "testhost",
      default_harness: :fixture,
      default_model: Model.new("fixture-model"),
      drain_timeout_ms: 1_000,
      kungfu_bundle_root_dir: Path.expand("fixtures/kungfu", __DIR__)
    ],
    do: Application.put_env(:tightbeam, key, value)

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)

bin = Path.join(root, "fixture-bin")
File.mkdir_p!(bin)

if phase == "prepare" do
  refute File.exists?(base)
  {:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])
  :ignore = Boot.start_link(%{base_dir: base})
  %{user_id: ^owner} = Tightbeam.Devices.add_user(db, owner, false)
  :ok = GenServer.stop(db)

  {:ok, candidate_law} = Tightbeam.Identity.learn!(base, "agentic-engineering", "test")
  {:ok, _revision} = Tightbeam.Identity.publish_live!(base, candidate_law)
  File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
  Tightbeam.RecoveryFixture.place_adapter!(base)

  for name <- ~w(claude codex fixture npm ssh) do
    path = Path.join(bin, name)

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = --dangerously-bypass-hook-trust ]; then shift; fi
    if [ "$*" = --version ]; then echo 'feed fixture 1.0'; exit 0; fi
    exit 64
    """)

    File.chmod!(path, 0o755)
  end

  agent = Path.join(bin, "harklight-agent")

  File.write!(agent, """
  #!/bin/sh
  printf '%s\n' "$*" >> '#{calls_path}'
  if [ -f '#{root}/resume' ]; then
    printf '%s\n' '{"kind":"caught_up","rev":9}'
    exec sleep 300
  fi
  printf '%s\n' '{"kind":"caught_up","rev":8}'
  while [ ! -f '#{root}/fail' ]; do sleep 0.05; done
  printf '%s\n' 'listen: live updates paused: internal_error (Request-Id Some("fixture-original-id"))' >&2
  exit 1
  """)

  File.chmod!(agent, 0o755)
else
  if scenario == "neither-store", do: File.rmdir!(refused_file)
end

System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

for module <- Tightbeam.Harness.all(),
    key <- module.credential_env_vars(),
    do: System.delete_env(key)

File.mkdir_p!(Path.join(base, "work"))
Application.put_env(:tightbeam, :autostart, true)
{:ok, _} = Application.ensure_all_started(:tightbeam)

rows = fn sql ->
  {:ok, rows} = DB.query(DB, sql)
  rows
end

calls = fn ->
  File.read(calls_path)
  |> case do
    {:ok, contents} -> String.split(contents, "\n", trim: true)
    {:error, :enoent} -> []
  end
end

pause_rows = fn -> rows.("SELECT diagnostic FROM harklight_feed_pauses") end
checkpoint = "SELECT rev FROM harklight_feed_checkpoints"
launch = "SELECT owner FROM harklight_feed_launches"
expected = "listen --follow --session #{handle} --after 8"

if phase == "prepare" do
  session =
    Org.create(DB, %{
      session_key: "agent:fixture:feed",
      display_name: "Feed fixture",
      owner_user_id: owner,
      origin: "user:" <> owner,
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture-model")
    })

  {:ok, _} =
    DB.query(
      DB,
      """
      INSERT INTO harklight_wake_handles(handle,sessionKey,host,state,createdAt,updatedAt)
      VALUES(?1,?2,?3,'active',1,1)
      """,
      [handle, session.session_key, session.host]
    )

  :ok = HarklightWakes.capture_feed(DB, handle, 8, [], :live)

  if scenario == "clean" do
    :ok =
      DB.execute(DB, """
      CREATE TRIGGER reject_launch BEFORE INSERT ON harklight_feed_launches
      BEGIN SELECT RAISE(ABORT, 'refuse launch custody'); END;
      """)

    HarklightWakes.activate(handle)
    await.(fn -> Map.has_key?(:sys.get_state(HarklightWakes).retry_timers, handle) end)
    assert calls.() == []
    assert rows.(launch) == []
    :ok = DB.execute(DB, "DROP TRIGGER reject_launch")
  else
    HarklightWakes.activate(handle)
  end

  await.(fn ->
    calls.() == [expected] and
      MapSet.size(:sys.get_state(HarklightWakes).starts_in_flight) == 0
  end)

  assert [[_]] = rows.(launch)

  if scenario == "clean" do
    :ok = Application.stop(:tightbeam)
    File.touch!(Path.join(root, "prepare-ready"))
  else
    :ok =
      DB.execute(DB, """
      CREATE TRIGGER reject_pause BEFORE INSERT ON harklight_feed_pauses
      BEGIN SELECT RAISE(ABORT, 'refuse pause projection'); END;
      """)

    File.mkdir_p!(refused_file)
    File.touch!(Path.join(root, "fail"))

    await.(fn -> Map.has_key?(:sys.get_state(HarklightWakes).pending_failures, handle) end)
    {status, observed_at, true} = :sys.get_state(HarklightWakes).pending_failures[handle]
    assert inspect(status) =~ "fixture-original-id"
    File.write!(recovery_time, Integer.to_string(observed_at))
    refute File.exists?(intent)

    case scenario do
      "journal-first" ->
        File.rmdir!(refused_file)
        await.(fn -> File.regular?(intent) end)

        assert {:failure, ^status, ^observed_at, true} =
                 intent |> File.read!() |> :erlang.binary_to_term([:safe])

      "sqlite-first" ->
        :ok = DB.execute(DB, "DROP TRIGGER reject_pause")
        await.(fn -> pause_rows.() != [] end)
        refute File.exists?(intent)

      "neither-store" ->
        :ok
    end

    if scenario == "sqlite-first" do
      assert [[_]] = pause_rows.()
      assert rows.(launch) == []
    else
      assert pause_rows.() == []
      assert [[_]] = rows.(launch)
    end

    assert rows.(checkpoint) == [[8]]
    File.touch!(Path.join(root, "prepare-ready"))
    Process.sleep(:infinity)
  end
else
  if scenario == "clean" do
    await.(fn -> calls.() == [expected, expected] end)
    assert pause_rows.() == []
  else
    if scenario != "sqlite-first" do
      HarklightWakes.activate(handle)
      await.(fn -> Map.has_key?(:sys.get_state(HarklightWakes).retry_timers, handle) end)
      assert pause_rows.() == []
      assert [[_]] = rows.(launch)
      :ok = DB.execute(DB, "DROP TRIGGER reject_pause")
      await.(fn -> pause_rows.() != [] end)
    end

    assert calls.() == [expected]
    assert rows.(checkpoint) == [[8]]
    [[diagnostic]] = pause_rows.()

    if scenario in ["journal-first", "sqlite-first"] do
      assert diagnostic =~ "internal_error"
      assert diagnostic =~ "fixture-original-id"
      at = recovery_time |> File.read!() |> String.to_integer()
      assert rows.("SELECT updatedAt FROM harklight_wake_handles") == [[at]]
      assert rows.(launch) == []
    else
      assert diagnostic =~ "feed_custody_uncertain"
      assert diagnostic =~ "before the feed outcome was recorded"
      refute diagnostic =~ "fixture-original-id"
      assert [[_]] = rows.(launch)
    end

    File.touch!(Path.join(root, "resume"))
    HarklightWakes.activate(handle, true)
    # Let ordinary activation pass through listener admission.
    Process.sleep(350)
    assert calls.() == [expected]
    assert rows.(checkpoint) == [[8]]

    assert %{counts: %{listening: 1}} =
             HarklightWakes.retry_command(DB, %{params: %{handle: handle}})

    assert calls.() == [expected, expected]
    assert rows.(checkpoint) == [[9]]
    assert pause_rows.() == []
  end

  :ok = Application.stop(:tightbeam)
  File.touch!(Path.join(root, "restart-ready"))
end
