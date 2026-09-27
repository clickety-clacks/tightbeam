defmodule Mix.Tasks.Tightbeam.DoctorTest do
  use ExUnit.Case, async: true

  import Tightbeam.TestCase, only: [catalog_reply: 1]

  alias Mix.Tasks.Tightbeam.Doctor
  alias Tightbeam.HarnessBinaryProvenance

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-doctor-#{System.unique_integer([:positive])}")

    identity_dir = Path.join(base_dir, "identity")
    File.mkdir_p!(Path.join(identity_dir, ".git"))
    File.write!(Path.join([identity_dir, ".git", "HEAD"]), "ref: refs/heads/main\n")
    File.write!(Path.join(identity_dir, "README.md"), "identity")
    on_exit(fn -> File.rm_rf!(base_dir) end)

    inputs = [
      base_dir: base_dir,
      default_model: Tightbeam.Model.new("claude-live", effort: "medium"),
      default_harness: :claude,
      advertised_url: "https://tightbeam.example",
      hosts: %{"local-test" => %{ssh: nil, base_dir: base_dir, cli_bin: nil}},
      local_host_name: "local-test",
      cli_bin: Path.join(base_dir, "bin"),
      github_gh_path: "/fixture/bin/gh",
      harness_binary_probe: fn harness, _cli_bin ->
        {:ok, %{bin: "/fake/#{harness}", version: "#{harness} 1.0"}}
      end
    ]

    catalog =
      {:ok,
       %{
         "claude" => [entry("claude-live", ["medium"])],
         "codex" => [entry("codex-live", ["high"])],
         "cursor" => [entry("auto", [])],
         "pi" => [entry("opencode-go/gpt-5.6-luna", ["medium"])],
         "fixture" => [entry("fixture-model", [])]
       }}

    %{base_dir: base_dir, catalog: catalog, inputs: inputs}
  end

  test "all bootstrap checks pass with hermetic inputs", ctx do
    assert {0, %{ready: true, checks: checks}} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert Enum.all?(checks, & &1.ok)
  end

  test "capture records adapter selector metadata without using PATH as provenance",
       _ctx do
    pi =
      HarnessBinaryProvenance.capture(:pi, "eezo", "/eezo", "/usr/local/bin:/usr/bin", [],
        process_env: %{}
      )

    codex =
      HarnessBinaryProvenance.capture(
        :codex,
        "eezo",
        "/eezo",
        "/usr/local/bin:/usr/bin",
        [{"ANTHROPIC_API_KEY", "SECRETXYZ"}, {"CODEX_PATH", "/opt/pinned/codex"}],
        process_env: %{}
      )

    bundled =
      HarnessBinaryProvenance.capture(:claude, "eezo", "/eezo", "/usr/local/bin:/usr/bin", [],
        process_env: %{}
      )

    remote_unknown =
      HarnessBinaryProvenance.capture(:codex, "racter", "/racter", "$PATH", [],
        process_env: %{},
        without_override_evidence?: true
      )

    remote_system =
      HarnessBinaryProvenance.capture(:pi, "racter", "/racter", "$PATH", [],
        process_env: %{},
        without_override_evidence?: true
      )

    remote_unsupported =
      HarnessBinaryProvenance.capture(:fixture, "racter", "/racter", "$PATH", [],
        process_env: %{},
        without_override_evidence?: true
      )

    assert pi["selection_rule"] == "system"
    assert codex["selection_rule"] == "pinned_override"
    assert codex["override_path"] == "/opt/pinned/codex"
    assert bundled["selection_rule"] == "bundled_fallback"
    assert remote_unknown["selection_rule"] == "unknown"
    assert remote_system["selection_rule"] == "system"
    assert remote_unsupported["selection_rule"] == "unsupported"
    refute JSON.encode!(codex) =~ "SECRETXYZ"

    relative_pin =
      HarnessBinaryProvenance.capture(:codex, "eezo", "/eezo", "/usr/bin", [],
        process_env: %{"CODEX_PATH" => "bin/codex"}
      )

    assert %{"status" => "unavailable", "source" => "pinned_override"} =
             HarnessBinaryProvenance.probe_capture(%{ssh: nil}, relative_pin)
  end

  test "an unobserved system selector stays unknown and configured pins beat PATH" do
    hosts = %{
      "eezo" => %{ssh: nil, base_dir: "/eezo", cli_bin: "/eezo/bin"}
    }

    probe = fn _host_config, capture ->
      if capture["harness"] == "codex" do
        assert capture["selection_rule"] == "pinned_override"

        %{
          "status" => "observed",
          "source" => capture["selection_rule"],
          "path" => capture["override_path"],
          "version" => "codex 1.0"
        }
      else
        HarnessBinaryProvenance.probe_capture(%{ssh: nil}, capture)
      end
    end

    assert {:ok, report} =
             HarnessBinaryProvenance.report_for_inputs(
               "/eezo",
               hosts,
               %{{"eezo", "codex"} => [{"CODEX_PATH", "/opt/pinned/codex"}]},
               [],
               harnesses: [Tightbeam.Harness.Pi, Tightbeam.Harness.Codex],
               process_env: %{},
               probe: probe
             )

    pi = Enum.find(report["rows"], &(&1["harness"] == "pi"))
    codex = Enum.find(report["rows"], &(&1["harness"] == "codex"))

    assert pi["next_launch"]["status"] == "unknown"
    assert pi["next_launch"]["source"] == "unknown"
    assert codex["next_launch"]["source"] == "pinned_override"
    assert codex["next_launch"]["path"] == "/opt/pinned/codex"

    human = HarnessBinaryProvenance.format_human(report)
    assert human =~ "harness binary eezo/pi next launch: unknown (unknown)"
    assert human =~ "/opt/pinned/codex; codex 1.0"
  end

  test "system provenance needs an exact prepared launch executable, not PATH discovery" do
    temp_dir =
      Path.join(System.tmp_dir!(), "tightbeam-system-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    path_copy = Path.join(temp_dir, "pi")
    File.write!(path_copy, "#!/bin/sh\nprintf 'pi 2.4.0\\n'\n")
    File.chmod!(path_copy, 0o755)

    pi_capture =
      HarnessBinaryProvenance.capture(:pi, "eezo", temp_dir, temp_dir <> ":/usr/bin:/bin", [])

    assert %{"status" => "unknown", "source" => "unknown"} =
             HarnessBinaryProvenance.observe_selection(%{ssh: nil}, pi_capture)

    selected = Path.join(temp_dir, "cursor-agent")
    File.write!(selected, "#!/bin/sh\nprintf 'cursor-agent 2.4.0\\n'\n")
    File.chmod!(selected, 0o755)

    cursor_capture =
      HarnessBinaryProvenance.capture(:cursor, "eezo", temp_dir, temp_dir <> ":/usr/bin:/bin", [])

    observed =
      HarnessBinaryProvenance.capture_launch_observation(
        %{ssh: nil},
        cursor_capture,
        launch_plan: [cmd: [selected, "acp"]]
      )["launch_observation"]

    assert %{
             "status" => "observed",
             "source" => "system",
             "path" => ^selected,
             "version" => "cursor-agent 2.4.0"
           } = observed

    assert %{"status" => "unknown", "source" => "unknown"} =
             HarnessBinaryProvenance.capture_launch_observation(
               %{ssh: nil},
               cursor_capture,
               launch_plan: [cmd: ["cursor-agent", "acp"]]
             )["launch_observation"]
  end

  test "missing and unprobeable explicit selections keep their source and status" do
    temp_dir =
      Path.join(System.tmp_dir!(), "tightbeam-provenance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    broken = Path.join(temp_dir, "codex-broken")
    File.write!(broken, "#!/bin/sh\necho version-unavailable >&2\nexit 9\n")
    File.chmod!(broken, 0o755)

    unprobeable =
      HarnessBinaryProvenance.capture(:codex, "eezo", temp_dir, "/usr/bin", [],
        process_env: %{"CODEX_PATH" => broken}
      )

    missing =
      HarnessBinaryProvenance.capture(:codex, "eezo", temp_dir, "/usr/bin", [],
        process_env: %{"CODEX_PATH" => Path.join(temp_dir, "absent-codex")}
      )

    assert %{
             "status" => "unprobeable",
             "source" => "pinned_override",
             "path" => ^broken
           } = HarnessBinaryProvenance.probe_capture(%{ssh: nil}, unprobeable)

    assert %{
             "status" => "missing",
             "source" => "pinned_override"
           } = HarnessBinaryProvenance.probe_capture(%{ssh: nil}, missing)
  end

  test "binary provenance separates the captured launch from next launch and emits fallback warning" do
    hosts = %{"eezo" => %{ssh: nil, base_dir: "/eezo", cli_bin: "/eezo/bin"}}

    old_launch_capture =
      HarnessBinaryProvenance.capture(
        :codex,
        "eezo",
        "/eezo",
        "/system/bin:/usr/bin",
        [{"CODEX_PATH", "/opt/old/codex"}]
      )

    old_launch =
      HarnessBinaryProvenance.capture_launch_observation(
        %{ssh: nil},
        old_launch_capture,
        probe: fn _host, capture ->
          %{
            "status" => "observed",
            "source" => capture["selection_rule"],
            "path" => capture["override_path"],
            "version" => "codex 1.0"
          }
        end
      )

    probe = fn _host, capture ->
      case capture["selection_rule"] do
        "pinned_override" ->
          %{
            "status" => "observed",
            "source" => capture["selection_rule"],
            "path" => capture["override_path"],
            "version" => "codex 1.0"
          }

        "bundled_fallback" ->
          %{
            "status" => "observed",
            "source" => capture["selection_rule"],
            "path" => "/eezo/adapters/node_modules/@openai/codex/bin/codex.js",
            "version" => "codex 2.0"
          }

        _ ->
          %{"status" => "missing", "source" => capture["selection_rule"]}
      end
    end

    assert {:ok, report} =
             HarnessBinaryProvenance.report_for_inputs(
               "/eezo",
               hosts,
               %{},
               [
                 %{
                   "host" => "eezo",
                   "harness" => "codex",
                   "generation" => 4,
                   "ready" => true,
                   "capture" => old_launch
                 }
               ],
               harnesses: [Tightbeam.Harness.Codex],
               process_env: %{},
               probe: probe
             )

    [row] = report["rows"]
    [running] = row["running"]
    assert running["source"] == "pinned_override"
    assert running["path"] == "/opt/old/codex"
    assert row["next_launch"]["source"] == "bundled_fallback"
    assert row["next_launch"]["path"] == "/eezo/adapters/node_modules/@openai/codex/bin/codex.js"
    assert "bundled_fallback_selected" in row["warnings"]
  end

  test "remote next-launch selection uses only the named remote override evidence" do
    hosts = %{
      "racter" => %{
        ssh: "clu@racter",
        base_dir: "/racter/tightbeam",
        cli_bin: "/racter/tightbeam/bin"
      }
    }

    probe = fn _host, capture ->
      %{
        "status" => "observed",
        "source" => capture["selection_rule"],
        "path" => capture["override_path"],
        "version" => "codex 2.0"
      }
    end

    assert {:ok, report} =
             HarnessBinaryProvenance.report_for_inputs(
               "/gateway",
               hosts,
               %{},
               [],
               harnesses: [Tightbeam.Harness.Codex],
               process_env: %{},
               remote_runner: fn "ssh", _args, _opts -> {"/opt/remote/codex", 0} end,
               probe: probe
             )

    assert [
             %{
               "next_launch" => %{
                 "source" => "pinned_override",
                 "path" => "/opt/remote/codex"
               }
             }
           ] =
             report["rows"]
  end

  test "same-harness versions warn only when observed versions differ" do
    row = fn host, version ->
      %{
        "host" => host,
        "harness" => "codex",
        "running" => [%{"status" => "observed", "version" => version}],
        "next_launch" => %{"status" => "unknown", "source" => "unknown"}
      }
    end

    assert [first, second] =
             HarnessBinaryProvenance.project([row.("eezo", "1.0"), row.("racter", "2.0")])

    assert "observed_version_differs_across_hosts" in first["warnings"]
    assert "observed_version_differs_across_hosts" in second["warnings"]

    next_row = fn host, version ->
      %{
        "host" => host,
        "harness" => "codex",
        "running" => [],
        "next_launch" => %{"status" => "observed", "version" => version}
      }
    end

    assert [first, second] =
             HarnessBinaryProvenance.project([
               next_row.("eezo", "1.0"),
               next_row.("racter", "2.0")
             ])

    assert "observed_version_differs_across_hosts" in first["warnings"]
    assert "observed_version_differs_across_hosts" in second["warnings"]

    assert [first, second] =
             HarnessBinaryProvenance.project([row.("eezo", "1.0"), row.("racter", "1.0")])

    refute "observed_version_differs_across_hosts" in first["warnings"]
    refute "observed_version_differs_across_hosts" in second["warnings"]
  end

  test "unreachable and unsupported selections stay unknown instead of being inferred" do
    hosts = %{
      "racter" => %{
        ssh: "clu@racter",
        base_dir: "/racter/tightbeam",
        cli_bin: "/racter/tightbeam/bin"
      }
    }

    stale_capture =
      HarnessBinaryProvenance.capture(:codex, "racter", "/racter/tightbeam", "$PATH", [],
        process_env: %{},
        without_override_evidence?: true
      )

    assert {:ok, report} =
             HarnessBinaryProvenance.report_for_inputs(
               "/gateway",
               hosts,
               %{},
               [
                 %{
                   "host" => "racter",
                   "harness" => "codex",
                   "generation" => 7,
                   "ready" => true,
                   "capture" => stale_capture
                 }
               ],
               harnesses: [Tightbeam.Harness.Codex, Tightbeam.Harness.Fixture],
               process_env: %{},
               without_override_evidence?: true,
               remote_runner: fn _command, _args, _opts -> {"", 255} end,
               probe: &HarnessBinaryProvenance.probe_capture/2
             )

    assert %{"status" => "unknown", "source" => "unknown"} =
             report["rows"] |> Enum.at(0) |> Map.fetch!("next_launch")

    assert %{"status" => "unsupported", "source" => "unsupported"} =
             report["rows"] |> Enum.at(1) |> Map.fetch!("next_launch")

    assert %{"status" => "stale", "source" => "unknown"} =
             report["rows"] |> Enum.at(0) |> Map.fetch!("running") |> Enum.at(0)
  end

  # The ENTRY decides whether an effort is required. Rejecting `nil` out of hand
  # failed a perfectly valid default on an untiered model — a false readiness
  # verdict on a selection the gateway and the catalog both accept.
  test "an untiered default model is live without an effort, and a tiered one names its levels",
       ctx do
    catalog =
      {:ok,
       %{
         "claude" => [entry("claude-flat", [])],
         "codex" => [entry("codex-tiered", ["low", "high"])],
         "fixture" => []
       }}

    untiered = put(ctx.inputs, :default_model, Tightbeam.Model.new("claude-flat"))
    {_status, report} = Doctor.evaluate(catalog, untiered)
    assert find(report, "default_model").ok

    # …and an effort on a model that has none is refused, by name.
    with_effort =
      put(ctx.inputs, :default_model, Tightbeam.Model.new("claude-flat", effort: "high"))

    {_status, report} = Doctor.evaluate(catalog, with_effort)
    check = find(report, "default_model")
    refute check.ok
    assert check.detail =~ "has no effort tiers"

    # A TIERED model with no effort fails, and says which levels it has rather
    # than sending the operator to re-pick a model that was never the problem.
    tiered =
      ctx.inputs
      |> put(:default_harness, :codex)
      |> put(:default_model, Tightbeam.Model.new("codex-tiered"))

    {_status, report} = Doctor.evaluate(catalog, tiered)
    check = find(report, "default_model")
    refute check.ok
    assert check.detail =~ "offers low|high"
  end

  test "injected default model passes when live and fails when invalid", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "default_model").ok

    # nil: unset. Bare family: no effort chosen. Unknown family: not offered.
    # A context variant of a live model is NOT the live model, which is exactly
    # what a stripped suffix used to hide.
    for model <- [
          nil,
          Tightbeam.Model.new("claude-live"),
          Tightbeam.Model.new("claude-dead", effort: "medium"),
          Tightbeam.Model.new("claude-live", effort: "medium", context: "1m")
        ] do
      {_status, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :default_model, model))
      check = find(report, "default_model")

      refute check.ok
      assert check.fix =~ "TIGHTBEAM_DEFAULT_MODEL"
      assert check.fix =~ "mix tightbeam.catalog.diff"
    end
  end

  test "fetch_live preserves ready harnesses and doctor warns for one dead credential", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "harness_auth:claude").ok
    assert find(passing, "harness_auth:codex").ok

    fixture = Path.expand("../fixtures/model_catalog/codex_models.jsonc", __DIR__)
    codex_json = fixture_body(fixture)

    # fetch_live blocks in await_fresh until every harness inventory reports a
    # settled health, so it returns as soon as the async refreshes land and this
    # number is only a ceiling on pathology. It has to stay well clear of real
    # scheduling delay: at 1_000 the deadline expired under four concurrent full
    # suites and the call returned {:error, %{"claude" => {:unavailable,
    # :not_derived}, "codex" => {:unavailable, :not_derived}}}.
    catalog =
      Mix.Tasks.Tightbeam.Catalog.Diff.fetch_live(ctx.base_dir, 20_000,
        name: :"doctor_catalog_#{System.unique_integer([:positive])}",
        credential_status: fn
          :anthropic -> {:needs_onboarding, :dead_credential}
          _provider -> :onboarded
        end,
        sh: fn _command -> catalog_reply(codex_json) end
      )

    assert {:ok, %{"claude" => [], "codex" => [_ | _]}, %{"claude" => reason}} = catalog
    assert reason == {:unavailable, {:needs_onboarding, :dead_credential}}

    inputs =
      ctx.inputs
      |> put(:default_harness, :codex)
      |> put(:default_model, Tightbeam.Model.new("gpt-5.6-sol", effort: "medium"))

    {0, report} = Doctor.evaluate(catalog, inputs)
    failed = find(report, "harness_auth:claude")

    assert report.ready
    refute failed.ok
    assert failed.level == :warn
    assert failed.detail =~ "dead_sign_in: harness=claude"
    assert failed.detail =~ "dead_credential"
    assert failed.fix =~ "Re-onboard the claude"
    assert find(report, "base_dir_identity").ok
    assert find(report, "advertised_url").ok
    assert find(report, "hosts_registered").ok
  end

  test "one fully ready harness passes while the unavailable harness warns", ctx do
    probe = fn
      :claude, _cli_bin -> {:ok, %{bin: "/fake/claude", version: "claude 1.0"}}
      :codex, _cli_bin -> {:error, :not_found}
      :cursor, _cli_bin -> {:error, :not_found}
      :pi, _cli_bin -> {:error, :not_found}
      :fixture, _cli_bin -> {:error, :not_found}
    end

    {0, report} =
      Doctor.evaluate(ctx.catalog, put(ctx.inputs, :harness_binary_probe, probe))

    assert report.ready
    assert find(report, "harness_binary:claude").level == :pass
    assert find(report, "harness_binary:codex").level == :warn
    assert find(report, "harness_binary:codex").fix =~ "Install the codex CLI"
    assert Doctor.format(report, :human) =~ "WARN"
  end

  test "zero usable harnesses fails with the non-default harness as WARN", ctx do
    probe = fn _harness, _cli_bin -> {:error, :not_found} end

    {1, report} =
      Doctor.evaluate(ctx.catalog, put(ctx.inputs, :harness_binary_probe, probe))

    refute report.ready
    assert find(report, "harness_binary:claude").level == :fail
    assert find(report, "harness_binary:codex").level == :warn
  end

  test "no credential makes doctor nonzero and prints the readiness remedy", ctx do
    inputs = Keyword.put(ctx.inputs, :credential_state, fn _provider -> :missing end)

    {1, report} = Doctor.evaluate(ctx.catalog, inputs)

    refute report.ready
    auth = find(report, "harness_auth:claude")
    refute auth.ok
    assert auth.detail =~ "Tightbeam has no credential for anthropic on local-test"
    assert auth.detail =~ "normal claude CLI login"
    assert auth.detail =~ Path.join(ctx.base_dir, "auth")
    assert auth.detail =~ "tightbeam onboard anthropic --as-user <userId>"
    assert auth.fix == "tightbeam onboard anthropic --as-user <userId>"
    assert Doctor.format(report, :human) =~ "Tightbeam has no credential"
  end

  # The exit code is the contract a deploy script gates on, so the difference
  # between "this credential is dead" and "this task cannot see credentials"
  # has to be visible THERE, not only in the prose.
  test "an unverifiable credential is informational and does not fail the run", ctx do
    unverifiable = {:unavailable, {:needs_onboarding, :credential_server_unavailable}}

    catalog =
      {:ok, %{"claude" => [], "codex" => []},
       %{"claude" => unverifiable, "codex" => unverifiable}}

    {status, report} = Doctor.evaluate(catalog, ctx.inputs)

    assert status == 0, "a check that could not be performed must not fail the run"
    assert report.ready

    auth = find(report, "harness_auth:claude")
    assert auth.unverifiable
    assert auth.level == :info
    refute auth.ok, "it is still not a PASS — nothing was verified"
    assert auth.detail =~ "UNKNOWN"
    refute auth.detail =~ "dead_sign_in"
    refute auth.fix =~ ~r/^Re-onboard/

    # The same blindness reaches default_model through an empty inventory; calling
    # that "not live" sent the operator to repoint a model that was fine.
    model = find(report, "default_model")
    assert model.unverifiable
    assert model.detail =~ "UNKNOWN"
    refute model.detail =~ "is not live"
  end

  # The precision half: only credential_server_unavailable is unverifiable.
  test "a genuinely dead credential still fails the run", ctx do
    dead = {:unavailable, {:needs_onboarding, :dead_credential}}
    catalog = {:ok, %{"claude" => [], "codex" => []}, %{"claude" => dead, "codex" => dead}}

    {status, report} = Doctor.evaluate(catalog, ctx.inputs)

    assert status == 1, "a dead credential is a real failure and must fail the run"
    refute report.ready

    auth = find(report, "harness_auth:claude")
    refute auth.unverifiable
    assert auth.detail =~ "dead_sign_in"
    assert auth.fix =~ "Re-onboard"
  end

  test "catalog fetch failures are loud and classified for auth and model checks", ctx do
    catalog = {:error, %{"claude" => {:unavailable, :missing_token}}}
    {1, report} = Doctor.evaluate(catalog, ctx.inputs)

    refute report.ready
    assert find(report, "default_model").detail =~ "catalog_unavailable"

    auth = find(report, "harness_auth:claude")
    refute auth.ok
    assert auth.detail =~ "harness=claude"
    assert auth.detail =~ "missing_token"
  end

  test "base dir and populated identity repo each have a fail branch", ctx do
    File.rm_rf!(ctx.base_dir)
    {1, missing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    refute find(missing, "base_dir_identity").ok
    assert find(missing, "base_dir_identity").fix == "Run mix tightbeam.init."

    File.mkdir_p!(Path.join([ctx.base_dir, "identity", ".git"]))
    {1, empty} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    refute find(empty, "base_dir_identity").ok
  end

  test "injected advertised URL passes and absent URL without a fallback fails", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "advertised_url").ok

    for value <- [nil, "  "] do
      {1, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :advertised_url, value))
      check = find(report, "advertised_url")
      refute check.ok
      assert check.fix == "Set TIGHTBEAM_ADVERTISED_URL."
    end
  end

  test "local host resolution has pass and fail branches", ctx do
    {_status, passing} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    assert find(passing, "hosts_registered").ok

    {1, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :hosts, %{}))
    check = find(report, "hosts_registered")
    refute check.ok
    assert check.detail =~ "local-test"
    assert check.fix == "Register a host."
  end

  test "github auth is not checked when the project has no github remote", ctx do
    {0, report} = Doctor.evaluate(ctx.catalog, ctx.inputs)

    refute find(report, "github_auth:github.com")
    assert report.github == nil
  end

  test "github auth passes only when the host probe reports live cli and git auth", ctx do
    inputs =
      ctx.inputs
      |> put(:github_remote_url, "https://github.com/example/project.git")
      |> put(:github_probe, fn "github.com", "https://github.com/example/project.git" ->
        {:ok, %{account: "octo", git_protocol: "https"}}
      end)

    {0, report} = Doctor.evaluate(ctx.catalog, inputs)
    check = find(report, "github_auth:github.com")

    assert check.ok
    assert check.detail =~ "GitHub github.com is live for octo via https"
    assert check.detail =~ "host local-test"
    assert check.detail =~ "gh /fixture/bin/gh"
    assert check.detail =~ "state live"
    assert check.detail =~ "storage file"

    assert report.github == %{
             account: "octo",
             gh_path: "/fixture/bin/gh",
             git_protocol: "https",
             host: "local-test",
             hostname: "github.com",
             repair: nil,
             state: "live",
             storage: "file"
           }

    # Word-boundary match: the report legitimately prints filesystem paths, and
    # a random temp dir name can embed the substring (observed live in CI:
    # `…0PATJgI2…`). The assertion is about the WORD "PAT", not those bytes.
    refute Doctor.format(report, :human) =~ ~r/\bPAT\b/
  end

  test "github auth failure names onboarding repair and never asks for a PAT", ctx do
    inputs =
      ctx.inputs
      |> put(:github_remote_url, "git@github.com:example/project.git")
      |> put(:github_probe, fn "github.com", "git@github.com:example/project.git" ->
        {:error, :needs_onboarding,
         "not logged in github_pat_secret https://user:ghp_secret@github.com/example/project.git"}
      end)

    {1, report} = Doctor.evaluate(ctx.catalog, inputs)
    check = find(report, "github_auth:github.com")

    refute report.ready
    refute check.ok
    assert check.detail =~ "needs_onboarding: not logged in"
    refute check.detail =~ "github_pat_secret"
    refute check.detail =~ "ghp_secret"
    assert check.detail =~ "https://[redacted]@github.com/example/project.git"
    assert check.detail =~ "host local-test"
    assert check.detail =~ "gh /fixture/bin/gh"
    assert check.detail =~ "storage file"
    assert check.fix =~ "tightbeam onboard github --hostname github.com"
    assert check.fix =~ "--remote git@github.com:example/project.git"
    assert check.fix =~ "Do not paste a PAT into an agent."
    assert report.github.state == "needs_onboarding"
    assert report.github.host == "local-test"
    assert report.github.gh_path == "/fixture/bin/gh"
    assert report.github.storage == "file"
    assert report.github.repair =~ "--remote git@github.com:example/project.git"
  end

  test "github missing CLI reports storage as unknown", ctx do
    inputs =
      ctx.inputs
      |> put(:github_remote_url, "https://github.com/example/project.git")
      |> put(:github_gh_path, nil)
      |> put(:github_probe, fn "github.com", "https://github.com/example/project.git" ->
        {:error, :missing_cli, "gh is missing from PATH"}
      end)

    {1, report} = Doctor.evaluate(ctx.catalog, inputs)
    check = find(report, "github_auth:github.com")

    refute check.ok
    assert check.detail =~ "gh missing"
    assert check.detail =~ "storage unknown"
    assert report.github.state == "missing_cli"
    assert report.github.gh_path == nil
    assert report.github.storage == nil
  end

  # RULED: doctor never creates org state. An org that has not booted has no DB,
  # so the registry is unreadable — a fact for the table, not a failed check and
  # never a reason to conjure the DB into existence.
  test "an absent org database is a fact row, not a failure", ctx do
    {status, report} = Doctor.evaluate(ctx.catalog, put(ctx.inputs, :hosts, :absent))
    check = find(report, "hosts_registered")

    assert status == 0
    assert check.unverifiable
    assert check.level == :info
    assert check.detail =~ "org database absent"
  end

  test "org_hosts leaves an absent org database absent", ctx do
    db_path = Path.join(ctx.base_dir, "state.db")
    refute File.exists?(db_path)

    assert Doctor.org_hosts(ctx.base_dir) == :absent

    # The never-creates-state half of the ruling: looking did not create it.
    refute File.exists?(db_path)
  end

  @tag :tmp_dir
  test "org_hosts reads a present hosts table through the read-only open", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "guard_doctor_runtime.exs",
      "guarded-doctor-readonly: ok"
    )
  end

  test "human and JSON formats expose status, detail, fixes, and readiness", ctx do
    {0, report} = Doctor.evaluate(ctx.catalog, ctx.inputs)
    human = Doctor.format(report, :human)

    assert human =~ "check"
    assert human =~ "status"
    assert human =~ "fix-if-failed"
    assert human =~ "default_model"
    assert human =~ "PASS"

    assert {:ok, %{"ready" => true, "checks" => checks}} =
             report |> Doctor.format(:json) |> JSON.decode()

    assert Enum.any?(checks, &(&1["name"] == "advertised_url" and &1["ok"] == true))
    assert Enum.all?(checks, &is_binary(&1["level"]))
  end

  test "terminal keys skip credential probing and share canonical human and JSON bytes", ctx do
    parent = self()

    statement =
      "local-test lost codex: its openai credential was rejected. Redirect destination: not yet observed; lawful alternate routing remains " <>
        "enabled. local-test needs a human sign-in for codex; run on local-test: tightbeam " <>
        "onboard openai --as-user <adminUserId> (replace <adminUserId> with your own " <>
        "administrator id)."

    incident = %{
      incident_id: "tcf_fixture",
      class: "terminal_credential_failure",
      state: "open",
      host: "local-test",
      harness: "codex",
      provider: "openai",
      statement_id: "terminal-credential:tcf_fixture",
      redirect_destinations: [],
      canonical_statement: statement
    }

    catalog =
      {:ok, elem(ctx.catalog, 1) |> Map.put("codex", []),
       %{"codex" => {:unavailable, {:terminal_credential_failure, "tcf_fixture"}}}}

    inputs =
      ctx.inputs
      |> put(:terminal_incidents, [incident])
      |> put(:credential_state, fn provider ->
        send(parent, {:credential_probe, provider})
        :present
      end)

    {0, report} = Doctor.evaluate(catalog, inputs)

    refute_receive {:credential_probe, :openai}, 50
    assert report.terminal_credentials == [incident]
    assert Doctor.format(report, :human) =~ statement

    assert {:ok, %{"terminal_credentials" => [%{"canonical_statement" => ^statement}]}} =
             report |> Doctor.format(:json) |> JSON.decode()

    check = find(report, "harness_auth:codex")
    refute check.ok
    assert check.level == :warn
    assert check.detail =~ "terminal credential incident tcf_fixture"
  end

  test "human and JSON doctor output render the same binary provenance rows", ctx do
    provenance = %{
      "schema_version" => 1,
      "rows" => [
        %{
          "host" => "eezo",
          "harness" => "codex",
          "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"},
          "running" => [
            %{
              "status" => "observed",
              "source" => "bundled_fallback",
              "path" => "/eezo/adapters/codex.js",
              "version" => "codex 0.145.0",
              "generation" => 4,
              "adapter" => %{"package" => "codex-acp", "version" => "1.12.0"}
            }
          ],
          "next_launch" => %{
            "status" => "observed",
            "source" => "pinned_override",
            "path" => "/usr/local/bin/codex",
            "version" => "codex 0.145.1"
          },
          "warnings" => ["bundled_fallback_selected"]
        }
      ]
    }

    {0, report} =
      Doctor.evaluate(ctx.catalog, put(ctx.inputs, :harness_binary_provenance, provenance))

    human = Doctor.format(report, :human)
    assert human =~ "harness adapter eezo/codex next launch: codex-acp 1.12.0"
    assert human =~ "harness adapter eezo/codex running generation 4: codex-acp 1.12.0"
    assert human =~ "harness binary eezo/codex running: observed (bundled_fallback)"
    assert human =~ "/eezo/adapters/codex.js; codex 0.145.0"
    assert human =~ "warning: bundled_fallback_selected"

    assert {:ok, decoded} = report |> Doctor.format(:json) |> JSON.decode()
    assert decoded["harness_binary_provenance"] == provenance
  end

  # AC5, doctor's half: an installed-but-unrunnable harness (on PATH but fails to
  # execute — the gibson codex-as-`.js`-without-node incident) must have its
  # EXECUTABILITY gap named as its own row, distinct from the credential axis —
  # doctor is O5's REFERENCE three-way taxonomy that readiness reflects, so it must
  # not collapse an unrunnable harness into "merely no credential." Regression
  # guard: this behavior already holds and must stay.
  test "an installed-but-unrunnable harness names the executability gap, distinct from credential",
       ctx do
    probe = fn
      :claude, _cli_bin -> {:ok, %{bin: "/fake/claude", version: "claude 1.0"}}
      :codex, _cli_bin -> {:error, {:exec_failed, "node: not found"}}
      :cursor, _cli_bin -> {:ok, %{bin: "/fake/cursor", version: "cursor 1.0"}}
      :pi, _cli_bin -> {:ok, %{bin: "/fake/pi", version: "pi 1.0"}}
      :fixture, _cli_bin -> {:ok, %{bin: "/fake/fixture", version: "fixture 1.0"}}
    end

    inputs =
      ctx.inputs
      |> put(:harness_binary_probe, probe)
      |> put(:credential_state, fn _provider -> :missing end)

    {_status, report} = Doctor.evaluate(ctx.catalog, inputs)

    # The executability gap is named on its OWN row and points at the exec failure.
    binary = find(report, "harness_binary:codex")
    refute binary.ok, "an unrunnable codex CLI must not read as OK"
    assert binary.detail =~ "exec_failed", "the executability gap must name the exec failure"

    # …and it is DISTINCT from the credential axis: the credential row still exists
    # and speaks for itself, so codex's problem is never reported as merely
    # "no credential." A runnable harness's binary row stays a PASS.
    assert find(report, "harness_auth:codex"), "the credential axis is a separate row"
    assert find(report, "harness_binary:claude").ok
  end

  defp put(inputs, key, value), do: Keyword.put(inputs, key, value)

  defp entry(family, efforts) do
    %{
      family: family,
      context: nil,
      display_name: family,
      name: family,
      efforts: efforts,
      max_input_tokens: nil,
      capabilities: %{},
      provider: :anthropic
    }
  end

  defp find(report, name), do: Enum.find(report.checks, &(&1.name == name))

  defp fixture_body(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
  end
end
