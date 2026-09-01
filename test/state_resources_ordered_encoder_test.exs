defmodule Tightbeam.StateResourcesOrderedEncoderTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Firehose.{Publisher, Registry}
  alias Tightbeam.StateResources

  @catalog %{
    {"testhost", "fixture"} => [
      %{
        family: "fixture-model",
        context: "1m",
        efforts: ["medium"],
        provider: :fixture_provider
      }
    ]
  }

  @field_order %{
    "work items" =>
      ~w(id title specRefName specRefSha256 isBug ownerUserId state failReason routingWakeId slateWakeId createdByUser createdBySession createdInTurnSeq createdContextKnown createdAt rowVersion),
    "assignments" =>
      ~w(id subject holderKey holderRole holderFallback openedByUser openedBySession openedAt state outcome closedAt closedByUser closedBySession closingAttestId workItemId reviewsAssignmentId holderHarness holderProvider files effectKind derivedStatus rowVersion),
    "attests" =>
      ~w(id assignmentId kind verdictKind note bySession byUser producer producerCommand byHarness byProvider commitRefs ts rowVersion),
    "wakes" =>
      ~w(wakeId sessionKey targetRole origin prompt consumer dueAt state createdAt firedAt reresolve reresolveSeed reresolveRung conditionKind conditionScope conditionAfterId firedBy creatorSessionKey rumination workItemId assignmentId canceledAt targetGate class classElection deliveryRule digest summon rowVersion),
    "turns" =>
      ~w(seq sessionKey messageId wakeId origin prompt roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness replyAttention status owner adapterGen requestRef error createdAt startedAt endedAt publishedAt rowVersion),
    "decision requests" =>
      ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId lineageRung effortGeneration deadlineWakeId raisedAt deadlineAt statuteName question options context status decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt rowVersion),
    "sessions" =>
      ~w(sessionKey displayName kind orderIndex isBuiltIn adopted ownerUserId origin spawnedBy handle archetype overrides identityName identityRevision harness provider model thinkingLevel modelContext host clearedThroughSeq state createdAt updatedAt mechanicalStatus rowVersion),
    "roles" => ~w(name boundSessionKey ownerUserId createdAt updatedAt rowVersion),
    "users" => ~w(userId isAdmin createdAt rowVersion),
    "devices" => ~w(deviceId userId claimedName status platform model createdAt rowVersion),
    "artifacts" =>
      ~w(artifactId kind title description createdBySession workItemId parentSession originPath contentSha256 recordedMessageId recordedTurnEvidence state home createdAt updatedAt rowVersion),
    "read markers" => ~w(userId scopeKey marker updatedAt rowVersion),
    "transcript messages" =>
      ~w(id seq sessionKey role messageType content at sender deviceId clientMessageId replyToMessageId replyToClientMessageId llmVisibleMessageId attachments attentionTier turnSeq assignmentId jobRef harness provider model effort context rowVersion),
    "condition facts" => ~w(id ts kind scope origin rowVersion),
    "critical state" =>
      ~w(sessionKey reason startedAt expiresAt hardDeadline updatedAt rowVersion),
    "config" => ~w(key value updatedAt rowVersion),
    "host environment" => ~w(host harness name value valuePresent updatedAt rowVersion),
    "hosts" => ~w(host rowVersion),
    "identity" => ~w(name liveRevision state sessionRevisions staleness conflicts rowVersion),
    "kungfu" =>
      ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion)
  }

  @resource_aliases %{
    "work-items" => "work items",
    "decision-requests" => "decision requests",
    "read-markers" => "read markers",
    "messages" => "transcript messages",
    "condition-facts" => "condition facts",
    "critical-state" => "critical state"
  }

  test "one shared encoder emits the exact R7/R7a order for every rebuildable resource" do
    registry_resources =
      Registry.rows()
      |> Map.values()
      |> Enum.map(& &1.resource)
      |> Enum.reject(&(&1 == "productions"))
      |> Enum.map(&Map.get(@resource_aliases, &1, &1))
      |> MapSet.new()

    assert registry_resources == MapSet.new(Map.keys(@field_order))

    for {resource, fields} <- @field_order do
      item = item(resource, fields)

      assert StateResources.encode_item(resource, item, @catalog) ==
               expected_bytes(resource, fields, item)
    end
  end

  test "the shared public serializer preserves canonical JSON null and boolean types" do
    session =
      "sessions"
      |> item(Map.fetch!(@field_order, "sessions"))
      |> Map.put("overrides", nil)
      |> Map.put("isBuiltIn", true)
      |> Map.put("adopted", false)
      |> Map.put("state", :active)
      |> StateResources.session()

    assert session["overrides"] == nil
    assert session["isBuiltIn"] === true
    assert session["adopted"] === false
    assert session["state"] == "active"

    bytes = StateResources.encode_item("sessions", session, @catalog)
    assert JSON.decode!(bytes) == session
  end

  test "A17 randomizes map and set order 1,000 times without changing item bytes" do
    items =
      Map.new(@field_order, fn {resource, fields} ->
        {resource, item(resource, fields)}
      end)

    expected =
      Map.new(items, fn {resource, item} ->
        {resource, StateResources.encode_item(resource, item, @catalog)}
      end)

    :rand.seed(:exsss, {17, 71, 171})

    for _iteration <- 1..1_000, {resource, _fields} <- @field_order do
      randomized = items |> Map.fetch!(resource) |> randomize_item(resource)

      assert StateResources.encode_item(resource, randomized, @catalog) ==
               Map.fetch!(expected, resource)
    end
  end

  test "Publisher RawJSON payload bytes come from the shared encoder for every resource" do
    Registry.rows()
    |> Map.values()
    |> Enum.reject(&(&1.resource == "productions"))
    |> Enum.uniq_by(& &1.resource)
    |> Enum.each(fn row ->
      resource = Map.get(@resource_aliases, row.resource, row.resource)
      fields = Map.fetch!(@field_order, resource)
      item = item(resource, fields)
      item_bytes = StateResources.encode_item(row.resource, item, @catalog)

      wire =
        Publisher.encode_wire_notice(
          %{
            "class" => row.class,
            "op" => row.op,
            "occurredAt" => 1,
            "refs" => %{},
            "payload" => item
          },
          @catalog
        )

      assert wire =~ "\"payload\":" <> item_bytes
    end)
  end

  test "messageType is the sole conditional omission and is never encoded as null" do
    fields = Map.fetch!(@field_order, "transcript messages")
    item = item("transcript messages", fields)
    omitted = Map.delete(item, "messageType")

    refute StateResources.encode_item("messages", omitted) =~ "\"messageType\""

    assert_raise ArgumentError, ~r/messageType/, fn ->
      StateResources.encode_item("messages", Map.put(item, "messageType", nil))
    end

    assert StateResources.encode_item("messages", Map.put(item, "messageType", "")) =~
             ~s("messageType":"")
  end

  test "the closed field table rejects extra and missing R7 input" do
    fields = Map.fetch!(@field_order, "work items")
    item = item("work items", fields)

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      StateResources.encode_item("work-items", Map.put(item, "cliToken", "secret"))
    end

    assert_raise ArgumentError, ~r/extra or missing field/, fn ->
      StateResources.encode_item("work-items", Map.delete(item, "title"))
    end
  end

  test "the shared schema rejects wrong types, nullability, enums, and versions for every field" do
    for {resource, types} <- StateResources.item_wire_schema() do
      fields = Map.fetch!(@field_order, resource)
      item = item(resource, fields)

      for {field, type} <- types do
        invalid = Map.put(item, field, invalid_value(type))

        assert_raise ArgumentError, fn -> StateResources.encode_item(resource, invalid) end
        refute StateResources.complete_item?(resource, invalid)
      end
    end

    fact = item("condition facts", Map.fetch!(@field_order, "condition facts"))

    assert_raise ArgumentError, ~r/id must equal rowVersion/, fn ->
      StateResources.encode_item("condition facts", Map.put(fact, "id", 2))
    end

    attest = item("attests", Map.fetch!(@field_order, "attests"))

    assert_raise ArgumentError, ~r/verdictKind/, fn ->
      StateResources.encode_item("attests", Map.put(attest, "verdictKind", "approved"))
    end

    assert_raise ArgumentError, ~r/verdictKind/, fn ->
      invalid = Map.put(attest, "kind", "verdict")
      StateResources.encode_item("attests", invalid)
    end
  end

  test "nested shapes validate their exact keys and value types" do
    cases = [
      {"sessions", "overrides", %{"skillsAdd" => [1], "guidanceExtra" => nil}},
      {"transcript messages", "attachments",
       [%{"assetId" => "a", "mimeType" => "m", "filename" => "f", "size" => "1"}]},
      {"attests", "commitRefs", [%{"repo" => "r", "commit" => 1}]},
      {"decision requests", "options", [%{"label" => 1}]},
      {"identity", "sessionRevisions", %{"session" => 1}},
      {"kungfu", "documents", [%{"path" => "p", "content" => "c", "sha256" => 1}]}
    ]

    for {resource, field, invalid_value} <- cases do
      item = item(resource, Map.fetch!(@field_order, resource))

      assert_raise ArgumentError, fn ->
        StateResources.encode_item(resource, Map.put(item, field, invalid_value))
      end
    end
  end

  test "Publisher refuses a schema-invalid complete row before emitting JSON" do
    fields = Map.fetch!(@field_order, "users")
    invalid = "users" |> item(fields) |> Map.put("isAdmin", "not-a-boolean")

    assert StateResources.item_shape_complete?("users", invalid)
    refute StateResources.complete_item?("users", invalid)

    assert_raise ArgumentError, fn ->
      Publisher.encode_wire_notice(%{
        "class" => "user.added",
        "op" => "upsert",
        "occurredAt" => 1,
        "refs" => %{"userId" => "flynn"},
        "payload" => invalid
      })
    end
  end

  test "session enums and catalog-backed values fail closed at the shared encoder" do
    valid =
      "sessions"
      |> item(Map.fetch!(@field_order, "sessions"))
      |> Map.merge(%{
        "harness" => "fixture",
        "provider" => "fixture_provider",
        "model" => "fixture-model",
        "thinkingLevel" => "medium",
        "modelContext" => "1m",
        "host" => "testhost",
        "mechanicalStatus" => "idle"
      })

    assert StateResources.complete_item?("sessions", valid, @catalog)

    assert StateResources.encode_item("sessions", valid, @catalog) ==
             expected_bytes("sessions", Map.fetch!(@field_order, "sessions"), valid)

    for {field, value} <- [
          {"mechanicalStatus", "wedged"},
          {"harness", "not-a-served-harness"},
          {"provider", "other-provider"},
          {"model", "other-model"},
          {"thinkingLevel", "extreme"},
          {"modelContext", "2m"}
        ] do
      invalid = Map.put(valid, field, value)
      refute StateResources.complete_item?("sessions", invalid, @catalog)

      assert_raise ArgumentError, fn ->
        StateResources.encode_item("sessions", invalid, @catalog)
      end
    end
  end

  test "every catalog-backed R7 field matches one served tuple" do
    valid = [
      {"assignments", %{"holderHarness" => "fixture", "holderProvider" => "fixture_provider"}},
      {"attests", %{"byHarness" => "fixture", "byProvider" => "fixture_provider"}},
      {"turns",
       %{
         "harness" => "fixture",
         "model" => "fixture-model",
         "thinkingLevel" => "medium",
         "modelContext" => "1m"
       }},
      {"sessions",
       %{
         "host" => "testhost",
         "harness" => "fixture",
         "provider" => "fixture_provider",
         "model" => "fixture-model",
         "thinkingLevel" => "medium",
         "modelContext" => "1m"
       }},
      {"transcript messages",
       %{
         "harness" => "fixture",
         "provider" => "fixture_provider",
         "model" => "fixture-model",
         "effort" => "medium",
         "context" => "1m"
       }},
      {"host environment", %{"host" => "testhost", "harness" => "fixture"}}
    ]

    for {resource, selections} <- valid do
      canonical = resource |> item(Map.fetch!(@field_order, resource)) |> Map.merge(selections)
      assert StateResources.complete_item?(resource, canonical, @catalog)
      assert is_binary(StateResources.encode_item(resource, canonical, @catalog))

      for field <- Map.keys(selections), field != "host" do
        invalid = Map.put(canonical, field, "not-served")
        refute StateResources.complete_item?(resource, invalid, @catalog)

        assert_raise ArgumentError, fn ->
          StateResources.encode_item(resource, invalid, @catalog)
        end
      end
    end

    absent_harness = [
      {"assignments", %{"holderHarness" => "codex", "holderProvider" => nil}},
      {"attests", %{"byHarness" => "codex", "byProvider" => nil}},
      {"turns",
       %{
         "harness" => "codex",
         "model" => nil,
         "thinkingLevel" => nil,
         "modelContext" => nil
       }},
      {"sessions",
       %{
         "host" => nil,
         "harness" => "codex",
         "provider" => nil,
         "model" => nil,
         "thinkingLevel" => nil,
         "modelContext" => nil
       }},
      {"transcript messages",
       %{
         "harness" => "codex",
         "provider" => nil,
         "model" => nil,
         "effort" => nil,
         "context" => nil
       }},
      {"host environment", %{"host" => "testhost", "harness" => "codex"}}
    ]

    for {resource, selections} <- absent_harness do
      invalid = resource |> item(Map.fetch!(@field_order, resource)) |> Map.merge(selections)
      refute StateResources.complete_item?(resource, invalid, @catalog)

      assert_raise ArgumentError, ~r/absent from the served harness catalog/, fn ->
        StateResources.encode_item(resource, invalid, @catalog)
      end
    end

    device =
      item("devices", Map.fetch!(@field_order, "devices")) |> Map.put("model", "physical-model")

    assert StateResources.complete_item?("devices", device, %{})
  end

  test "device projection omits derived admin state and Publisher refuses it as wire drift" do
    projection =
      StateResources.device(%{
        device_id: "device-canonical",
        user_id: "flynn",
        claimed_name: "Canonical device",
        status: "allowlisted",
        is_admin: true,
        token: "tbt_storage_secret",
        platform: nil,
        model: nil,
        created_at: 1,
        row_version: 2
      })

    assert MapSet.new(Map.keys(projection)) ==
             MapSet.new(Map.fetch!(@field_order, "devices"))

    refute Map.has_key?(projection, "isAdmin")
    refute Map.has_key?(projection, "token")

    notice = %{
      "class" => "device.approved",
      "op" => "upsert",
      "occurredAt" => 1,
      "refs" => %{"deviceId" => projection["deviceId"]},
      "payload" => projection
    }

    assert JSON.decode!(Publisher.encode_wire_notice(notice, %{})) == notice

    assert_raise ArgumentError, ~r/no permitted legacy partial shape/, fn ->
      Publisher.encode_wire_notice(put_in(notice, ["payload", "isAdmin"], true), %{})
    end
  end

  test "Publisher rejects known item supersets and secret fields instead of using the raw fallback" do
    canonical =
      "config"
      |> item(Map.fetch!(@field_order, "config"))

    for payload <- [
          Map.put(canonical, "unexpected", "storage-drift"),
          Map.put(canonical, "cliToken", "tbc_should_never_cross_the_wire")
        ] do
      assert StateResources.item_shape_superset?("config", payload)

      assert_raise ArgumentError, fn -> StateResources.encode_item("config", payload) end

      assert_raise ArgumentError, fn ->
        Publisher.encode_wire_notice(%{
          "class" => "config.updated",
          "op" => "upsert",
          "occurredAt" => 1,
          "refs" => %{"key" => "default-priority"},
          "payload" => payload
        })
      end
    end

    partial_secret = %{"key" => "default-priority", "cliToken" => "tbc_secret"}
    assert StateResources.item_has_secret_fields?(partial_secret)
    refute StateResources.item_shape_superset?("config", partial_secret)

    assert_raise ArgumentError, fn ->
      Publisher.encode_wire_notice(%{
        "class" => "config.updated",
        "op" => "upsert",
        "occurredAt" => 1,
        "refs" => %{"key" => "default-priority"},
        "payload" => partial_secret
      })
    end

    complete_secret =
      "decision requests"
      |> item(Map.fetch!(@field_order, "decision requests"))
      |> Map.put("context", %{"nested" => [%{"cliToken" => "tbc_secret"}]})

    assert StateResources.item_shape_complete?("decision-requests", complete_secret)
    assert StateResources.item_has_secret_fields?(complete_secret)

    assert_raise ArgumentError, ~r/forbidden field/, fn ->
      Publisher.encode_wire_notice(
        %{
          "class" => "decision_request.opened",
          "op" => "upsert",
          "occurredAt" => 1,
          "refs" => %{"decisionRequestId" => complete_secret["id"]},
          "payload" => complete_secret
        },
        @catalog
      )
    end
  end

  test "legacy partial notices retain their current wire path until their serializer is R7-complete" do
    notice = %{
      "class" => "work_item.created",
      "op" => "upsert",
      "payload" => %{"id" => "wi_legacy", "rowVersion" => 1}
    }

    refute StateResources.complete_item?("work-items", notice["payload"])
    assert Publisher.encode_wire_notice(notice) == JSON.encode!(notice)

    additive = put_in(notice, ["payload", "priority"], 4)
    refute StateResources.item_shape_superset?("work-items", additive["payload"])
    assert_raise ArgumentError, fn -> Publisher.encode_wire_notice(additive) end

    assert_raise ArgumentError, ~r/no permitted legacy partial shape/, fn ->
      Publisher.encode_wire_notice(%{
        "class" => "message.created",
        "op" => "upsert",
        "payload" => %{
          "id" => "s_legacy",
          "seq" => 1,
          "sessionKey" => "agent:legacy",
          "role" => "assistant",
          "content" => "legacy",
          "timestamp" => 1,
          "sender" => "tightbeam",
          "deviceId" => nil,
          "clientMessageId" => nil,
          "replyToMessageId" => nil,
          "replyToClientMessageId" => nil,
          "llmVisibleMessageId" => "s_legacy",
          "attachments" => [],
          "attentionTier" => 0,
          "rowVersion" => 1
        }
      })
    end

    for {class, payload} <- [
          {"config.updated", %{"key" => "default-priority", "value" => "private-priority"}},
          {"host_env.updated",
           %{
             "host" => "h",
             "harness" => "fixture",
             "name" => "OPENAI_API_KEY",
             "value" => "sk-private"
           }},
          {"work_item.created",
           %{
             "id" => "wi_partial",
             "rowVersion" => 1,
             "metadata" => %{"cliToken" => "secret"}
           }}
        ] do
      assert_raise ArgumentError, fn ->
        Publisher.encode_wire_notice(%{"class" => class, "op" => "upsert", "payload" => payload})
      end
    end
  end

  defp item(resource, fields) do
    Map.new(fields, fn field -> {field, value(resource, field)} end)
  end

  defp value("sessions", "overrides"),
    do: %{"guidanceExtra" => nil, "skillsAdd" => ["beta", "alpha"]}

  defp value("sessions", "harness"), do: "fixture"
  defp value("host environment", "host"), do: "testhost"
  defp value("host environment", "harness"), do: "fixture"

  defp value("assignments", "files"), do: ["second", "first"]

  defp value("transcript messages", "attachments"),
    do: [%{"size" => 1, "filename" => "f", "mimeType" => "m", "assetId" => "a"}]

  defp value("transcript messages", "context"), do: opaque_json()

  defp value("attests", "commitRefs"),
    do: [%{"commit" => "c", "repo" => "r"}]

  defp value("decision requests", "options"), do: [%{"label" => "one"}]
  defp value("decision requests", "context"), do: opaque_json()
  defp value("identity", "sessionRevisions"), do: %{"z" => "2", "a" => "1"}
  defp value("identity", "staleness"), do: ["zeta", "alpha"]
  defp value("identity", "conflicts"), do: ["zeta", "alpha"]

  defp value("kungfu", "phrases"), do: ["zeta", "alpha"]

  defp value("kungfu", "documents"),
    do: [
      %{"sha256" => "z", "content" => "z", "path" => "z.md"},
      %{"sha256" => "a", "content" => "a", "path" => "a.md"}
    ]

  defp value("transcript messages", "messageType"), do: "agent"

  defp value(resource, field) do
    StateResources.item_wire_schema()
    |> Map.fetch!(resource)
    |> Map.fetch!(field)
    |> valid_value(field)
  end

  defp valid_value({:nullable, _type}, _field), do: nil
  defp valid_value(:string, field), do: field
  defp valid_value(:integer, _field), do: 1
  defp valid_value(:positive_integer, _field), do: 1
  defp valid_value(:boolean, _field), do: false
  defp valid_value({:enum, values}, _field), do: hd(values)
  defp valid_value({:array, :string, _order}, _field), do: ["second", "first"]
  defp valid_value(:json, _field), do: opaque_json()

  defp opaque_json, do: %{"b" => [%{"z" => 1, "a" => 2}], "a" => %{"z" => 2, "a" => 1}}

  defp expected_bytes(resource, fields, item) do
    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <> ":" <> expected_value(resource, field, Map.fetch!(item, field))
      end)

    "{" <> encoded <> "}"
  end

  defp expected_value("sessions", "overrides", _value),
    do: ~s({"skillsAdd":["alpha","beta"],"guidanceExtra":null})

  defp expected_value("transcript messages", "attachments", _value),
    do: ~s([{"assetId":"a","mimeType":"m","filename":"f","size":1}])

  defp expected_value("transcript messages", "context", _value), do: expected_opaque_json()

  defp expected_value("attests", "commitRefs", _value),
    do: ~s([{"repo":"r","commit":"c"}])

  defp expected_value("decision requests", "options", _value), do: ~s([{"label":"one"}])
  defp expected_value("decision requests", "context", _value), do: expected_opaque_json()
  defp expected_value("identity", "sessionRevisions", _value), do: ~s({"a":"1","z":"2"})

  defp expected_value("identity", field, _value) when field in ~w(staleness conflicts),
    do: ~s(["alpha","zeta"])

  defp expected_value("kungfu", "phrases", _value), do: ~s(["alpha","zeta"])

  defp expected_value("kungfu", "documents", _value),
    do:
      ~s([{"path":"a.md","content":"a","sha256":"a"},{"path":"z.md","content":"z","sha256":"z"}])

  defp expected_value(_resource, _field, value), do: JSON.encode!(value)

  defp expected_opaque_json, do: ~s({"a":{"a":1,"z":2},"b":[{"a":2,"z":1}]})

  defp invalid_value({:nullable, {:enum, _values}}), do: "outside-enum"
  defp invalid_value({:nullable, _type}), do: :not_a_wire_value
  defp invalid_value(:string), do: nil
  defp invalid_value(:integer), do: "not-an-integer"
  defp invalid_value(:positive_integer), do: 0
  defp invalid_value(:boolean), do: "not-a-boolean"
  defp invalid_value({:catalog, _field}), do: nil
  defp invalid_value({:enum, [value | _values]}) when is_integer(value), do: 99
  defp invalid_value({:enum, _values}), do: "outside-enum"
  defp invalid_value({:array, _type, _order}), do: %{}
  defp invalid_value(:session_overrides), do: %{}
  defp invalid_value(:string_map), do: []
  defp invalid_value(:json), do: :not_json

  defp randomize_item(item, "sessions") do
    update_in(item["overrides"], fn overrides ->
      overrides
      |> Map.update!("skillsAdd", &Enum.shuffle/1)
      |> shuffled_map()
    end)
    |> shuffled_map()
  end

  defp randomize_item(item, "transcript messages") do
    item
    |> Map.update!("attachments", fn attachments -> Enum.map(attachments, &shuffled_map/1) end)
    |> Map.update!("context", &randomize_json/1)
    |> shuffled_map()
  end

  defp randomize_item(item, "attests") do
    item
    |> Map.update!("commitRefs", fn refs -> Enum.map(refs, &shuffled_map/1) end)
    |> shuffled_map()
  end

  defp randomize_item(item, "decision requests") do
    item
    |> Map.update!("options", fn options -> Enum.map(options, &shuffled_map/1) end)
    |> Map.update!("context", &randomize_json/1)
    |> shuffled_map()
  end

  defp randomize_item(item, "identity") do
    item
    |> Map.update!("sessionRevisions", &shuffled_map/1)
    |> Map.update!("staleness", &Enum.shuffle/1)
    |> Map.update!("conflicts", &Enum.shuffle/1)
    |> shuffled_map()
  end

  defp randomize_item(item, "kungfu") do
    item
    |> Map.update!("phrases", &Enum.shuffle/1)
    |> Map.update!("documents", fn documents ->
      documents |> Enum.shuffle() |> Enum.map(&shuffled_map/1)
    end)
    |> shuffled_map()
  end

  defp randomize_item(item, _resource), do: shuffled_map(item)

  defp randomize_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {key, randomize_json(item)} end)
    |> Enum.shuffle()
    |> Map.new()
  end

  defp randomize_json(value) when is_list(value), do: Enum.map(value, &randomize_json/1)
  defp randomize_json(value), do: value

  defp shuffled_map(value), do: value |> Enum.shuffle() |> Map.new()
end
