defmodule Tightbeam.StateResourcesOrderedEncoderTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Firehose.{Publisher, Registry}
  alias Tightbeam.StateResources

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
      assert StateResources.encode_item(resource, item) == expected_bytes(resource, fields, item)
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
      item_bytes = StateResources.encode_item(row.resource, item)

      wire =
        Publisher.encode_wire_notice(%{
          "class" => row.class,
          "op" => row.op,
          "occurredAt" => 1,
          "refs" => %{},
          "payload" => item
        })

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

  test "legacy partial notices retain their current wire path until their serializer is R7-complete" do
    notice = %{
      "class" => "work_item.created",
      "op" => "upsert",
      "payload" => %{"id" => "wi_legacy", "rowVersion" => 1}
    }

    refute StateResources.complete_item?("work-items", notice["payload"])
    assert Publisher.encode_wire_notice(notice) == JSON.encode!(notice)
  end

  defp item(resource, fields) do
    Map.new(fields, fn field -> {field, value(resource, field)} end)
  end

  defp value("sessions", "overrides"),
    do: %{"guidanceExtra" => nil, "skillsAdd" => ["beta", "alpha"]}

  defp value("transcript messages", "attachments"),
    do: [%{"size" => 1, "filename" => "f", "mimeType" => "m", "assetId" => "a"}]

  defp value("transcript messages", "context"), do: opaque_json()

  defp value("attests", "commitRefs"),
    do: [%{"commit" => "c", "repo" => "r"}]

  defp value("decision requests", "options"), do: [%{"label" => "one"}]
  defp value("decision requests", "context"), do: opaque_json()
  defp value("identity", "sessionRevisions"), do: %{"z" => "2", "a" => "1"}

  defp value("kungfu", "documents"),
    do: [%{"sha256" => "s", "content" => "c", "path" => "p"}]

  defp value("transcript messages", "messageType"), do: "agent"
  defp value(_resource, field), do: field

  defp opaque_json, do: %{"b" => [%{"z" => 1, "a" => 2}], "a" => %{"z" => 2, "a" => 1}}

  defp expected_bytes(resource, fields, item) do
    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <> ":" <> expected_value(resource, field, Map.fetch!(item, field))
      end)

    "{" <> encoded <> "}"
  end

  defp expected_value("sessions", "overrides", _value),
    do: ~s({"skillsAdd":["beta","alpha"],"guidanceExtra":null})

  defp expected_value("transcript messages", "attachments", _value),
    do: ~s([{"assetId":"a","mimeType":"m","filename":"f","size":1}])

  defp expected_value("transcript messages", "context", _value), do: expected_opaque_json()

  defp expected_value("attests", "commitRefs", _value),
    do: ~s([{"repo":"r","commit":"c"}])

  defp expected_value("decision requests", "options", _value), do: ~s([{"label":"one"}])
  defp expected_value("decision requests", "context", _value), do: expected_opaque_json()
  defp expected_value("identity", "sessionRevisions", _value), do: ~s({"a":"1","z":"2"})

  defp expected_value("kungfu", "documents", _value),
    do: ~s([{"path":"p","content":"c","sha256":"s"}])

  defp expected_value(_resource, _field, value), do: JSON.encode!(value)

  defp expected_opaque_json, do: ~s({"a":{"a":1,"z":2},"b":[{"a":2,"z":1}]})
end
