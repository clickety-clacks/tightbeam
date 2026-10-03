[payload, base, cli] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Application.ensure_all_started(:inets)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
alias Tightbeam.{DB, Harness, Model}
arena = Path.dirname(base)
template = Path.join(arena, "template")
File.mkdir_p!(template)
File.write!(Path.join(template, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
Tightbeam.RecoveryFixture.place_adapter!(template, seed_credential: false)
:initialized = Tightbeam.Identity.init!(template)
identity_revision = Tightbeam.Identity.live_revision!(template)
File.mkdir_p!(Path.join(template, "homes/testhost"))
File.write!(Path.join(template, "homes/testhost/synthetic.txt"), "no credentials\n")
Tightbeam.ClientE2E.LegGateway.provision!(template, base)
["adapters", "homes", "identity"] = File.ls!(base) |> Enum.sort()
# The supported boot redirection opens this log before starting the gateway.
File.write!(Path.join(base, "gateway.log"), "synthetic preboot log\n")
false = File.exists?(Path.join(base, "state.db"))
false = File.exists?(Path.join(base, "build-owner.json"))
tripwire = Path.join(arena, "forbidden-execution.log")
bin = Path.join(arena, "fixture-bin")
File.mkdir_p!(bin)
# These are synthetic CLI probes, never harness adapters or provider clients.
for name <- ["claude", "codex", "fixture", "pi"] do
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
for module <- Harness.all(), key <- module.credential_env_vars(), do: System.delete_env(key)

for name <- ["claude", "codex", "fixture", "pi", "npm", "ssh"] do
  true = System.find_executable(name) == Path.join(bin, name)
end

for module <- Harness.all() do
  %{input: %{profile: profile}} =
    Enum.find(
      module.conformance_vectors()["ensure_adapter"],
      &(&1.case == "local_present")
    )

  true = File.exists?(Path.join(base, "adapters/node_modules/.bin/#{profile.adapter_bin}"))
end

# Keep the synthetic working directory and probe binaries OUTSIDE the new base.
Application.put_env(:tightbeam, :cwd, arena)
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Model.new("fixture-model"))
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
{:ok, _apps} = Application.ensure_all_started(:tightbeam)

try do
  Tightbeam.Readiness.await_settled()
  :ok = DB.assert_base_admitted!(DB, base)
  stamp = hd(Tightbeam.Schema.guard_compatible_stamps())
  {:ok, [[^stamp]]} = DB.query(DB, "SELECT shape FROM schema_stamp", [])
  ^identity_revision = Tightbeam.Identity.live_revision!(base)
  true = File.regular?(Path.join(base, "build-owner.json"))
  true = File.regular?(Path.join(base, "gateway.json"))
  {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM users", [])

  {_, listener, _, _} =
    Enum.find(
      Supervisor.which_children(Tightbeam.Supervisor),
      fn {id, _, _, _} -> match?({Bandit, _}, id) end
    )

  {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
  {:ok, {{_, 200, _}, _, _}} = :httpc.request(~c"http://127.0.0.1:#{port}/version")

  {output, 0} =
    System.cmd(cli, ["add-user", "synthetic-admin", "--admin"],
      env: [{"TIGHTBEAM_BASE_DIR", base}],
      stderr_to_stdout: true
    )

  %{"user" => %{"userId" => "synthetic-admin", "isAdmin" => true}} = JSON.decode!(output)
  {:ok, [["synthetic-admin", 1]]} = DB.query(DB, "SELECT userId, isAdmin FROM users", [])
  {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns", [])
  "no credentials\n" = File.read!(Path.join(base, "homes/testhost/synthetic.txt"))
  false = File.exists?(tripwire)
after
  :ok = Application.stop(:tightbeam)
end

false = File.exists?(tripwire)
IO.puts("provisioned-gateway-bootstrap: ok")
