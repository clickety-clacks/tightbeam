[payload, base] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
alias Tightbeam.{Boot, DB, Harness, Ledger, Model, Org, Projection, ReadMarkers, ToolCalls}
alias Tightbeam.Firehose.Publisher

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])

:ignore = Boot.start_link(%{base_dir: base})
marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(db)

File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
tripwire = Path.join(base, "forbidden-execution.log")
bin = Path.join(base, "fixture-bin")
File.mkdir_p!(bin)
# These are synthetic CLI probes, never harness adapters or provider clients.
for name <- ["claude", "codex", "fixture"] do
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

for name <- ["claude", "codex", "fixture", "npm", "ssh"] do
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

File.mkdir_p!(Path.join(base, "work"))
Application.put_env(:tightbeam, :cwd, Path.join(base, "work"))
{:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
{:ok, {_, port}} = :inet.sockname(listener)
:ok = :gen_tcp.close(listener)
Application.put_env(:tightbeam, :port, port)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Model.new("fixture-model"))
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
{:ok, _apps} = Application.ensure_all_started(:tightbeam)

import ExUnit.Assertions
alias Tightbeam.ClientE2E.{SimClient, WS}

try do
  Tightbeam.Readiness.await_settled()
  :ok = DB.assert_base_admitted!(DB, base)

  {:ok, device} =
    SimClient.pair("127.0.0.1", port, device_id: "cold-firehose", claimed_name: "Synthetic")

  session =
    Org.create(DB, %{
      session_key: "agent:observer-worker",
      display_name: "Observer fixture",
      owner_user_id: device.user_id,
      origin: "user:#{device.user_id}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

  user_message_id = "observer-question"
  reply_message_id = "observer-answer"

  {:ok, _} =
    DB.query(
      DB,
      """
      INSERT INTO messages
        (id, sessionKey, role, content, timestamp, sender, llmVisibleMessageId, attachments)
      VALUES (?1, ?2, 'user', 'observer question', 1, ?3, ?1, '[]')
      """,
      [user_message_id, session.session_key, "user:#{device.user_id}"]
    )

  {:ok, _} =
    DB.query(
      DB,
      """
      INSERT INTO messages
        (id, sessionKey, role, content, timestamp, sender, replyToMessageId,
         llmVisibleMessageId, attachments)
      VALUES (?1, ?2, 'assistant', 'observer answer', 2, 'agent:observer-worker', ?3, ?1, '[]')
      """,
      [reply_message_id, session.session_key, user_message_id]
    )

  {:ok, true, _marker} =
    ReadMarkers.set(DB, device.user_id, "chat:observer", "observer-answer")

  %{"cliToken" => cli_token} = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

  {:ok, observer_ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=2")

  try do
    :ok =
      WS.send_text(
        observer_ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 2,
          "subscriptionId" => "credentialless",
          "filters" => %{"classes" => ["work_item.created"]}
        })
      )

    {:ok, {:text, observer_ready}, observer_ws} = WS.recv(observer_ws, 2_000)

    assert %{"type" => "subscription_ready", "subscriptionId" => "credentialless"} =
             JSON.decode!(observer_ready)

    {:ok, archetype_ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=2")

    try do
      :ok =
        WS.send_text(
          archetype_ws,
          JSON.encode!(%{
            "type" => "subscribe",
            "protocolVersion" => 2,
            "subscriptionId" => "late-product-owners",
            "filters" => %{
              "classes" => ["message.created", "tool_call."],
              "archetype" => "product-owner"
            }
          })
        )

      {:ok, {:text, archetype_ready}, archetype_ws} = WS.recv(archetype_ws, 2_000)

      assert %{
               "type" => "subscription_ready",
               "subscriptionId" => "late-product-owners"
             } = JSON.decode!(archetype_ready)

      late_session = fn session_key, archetype ->
        Org.create(DB, %{
          session_key: session_key,
          display_name: session_key,
          owner_user_id: device.user_id,
          origin: "user:#{device.user_id}",
          archetype: archetype,
          host: "testhost",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable")
        })
      end

      product_owner = late_session.("agent:late-product-owner", "product-owner")
      coder = late_session.("agent:late-coder", "coder")

      for {session, suffix} <- [{product_owner, "po"}, {coder, "coder"}] do
        prompt = "late session #{suffix} prompt"

        {:ok, {:appended, message}} =
          DB.transaction(DB, fn txn ->
            {:appended, message} =
              Projection.append_in_txn(txn, %{
                session_key: session.session_key,
                role: "user",
                content: prompt
              })

            :ok = Publisher.message_in_txn(txn, session.session_key, message)
            {:appended, message}
          end)

        {:ok, _turn_seq} =
          Ledger.enqueue(DB, %{
            session_key: session.session_key,
            message_id: message.id,
            origin: "user:#{device.user_id}",
            prompt: prompt
          })

        {:ok, turn} = Ledger.claim_next(DB, session.session_key, "firehose-archetype-test")

        start =
          ToolCalls.normalize_notification(%{
            "title" => "Read fixture",
            "kind" => "read",
            "status" => "in_progress",
            "rawInput" => %{"path" => "#{suffix}.txt"}
          })

        assert {:ok, :started} =
                 ToolCalls.observe(
                   DB,
                   session.session_key,
                   turn.seq,
                   "call-#{suffix}",
                   start,
                   %{},
                   nil
                 )

        terminal = ToolCalls.normalize_notification(%{"status" => "completed"})

        assert {:ok, :ended} =
                 ToolCalls.observe(
                   DB,
                   session.session_key,
                   turn.seq,
                   "call-#{suffix}",
                   terminal,
                   start,
                   nil
                 )
      end

      {archetype_notices, archetype_ws} =
        Enum.reduce(1..3, {[], archetype_ws}, fn _, {notices, ws} ->
          {:ok, {:text, raw}, next_ws} = WS.recv(ws, 2_000)
          {[JSON.decode!(raw) | notices], next_ws}
        end)

      archetype_notices = Enum.reverse(archetype_notices)

      assert Enum.map(archetype_notices, & &1["class"]) |> Enum.sort() ==
               ["message.created", "tool_call.ended", "tool_call.started"]

      assert Enum.all?(archetype_notices, fn notice ->
               notice["refs"]["sessionKey"] == product_owner.session_key
             end)

      assert {:error, :timeout, _archetype_ws} = WS.recv(archetype_ws, 250)
    after
      WS.close(archetype_ws)
    end

    {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=2")

    try do
      :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => device.token}))
      {:ok, {:text, auth}, ws} = WS.recv(ws, 2_000)
      assert %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

      :ok =
        WS.send_text(
          ws,
          JSON.encode!(%{
            "type" => "subscribe",
            "protocolVersion" => 2,
            "subscriptionId" => "cold",
            "filters" => %{"classes" => ["work_item.created"]}
          })
        )

      {:ok, {:text, ready}, ws} = WS.recv(ws, 2_000)
      assert %{"type" => "subscription_ready"} = JSON.decode!(ready)

      headers = [
        {~c"authorization", String.to_charlist("Bearer " <> cli_token)},
        {~c"x-tightbeam-cli-version",
         String.to_charlist(Tightbeam.CliCompatibility.required_version())}
      ]

      body =
        JSON.encode!(%{
          "verb" => "work-item-create",
          "asUser" => device.user_id,
          "params" => %{"title" => "Cold persistent delivery"}
        })

      {:ok, {{_, 200, _}, _, response}} =
        :httpc.request(
          :post,
          {~c"http://127.0.0.1:#{port}/agent/dispatch", headers, ~c"application/json", body},
          [timeout: 2_000],
          body_format: :binary
        )

      assert %{"result" => %{"id" => id}} = JSON.decode!(response)
      {:ok, {:text, raw}, ws} = WS.recv(ws, 2_000)

      assert %{
               "type" => "change",
               "class" => "work_item.created",
               "refs" => %{"workItemId" => ^id},
               "payload" => item
             } = JSON.decode!(raw)

      {:ok, {:text, observer_raw}, observer_ws} = WS.recv(observer_ws, 2_000)

      assert %{
               "type" => "change",
               "class" => "work_item.created",
               "refs" => %{"workItemId" => ^id},
               "payload" => ^item
             } = JSON.decode!(observer_raw)

      {:ok, {{_, 200, _}, _, detail}} =
        :httpc.request(
          :get,
          {String.to_charlist("http://127.0.0.1:#{port}/api/work-items/#{id}"),
           [{~c"authorization", String.to_charlist("Bearer " <> device.token)}]},
          [timeout: 2_000],
          body_format: :binary
        )

      assert JSON.decode!(detail)["item"] == item

      get_json = fn path, auth_headers ->
        {:ok, {{_, 200, _}, _, response}} =
          :httpc.request(
            :get,
            {String.to_charlist("http://127.0.0.1:#{port}" <> path), auth_headers},
            [timeout: 2_000],
            body_format: :binary
          )

        JSON.decode!(response)
      end

      authenticated_headers = [
        {~c"authorization", String.to_charlist("Bearer " <> cli_token)}
      ]

      anonymous_sessions = get_json.("/api/sessions", [])
      authenticated_sessions = get_json.("/api/sessions", authenticated_headers)
      assert anonymous_sessions["items"] == authenticated_sessions["items"]
      assert Enum.any?(anonymous_sessions["items"], &(&1["sessionKey"] == session.session_key))

      encoded_session_key = URI.encode_www_form(session.session_key)
      session_path = "/api/sessions/#{encoded_session_key}"
      assert get_json.(session_path, []) == get_json.(session_path, authenticated_headers)

      messages_path = session_path <> "/messages"
      anonymous_messages = get_json.(messages_path, [])
      authenticated_messages = get_json.(messages_path, authenticated_headers)
      assert anonymous_messages["items"] == authenticated_messages["items"]

      assert Enum.map(anonymous_messages["items"], & &1["id"]) == [
               user_message_id,
               reply_message_id
             ]

      message_path = messages_path <> "/#{reply_message_id}"

      assert get_json.(message_path, []) == get_json.(message_path, authenticated_headers)

      as_user = URI.encode_www_form(device.user_id)
      marker_collection = "/api/read-markers?asUser=#{as_user}"
      anonymous_markers = get_json.(marker_collection, [])
      authenticated_markers = get_json.(marker_collection, authenticated_headers)
      assert anonymous_markers["items"] == authenticated_markers["items"]
      assert Enum.any?(anonymous_markers["items"], &(&1["scopeKey"] == "chat:observer"))

      encoded_scope = URI.encode_www_form("chat:observer")
      marker_detail = "/api/read-markers/#{encoded_scope}?asUser=#{as_user}"
      assert get_json.(marker_detail, []) == get_json.(marker_detail, authenticated_headers)

      assert File.regular?(Path.join(base, "state.db"))
      assert File.read!(Path.join(base, "build-owner.json")) == marker
      refute File.exists?(tripwire)
    after
      WS.close(ws)
    end
  after
    WS.close(observer_ws)
  end
after
  :ok = Application.stop(:tightbeam)
end

refute File.exists?(tripwire)
IO.puts("guarded-firehose-loopback: ok")
