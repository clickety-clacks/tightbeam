alias Tightbeam.{DB, Devices, Model, Org, Placement}

root = System.fetch_env!("RELAY_PROOF_ROOT")
url = System.fetch_env!("RELAY_PROOF_URL")
person = "fixture-person"
work = "wi-relay-fixture"

{status, _} = Devices.pair(%{device_id: "fixture-device", claimed_name: person,
  platform: nil, model: nil})
true = status in [:paired, :pending]

for role <- ~w(sender relay) do
  key = "agent:relay-fixture:" <> role
  %{cli_token: token} = Org.create(%{
    session_key: key, display_name: key, owner_user_id: person,
    origin: "user:" <> person, archetype: "default",
    host: Placement.local_host_name(), harness: "claude",
    provider: "anthropic", model: Model.new("fable")
  })
  directory = Path.join(root, role)
  File.mkdir!(directory)
  path = Path.join(directory, ".tightbeam-session")
  File.write!(path, JSON.encode!(%{url: url, token: token, sessionKey: key}), [:exclusive])
  File.chmod!(path, 0o600)
end

{:ok, _} = DB.query(
  DB,
  "INSERT INTO work_items (id,title,ownerUserId,createdByUser,createdAt) VALUES (?1,'Fixture',?2,?2,1)",
  [work, person]
)
