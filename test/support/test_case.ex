defmodule Tightbeam.TestCase do
  @moduledoc false

  # WAITING ON THINGS — read this before adding a sleep or a refute.
  #
  # `start_supervised!` is NOT a boot barrier for an adapter. `Acp.Adapter.init/1`
  # returns `{:ok, nil, {:continue, {:boot, opts}}}`, so it returns before `node`
  # is spawned and before the `initialize` round trip; anything sent to a fresh
  # adapter queues behind that boot.
  #
  # The sanctioned barriers, in order of preference. `assert_ready/2` (an
  # unbounded receive plus a death monitor, acp_adapter_test.exs) for adapter
  # boot. A `GenServer.call` into the target — including `:sys.get_state/1` —
  # when the thing you are waiting on is a `cast`: both are answered in mailbox
  # order, so the cast has RUN when the call returns.
  #
  # A fixed sleep before a `refute_receive`/`refute_received` is a false-pass
  # generator, not a budget: if the work has not started yet, the absence you
  # assert is the absence of a beginning. Make the racing side signal before it
  # acts, `assert_receive` that signal, then refute.
  #
  # A predicate-poll helper that returns `false` on exhaustion must be called
  # under `assert` — in statement position its timeout is silent, and the test
  # passes having proven nothing.
  #
  # Which SIDE the budget sits on decides how it fails, and the two are not
  # symmetric. A CHECK-side wait — how long you will watch for an effect —
  # under-detects: for effect time T and window W, T<W is observed and T>W is
  # missed, and load only raises T, so a longer check-side wait is never worse
  # (neither a written file nor a received message is reversible once it lands).
  # A SETUP-side budget is the dangerous one: it is the window the effect must
  # land INSIDE, so load closes it and the test suppresses nothing while still
  # going green. The case that established this: a kill test whose fixture slept
  # 2s, which at load 97 finished on its own before the kill arrived, so the test
  # passed having killed nothing. Give such a fixture a window load cannot close.
  # Do not "simplify" a widened check-side wait back down on a symmetry that does
  # not hold.

  use ExUnit.CaseTemplate

  @persistent_keys [
    Tightbeam.Rules,
    Tightbeam.Rails,
    Tightbeam.Archetypes,
    {Tightbeam.Application, :draining}
  ]

  using do
    quote do
      import Tightbeam.TestCase,
        only: [
          register_hosts: 2,
          catalog_reply: 1,
          catalog_reply: 2,
          catalog_probe_harness: 1,
          claim_org: 2,
          cursor_signing!: 1,
          ensure_all_schemas: 1,
          ensure_main_session: 2
        ]
    end
  end

  setup do
    assert_hermetic_tmp!()
    snapshot = snapshot()
    on_exit(fn -> restore(snapshot) end)

    # The ONE place the episode writer starts for tests. Not per-suite ceremony and
    # deliberately not lazy: call sites use the named process and a missing one is loud,
    # so a suite that evaluates a check-tier statute must find a real writer here rather
    # than silently conjuring one. Fresh per test, so ordering state never leaks between
    # them; suites that never touch rails just have an idle process.
    start_supervised!({Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes})

    # Same contract as the episode writer above: `Artifacts.record/2` reads the
    # named process, and an absent one degrades to a weaker evidence class rather
    # than failing loudly — so a suite that asserts `tool-call-observed` must find
    # a real writer here or it would silently be asserting the fallback.
    start_supervised!({Tightbeam.TurnObservations, name: Tightbeam.TurnObservations})

    :ok
  end

  @doc "Create the complete production schema for a unit-test database."
  def ensure_all_schemas(db), do: Tightbeam.Schema.ensure_all(db)

  @doc "Provision or load the real durable cursor-signing provider for a test base dir."
  def cursor_signing!(base_dir) do
    base_dir = cursor_signing_base_dir(base_dir)

    case Tightbeam.CursorSigning.load(base_dir) do
      {:ok, provider} ->
        case Tightbeam.CursorSigning.validate(provider) do
          :ok ->
            provider

          {:error, :cursor_signing_unprovisioned} ->
            :ok = Tightbeam.CursorSigning.provision(base_dir)
            Tightbeam.CursorSigning.load!(base_dir)

          {:error, reason} ->
            raise Tightbeam.CursorSigning.Error, reason: reason
        end

      {:error, %Tightbeam.CursorSigning.Error{reason: reason}}
      when reason in [:missing_directory, :missing_material] ->
        :ok = Tightbeam.CursorSigning.provision(base_dir)
        Tightbeam.CursorSigning.load!(base_dir)

      {:error, reason} ->
        raise reason
    end
  end

  defp cursor_signing_base_dir(base_dir) do
    if Path.expand(base_dir) == Path.expand("/tmp") do
      Path.join(System.tmp_dir!(), "tightbeam-cursor-signing-fixture")
    else
      base_dir
    end
  end

  @doc "Claim a fresh test org through the production cold-start coordinator."
  def claim_org(db, input) do
    Tightbeam.ColdStart.pair(db, input, %{
      host: "testhost",
      harness: :claude,
      provider: fn -> :anthropic end,
      model: Tightbeam.Model.new("fable")
    })
  end

  @doc "Create the canonical self-parented Main fixture for an owner when absent."
  def ensure_main_session(db, owner) do
    key = Tightbeam.Org.personal_session_key(owner)

    case Tightbeam.Org.get(db, key) do
      nil ->
        Tightbeam.Org.create(db, %{
          session_key: key,
          display_name: "Main",
          kind: "main",
          is_built_in: true,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          harness: "claude",
          provider: "anthropic",
          model: Tightbeam.Model.new("fable"),
          host: "testhost"
        })

      %{kind: "main", operational_parent: ^key} = session ->
        session

      session ->
        raise "invalid Main fixture for #{owner}: #{inspect(session)}"
    end
  end

  @doc """
  Register satellite hosts the way the product does.

  `assimilate` records a host through `Placement.register_host/3`, a row in the
  org DB's `hosts` table — the one host store. Tests used to inject
  `Application.put_env(:tightbeam, :hosts, …)`, a SECOND store that existed only
  because `TIGHTBEAM_HOSTS` did; both are gone. Beyond removing the duplication,
  this scopes host config to the test's own DB instead of global app env, so
  two tests can no longer see each other's hosts.

  This is assimilate's recording step, not the whole verb: the rest of it probes
  ssh and installs adapters on a real machine, which a test naming a fictional
  host cannot do.
  """
  def register_hosts(db, hosts) do
    # The registry is a table; a suite that registers hosts declares it.
    :ok = Tightbeam.Placement.ensure_schema(db)

    Enum.each(hosts, fn {name, config} ->
      {:ok, _entry} = Tightbeam.Placement.register_host(db, name, config)
    end)
  end

  @doc """
  Wrap a catalog body the way the probe's shell hands it back.

  Both harness catalogs are now one HTTPS call made BY the host that owns the
  credential, so a test supplies a RESPONSE, not a file. curl cannot return a
  status any other way than printing it, so it rides on a trailing line, with
  whatever the probe learned on that host after it — for codex, the `codex
  --version` that decided which models the server would even list.
  """
  def catalog_reply(body, status \\ 200)
  def catalog_reply(body, status), do: {body <> "\n#{status} 0.145.0", 0}

  @doc "Which harness a captured catalog-probe argv belongs to."
  def catalog_probe_harness(argv) do
    if argv |> List.last() |> String.contains?("api.anthropic.com"),
      do: :claude,
      else: :codex
  end

  # Per-test scratch dirs are named with System.unique_integer/1, which is unique
  # only within one BEAM. They stay collision-free because config/test.exs points
  # TMPDIR at a per-BEAM root. If that root goes missing, System.tmp_dir!/0 falls
  # back to the shared /tmp, concurrent `mix test` processes mint the same scratch
  # names, and each one's rm_rf cleanup deletes fixtures another is still using —
  # which reads as a passing assertion over an absent file, not as a failure.
  defp assert_hermetic_tmp! do
    suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)
    actual = System.tmp_dir!()

    if actual != suite_tmp do
      raise "test tmp root is not hermetic: expected #{suite_tmp}, got #{actual}"
    end
  end

  @doc false
  def snapshot do
    %{
      application: Map.new(Application.get_all_env(:tightbeam)),
      persistent: Map.new(@persistent_keys, &{&1, persistent_value(&1)}),
      system: System.get_env()
    }
  end

  @doc false
  def restore(snapshot) do
    restore_application(snapshot.application)
    restore_persistent(snapshot.persistent)
    restore_system(snapshot.system)
  end

  defp persistent_value(key) do
    sentinel = make_ref()

    case :persistent_term.get(key, sentinel) do
      ^sentinel -> :absent
      value -> {:present, value}
    end
  end

  defp restore_application(expected) do
    current = Map.new(Application.get_all_env(:tightbeam))

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> Application.put_env(:tightbeam, key, value)
        {:error, {:ok, _value}} -> Application.delete_env(:tightbeam, key)
        {:error, :error} -> :ok
      end
    end)
  end

  defp restore_persistent(expected) do
    Enum.each(expected, fn {key, expected_value} ->
      case {expected_value, persistent_value(key)} do
        {value, value} -> :ok
        {:absent, _current} -> :persistent_term.erase(key)
        {{:present, value}, _current} -> :persistent_term.put(key, value)
      end
    end)
  end

  defp restore_system(expected) do
    current = System.get_env()

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> System.put_env(key, value)
        {:error, {:ok, _value}} -> System.delete_env(key)
        {:error, :error} -> :ok
      end
    end)
  end
end
