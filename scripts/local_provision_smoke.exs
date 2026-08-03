# LOCAL PROVISION SMOKE — a gateway host with a bare base_dir supplies its own ACP
# adapter and then uses it. Fresh base_dir, no adapters, real npm, real local patcher,
# real adapter process, real prompt. Nothing here is mocked (#46).
#
# The unit tests prove the seam with a stand-in for npm, which cannot prove the thing
# that actually goes wrong: that what npm leaves on disk is a tree the local patcher
# accepts and the adapter can be launched from. That is why this exists.
#
# Run on a host with node/npm and real claude credentials:
#   mix run --no-start scripts/local_provision_smoke.exs
#
# `--no-start` on purpose: this exercises spinup against a scratch base_dir it creates
# itself, and has no business booting the gateway (or depending on the state of whatever
# identity repo the operator's own base_dir happens to hold).
#
# Requires ~/.tightbeam-beam/auth/claude/.credentials.json. Network required — this really
# does hit the npm registry, which is the point.

{:ok, _} = Application.ensure_all_started(:exqlite)

alias Tightbeam.{DB, EventLog, Harness, Spinup}
alias Tightbeam.Acp.Adapter

module = Harness.Claude
real_base = Path.expand("~/.tightbeam-beam")
base = Path.join(System.tmp_dir!(), "tb-local-provision-#{System.unique_integer([:positive])}")
host = "smokehost"

File.mkdir_p!(base)
File.cp_r!(Path.join(real_base, "auth"), Path.join(base, "auth"))

Application.put_env(:tightbeam, :hosts, %{
  host => %{ssh: nil, base_dir: base, cli_bin: nil}
})

adapter_path = Path.join([base, "adapters", "node_modules", ".bin", "claude-agent-acp"])
IO.puts("[provision] base_dir=#{base}")
IO.puts("[provision] adapter absent before: #{not File.exists?(adapter_path)}")

if File.exists?(adapter_path), do: raise("fixture is not fresh: #{adapter_path} already exists")

db = :local_provision_smoke_db
{:ok, _} = DB.start_link(path: ":memory:", name: db)
:ok = EventLog.ensure_schema(db)

# The real thing: default sh (System.cmd), and no :patch_adapter opt so the harness
# supplies its own patch_local/1 rather than a no-op.
started = System.monotonic_time(:millisecond)
result = Spinup.ensure_ready(%{base_dir: base}, :claude, host, db: db)
elapsed = System.monotonic_time(:millisecond) - started

IO.puts("[provision] ensure_ready -> #{inspect(result)} in #{elapsed}ms")
:ok = result

[%{detail: detail}] = EventLog.lifecycle_events(db)
IO.puts("[provision] lifecycle: #{detail}")
true = detail =~ "deployed adapters"

# The pin actually landed, read off the installed package rather than the command we
# meant to run. #47 measured both adapters drifting past their pins under a bare name.
for harness <- Harness.all() do
  package =
    Path.join([base, "adapters", "node_modules", harness.install_package(), "package.json"])

  %{"version" => installed} = package |> File.read!() |> JSON.decode!()
  IO.puts("[provision] #{harness.wire_name()}: installed #{installed}, pinned #{harness.adapter_version()}")
  ^installed = harness.adapter_version()
end

# AdapterPatch.ensure!/6 asserts the installed version and raises on a bundle whose
# anchors it does not recognise, so ensure_ready returning :ok already means the patcher
# accepted the tree npm produced. The other half — that it actually rewrote the bytes —
# needs a control, or "patched" is indistinguishable from "never looked".
#
# The control: the same pinned release, installed again, untouched by tightbeam. Diffing
# the two package trees names the patched file by observation instead of asserting a
# filename the harness module happens to hold — and it also pins that the patcher touches
# exactly one file, which reading a known path would not.
package_dir = fn bin ->
  bin |> File.read_link!() |> Path.expand(Path.dirname(bin)) |> Path.dirname() |> Path.dirname()
end

control = Path.join(System.tmp_dir!(), "tb-control-#{System.unique_integer([:positive])}")

{_, 0} =
  System.cmd(
    "npm",
    ["install", "--prefix", control, "#{module.install_package()}@#{module.adapter_version()}"],
    stderr_to_stdout: true
  )

control_bin = Path.join([control, "node_modules", ".bin", Path.basename(adapter_path)])
provisioned_dir = package_dir.(adapter_path)
pristine_dir = package_dir.(control_bin)

changed =
  provisioned_dir
  |> Path.join("**/*.js")
  |> Path.wildcard()
  |> Enum.map(&Path.relative_to(&1, provisioned_dir))
  |> Enum.filter(fn rel ->
    File.read!(Path.join(provisioned_dir, rel)) != File.read!(Path.join(pristine_dir, rel))
  end)

IO.puts("[provision] files rewritten by the patcher: #{inspect(changed)}")

if changed == [], do: raise("the patcher left the installed tree byte-identical to npm's")

if length(changed) > 1, do: raise("the patcher touched more than the adapter bundle")

[relative] = changed
provisioned_bundle = File.read!(Path.join(provisioned_dir, relative))
pristine_bundle = File.read!(Path.join(pristine_dir, relative))

if module.patch_adapter_source(pristine_bundle) != provisioned_bundle,
  do: raise("the bundle on disk is not what patch_adapter_source/1 produces from pristine")

IO.puts(
  "[provision] #{relative}: #{byte_size(pristine_bundle)} -> #{byte_size(provisioned_bundle)} bytes, exactly the local patch"
)

File.rm_rf!(control)

# And a real turn through the adapter that was just provisioned.
home = Path.join([base, "homes", "smoke"])
File.mkdir_p!(home)

File.cp!(
  Path.join([base, "auth", "claude", ".credentials.json"]),
  Path.join(home, ".credentials.json")
)

cwd = Path.join([base, "work", "smoke"])
File.mkdir_p!(cwd)

target = %{
  base_dir: base,
  host_name: host,
  host_config: %{base_dir: base, ssh: nil},
  sh: &Tightbeam.Harness.Support.system_cmd/1
}

launch = module.prepare_launch(target, home, common_env: [], remote_env: [], lineage: "smoke")
IO.puts("[turn] cmd=#{inspect(Keyword.fetch!(launch, :cmd))}")

{:ok, adapter} =
  Adapter.start_link(
    harness: :claude,
    cmd: Keyword.fetch!(launch, :cmd),
    env: Keyword.fetch!(launch, :env),
    home: home,
    cwd: cwd,
    stderr_path: Path.join(base, "adapter.stderr.log"),
    name: :local_provision_adapter
  )

{:ok, sid} = Adapter.new_session(adapter, "haiku", cwd, [], "Be terse.")
IO.puts("[turn] session #{sid}")

{:ok, %{stop_reason: stop, text: text}} =
  Adapter.prompt(adapter, sid, "Reply with the single word: provisioned")

IO.puts("[turn] stop_reason=#{inspect(stop)}")
IO.puts("[turn] text=#{inspect(String.slice(text, 0, 120))}")

if String.trim(text) == "", do: raise("adapter produced no text")

IO.puts(
  "\nPASS — bare base_dir provisioned itself at the pin, the patcher accepted it, and a turn ran through it."
)

# Stop the adapter before clearing its tree; rm_rf under a live node process races it.
:ok = GenServer.stop(adapter, :normal, 10_000)
_ = File.rm_rf(base)
