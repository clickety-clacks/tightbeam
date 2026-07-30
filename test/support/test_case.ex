defmodule Tightbeam.TestCase do
  @moduledoc false

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
        only: [register_hosts: 2, catalog_reply: 1, catalog_reply: 2, catalog_probe_harness: 1]
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

    :ok
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
