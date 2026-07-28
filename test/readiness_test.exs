defmodule Tightbeam.ReadinessTest do
  @moduledoc """
  Proofs for the boot readiness summary.

  The defect it exists for: boot ended on `Running ... (http)` — a success
  line — on an org that could not run a single turn. So the load-bearing
  property is not that the summary is pretty, it is that the CLOSING statement
  is true, names the missing thing, and says what to do.

  The catalog is a stub here rather than a real server: every fact the summary
  reads is already-cached `{entries, health}`, so a stub supplies exactly what
  boot would have supplied and the tests stay hermetic. That is the whole point
  of the design — if this needed a live catalog to test, it would be doing I/O
  it promised not to do.
  """
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Harness, Readiness}

  defmodule StubCatalog do
    @moduledoc false
    use GenServer

    def start(answers), do: GenServer.start(__MODULE__, answers)
    def init(answers), do: {:ok, answers}

    # Keyed by {host, harness}, like the real server. Tests that care about one
    # host key their answers by harness alone and let this default the host.
    def handle_call({:get, {host, harness}}, _from, answers) do
      answer =
        Map.get(answers, {host, harness}) || Map.get(answers, harness) ||
          {[], {:unavailable, :not_derived}}

      {:reply, answer, answers}
    end

    def handle_call(:get, _from, answers), do: {:reply, answers, answers}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "readiness_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, config: %{base_dir: base, default_model: "m[medium]"}}
  end

  defp install_adapter!(base, module) do
    path =
      Path.join([
        base,
        "adapters",
        "node_modules",
        ".bin",
        Path.basename(module.install_package())
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    path
  end

  defp catalog!(answers) do
    {:ok, pid} = StubCatalog.start(answers)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp live(ref), do: {[%{ref: ref}], :fresh}

  ## The verdict

  test "a bare org says NOT READY and the verdict is the FIRST line", ctx do
    catalog = catalog!(%{})

    summary = Readiness.summary(ctx.config, catalog)
    refute summary.runnable?

    [first | _] = lines = Readiness.render(summary, ctx.config)
    assert first =~ "NOT READY"
    assert first =~ "no harness on any host can run a turn"

    # Serving is still correct — the summary must say so rather than implying
    # the gateway is down.
    assert Enum.any?(lines, &(&1 =~ "serving"))
  end

  test "a fully ready install says so in ONE line and says nothing else", ctx do
    for module <- Harness.all(), do: install_adapter!(ctx.base, module)
    catalog = catalog!(Map.new(Harness.all(), &{&1.wire_name(), live("m[medium]")}))

    summary = Readiness.summary(ctx.config, catalog)
    assert summary.runnable?
    names = Enum.map_join(Harness.all(), ", ", &"#{&1.wire_name()} on testhost")

    # EXACT output, not "does not contain". A working install states it and stops.
    # "Does not nag" is guarded twice — the ready harness is rejected before
    # rendering, AND a gapless row renders nothing — so an assertion that only
    # forbids certain substrings passes when EITHER guard holds and cannot tell
    # you the other has gone. Pinning the whole render makes both load-bearing.
    assert Readiness.render(summary, ctx.config) == ["READY: #{names} can run turns."]
  end

  ## Naming the gap and the fix — the identity-check standard

  test "a missing adapter names the exact path and a command that installs it", ctx do
    [module | _] = Harness.all()
    catalog = catalog!(%{module.wire_name() => live("m[medium]")})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "adapter missing"))

    assert line =~ ctx.base, "must name the REAL path, not a placeholder"
    assert line =~ Path.basename(module.install_package())
    assert line =~ "npm install --prefix"
    assert line =~ module.install_package()
    assert line =~ "no turn can start"
  end

  test "a missing credential names the onboard command", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "no credential"))

    # The CLI's `onboard` takes the credential PROVIDER (anthropic|openai), not the
    # harness (claude|codex). This assertion used to pin wire_name(), so it stayed
    # green while the summary printed a command the CLI rejects outright — on the
    # one surface the operator is told to act on. Assert the provider, and assert
    # the harness name is NOT what gets handed to the verb.
    assert line =~ "tightbeam onboard #{module.credential_provider()}"
    refute line =~ "tightbeam onboard #{module.wire_name()}"
  end

  test "a default model outside the live catalog is named with the ref", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    catalog = catalog!(%{module.wire_name() => live("something-else[low]")})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "default model"))

    assert line =~ "m[medium]"
    assert line =~ "TIGHTBEAM_DEFAULT_MODEL"
  end

  ## Doctor's lesson: unverifiable is not failed

  test "a credential boot could not look at is UNKNOWN, never asserted dead", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    for reason <- [:credential_server_unavailable, :not_derived, :catalog_not_started] do
      health =
        case reason do
          :credential_server_unavailable -> {:unavailable, {:needs_onboarding, reason}}
          other -> {:unavailable, other}
        end

      catalog = catalog!(%{module.wire_name() => {[], health}})

      row =
        Enum.find(
          Readiness.summary(ctx.config, catalog).harnesses,
          &(&1.harness == module.wire_name())
        )

      assert match?({:unknown, _}, row.credential), "#{inspect(reason)} must be UNKNOWN"

      line =
        ctx.config
        |> Readiness.summary(catalog)
        |> Readiness.render(ctx.config)
        |> Enum.find(&(&1 =~ "credential state"))

      assert line =~ "UNKNOWN"
      assert line =~ "NOT a claim", "it must disclaim, not accuse"
      refute line =~ "Onboard it with", "no repair advice for something never observed"
    end
  end

  test "a blocked harness is NEVER silent, even in a state the constructor cannot make", ctx do
    # Exhaustive over the row state space: every non-runnable row must render at
    # least one line explaining itself. The one combination that used to render
    # nothing (adapter present, credential live, model unknown) is unreachable
    # through summary/2 today, but the invariant lives in two functions that do
    # not know about each other.
    rows =
      for adapter <- [:present, {:missing, "/p"}, {:unknown, :not_probed_on_satellite}],
          credential <- [:live, {:absent, :missing}, {:unknown, :x}, {:degraded, :y}],
          model <- [:selectable, {:absent, "m"}, :unknown] do
        %{
          host: "somehost",
          harness: "h",
          # Rows here are built directly rather than through harness_row/3, so a
          # new key must be mirrored or every row crashes instead of rendering —
          # which this test would report as a silence failure, correctly.
          provider: :a_provider,
          adapter: adapter,
          credential: credential,
          model: model,
          runnable?:
            not match?({:missing, _}, adapter) and credential == :live and model == :selectable
        }
      end

    for row <- Enum.reject(rows, & &1.runnable?) do
      explanation =
        %{runnable?: false, harnesses: [row]}
        |> Readiness.render(ctx.config)
        |> Enum.drop(3)
        |> Enum.reject(
          &(&1 == "" or String.starts_with?(&1, "Diagnose") or &1 =~ ~r/^  h on somehost:$/)
        )

      refute explanation == [],
             "blocked row renders no explanation: #{inspect(Map.drop(row, [:harness]))}"
    end
  end

  ## The derivation this module rests on

  test "every registered harness's adapter bin is its package basename", _ctx do
    # `adapter_state/3` derives the adapter's bin name from `install_package/0`
    # because no callback exposes it. If a harness ever breaks that convention,
    # its adapter would be reported permanently missing and the summary would
    # send operators to reinstall something already installed — so the
    # convention is pinned here rather than assumed.
    for module <- Harness.all() do
      # The harness behaviour exposes no adapter_bin, so the coupling is pinned
      # against the path Support ACTUALLY builds, as published in the harness's
      # own conformance vectors.
      expected = "/adapters/node_modules/.bin/" <> Path.basename(module.install_package())

      published =
        inspect(module.conformance_vectors(), limit: :infinity, printable_limit: :infinity)

      assert String.contains?(published, expected),
             "#{module.wire_name()}: Support builds no adapter path ending #{expected}, " <>
               "so Readiness.adapter_state/3 — which derives the bin name from " <>
               "install_package/0 — would report this adapter permanently missing"
    end
  end
end
