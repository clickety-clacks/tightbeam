defmodule Tightbeam.ReleaseCandidateWorkflowTest do
  use Tightbeam.TestCase, async: false

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/release_candidate.sh")
  @verifier Path.join(@root, "scripts/verify_release_candidate_manifest.py")
  @workflow Path.join(@root, ".github/workflows/release-candidate.yml")

  # Evidence fixture provenance: capture opaque package bytes from the repository's real
  # assembler and toolchain bytes from the same commands used by the workflow. The proof
  # verifier owns paths and hashes, not binary platform introspection, so the one native
  # package is copied into both platform slots to exercise its evidence contract. Assembly
  # runs in an isolated Git archive because packaging/assemble.sh cleans its build tree.
  setup_all do
    capture_root =
      Path.join(
        System.tmp_dir!(),
        "release-candidate-real-evidence-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(capture_root)
    on_exit(fn -> File.rm_rf!(capture_root) end)
    archive = Path.join(capture_root, "source.tar")
    assert {_, 0} = command("git", ["archive", "--format=tar", "-o", archive, "HEAD"], cd: @root)
    assert {_, 0} = command("tar", ["xf", archive, "-C", capture_root])
    File.rm!(archive)
    File.ln_s!(Path.join(@root, "deps"), Path.join(capture_root, "deps"))
    File.ln_s!(Path.join(@root, "cli/target"), Path.join(capture_root, "cli/target"))

    {assemble_output, 0} = command("sh", ["packaging/assemble.sh"], cd: capture_root)
    [artifact] = Regex.run(~r/^artifact: (.+)$/m, assemble_output, capture: :all_but_first)
    package = Path.join(capture_root, artifact)
    assert File.regular?(package)

    {:ok,
     real_package: package,
     real_toolchain: toolchain_record!(),
     fixture_provenance: "sh packaging/assemble.sh; elixir --version; rustc --version"}
  end

  test "preparation creates one exact candidate branch and canonical input manifest" do
    fixture = git_fixture!()

    {manifest, 0} =
      command("sh", [@script, "release-candidate/test", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert git!(fixture.repo, ["branch", "--show-current"]) == "release-candidate/test"
    assert git!(fixture.repo, ["rev-parse", "HEAD"]) == fixture.f2
    assert manifest =~ ~s("protected_base_sha":"#{fixture.base}")
    assert manifest =~ ~s("reviewed_feature_shas":["#{fixture.f1}","#{fixture.f2}"])
    assert manifest =~ ~s("source_sha":"#{fixture.f2}")
    assert manifest == String.trim(manifest) <> "\n"
  end

  test "preparation refuses dirty trees before it creates a branch" do
    fixture = git_fixture!()
    File.write!(Path.join(fixture.repo, "untracked"), "dirt")

    {output, status} =
      command("sh", [@script, "release-candidate/dirty", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert status != 0
    assert output =~ "worktree is dirty"
    refute git_ref?(fixture.repo, "refs/heads/release-candidate/dirty")
  end

  test "preparation refuses missing, duplicate, and reordered reviewed SHAs" do
    fixture = git_fixture!()

    cases = [
      [fixture.f2],
      [fixture.f1, fixture.f1, fixture.f2],
      [fixture.f2, fixture.f1]
    ]

    for {features, index} <- Enum.with_index(cases) do
      {output, status} =
        command(
          "sh",
          [@script, "release-candidate/refusal-#{index}", fixture.base | features],
          cd: fixture.repo
        )

      assert status != 0
      assert output =~ ~r/duplicate|missing, reordered, extra, or non-ancestral/
      refute git_ref?(fixture.repo, "refs/heads/release-candidate/refusal-#{index}")
    end
  end

  test "preparation refuses a candidate that is not descended from the protected base" do
    fixture = git_fixture!()
    git!(fixture.repo, ["switch", "--orphan", "unrelated"])
    File.write!(Path.join(fixture.repo, "unrelated"), "unrelated")
    git!(fixture.repo, ["add", "unrelated"])
    git!(fixture.repo, ["commit", "-m", "unrelated"])
    unrelated = git!(fixture.repo, ["rev-parse", "HEAD"])

    {output, status} =
      command("sh", [@script, "release-candidate/unrelated", fixture.base, unrelated],
        cd: fixture.repo
      )

    assert status != 0
    assert output =~ "is not descended from protected base"
  end

  test "preparation refuses a protected base after origin/main advances" do
    fixture = git_fixture!()
    git!(fixture.repo, ["push", "origin", "#{fixture.f1}:refs/heads/main"])
    git!(fixture.repo, ["fetch", "origin", "main"])

    {stale_output, stale_status} =
      command(
        "sh",
        [@script, "release-candidate/stale-base", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert stale_status != 0

    assert stale_output ==
             "release candidate: protected base #{fixture.base} is not the fetched origin/main #{fixture.f1}.\n"

    refute git_ref?(fixture.repo, "refs/heads/release-candidate/stale-base")
    refute git_ref?(fixture.remote, "refs/heads/release-candidate/stale-base")
    assert git!(fixture.repo, ["rev-parse", "HEAD"]) == fixture.f2
  end

  test "preparation refuses local and remote candidate branch reuse" do
    fixture = git_fixture!()
    local_branch = "release-candidate/local-reuse"
    remote_branch = "release-candidate/remote-reuse"
    git!(fixture.repo, ["branch", local_branch, fixture.f1])
    git!(fixture.repo, ["push", "origin", "#{fixture.f1}:refs/heads/#{remote_branch}"])

    {local_output, local_status} =
      command("sh", [@script, local_branch, fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert local_status != 0
    assert local_output == "release candidate: local branch #{local_branch} already exists.\n"
    assert git!(fixture.repo, ["rev-parse", "refs/heads/#{local_branch}"]) == fixture.f1
    refute git_ref?(fixture.remote, "refs/heads/#{local_branch}")
    assert git!(fixture.repo, ["rev-parse", "HEAD"]) == fixture.f2

    {remote_output, remote_status} =
      command("sh", [@script, remote_branch, fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    assert remote_status != 0
    assert remote_output == "release candidate: remote branch #{remote_branch} already exists.\n"
    refute git_ref?(fixture.repo, "refs/heads/#{remote_branch}")
    assert remote_ref!(fixture.remote, remote_branch) == fixture.f1
    assert git!(fixture.repo, ["rev-parse", "HEAD"]) == fixture.f2
  end

  test "workflow has closed triggers, least permission, exact checkout, and both native platforms" do
    workflow = File.read!(@workflow)

    assert workflow =~ ~s(- "release-candidate/**")
    assert workflow =~ "workflow_dispatch:"
    refute workflow =~ "tags:"
    assert workflow =~ "permissions:\n  contents: read"
    assert workflow =~ ~s(ref: ${{ needs.metadata.outputs.candidate_sha }})
    assert workflow =~ "test \"$(git rev-parse HEAD)\" = \"$CANDIDATE_SHA\""
    assert workflow =~ "platform: linux-x86_64"
    assert workflow =~ "platform: darwin-aarch64"
    assert workflow =~ "sh packaging/assemble.sh"
  end

  test "workflow publishes final proof only behind all test and package jobs" do
    workflow = File.read!(@workflow)
    [before_proof, proof_job] = String.split(workflow, "\n  proof:\n", parts: 2)

    assert workflow =~ "package:\n    needs: [metadata, test]"
    assert workflow =~ "proof:\n    needs: [metadata, package]\n    if: ${{ success() }}"
    refute before_proof =~ "release-candidate-proof-"
    assert proof_job =~ "release-candidate-proof-${{ needs.metadata.outputs.candidate_sha }}"

    assert workflow =~
             "No proof artifact exists unless metadata, both test jobs, and both package jobs passed."
  end

  test "packaged launcher turns SIGINT into a real OTP graceful drain", evidence do
    root =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-real-sigint-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {_, 0} = command("tar", ["xzf", evidence.real_package, "-C", root])

    launcher = Path.join(root, "tightbeam/bin/tightbeam-gateway")
    base_dir = Path.join(root, "base")
    pid_file = Path.join(root, "launcher.pid")
    port = unused_port()
    adapter_bin = Path.join(base_dir, "adapters/node_modules/.bin")

    File.mkdir_p!(adapter_bin)

    for adapter <- ["claude-agent-acp", "codex-acp"] do
      path = Path.join(adapter_bin, adapter)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    on_exit(fn ->
      if File.exists?(pid_file) do
        pid = pid_file |> File.read!() |> String.trim()
        command("kill", ["-KILL", pid])
      end
    end)

    task =
      Task.async(fn ->
        command(
          "sh",
          ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec \"$2\"", "sh", pid_file, launcher],
          env: [
            {"TIGHTBEAM_BASE_DIR", base_dir},
            {"TIGHTBEAM_PORT", Integer.to_string(port)},
            {"TIGHTBEAM_DRAIN_TIMEOUT_MS", "2000"},
            {"TIGHTBEAM_LOCAL_HOST_NAME", "gibson"},
            {"TIGHTBEAM_ADVERTISED_URL", nil},
            {"TIGHTBEAM_HOME", nil},
            {"TIGHTBEAM_MACHINE", nil},
            {"RELEASE_BOOT_SCRIPT", nil},
            {"RELEASE_BOOT_SCRIPT_CLEAN", nil},
            {"RELEASE_COMMAND", nil},
            {"RELEASE_COOKIE", nil},
            {"RELEASE_DISTRIBUTION", nil},
            {"RELEASE_MODE", nil},
            {"RELEASE_NAME", nil},
            {"RELEASE_NODE", nil},
            {"RELEASE_PROG", nil},
            {"RELEASE_REMOTE_VM_ARGS", nil},
            {"RELEASE_ROOT", nil},
            {"RELEASE_SYS_CONFIG", nil},
            {"RELEASE_TMP", nil},
            {"RELEASE_VM_ARGS", nil},
            {"RELEASE_VSN", nil}
          ]
        )
      end)

    unless eventually(fn -> gateway_ready?(port) and File.exists?(pid_file) end, 300) do
      {output, status} = Task.await(task, 10_000)
      flunk("packaged gateway did not become ready (#{status}):\n#{output}")
    end

    pid = pid_file |> File.read!() |> String.trim()
    assert {_, 0} = command("kill", ["-INT", pid])
    assert {_, 0} = Task.await(task, 10_000)
    File.rm!(pid_file)

    {:ok, db} = Exqlite.Sqlite3.open(Path.join(base_dir, "state.db"), mode: :readonly)

    try do
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(db, "SELECT cleanShutdownAt FROM boot_epochs")

      assert {:ok, [[clean_shutdown_at]]} = Exqlite.Sqlite3.fetch_all(db, statement)
      assert is_integer(clean_shutdown_at)
      :ok = Exqlite.Sqlite3.release(db, statement)
    after
      :ok = Exqlite.Sqlite3.close(db)
    end
  end

  test "manifest verifier accepts complete exact evidence", evidence do
    fixture = proof_fixture!(evidence)

    assert {"", 0} = create_manifest(fixture)
    assert {"", 0} = verify_manifest(fixture)
    manifest = File.read!(fixture.manifest)
    assert manifest =~ ~s("schema":"tightbeam-release-candidate-proof/v1")
    assert manifest =~ ~s("protected_base_sha":"#{fixture.base}")
    assert manifest =~ ~s("source_sha":"#{fixture.f2}")
    assert manifest =~ ~s("workflow_sha":"#{fixture.workflow_sha}")
    assert manifest =~ ~s("packages":[)
    assert manifest =~ ~s("toolchains":[)
  end

  test "manifest verifier fails closed on wrong source and package hashes", evidence do
    fixture = proof_fixture!(evidence)
    assert {"", 0} = create_manifest(fixture)

    {wrong_source, wrong_status} =
      verify_manifest(fixture, expected_source_sha: String.duplicate("c", 40))

    assert wrong_status != 0
    assert wrong_source =~ "source_sha mismatch"

    File.write!(fixture.package, "changed package")
    {wrong_hash, hash_status} = verify_manifest(fixture)
    assert hash_status != 0
    assert wrong_hash =~ "hash mismatch"
  end

  test "manifest verifier rejects partial and changed toolchain evidence", evidence do
    fixture = proof_fixture!(evidence)
    File.rm!(fixture.darwin_toolchain)

    {partial, partial_status} = create_manifest(fixture)
    assert partial_status != 0
    assert partial =~ "missing darwin-aarch64 toolchain record"

    File.write!(fixture.darwin_toolchain, evidence.real_toolchain)
    assert {"", 0} = create_manifest(fixture)
    File.write!(fixture.darwin_toolchain, "changed")
    {changed, changed_status} = verify_manifest(fixture)
    assert changed_status != 0
    assert changed =~ "hash mismatch"
  end

  test "manifest verifier binds every toolchain path to its declared platform", evidence do
    fixture = proof_fixture!(evidence)
    assert {"", 0} = create_manifest(fixture)

    mutate_manifest!(fixture.manifest, ["toolchains", "0", "path"], "toolchains/linux-x86_64.txt")

    {output, status} = verify_manifest(fixture)
    assert status != 0
    assert output =~ "toolchain path does not match platform darwin-aarch64"
  end

  defp proof_fixture!(real_evidence) do
    fixture = git_fixture!()

    git!(fixture.repo, [
      "remote",
      "set-url",
      "origin",
      "git@github.com:clickety-clacks/tightbeam.git"
    ])

    {candidate_input, 0} =
      command(
        "sh",
        [@script, "--check", "release-candidate/proof", fixture.base, fixture.f1, fixture.f2],
        cd: fixture.repo
      )

    evidence = Path.join(fixture.root, "evidence")
    File.mkdir_p!(Path.join(evidence, "packages/darwin-aarch64"))
    File.mkdir_p!(Path.join(evidence, "packages/linux-x86_64"))
    File.mkdir_p!(Path.join(evidence, "toolchains"))
    input = Path.join(evidence, "candidate-input.json")
    File.write!(input, candidate_input)

    darwin_package =
      Path.join(evidence, "packages/darwin-aarch64/tightbeam-1.0.0-darwin-aarch64.tgz")

    linux_package = Path.join(evidence, "packages/linux-x86_64/tightbeam-1.0.0-linux-x86_64.tgz")
    File.cp!(real_evidence.real_package, darwin_package)
    File.cp!(real_evidence.real_package, linux_package)
    darwin_toolchain = Path.join(evidence, "toolchains/darwin-aarch64.txt")
    linux_toolchain = Path.join(evidence, "toolchains/linux-x86_64.txt")
    File.write!(darwin_toolchain, real_evidence.real_toolchain)
    File.write!(linux_toolchain, real_evidence.real_toolchain)
    File.write!(Path.join(evidence, "fixture-provenance.txt"), real_evidence.fixture_provenance)

    Map.merge(fixture, %{
      candidate_input: input,
      darwin_toolchain: darwin_toolchain,
      evidence: evidence,
      manifest: Path.join(evidence, "release-candidate-manifest.json"),
      package: linux_package,
      workflow_sha: String.duplicate("a", 40)
    })
  end

  defp unused_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp gateway_ready?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp create_manifest(fixture) do
    command("python3", [
      @verifier,
      "create",
      "--candidate-input",
      fixture.candidate_input,
      "--evidence-root",
      fixture.evidence,
      "--workflow-sha",
      fixture.workflow_sha,
      "--run-id",
      "12345",
      "--output",
      fixture.manifest
    ])
  end

  defp verify_manifest(fixture, options \\ []) do
    source = Keyword.get(options, :expected_source_sha, fixture.f2)

    command("python3", [
      @verifier,
      "verify",
      "--manifest",
      fixture.manifest,
      "--evidence-root",
      fixture.evidence,
      "--repository-root",
      fixture.repo,
      "--expected-repository",
      "clickety-clacks/tightbeam",
      "--expected-ref",
      "refs/heads/release-candidate/proof",
      "--expected-source-sha",
      source,
      "--expected-workflow-sha",
      fixture.workflow_sha
    ])
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "release-candidate-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "origin.git")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Release Test"])
    git!(repo, ["config", "user.email", "release@test.invalid"])
    File.write!(Path.join(repo, "content"), "base\n")
    git!(repo, ["add", "content"])
    git!(repo, ["commit", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "-u", "origin", "main"])
    File.write!(Path.join(repo, "content"), "feature one\n", [:append])
    git!(repo, ["commit", "-am", "feature one"])
    f1 = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "content"), "feature two\n", [:append])
    git!(repo, ["commit", "-am", "feature two"])
    f2 = git!(repo, ["rev-parse", "HEAD"])
    %{base: base, f1: f1, f2: f2, remote: remote, repo: repo, root: root}
  end

  defp git!(directory, arguments) do
    {output, status} = command("git", arguments, cd: directory)
    assert status == 0, "git #{Enum.join(arguments, " ")} failed:\n#{output}"
    String.trim(output)
  end

  defp git_ref?(directory, ref) do
    {_output, status} = command("git", ["show-ref", "--verify", "--quiet", ref], cd: directory)
    status == 0
  end

  defp remote_ref!(remote, branch) do
    output = git!(remote, ["rev-parse", "refs/heads/#{branch}"])
    String.trim(output)
  end

  defp command(executable, arguments, options \\ []) do
    command_options =
      Keyword.merge([stderr_to_stdout: true, env: [{"LC_ALL", "C"}]], options)

    System.cmd(executable, arguments, command_options)
  end

  defp toolchain_record! do
    assert {elixir, 0} = command("elixir", ["--version"])
    assert {rust, 0} = command("rustc", ["--version"])
    elixir <> rust
  end

  defp mutate_manifest!(manifest, path, value) do
    script = """
    import json
    import sys

    manifest, *parts, value = sys.argv[1:]
    with open(manifest, encoding="utf-8") as stream:
        data = json.load(stream)
    target = data
    for part in parts[:-1]:
        target = target[int(part)] if isinstance(target, list) else target[part]
    key = parts[-1]
    if isinstance(target, list):
        target[int(key)] = value
    else:
        target[key] = value
    with open(manifest, "w", encoding="utf-8") as stream:
        stream.write(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\\n")
    """

    assert {"", 0} = command("python3", ["-c", script, manifest | path] ++ [value])
  end
end
