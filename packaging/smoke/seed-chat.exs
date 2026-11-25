alias Tightbeam.{Model, Org}

%{cli_token: token} =
  Org.create(%{
    session_key: "agent:packaged-smoke",
    display_name: "Generated packaged Chat",
    owner_user_id: "packaged-smoke",
    origin: "user:packaged-smoke",
    host: Tightbeam.Placement.local_host_name(),
    harness: "claude",
    provider: "anthropic",
    model: Model.new("claude-sonnet-5", effort: "medium"),
    archetype: "default"
  })

path = Path.join(System.fetch_env!("TB_PACKAGED_SMOKE_ROOT"), "generated-session-token")
File.write!(path, token, [:exclusive])
File.chmod!(path, 0o600)
