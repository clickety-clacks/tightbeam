import ExUnit.Assertions
alias Tightbeam.{Archetypes, DB, Devices, Identity}

[payload, base, phase, binary] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
true = Path.expand(base) == Path.expand(System.fetch_env!("TIGHTBEAM_BASE_DIR"))
root = Path.dirname(base)
source = Path.join(root, "synthetic-bundle")
dir = Path.join(base, "identity")

# Synthetic local/upstream divergence only; no copied organization or provider.
Application.put_env(:tightbeam, :identity_source_dir, source)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)

git = fn args ->
  {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  String.trim_trailing(output)
end

manifest = fn where ->
  """
  name = "coder"
  skills = []
  where = ["#{where}"]
  [guidance]
  text = '#include "coder.md"'
  """
end

if phase == "conflict" do
  false = File.exists?(base)
  File.mkdir_p!(Path.join(source, "archetypes"))
  File.mkdir_p!(Path.join(source, "guidance"))
  File.write!(Path.join(source, "archetypes/coder.toml"), manifest.("original"))
  File.write!(Path.join(source, "guidance/coder.md"), "original guidance\n")

  for file <-
        ~w(manifest.toml capabilities.md intake.md preferred-models.md setup.md sentinels/landing-watch) do
    dest = Path.join(source, file)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(Application.app_dir(:tightbeam, "priv/kungfu/agentic-engineering/#{file}"), dest)
  end

  {:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])
  :ignore = Tightbeam.Boot.start_link(%{base_dir: base})
  Devices.add_user(db, "recovery-admin", true)
  Devices.add_user(db, "recovery-reader", false)
  :ok = GenServer.stop(db)
  File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
  Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
end

# Existing synthetic adapter fixtures; forbid provider, npm and remote execution.
bin = Path.join(root, "fixture-bin")
File.mkdir_p!(bin)
tripwire = Path.join(root, "forbidden-execution")

for name <- ["claude", "codex", "fixture", "npm", "ssh"] do
  path = Path.join(bin, name)

  File.write!(path, """
  #!/bin/sh
  if [ "#{name}" = codex ] && [ "$1" = --dangerously-bypass-hook-trust ]; then shift; fi
  if [ "$#" = 1 ] && [ "$1" = --version ]; then echo 'synthetic 1.0'; exit 0; fi
  echo forbidden >> '#{tripwire}'
  exit 64
  """)

  File.chmod!(path, 0o755)
end

System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

for module <- Tightbeam.Harness.all(),
    key <- module.credential_env_vars(),
    do: System.delete_env(key)

Application.put_env(:tightbeam, :cwd, Path.join(base, "work"))
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Tightbeam.Model.new("fixture-model"))
Application.put_env(:tightbeam, :autostart, true)
File.mkdir_p!(Path.join(base, "work"))

before = if phase in ["abort", "resolve"], do: File.read!(Path.join(root, "pending.json"))
{:ok, _} = Application.ensure_all_started(:tightbeam)

{_, listener, _, _} =
  Enum.find(Supervisor.which_children(Tightbeam.Supervisor), fn {id, _, _, _} -> id == Bandit end)

{:ok, {_, port}} = ThousandIsland.listener_info(listener)

cli = fn args, user ->
  {output, status} =
    System.cmd(binary, args ++ ["--as-user", user],
      cd: base,
      env: [{"TIGHTBEAM_URL", "http://127.0.0.1:#{port}"}],
      stderr_to_stdout: true
    )

  assert status == 0, output
  JSON.decode!(output)
end

call = fn args -> cli.(args, "recovery-admin") end

edit = fn target, bytes ->
  path = Path.join(root, "edit-input")
  File.write!(path, bytes)
  call.(["identity", "edit", "coder"] ++ target ++ ["--file", path])
end

snapshot = fn ->
  %{
    "live" => Identity.live_revision!(base),
    "main" => git.(["rev-parse", "main"]),
    "merge" => File.read!(Path.join(dir, ".git/MERGE_HEAD")),
    "index" => git.(["ls-files", "--stage"]),
    "manifest" => File.read!(Path.join(dir, "archetypes/coder.toml")),
    "guidance" => File.read!(Path.join(dir, "guidance/coder.md"))
  }
end

case phase do
  "conflict" ->
    call.(["learn", "agentic-engineering"])
    edit.(["--manifest"], manifest.("local"))
    edit.([], "local customization\n")
    File.write!(Path.join(root, "stable"), Identity.live_revision!(base))
    File.write!(Path.join(source, "archetypes/coder.toml"), manifest.("incoming"))
    File.write!(Path.join(source, "guidance/coder.md"), "incoming guidance\n")
    result = call.(["identity", "relearn"])
    assert result["state"] == "relearn-conflicted"
    assert Enum.sort(result["conflictingPaths"]) == ["archetypes/coder.toml", "guidance/coder.md"]
    assert Identity.live_revision!(base) == File.read!(Path.join(root, "stable"))
    File.write!(Path.join(root, "pending.json"), JSON.encode!(snapshot.()))

  recovery when recovery in ["abort", "resolve"] ->
    assert snapshot.() == JSON.decode!(before)
    assert Archetypes.get("coder").where == ["local"]

    assert Archetypes.guidance(Archetypes.get("coder"), Archetypes.fragments()) =~
             "local customization"

    refute Archetypes.guidance(Archetypes.get("coder"), Archetypes.fragments()) =~
             "incoming guidance"

    {denial, status} =
      System.cmd(binary, ["identity", "relearn", "--abort", "--as-user", "recovery-reader"],
        cd: base,
        env: [{"TIGHTBEAM_URL", "http://127.0.0.1:#{port}"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert denial =~ "admin"
    assert snapshot.() == JSON.decode!(before)

    if recovery == "abort" do
      assert call.(["identity", "relearn", "--abort"])["state"] == "aborted"
      assert Identity.live_revision!(base) == File.read!(Path.join(root, "stable"))
      assert File.read!(Path.join(dir, "archetypes/coder.toml")) == manifest.("local")
      assert File.read!(Path.join(dir, "guidance/coder.md")) == "local customization\n"
      assert git.(["status", "--porcelain"]) == ""
      refute File.exists?(Path.join(dir, ".git/MERGE_HEAD"))
      assert call.(["identity", "relearn"])["state"] == "relearn-conflicted"
      File.write!(Path.join(root, "pending.json"), JSON.encode!(snapshot.()))
    else
      # Explicit operator resolution via the documented working-tree seam.
      File.write!(Path.join(dir, "archetypes/coder.toml"), manifest.("resolved"))
      File.write!(Path.join(dir, "guidance/coder.md"), "resolved customization\n")
      git.(["add", "archetypes/coder.toml", "guidance/coder.md"])
      assert call.(["identity", "relearn", "--resolve"])["state"] == "published"
      assert Identity.live_revision!(base) != File.read!(Path.join(root, "stable"))
      assert Archetypes.get("coder").where == ["resolved"]
      assert git.(["status", "--porcelain"]) == ""
    end

  "normal" ->
    assert Archetypes.get("coder").where == ["resolved"]
    assert call.(["identity", "relearn"])["state"] == "published"
    assert Archetypes.get("coder").where == ["resolved"]
    assert File.read!(Path.join(dir, "guidance/coder.md")) == "resolved customization\n"
end

assert Path.wildcard(Path.join(base, ".identity-law-*")) == []
refute File.exists?(tripwire)
:ok = Application.stop(:tightbeam)
IO.puts("identity-restart: #{phase} passed")
