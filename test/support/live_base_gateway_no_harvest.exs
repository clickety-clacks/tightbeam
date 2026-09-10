ExUnit.start(autorun: false)
import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config} ->
  store = Path.join([base, "auth", "codex", "auth.json"])
  abandoned = Path.join([base, "homes", "default--abandoned", "codex", "auth.json"])
  current = Path.join([base, "homes", "testhost", "codex", "auth.json"])

  baselines = [
    {store, "synthetic-legacy-store", {{2026, 1, 1}, {0, 0, 0}}},
    {abandoned, "synthetic-newer-abandoned", {{2026, 1, 3}, {0, 0, 0}}},
    {current, "synthetic-authoritative-home", {{2026, 1, 2}, {0, 0, 0}}}
  ]

  for {path, bytes, mtime} <- baselines do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    File.touch!(path, mtime)
  end

  before = Map.new(baselines, fn {path, _, _} -> {path, File.lstat!(path)} end)
  children = Gateway.children(config)
  assert is_list(children) and children != []

  for {path, bytes, _} <- baselines do
    assert File.read!(path) == bytes
    stat = File.lstat!(path)
    assert stat.type == :regular
    assert stat.inode == before[path].inode
    assert stat.mode == before[path].mode
    assert stat.mtime == before[path].mtime
  end

  # Missing authoritative credentials remain missing; newer abandoned bytes are
  # not an onboarding source, and startup does not backfill the legacy bank.
  File.rm!(current)
  children = Gateway.children(config)
  assert is_list(children) and children != []
  refute File.exists?(current)
  assert File.read!(store) == "synthetic-legacy-store"
  assert File.read!(abandoned) == "synthetic-newer-abandoned"
  assert Path.wildcard(Path.join([base, "staging", "credential-harvest", "*"])) == []
end)

IO.puts("guarded-gateway-no-harvest: ok")
