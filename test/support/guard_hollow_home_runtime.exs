[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))

  hollow =
    ~s({"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"refreshTokenExpiresAt":0,"scopes":[],"subscriptionType":"","rateLimitTier":""}})

  healthy =
    ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-fresh","refreshToken":"sk-ant-ort01-fresh","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference","user:sessions:claude_code"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}})

  home = Tightbeam.Homes.home_path(base, "eezo", :claude)
  other = Tightbeam.Homes.home_path(base, "other", :claude)

  for {path, bytes} <- [{home, hollow}, {other, healthy}] do
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".credentials.json"), bytes)
  end

  config = %{
    db: db,
    base_dir: base,
    port: 4_321,
    cwd: base,
    default_harness: :claude,
    default_model: Tightbeam.Model.new("claude-fable-5"),
    max_live_sessions_per_user: 50,
    wake_tick_ms: 60_000,
    onboarding_lease_ms: 1_800_000
  }

  assert [_ | _] = Tightbeam.Gateway.children_after_preflight(config)
  assert File.read!(Path.join(home, ".credentials.json")) == hollow
  assert File.read!(Path.join(other, ".credentials.json")) == healthy
  refute File.exists?(Path.join(base, "auth"))
  assert File.read!(Path.join(base, "build-owner.json")) == marker
after
  if Process.alive?(db), do: GenServer.stop(db)
end

IO.puts("guarded-hollow-home-composition: ok")
