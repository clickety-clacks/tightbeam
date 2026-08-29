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
  alias Tightbeam.Model

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
    db = :"readiness_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      config: %{
        base_dir: base,
        db: db,
        default_model: Model.new("m", effort: "medium"),
        # HERMETIC by default: the executability axis reuses the real
        # `Placement.harness_binary_probe`, which spawns a `--version` subprocess.
        # Tests that care about executability override this; every other test gets
        # a runnable stub so the summary stays the pure assembly its design
        # promises. A test wanting a broken binary passes its own probe.
        harness_binary_probe: fn _id, _cli_bin -> {:ok, %{bin: "stub", version: "stub 1.0"}} end
      }
    }
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

  # A real entry always carries its provider — routing reads it — so the stub's
  # must too, or the fixture would be a shape the catalog never produces.
  defp live(family, efforts \\ ["medium"]),
    do: {[%{family: family, context: nil, efforts: efforts, provider: :anthropic}], :fresh}

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

  test "a fully ready install says READY and adds ONLY the mandated pre-expiry advisory", ctx do
    for module <- Harness.all(), do: install_adapter!(ctx.base, module)
    catalog = catalog!(Map.new(Harness.all(), &{&1.wire_name(), live("m")}))

    # Under a service manager — the shape a finished install actually runs in.
    # systemd exports INVOCATION_ID; the foreground line below is the only other
    # thing a ready install can say, and it must not fire here.
    System.put_env("INVOCATION_ID", "test-supervised")
    on_exit(fn -> System.delete_env("INVOCATION_ID") end)

    summary = Readiness.summary(ctx.config, catalog)
    assert summary.runnable?
    names = Enum.map_join(Harness.all(), ", ", &"#{&1.wire_name()} on testhost")

    [first | rest] = Readiness.render(summary, ctx.config)

    # The verdict is still one clean line and still FIRST — the anti-nag guarantee
    # for GAPS holds: no adapter/credential/model/foreground line leaks here.
    assert first == "READY: #{names} can run turns."

    # …but O7/I8 (PO ruling) require the pre-expiry-absence to be NAMED for every
    # onboarded credential, so a healthy install is no longer literally one line:
    # it carries exactly one advisory per live credential, and NOTHING else.
    advisory = Enum.reject(rest, &(&1 == ""))
    assert length(advisory) == length(Harness.all())

    assert Enum.all?(advisory, &(&1 =~ "no pre-expiry warning is available")),
           "the only thing a ready install adds is the O7 pre-expiry advisory"

    refute Enum.any?(advisory, &(&1 =~ "FOREGROUND")), "supervised: no foreground line"
  end

  test "a ready install with NO service manager says so — the install is not finished", ctx do
    # The gap that cost a production host its uptime and its crash log (gibson,
    # 2026-08-05): a gateway running foreground in tmux does not survive a
    # reboot, and its `tee` log truncates on restart, so the run you need after
    # a crash is destroyed by the restart. READY is exactly when an operator
    # stops paying attention, so it is exactly where this has to be said.
    for module <- Harness.all(), do: install_adapter!(ctx.base, module)
    catalog = catalog!(Map.new(Harness.all(), &{&1.wire_name(), live("m")}))

    System.delete_env("INVOCATION_ID")
    System.delete_env("XPC_SERVICE_NAME")

    summary = Readiness.summary(ctx.config, catalog)
    assert summary.runnable?

    rendered = Readiness.render(summary, ctx.config)

    assert Enum.any?(rendered, &String.contains?(&1, "FOREGROUND")),
           "a ready but unsupervised gateway said nothing about not surviving a reboot"

    assert Enum.any?(rendered, &String.contains?(&1, "will not survive a logout or a reboot"))
  end

  ## Naming the gap and the fix — the identity-check standard

  test "a missing adapter names self-healing and only an executable manual command", ctx do
    [module | _] = Harness.all()
    base = Path.join(ctx.base, "operator's base")
    config = %{ctx.config | base_dir: base}
    catalog = catalog!(%{module.wire_name() => live("m")})

    line =
      config
      |> Readiness.summary(catalog)
      |> Readiness.render(config)
      |> Enum.find(&(&1 =~ "adapter missing"))

    assert line =~ base, "must name the REAL path, not a placeholder"
    assert line =~ Path.basename(module.install_package())
    assert line =~ "Boot only checks readiness; it does not install adapters"
    assert line =~ "install its pinned adapters automatically when the next session is spawned"
    refute line =~ "tightbeam assimilate"

    [_, command] = String.split(line, "Manual fallback: ", parts: 2)
    fake_bin = Path.join(ctx.base, "fake-bin")
    args_file = Path.join(ctx.base, "npm-args")
    File.mkdir_p!(fake_bin)

    npm = Path.join(fake_bin, "npm")
    File.write!(npm, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$TIGHTBEAM_TEST_ARGS\"\n")
    File.chmod!(npm, 0o755)

    assert {"", 0} =
             System.cmd("sh", ["-c", command],
               env: [
                 {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
                 {"TIGHTBEAM_TEST_ARGS", args_file}
               ]
             )

    assert File.read!(args_file) |> String.split("\n", trim: true) == [
             "install",
             "--prefix",
             Path.join(base, "adapters"),
             "--no-save",
             "#{module.install_package()}@#{module.adapter_version()}"
           ]
  end

  test "a missing credential names the separate login, auth root, and onboard command", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "Tightbeam has no credential"))

    # The CLI's `onboard` takes the credential PROVIDER (anthropic|openai), not the
    # harness (claude|codex). This assertion used to pin wire_name(), so it stayed
    # green while the summary printed a command the CLI rejects outright — on the
    # one surface the operator is told to act on. Assert the provider, and assert
    # the harness name is NOT what gets handed to the verb.
    assert line =~ "tightbeam onboard #{module.credential_provider()}"
    assert line =~ "--as-user <userId>"
    refute line =~ "tightbeam onboard #{module.wire_name()}"
    assert line =~ "normal #{module.wire_name()} CLI login"
    assert line =~ Path.join(ctx.base, "auth")
    assert line =~ "on testhost"
  end

  test "a missing Cursor credential renders the legal API-key command", ctx do
    module = Tightbeam.Harness.Cursor
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "Tightbeam has no credential for cursor"))

    assert line =~ "tightbeam onboard cursor --api-key --as-user <userId>"
  end

  test "a default model outside the live catalog is named by its fields", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    catalog = catalog!(%{module.wire_name() => live("something-else", ["low"])})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "default model"))

    # Named by FIELDS. The old rendering spelled this `m[medium]`, which is the
    # same syntax Anthropic uses for a context window — the collision this
    # refactor removed.
    assert line =~ "m (effort medium)"
    assert line =~ "TIGHTBEAM_DEFAULT_MODEL"
  end

  # THE WRONG CAUSE (task #12). A tiered model named with no effort IS in the
  # live catalog; what is missing is the tier. Blaming the catalog sends the
  # operator to `catalog.diff` to hunt for a model that is already there — the
  # same defect class adjudication was fixed for, surviving in a second copy
  # because readiness derived its own narrower answer.
  test "a default model missing only its effort tier is refused by the tier, not the catalog",
       ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    catalog = catalog!(%{module.wire_name() => live("tiered-model", ["low", "medium", "high"])})
    config = %{ctx.config | default_model: Model.new("tiered-model")}

    line =
      config
      |> Readiness.summary(catalog)
      |> Readiness.render(config)
      |> Enum.find(&(&1 =~ "tiered-model"))

    assert line, "the tier gap must be named at all"
    assert line =~ "effort tiers"
    assert line =~ "low|medium|high"
    assert line =~ "TIGHTBEAM_DEFAULT_EFFORT"

    # The lie: the model IS in the live catalog, so this must not be the refusal.
    refute line =~ "is not in #{module.wire_name()}'s live catalog"
  end

  # The catalog can fail for its OWN reason, with a working credential: the codex
  # models endpoint drops every model for a too-old client_version and returns
  # 200. No other row says that — the credential row calls it "degraded" — so a
  # model row that defers here is how the one honest diagnosis failed to reach
  # boot at all.
  test "a catalog emptied by a client_version filter blames the binary at boot", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{
        module.wire_name() => {[], {:unavailable, {:empty_catalog_for_client_version, "0.99.0"}}}
      })

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "default model"))

    assert line, "the catalog's own failure must be named"
    assert line =~ ~s(EMPTY model list for client_version "0.99.0")
    assert line =~ "credential is not implicated"
    assert line =~ "upgrade #{module.wire_name()}"

    # …and boot adds no remedy of its own, because re-picking a model cannot
    # repair a catalog that was never derived.
    refute line =~ "TIGHTBEAM_DEFAULT_MODEL"
    refute line =~ "TIGHTBEAM_DEFAULT_EFFORT"
  end

  test "a model with no tiers is told to UNSET the effort, not to pick one", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    # ctx.config's default is `m` at effort medium; this entry offers no tiers.
    catalog = catalog!(%{module.wire_name() => live("m", [])})

    line =
      ctx.config
      |> Readiness.summary(catalog)
      |> Readiness.render(ctx.config)
      |> Enum.find(&(&1 =~ "default model"))

    assert line =~ "has no effort tiers"
    assert line =~ "unset TIGHTBEAM_DEFAULT_EFFORT"

    # The remedy that cannot work: there is no tier to name.
    refute line =~ "to one of the tiers it offers"
  end

  test "an archetype whose where names no registered host is called out", ctx do
    catalog = catalog!(%{})

    archetypes = %{
      "default" => %{name: "default", where: ["testhost"]},
      "recon" => %{name: "recon", where: ["eezo", "racter"]}
    }

    lines =
      ctx.config
      |> Readiness.summary(catalog, archetypes)
      |> Readiness.render(ctx.config)

    line = Enum.find(lines, &(&1 =~ "archetype recon"))
    assert line, "the dangling archetype must be named"
    assert line =~ "eezo"
    assert line =~ "racter"
    assert line =~ "cannot be placed"
    refute Enum.any?(lines, &(&1 =~ "archetype default"))
  end

  test "a partial intersection and an anywhere grant are NOT flagged", ctx do
    # Both can still place: the registered subset serves the first, and ["*"]
    # places anywhere by definition. Flagging either would nag on healthy orgs.
    catalog = catalog!(%{})

    archetypes = %{
      "mixed" => %{name: "mixed", where: ["testhost", "eezo"]},
      "roamer" => %{name: "roamer", where: ["*"]}
    }

    summary = Readiness.summary(ctx.config, catalog, archetypes)
    assert summary.unplaceable_archetypes == []

    refute summary |> Readiness.render(ctx.config) |> Enum.any?(&(&1 =~ "archetype"))
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
    unroutable = %Tightbeam.Unroutable{
      cause: :family_absent,
      host: "somehost",
      harness: "h",
      selection: Model.new("m"),
      health: [{"h", :fresh}],
      offered: []
    }

    rows =
      for adapter <- [:present, {:missing, "/p"}, {:unknown, :not_probed_on_satellite}],
          binary <- [
            :runnable,
            {:broken, {:exec_failed, "boom"}},
            {:unknown, :not_probed_on_satellite}
          ],
          credential <- [:live, {:absent, :missing}, {:unknown, :x}, {:degraded, :y}],
          model <- [:selectable, :unset, {:unroutable, unroutable}, :unknown] do
        %{
          host: "somehost",
          base_dir: "/some/base",
          harness: "h",
          # Rows here are built directly rather than through harness_row/6, so a
          # new key must be mirrored or every row crashes instead of rendering —
          # which this test would report as a silence failure, correctly.
          provider: :a_provider,
          adapter: adapter,
          binary: binary,
          credential: credential,
          model: model,
          runnable?:
            not match?({:missing, _}, adapter) and not match?({:broken, _}, binary) and
              credential == :live and model == :selectable
        }
      end

    for row <- Enum.reject(rows, & &1.runnable?) do
      explanation =
        %{runnable?: false, harnesses: [row]}
        |> Readiness.render(ctx.config)
        |> Enum.drop(3)
        |> Enum.reject(
          # The O7 pre-expiry advisory is a standing note about a PRESENT
          # credential, not a gap explanation — rejecting it keeps this test's
          # teeth on the GAP-explanation invariant it exists for.
          &(&1 == "" or String.starts_with?(&1, "Diagnose") or &1 =~ "no pre-expiry warning" or
              &1 =~ ~r/^  h on somehost:$/)
        )

      refute explanation == [],
             "blocked row renders no explanation: #{inspect(Map.drop(row, [:harness]))}"
    end
  end

  ## Executability is a distinct axis (O5/I6), and the pre-expiry absence is named (O7/I8)

  # AC5, the real fail-before: with the vendor CLI installed but unable to
  # execute (the gibson codex-as-`.js`-without-node incident), boot said only
  # "Tightbeam has no credential for openai" — true and useless, since onboarding
  # a credential cannot start a binary that cannot run. Readiness must name the
  # EXECUTABILITY gap and must NOT lead with the credential remedy.
  test "an installed-but-unrunnable harness names the executability gap, not 'no credential'",
       ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    # Credential absent (catalog empty, needs_onboarding) AND the vendor CLI is
    # installed but cannot execute.
    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:error, {:exec_failed, "node: not found"}}
      end)

    summary = Readiness.summary(config, catalog)
    row = Enum.find(summary.harnesses, &(&1.harness == module.wire_name()))
    refute row.runnable?

    lines = Readiness.render(summary, config)
    exec_line = Enum.find(lines, &(&1 =~ "CANNOT RUN"))

    assert exec_line, "the executability gap must be named"
    assert exec_line =~ module.wire_name()
    assert exec_line =~ "onboarding a credential cannot help"

    # onboarding cannot help an unrunnable harness — the credential remedy is
    # suppressed so the operator is sent to the gap they can actually act on.
    refute Enum.any?(lines, &(&1 =~ "Tightbeam has no credential")),
           "must not lead with 'no credential' for a harness that cannot execute"
  end

  # AC5, the can-execute half: precedence must not swing the other way — a harness
  # that CAN run but has no credential is still sent to onboarding, not blamed on
  # executability.
  test "a runnable harness with no credential still names onboarding", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:ok, %{bin: "/fake", version: "1.0"}}
      end)

    lines = config |> Readiness.summary(catalog) |> Readiness.render(config)

    assert Enum.any?(lines, &(&1 =~ "tightbeam onboard #{module.credential_provider()}"))
    refute Enum.any?(lines, &(&1 =~ "CANNOT RUN"))
  end

  # The runnable? fold (present-but-unverified shape, supports O1/AC1): a live
  # credential and a fresh catalog do NOT make a harness runnable if its CLI cannot
  # execute. This is the exact case AC1 needs readiness to render as an
  # executability gap rather than as "no credential" or needs_onboarding.
  test "runnable? is false when the CLI cannot run despite a live credential and fresh catalog",
       ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    catalog = catalog!(%{module.wire_name() => live("m")})

    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:error, {:exec_failed, "node: not found"}}
      end)

    summary = Readiness.summary(config, catalog)
    row = Enum.find(summary.harnesses, &(&1.harness == module.wire_name()))

    assert row.credential == :live, "the credential IS present and live here"

    refute row.runnable?,
           "a harness whose CLI cannot run is not runnable even with a live credential"

    lines = Readiness.render(summary, config)
    assert Enum.any?(lines, &(&1 =~ "CANNOT RUN")), "the executability gap must be named"

    # It is NOT a needs-onboarding refusal — the credential is present and live,
    # so sending the operator to onboard would be false.
    refute Enum.any?(lines, &(&1 =~ "tightbeam onboard")),
           "a present-but-unverified host must not be sent to onboarding"
  end

  # A satellite whose executability boot cannot probe stays UNKNOWN and does not
  # veto runnability — the standing rule (no guessing on satellites) applies to the
  # executability axis exactly as it does to the adapter axis.
  test "executability boot cannot probe (satellite) stays unknown and does not veto", ctx do
    [module | _] = Harness.all()
    # Register a non-local host so its row is built as a satellite.
    {:ok, _} =
      Tightbeam.Placement.register_host(ctx.config.db, "faraway", %{
        ssh: "faraway",
        base_dir: "/remote/base",
        cli_bin: "/remote/bin"
      })

    catalog = catalog!(%{{"faraway", module.wire_name()} => live("m")})

    # A probe that would FAIL if it were ever called on the satellite — the point
    # is that it is not, so executability is unknown, not broken.
    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:error, {:exec_failed, "should not be probed on a satellite"}}
      end)

    row =
      Readiness.summary(config, catalog).harnesses
      |> Enum.find(&(&1.host == "faraway" and &1.harness == module.wire_name()))

    assert match?({:unknown, _}, row.binary),
           "satellite executability is unknowable from boot, so it must be unknown"

    # unknown does not veto: a live credential + fresh catalog + present-or-unknown
    # adapter on a satellite is still reported runnable, not blocked on a probe boot
    # could not run.
    assert row.runnable?
  end

  # AC7 (absence named): O7's positive deliverable. For each onboarded (live)
  # credential, readiness states plainly that no pre-expiry warning is available —
  # the credential self-rotates or never expires, so an observed 401 is its only
  # failure signal, not an advance courtesy.
  test "readiness names that no pre-expiry warning is available for each onboarded credential",
       ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)
    catalog = catalog!(%{module.wire_name() => live("m")})

    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:ok, %{bin: "/fake", version: "1.0"}}
      end)

    lines = config |> Readiness.summary(catalog) |> Readiness.render(config)
    line = Enum.find(lines, &(&1 =~ "pre-expiry"))

    assert line, "the absence of a pre-expiry warning must be named for an onboarded credential"
    assert line =~ module.wire_name()
    assert line =~ "401", "the only real failure signal (an observed 401) must be named"
  end

  # The absence line is for CREDENTIALS THAT EXIST. A host with no credential is
  # being told to onboard; naming a pre-expiry absence there would be noise about a
  # credential that is not present.
  test "the pre-expiry absence is NOT named for a host with no credential", ctx do
    [module | _] = Harness.all()
    install_adapter!(ctx.base, module)

    catalog =
      catalog!(%{module.wire_name() => {[], {:unavailable, {:needs_onboarding, :missing}}}})

    config =
      Map.put(ctx.config, :harness_binary_probe, fn _id, _cli_bin ->
        {:ok, %{bin: "/fake", version: "1.0"}}
      end)

    lines = config |> Readiness.summary(catalog) |> Readiness.render(config)

    refute Enum.any?(lines, &(&1 =~ "pre-expiry")),
           "no pre-expiry line for a credential that is not present"
  end

  ## The derivation this module rests on

  test "every registered harness publishes its readiness adapter or dedicated bundle", _ctx do
    # `adapter_state/3` derives the adapter's bin name from `install_package/0`
    # because no callback exposes it. If a harness ever breaks that convention,
    # its adapter would be reported permanently missing and the summary would
    # send operators to reinstall something already installed — so the
    # convention is pinned here rather than assumed.
    for module <- Harness.all() do
      # The harness behaviour exposes no adapter_bin, so the coupling is pinned
      # against the path Support ACTUALLY builds, as published in the harness's
      # own conformance vectors. Cursor launches its dedicated pinned bundle;
      # readiness still tracks the operator-side shim that onboarding stages.
      expected = "/adapters/node_modules/.bin/" <> Path.basename(module.install_package())

      published =
        inspect(module.conformance_vectors(), limit: :infinity, printable_limit: :infinity)

      if module == Tightbeam.Harness.Cursor do
        assert String.contains?(published, "/2026.08.11-e8db854/cursor-agent"),
               "cursor: Support does not publish the pinned dedicated bundle path"
      else
        assert String.contains?(published, expected),
               "#{module.wire_name()}: Support builds no adapter path ending #{expected}, " <>
                 "so Readiness.adapter_state/3 — which derives the bin name from " <>
                 "install_package/0 — would report this adapter permanently missing"
      end
    end
  end
end
