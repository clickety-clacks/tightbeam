defmodule Tightbeam.ManualCandidateWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @ci Path.join(@root, ".github/workflows/ci.yml")
  @manual Path.join(@root, ".github/workflows/candidate-package.yml")
  @gate Path.join(@root, ".github/actions/platform-gate/action.yml")
  @setup Path.join(@root, ".github/actions/platform-setup/action.yml")
  @guide Path.join(@root, "docs/MANUAL-CANDIDATE-PACKAGES.md")

  @checkout_pin "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
  @setup_beam_pin "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124"
  @rust_pin "dtolnay/rust-toolchain@4360b52568e2003a75bf9bc1d59f33a8e3fc893c"
  @cache_pin "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830"
  @upload_pin "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
  @download_pin "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"

  @allowed_external_repositories ~w(
    actions/checkout
    erlef/setup-beam
    dtolnay/rust-toolchain
    actions/cache
    actions/upload-artifact
    actions/download-artifact
  )

  @normal_release_sha256 "202cd9db25dadcab504254d54235d411562387cd2531c0d7dcd8a499d29bb82a"
  @normal_publish_release_sha256 "a7d5068ec122f0738d7825311d04dd77eba0471bb6bf317508edd1a11d0633b3"

  @allowed_run_entrypoints [
    "manual:resolve:Validate dispatch authority and input",
    "manual:resolve:Resolve the pushed branch tip and trusted action blobs",
    "manual:platform-test:Refuse GitHub re-run attempts",
    "manual:platform-test:Verify exact detached candidate source",
    "manual:package:Refuse GitHub re-run attempts",
    "manual:package:Verify exact detached candidate source",
    "manual:package:Record package-runner observations",
    "manual:package:Assemble the candidate package",
    "manual:package:Stage package and provenance",
    "manual:aggregate:Refuse GitHub re-run attempts",
    "manual:aggregate:Validate and assemble the candidate bundle",
    "gate:Validate gate inputs",
    "gate:Public rule facts never shrink",
    "gate:Toolchain versions (the parity record)",
    "gate:Put the in-repo harness CLI on PATH (suite prerequisite)",
    "gate:Declare a git identity (suite prerequisite)",
    "gate:cargo build --release (suite prerequisite)",
    "gate:Containment environment (diagnostic)",
    "gate:mix compile",
    "gate:mix format --check-formatted",
    "gate:mix test",
    "gate:cargo fmt --check",
    "gate:cargo test",
    "setup:Validate setup phase and cache selector",
    "setup:mix deps.get"
  ]

  @host_rows [
    ["Clean GitHub-hosted CI", "Build, test, and package both candidate artifacts."],
    [
      "EEZO",
      "Clawline client/simulator only; no Tightbeam build, package install, gateway, provider preflight, smoke, or switch proof."
    ],
    [
      "Shrdlu",
      "Existing in-place installed Linux proof target; no isolation install or local build."
    ],
    [
      "TARS",
      "Packaged macOS target only; no candidate install, gateway, provider preflight, smoke, or switch proof."
    ],
    ["Gibson", "Production-only evidence history; no candidate action."]
  ]

  @global_refusal "Across EEZO, Shrdlu, TARS, and Gibson the handoff creates no alternate root or base,\n" <>
                    "copied home, side gateway, parallel install, local or test-host build, or credential\n" <>
                    "transfer. Existing credentials remain on their existing hosts."

  test "normal CI keeps its public shape and delegates only its gate steps" do
    ci = yaml!(@ci)
    on = workflow_on(ci)

    assert on == %{
             "push" => %{"branches" => ["main"], "tags" => ["v*.*.*"]},
             "pull_request" => :null
           }

    assert ci["permissions"] == %{"contents" => "read"}
    test_job = ci["jobs"]["test"]
    assert test_job["name"] == "${{ matrix.name }}"
    assert test_job["runs-on"] == "${{ matrix.os }}"
    assert test_job["strategy"]["fail-fast"] == false

    assert test_job["strategy"]["matrix"]["include"] == [
             %{"os" => "ubuntu-latest", "name" => "linux"},
             %{"os" => "macos-latest", "name" => "macos"}
           ]

    assert test_job["steps"] == [
             %{"uses" => "actions/checkout@v4", "with" => %{"fetch-depth" => 2}},
             %{
               "name" => "Authoritative platform gate",
               "uses" => "./.github/actions/platform-gate",
               "with" => %{
                 "source_directory" => ".",
                 "platform" => "${{ matrix.name }}",
                 "use_cache" => "true"
               }
             }
           ]

    assert ci["jobs"]["release"]["needs"] == "test"
    assert yaml_fragment_sha256!(@ci, ["jobs", "release"]) == @normal_release_sha256

    assert yaml_fragment_sha256!(@ci, ["jobs", "publish-release"]) ==
             @normal_publish_release_sha256
  end

  test "the canonical actions preserve setup and gate ownership and order" do
    gate = yaml!(@gate)
    setup = yaml!(@setup)

    assert gate["runs"]["using"] == "composite"
    assert setup["runs"]["using"] == "composite"

    assert Enum.map(gate["runs"]["steps"], & &1["name"]) == [
             "Validate gate inputs",
             "Public rule facts never shrink",
             "Install toolchains",
             "Toolchain versions (the parity record)",
             "Put the in-repo harness CLI on PATH (suite prerequisite)",
             "Declare a git identity (suite prerequisite)",
             "Restore cargo registry cache",
             "cargo build --release (suite prerequisite)",
             "Containment environment (diagnostic)",
             "Restore Mix dependencies and fetch them",
             "mix compile",
             "mix format --check-formatted",
             "mix test",
             "cargo fmt --check",
             "cargo test"
           ]

    assert run_step_names(gate) == [
             "Validate gate inputs",
             "Public rule facts never shrink",
             "Toolchain versions (the parity record)",
             "Put the in-repo harness CLI on PATH (suite prerequisite)",
             "Declare a git identity (suite prerequisite)",
             "cargo build --release (suite prerequisite)",
             "Containment environment (diagnostic)",
             "mix compile",
             "mix format --check-formatted",
             "mix test",
             "cargo fmt --check",
             "cargo test"
           ]

    assert run_step_names(setup) == [
             "Validate setup phase and cache selector",
             "mix deps.get"
           ]

    gate_setup_phases =
      gate["runs"]["steps"]
      |> Enum.filter(&(&1["uses"] == "./.github/actions/platform-setup"))
      |> Enum.map(& &1["with"]["phase"])

    assert gate_setup_phases == ["toolchains", "cargo-cache", "mix-dependencies"]
    assert Enum.count(setup["runs"]["steps"], &(&1["uses"] == @setup_beam_pin)) == 1
    assert Enum.count(setup["runs"]["steps"], &(&1["uses"] == @rust_pin)) == 1
    assert Enum.count(setup["runs"]["steps"], &(&1["uses"] == @cache_pin)) == 2

    cache_steps = Enum.filter(setup["runs"]["steps"], &(&1["uses"] == @cache_pin))
    assert Enum.all?(cache_steps, &String.contains?(&1["if"], "inputs.use_cache == 'true'"))

    validation = hd(setup["runs"]["steps"])["run"]
    assert validation =~ "toolchains|cargo-cache|mix-dependencies"
    assert validation =~ "true|false"

    setup_text = File.read!(@setup)
    refute setup_text =~ "source_tree_sha256"
    refute setup_text =~ "requested_sha"
    refute setup_text =~ "reviewed-clean"
  end

  test "the manual graph has the exact hosted topology, authority, and retry guards" do
    manual = yaml!(@manual)
    jobs = manual["jobs"]

    assert manual["name"] == "candidate package"

    assert workflow_on(manual) == %{
             "workflow_dispatch" => %{
               "inputs" => %{
                 "source_sha" => %{
                   "description" =>
                     "Full 40-character lowercase commit SHA at a pushed base-repository branch tip",
                   "required" => true,
                   "type" => "string"
                 }
               }
             }
           }

    assert manual["permissions"] == %{"contents" => "read"}
    refute Map.has_key?(manual, "concurrency")
    assert Map.keys(jobs) |> Enum.sort() == ["aggregate", "package", "platform-test", "resolve"]

    assert run_step_names(jobs["resolve"]) == [
             "Validate dispatch authority and input",
             "Resolve the pushed branch tip and trusted action blobs"
           ]

    assert run_step_names(jobs["platform-test"]) == [
             "Refuse GitHub re-run attempts",
             "Verify exact detached candidate source"
           ]

    assert run_step_names(jobs["package"]) == [
             "Refuse GitHub re-run attempts",
             "Verify exact detached candidate source",
             "Record package-runner observations",
             "Assemble the candidate package",
             "Stage package and provenance"
           ]

    assert run_step_names(jobs["aggregate"]) == [
             "Refuse GitHub re-run attempts",
             "Validate and assemble the candidate bundle"
           ]

    assert jobs["platform-test"]["strategy"]["matrix"]["include"] == [
             %{"os" => "ubuntu-latest", "name" => "linux"},
             %{"os" => "macos-latest", "name" => "macos"}
           ]

    assert jobs["package"]["strategy"]["matrix"]["include"] == [
             %{
               "os" => "ubuntu-latest",
               "platform" => "linux",
               "package_platform" => "linux-x86_64"
             },
             %{
               "os" => "macos-latest",
               "platform" => "macos",
               "package_platform" => "darwin-aarch64"
             }
           ]

    assert jobs["package"]["needs"] == ["resolve", "platform-test"]
    assert jobs["aggregate"]["needs"] == ["resolve", "package"]
    assert jobs["aggregate"]["name"] == "candidate bundle"

    for job_id <- ["resolve", "platform-test", "package", "aggregate"] do
      steps = jobs[job_id]["steps"]
      first_run = hd(steps)["run"]
      assert first_run =~ "GITHUB_RUN_ATTEMPT"
      assert first_run =~ "fresh dispatch"
      refute Map.has_key?(jobs[job_id], "permissions")
      refute Map.has_key?(jobs[job_id], "environment")
    end

    manual_text = File.read!(@manual)
    refute manual_text =~ "secrets."
    refute manual_text =~ "id-token"
    refute manual_text =~ "self-hosted"
    refute manual_text =~ "docker://"
    refute manual_text =~ "softprops/action-gh-release"
    refute manual_text =~ "npm publish"
    refute manual_text =~ "npm install -g"

    checkout_steps = Enum.filter(walk(manual), &(&1 == @checkout_pin))
    assert length(checkout_steps) == 5

    manual["jobs"]
    |> walk_maps()
    |> Enum.filter(&(&1["uses"] == @checkout_pin))
    |> Enum.each(fn step -> assert step["with"]["persist-credentials"] == false end)

    package_phases =
      jobs["package"]["steps"]
      |> Enum.filter(&(&1["uses"] == "./.github/actions/platform-setup"))
      |> Enum.map(& &1["with"]["phase"])

    assert package_phases == ["toolchains", "mix-dependencies"]

    assert Enum.all?(
             Enum.filter(
               jobs["package"]["steps"],
               &(&1["uses"] == "./.github/actions/platform-setup")
             ),
             &(&1["with"]["use_cache"] == "false")
           )

    assert Enum.count(
             jobs["platform-test"]["steps"],
             &(&1["uses"] == "./.github/actions/platform-gate")
           ) == 1

    assert Enum.find(
             jobs["platform-test"]["steps"],
             &(&1["uses"] == "./.github/actions/platform-gate")
           )[
             "with"
           ]["use_cache"] == "false"
  end

  test "every external action reachable from the manual graph has a reviewed full commit pin" do
    documents = [yaml!(@manual), yaml!(@gate), yaml!(@setup)]

    uses =
      documents
      |> Enum.flat_map(&walk_maps/1)
      |> Enum.map(& &1["uses"])
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&String.contains?(&1, "@"))

    assert MapSet.new(uses) ==
             MapSet.new([
               @checkout_pin,
               @setup_beam_pin,
               @rust_pin,
               @cache_pin,
               @upload_pin,
               @download_pin
             ])

    for use <- uses do
      [repository, sha] = String.split(use, "@", parts: 2)
      assert repository in @allowed_external_repositories
      assert sha =~ ~r/^[0-9a-f]{40}$/
    end

    local_uses =
      documents
      |> Enum.flat_map(&walk/1)
      |> Enum.filter(
        &(&1 in ["./.github/actions/platform-gate", "./.github/actions/platform-setup"])
      )

    assert MapSet.new(local_uses) ==
             MapSet.new(["./.github/actions/platform-gate", "./.github/actions/platform-setup"])
  end

  test "every run entry point is allowlisted and command construction is impossible" do
    manual = yaml!(@manual)
    gate = yaml!(@gate)
    setup = yaml!(@setup)

    actual =
      run_entrypoints(manual, "manual") ++
        run_entrypoints(gate, "gate") ++ run_entrypoints(setup, "setup")

    assert MapSet.new(actual) == MapSet.new(@allowed_run_entrypoints)
    assert length(actual) == length(@allowed_run_entrypoints)

    for run <- run_bodies([manual, gate, setup]) do
      assert static_run_body?(run),
             "run body constructs or dispatches a command dynamically:\n#{run}"
    end

    for fixture <- [
          ~S|cmd="git rev-parse "; cmd+="$CANDIDATE_SHA"; $cmd|,
          "runner=git\n$runner rev-parse \"$CANDIDATE_SHA\"",
          "command='git rev-parse'\n$command \"$CANDIDATE_SHA\"",
          "args=(git rev-parse \"$CANDIDATE_SHA\")\n\"${args[@]}\""
        ] do
      refute static_run_body?(fixture), "constructed command fixture passed:\n#{fixture}"
    end
  end

  test "raw dispatch input has one data-only transport and validated SHA use stays quoted" do
    manual = yaml!(@manual)
    resolve = manual["jobs"]["resolve"]
    validate = hd(resolve["steps"])

    assert validate["env"]["REQUESTED_SOURCE_SHA"] == "${{ inputs.source_sha }}"
    assert validate["id"] == "validate"

    assert resolve["outputs"]["validated_source_sha"] ==
             "${{ steps.validate.outputs.validated_source_sha }}"

    assert File.read!(@manual)
           |> occurrences("${{ inputs.source_sha }}") == 1

    run_bodies =
      manual
      |> walk_maps()
      |> Enum.map(& &1["run"])
      |> Enum.filter(&is_binary/1)

    for run <- run_bodies do
      refute run =~ "${{ inputs.source_sha }}"
      refute run =~ ~r/(^|\s)eval(\s|$)/m
      refute run =~ ~r/(^|\s)(sh|bash)\s+-c(\s|$)/m

      run
      |> String.replace("\"$CANDIDATE_SHA\"", "")
      |> refute_candidate_sha_expansion()
    end
  end

  test "the real validation script refuses mutable and shell-shaped input before output" do
    manual = yaml!(@manual)
    script = manual["jobs"]["resolve"]["steps"] |> hd() |> Map.fetch!("run")

    invalid = [
      "coder/live-session-tune-cli",
      "v0.1.7",
      "20d1d690",
      "https://github.com/clickety-clacks/tightbeam/commit/20d1d690",
      String.upcase("20d1d6903129d7f26f16d528ddd07037098f1edb"),
      "20d1d6903129d7f26f16d528ddd07037098f1edba",
      "dead beef",
      "-deadbeef",
      "refs/heads/main",
      ~S|$(touch "$PWD/input-injected")|,
      ~S|deadbeef; touch "$PWD/input-injected"|,
      ~S|`touch "$PWD/input-injected"`|,
      ~S|deadbeef"|,
      "deadbeef\ntouch \"$PWD/input-injected\"",
      "20d1d6903129d7f26f16d528ddd07037098f1edb;touch-suffix"
    ]

    for value <- invalid do
      root = tmp_dir!("candidate-validation")
      output = Path.join(root, "github-output")
      sentinel = Path.join(root, "input-injected")

      {message, status} =
        System.cmd("bash", ["-c", script],
          cd: root,
          stderr_to_stdout: true,
          env: validation_env(value, output)
        )

      assert status != 0, "input unexpectedly passed: #{inspect(value)}\n#{message}"
      refute File.exists?(sentinel), "input executed shell text: #{inspect(value)}"
      refute File.exists?(output), "invalid input wrote a requested-SHA output: #{inspect(value)}"
      File.rm_rf!(root)
    end

    root = tmp_dir!("candidate-validation-good")
    output = Path.join(root, "github-output")
    sha = "20d1d6903129d7f26f16d528ddd07037098f1edb"

    {message, 0} =
      System.cmd("bash", ["-c", script],
        cd: root,
        stderr_to_stdout: true,
        env: validation_env(sha, output)
      )

    assert message == ""
    assert File.read!(output) == "validated_source_sha=#{sha}\n"
    File.rm_rf!(root)
  end

  test "the real resolver selects the bytewise-first full branch independently of order" do
    manual = yaml!(@manual)

    script =
      manual["jobs"]["resolve"]["steps"]
      |> Enum.find(&(&1["id"] == "resolve"))
      |> Map.fetch!("run")

    sha = "20d1d6903129d7f26f16d528ddd07037098f1edb"
    workflow_sha = String.duplicate("1", 40)

    for {order, locale} <- [{"a-first", "C"}, {"z-first", "POSIX"}] do
      root = tmp_dir!("candidate-resolver")
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      fake_git = Path.join(bin, "git")
      File.write!(fake_git, fake_git_script())
      File.chmod!(fake_git, 0o755)
      output = Path.join(root, "github-output")

      env = [
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
        {"FIXTURE_ORDER", order},
        {"LC_ALL", locale},
        {"CANDIDATE_SHA", sha},
        {"TRUSTED_WORKFLOW_SHA", workflow_sha},
        {"GITHUB_REPOSITORY", "clickety-clacks/tightbeam"},
        {"GITHUB_OUTPUT", output}
      ]

      {message, status} =
        System.cmd("bash", ["-c", script], cd: root, stderr_to_stdout: true, env: env)

      assert status == 0, message
      outputs = parse_outputs(File.read!(output))
      assert outputs["requested_sha"] == sha
      assert outputs["resolved_sha"] == sha
      assert outputs["qualifying_pushed_ref"] == "refs/heads/Z-tip"
      assert outputs["trusted_workflow_sha"] == workflow_sha
      assert outputs["trusted_gate_blob"] == String.pad_leading("2", 40, "0")
      assert outputs["trusted_setup_blob"] == String.pad_leading("3", 40, "0")
      assert outputs["source_tree_sha256"] =~ ~r/^[0-9a-f]{64}$/
      File.rm_rf!(root)
    end
  end

  test "exact-source guards precede candidate execution in test and package jobs" do
    manual = yaml!(@manual)

    for job_id <- ["platform-test", "package"] do
      steps = manual["jobs"][job_id]["steps"]
      names = Enum.map(steps, & &1["name"])
      guard_index = Enum.find_index(names, &(&1 == "Refuse GitHub re-run attempts"))
      trusted_index = Enum.find_index(names, &(&1 == "Check out the trusted workflow revision"))
      candidate_index = Enum.find_index(names, &(&1 == "Check out the exact candidate source"))
      verify_index = Enum.find_index(names, &(&1 == "Verify exact detached candidate source"))

      assert guard_index < trusted_index
      assert trusted_index < candidate_index
      assert candidate_index < verify_index

      verify = Enum.at(steps, verify_index)["run"]
      assert verify =~ "git rev-parse HEAD"
      assert verify =~ "git symbolic-ref -q HEAD"
      assert verify =~ "git status --porcelain"
      assert verify =~ "git ls-tree -r -z --full-tree \"$CANDIDATE_SHA\""
    end
  end

  test "aggregation checks every authority, observation, digest, and exact final set" do
    manual = yaml!(@manual)
    aggregate = manual["jobs"]["aggregate"]

    validate =
      Enum.find(aggregate["steps"], &(&1["name"] == "Validate and assemble the candidate bundle"))

    script = validate["run"]

    for field <- [
          "repository",
          "requested_sha",
          "resolved_sha",
          "qualifying_pushed_ref",
          "source_tree_sha256",
          "trusted_workflow_sha",
          "trusted_gate_blob",
          "trusted_setup_blob",
          "workflow.name",
          "workflow.ref",
          "workflow.sha",
          "run.id",
          "run.number",
          "run.attempt",
          "run.url",
          "run.actor",
          "run.triggering_actor",
          "package.filename",
          "package.platform",
          "package.bytes",
          "package.sha256",
          "observed_by_package_job"
        ] do
      assert script =~ field
    end

    assert script =~ "final bundle must contain exactly four files"
    assert script =~ "SHA256SUMS"
    assert script =~ "candidate-provenance.json"

    upload = Enum.find(aggregate["steps"], &(&1["name"] == "Upload candidate bundle"))
    assert upload["uses"] == @upload_pin
    assert upload["with"]["retention-days"] == 90
    assert upload["with"]["if-no-files-found"] == "error"
    assert upload["with"]["overwrite"] == false
    assert upload["with"]["name"] =~ "tightbeam-candidate-"
  end

  test "the real aggregator refuses every final-set and provenance mismatch" do
    script = aggregation_script!()

    {root, fixture, message, status} = run_aggregation_fixture(script, fn _fixture -> :ok end)
    assert status == 0, message

    assert File.ls!(Path.join(root, "candidate-bundle")) |> Enum.sort() ==
             [
               "SHA256SUMS",
               "candidate-provenance.json",
               fixture.filenames["darwin-aarch64"],
               fixture.filenames["linux-x86_64"]
             ]
             |> Enum.sort()

    File.rm_rf!(root)

    final_set_fixtures = [
      {"missing platform output", fn fixture -> File.rm!(fixture.packages["darwin-aarch64"]) end},
      {"wrong package filename",
       fn fixture ->
         path = fixture.packages["linux-x86_64"]
         File.rename!(path, Path.join(Path.dirname(path), "wrong-name.tgz"))
       end},
      {"extra package",
       fn fixture ->
         File.write!(
           Path.join(Path.dirname(fixture.packages["linux-x86_64"]), "extra.tgz"),
           "extra"
         )
       end},
      {"package digest mismatch",
       fn fixture ->
         path = fixture.packages["linux-x86_64"]
         <<_first, rest::binary>> = File.read!(path)
         File.write!(path, "X" <> rest)
       end},
      {"package byte-size mismatch",
       fn fixture ->
         platform = "linux-x86_64"
         path = fixture.packages[platform]
         File.write!(path, File.read!(path) <> "X")

         mutate_fragment!(fixture.fragments[platform], ["package", "sha256"], file_sha256(path))
       end}
    ]

    for {label, mutate} <- final_set_fixtures do
      assert_aggregation_refuses(script, label, mutate)
    end

    resolver_mismatches = [
      {["repository"], "wrong/repository"},
      {["requested_sha"], String.duplicate("a", 40)},
      {["resolved_sha"], String.duplicate("b", 40)},
      {["qualifying_pushed_ref"], "refs/heads/wrong"},
      {["source_tree_sha256"], String.duplicate("c", 64)},
      {["trusted_workflow_sha"], String.duplicate("d", 40)},
      {["trusted_gate_blob"], String.duplicate("e", 40)},
      {["trusted_setup_blob"], String.duplicate("f", 40)}
    ]

    for {path, wrong} <- resolver_mismatches do
      assert_aggregation_refuses(script, Enum.join(path, "."), fn fixture ->
        Enum.each(fixture.fragments, fn {_platform, fragment} ->
          mutate_fragment!(fragment, path, wrong)
        end)
      end)
    end

    context_mismatches = [
      {["workflow", "name"], "wrong workflow"},
      {["workflow", "ref"], "wrong workflow ref"},
      {["workflow", "sha"], String.duplicate("a", 40)},
      {["run", "id"], "999"},
      {["run", "number"], "999"},
      {["run", "attempt"], "2"},
      {["run", "url"], "https://github.com/wrong/run"},
      {["run", "actor"], "wrong-actor"},
      {["run", "triggering_actor"], "wrong-triggering-actor"}
    ]

    for {path, wrong} <- context_mismatches do
      assert_aggregation_refuses(script, Enum.join(path, "."), fn fixture ->
        Enum.each(fixture.fragments, fn {_platform, fragment} ->
          mutate_fragment!(fragment, path, wrong)
        end)
      end)
    end

    package_mismatches = [
      {["package", "filename"], "wrong.tgz"},
      {["package", "platform"], "wrong-platform"},
      {["package", "bytes"], 999_999},
      {["package", "sha256"], String.duplicate("0", 64)}
    ]

    for {path, wrong} <- package_mismatches do
      assert_aggregation_refuses(script, Enum.join(path, "."), fn fixture ->
        mutate_fragment!(fixture.fragments["linux-x86_64"], path, wrong)
      end)
    end
  end

  test "the guide fixes every host role and refuses each prohibited boundary mutation" do
    guide = File.read!(@guide)
    assert host_rows(guide) == @host_rows
    assert guide =~ @global_refusal
    assert guide =~ "candidate bundle` aggregation\njob to have the final conclusion `success`"
    assert guide =~ "expires after 90 days"
    assert guide =~ "shasum -a 256 -c SHA256SUMS"
    assert guide =~ "observed_by_package_job"
    assert guide =~ "fresh dispatch"
    assert guide =~ "actual installed Shrdlu instance"

    role_action_additions = [
      {"EEZO build", "EEZO may perform a Tightbeam build."},
      {"EEZO package install", "EEZO may perform a candidate package install."},
      {"EEZO gateway", "EEZO may start a Tightbeam gateway."},
      {"EEZO provider preflight", "EEZO may run a provider preflight."},
      {"EEZO smoke", "EEZO may run candidate smoke proof."},
      {"EEZO switch proof", "EEZO may run candidate switch proof."},
      {"TARS install", "TARS may perform a candidate install."},
      {"TARS gateway", "TARS may start a candidate gateway."},
      {"TARS provider preflight", "TARS may run a provider preflight."},
      {"TARS smoke", "TARS may run candidate smoke proof."},
      {"TARS switch proof", "TARS may run candidate switch proof."},
      {"Gibson checkout", "Gibson may check out the candidate."},
      {"Gibson build", "Gibson may build the candidate."},
      {"Gibson test", "Gibson may test the candidate."},
      {"Gibson package", "Gibson may package the candidate."},
      {"Gibson download", "Gibson may download the candidate."},
      {"Gibson install", "Gibson may install the candidate."},
      {"Gibson restart", "Gibson may restart for the candidate."},
      {"Gibson proof", "Gibson may run candidate proof."}
    ]

    for {label, addition} <- role_action_additions do
      mutated = guide <> "\n" <> addition
      refute host_boundary_valid?(mutated), "fixture did not violate #{label}"
    end

    mutated = String.replace(guide, "no isolation install or local build", "isolation install")
    refute host_boundary_valid?(mutated), "fixture did not violate Shrdlu isolation"

    for host <- ["EEZO", "Shrdlu", "TARS", "Gibson"] do
      changed_refusal = String.replace(@global_refusal, host, "", global: false)
      mutated = String.replace(guide, @global_refusal, changed_refusal, global: false)
      refute host_boundary_valid?(mutated), "global refusal accepted missing #{host}"
    end

    additions = [
      "Shrdlu may use /tmp/tightbeam-candidate as its global npm prefix.",
      "Shrdlu may use /tmp/tightbeam-candidate as its base.",
      "EEZO may use a copied Tightbeam home.",
      "TARS may start a side Tightbeam gateway.",
      "Shrdlu may keep a parallel Tightbeam install.",
      "scp ~/.tightbeam/credentials shrdlu:~/.tightbeam/credentials"
    ]

    for addition <- additions do
      refute host_boundary_valid?(guide <> "\n" <> addition),
             "host boundary accepted prohibited addition: #{addition}"
    end

    for host <- ["EEZO", "Shrdlu", "TARS", "Gibson"], kind <- ["local", "test-host"] do
      addition = "#{host} may perform a #{kind} build."

      refute host_boundary_valid?(guide <> "\n" <> addition),
             "host boundary accepted #{kind} build on #{host}"
    end
  end

  defp yaml!(path) do
    script = ~S"""
    require "yaml"
    require "json"
    value = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    STDOUT.write(JSON.generate(value))
    """

    {json, 0} = System.cmd("ruby", ["-e", script, path], stderr_to_stdout: true)
    :json.decode(json)
  end

  defp yaml_fragment_sha256!(path, keys) do
    script = ~S"""
    require "yaml"
    require "json"
    value = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    ARGV.drop(1).each { |key| value = value.fetch(key) }
    STDOUT.write(JSON.generate(value))
    """

    {json, 0} = System.cmd("ruby", ["-e", script, path | keys], stderr_to_stdout: true)
    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end

  defp workflow_on(document), do: document["on"] || document["true"]

  defp run_step_names(job_or_action) do
    steps = job_or_action["steps"] || job_or_action["runs"]["steps"]

    steps
    |> Enum.filter(&is_binary(&1["run"]))
    |> Enum.map(& &1["name"])
  end

  defp run_entrypoints(%{"jobs" => jobs}, label) do
    for {job_id, job} <- jobs,
        step <- job["steps"],
        is_binary(step["run"]),
        do: "#{label}:#{job_id}:#{step["name"]}"
  end

  defp run_entrypoints(%{"runs" => %{"steps" => steps}}, label) do
    for step <- steps, is_binary(step["run"]), do: "#{label}:#{step["name"]}"
  end

  defp run_bodies(documents) do
    documents
    |> Enum.flat_map(&walk_maps/1)
    |> Enum.map(& &1["run"])
    |> Enum.filter(&is_binary/1)
  end

  defp static_run_body?(run) do
    forbidden = [
      ~r/(^|\s)eval(\s|$)/m,
      ~r/(^|\s)(sh|bash)\s+-c(\s|$)/m,
      ~r/(?im)^\s*(?:(?:local|readonly)\s+|declare(?:\s+-[a-z]+)?\s+)?[a-z_][a-z0-9_]*(?:cmd|command)[a-z0-9_]*\s*\+?=/,
      ~r/\+=/,
      ~r/(?m)^\s*\$[A-Za-z_][A-Za-z0-9_]*(?:\s|$)/,
      ~r/(?m)^\s*\$\{[A-Za-z_][A-Za-z0-9_]*\}(?:\s|$)/,
      ~r/(?m)^\s*"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"(?:\s|$)/
    ]

    Enum.all?(forbidden, &(not Regex.match?(&1, run)))
  end

  defp walk(value) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> [key | walk(item)] end)

  defp walk(value) when is_list(value), do: Enum.flat_map(value, &walk/1)
  defp walk(value), do: [value]

  defp walk_maps(value) when is_map(value) do
    [value | Enum.flat_map(Map.values(value), &walk_maps/1)]
  end

  defp walk_maps(value) when is_list(value), do: Enum.flat_map(value, &walk_maps/1)
  defp walk_maps(_value), do: []

  defp occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp refute_candidate_sha_expansion(run) do
    refute run =~ "CANDIDATE_SHA"
  end

  defp validation_env(value, output) do
    [
      {"REQUESTED_SOURCE_SHA", value},
      {"REQUIRED_DEFAULT_REF", "refs/heads/main"},
      {"GITHUB_RUN_ATTEMPT", "1"},
      {"GITHUB_REPOSITORY", "clickety-clacks/tightbeam"},
      {"GITHUB_REF", "refs/heads/main"},
      {"GITHUB_OUTPUT", output}
    ]
  end

  defp fake_git_script do
    ~S"""
    #!/bin/sh
    set -eu
    case "$1" in
      for-each-ref)
        if [ "$FIXTURE_ORDER" = "a-first" ]; then
          printf '%s %s\n' "$CANDIDATE_SHA" refs/remotes/origin/a-tip
          printf '%s %s\n' "$CANDIDATE_SHA" refs/remotes/origin/Z-tip
        else
          printf '%s %s\n' "$CANDIDATE_SHA" refs/remotes/origin/Z-tip
          printf '%s %s\n' "$CANDIDATE_SHA" refs/remotes/origin/a-tip
        fi
        ;;
      symbolic-ref)
        exit 1
        ;;
      ls-tree)
        printf '100644 blob 1111111111111111111111111111111111111111\tfixture\0'
        ;;
      rev-parse)
        case "$2" in
          HEAD) printf '%s\n' "$TRUSTED_WORKFLOW_SHA" ;;
          *platform-gate/action.yml) printf '%040d\n' 2 ;;
          *platform-setup/action.yml) printf '%040d\n' 3 ;;
          refs/remotes/origin/*) printf '%s\n' "$CANDIDATE_SHA" ;;
          *) echo "unexpected rev-parse operand: $2" >&2; exit 2 ;;
        esac
        ;;
      *)
        echo "unexpected git command: $*" >&2
        exit 2
        ;;
    esac
    """
  end

  defp parse_outputs(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end)
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp aggregation_script! do
    yaml!(@manual)["jobs"]["aggregate"]["steps"]
    |> Enum.find(&(&1["name"] == "Validate and assemble the candidate bundle"))
    |> Map.fetch!("run")
  end

  defp run_aggregation_fixture(script, mutate) do
    root = tmp_dir!("candidate-aggregation")
    fixture = write_aggregation_fixture!(root)
    mutate.(fixture)

    {message, status} =
      System.cmd("bash", ["-c", script],
        cd: root,
        stderr_to_stdout: true,
        env: aggregation_env()
      )

    {root, fixture, message, status}
  end

  defp assert_aggregation_refuses(script, label, mutate) do
    {root, _fixture, message, status} = run_aggregation_fixture(script, mutate)

    assert status != 0, "aggregation accepted #{label}:\n#{message}"
    File.rm_rf!(root)
  end

  defp write_aggregation_fixture!(root) do
    candidate_sha = aggregation_candidate_sha()
    short_sha = String.slice(candidate_sha, 0, 7)

    records =
      for platform <- ["darwin-aarch64", "linux-x86_64"], into: %{} do
        directory = Path.join([root, "aggregate-input", platform])
        File.mkdir_p!(directory)
        filename = "tightbeam-0.1.7-#{platform}-#{short_sha}.tgz"
        package = Path.join(directory, filename)
        bytes = "fixture package bytes for #{platform}\n"
        File.write!(package, bytes)
        fragment = Path.join(directory, "candidate-provenance-#{platform}.json")
        File.write!(fragment, encode_json(aggregation_fragment(platform, filename, bytes)))
        {platform, %{package: package, fragment: fragment, filename: filename}}
      end

    %{
      packages: Map.new(records, fn {platform, record} -> {platform, record.package} end),
      fragments: Map.new(records, fn {platform, record} -> {platform, record.fragment} end),
      filenames: Map.new(records, fn {platform, record} -> {platform, record.filename} end)
    }
  end

  defp aggregation_fragment(platform, filename, bytes) do
    env = Map.new(aggregation_env())

    %{
      "repository" => env["EXPECTED_REPOSITORY"],
      "requested_sha" => env["REQUESTED_SHA"],
      "resolved_sha" => env["RESOLVED_SHA"],
      "qualifying_pushed_ref" => env["QUALIFYING_PUSHED_REF"],
      "source_tree_sha256" => env["SOURCE_TREE_SHA256"],
      "trusted_workflow_sha" => env["TRUSTED_WORKFLOW_SHA"],
      "trusted_gate_blob" => env["TRUSTED_GATE_BLOB"],
      "trusted_setup_blob" => env["TRUSTED_SETUP_BLOB"],
      "workflow" => %{
        "name" => env["GITHUB_WORKFLOW"],
        "ref" => env["GITHUB_WORKFLOW_REF"],
        "sha" => env["GITHUB_WORKFLOW_SHA"]
      },
      "run" => %{
        "id" => env["GITHUB_RUN_ID"],
        "number" => env["GITHUB_RUN_NUMBER"],
        "attempt" => env["GITHUB_RUN_ATTEMPT"],
        "url" =>
          "#{env["GITHUB_SERVER_URL"]}/#{env["GITHUB_REPOSITORY"]}/actions/runs/#{env["GITHUB_RUN_ID"]}",
        "actor" => env["GITHUB_ACTOR"],
        "triggering_actor" => env["GITHUB_TRIGGERING_ACTOR"]
      },
      "package" => %{
        "filename" => filename,
        "platform" => platform,
        "bytes" => byte_size(bytes),
        "sha256" => sha256(bytes)
      },
      "observed_by_package_job" => %{
        "runner_os" => if(platform == "linux-x86_64", do: "Linux", else: "macOS"),
        "runner_arch" => if(platform == "linux-x86_64", do: "X64", else: "ARM64"),
        "image_os" => nil,
        "image_version" => nil,
        "toolchains" => %{
          "elixir" => "1.19.5",
          "erlang_otp" => "28",
          "rust" => "rustc fixture",
          "cargo" => "cargo fixture",
          "node" => "v24.0.0",
          "npm" => "11.0.0"
        }
      }
    }
  end

  defp aggregation_env do
    candidate_sha = aggregation_candidate_sha()

    [
      {"CANDIDATE_SHA", candidate_sha},
      {"EXPECTED_REPOSITORY", "clickety-clacks/tightbeam"},
      {"REQUESTED_SHA", candidate_sha},
      {"RESOLVED_SHA", candidate_sha},
      {"QUALIFYING_PUSHED_REF", "refs/heads/candidate"},
      {"SOURCE_TREE_SHA256", String.duplicate("2", 64)},
      {"TRUSTED_WORKFLOW_SHA", String.duplicate("1", 40)},
      {"TRUSTED_GATE_BLOB", String.duplicate("3", 40)},
      {"TRUSTED_SETUP_BLOB", String.duplicate("4", 40)},
      {"GITHUB_SERVER_URL", "https://github.com"},
      {"GITHUB_REPOSITORY", "clickety-clacks/tightbeam"},
      {"GITHUB_WORKFLOW", "candidate package"},
      {"GITHUB_WORKFLOW_REF",
       "clickety-clacks/tightbeam/.github/workflows/candidate-package.yml@refs/heads/main"},
      {"GITHUB_WORKFLOW_SHA", String.duplicate("1", 40)},
      {"GITHUB_RUN_ID", "12345"},
      {"GITHUB_RUN_NUMBER", "67"},
      {"GITHUB_RUN_ATTEMPT", "1"},
      {"GITHUB_ACTOR", "fixture-actor"},
      {"GITHUB_TRIGGERING_ACTOR", "fixture-triggering-actor"}
    ]
  end

  defp aggregation_candidate_sha,
    do: "20d1d6903129d7f26f16d528ddd07037098f1edb"

  defp mutate_fragment!(path, keys, value) do
    updated =
      path
      |> File.read!()
      |> :json.decode()
      |> put_in(Enum.map(keys, &Access.key!(&1)), value)

    File.write!(path, encode_json(updated))
  end

  defp encode_json(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp file_sha256(path), do: path |> File.read!() |> sha256()

  defp host_rows(guide) do
    guide
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.take(5)
    |> Enum.map(fn row ->
      row
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)
    end)
  end

  defp host_boundary_valid?(guide) do
    forbidden = [
      "/tmp/tightbeam-candidate",
      "copied Tightbeam home",
      "may start a side Tightbeam gateway",
      "may keep a parallel Tightbeam install",
      "scp ~/.tightbeam/credentials",
      "may perform a local build",
      "may perform a test-host build"
    ]

    forbidden_permissions = [
      {"EEZO", "build"},
      {"EEZO", "install"},
      {"EEZO", "gateway"},
      {"EEZO", "provider preflight"},
      {"EEZO", "smoke"},
      {"EEZO", "switch proof"},
      {"TARS", "install"},
      {"TARS", "gateway"},
      {"TARS", "provider preflight"},
      {"TARS", "smoke"},
      {"TARS", "switch proof"},
      {"Gibson", "check out"},
      {"Gibson", "build"},
      {"Gibson", "test"},
      {"Gibson", "package"},
      {"Gibson", "download"},
      {"Gibson", "install"},
      {"Gibson", "restart"},
      {"Gibson", "proof"}
    ]

    host_rows(guide) == @host_rows and guide =~ @global_refusal and
      Enum.all?(forbidden, &(not String.contains?(guide, &1))) and
      Enum.all?(forbidden_permissions, fn {host, action} ->
        pattern = ~r/\b#{Regex.escape(host)}\b[^.\n]*\bmay\b[^.\n]*#{Regex.escape(action)}/i
        not Regex.match?(pattern, guide)
      end)
  end
end
