defmodule Tightbeam.StateResources do
  @moduledoc """
  Canonical public item serializers shared by state reads and the firehose.

  Every resource enters the public wire through one named function here.
  Storage-secret field names are impossible to emit from this seam.
  """

  @fields ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion)
  @aliases %{
    root_archetype: "rootArchetype",
    installed_revision: "installedRevision",
    row_version: "rowVersion"
  }

  @secret_keys MapSet.new(["cliToken", "token", "identityToken"])

  @session_select """
  SELECT sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
         ownerUserId, origin, spawnedBy, handle, archetype, overrides,
         identityName, identityRevision, harness, provider, model,
         thinkingLevel, modelContext, host, clearedThroughSeq, state,
         createdAt, updatedAt, mechanicalStatus, updatedAt
  FROM sessions
  """

  @turn_select """
  SELECT t.seq, t.sessionKey, t.messageId, t.wakeId, t.origin, t.prompt,
         t.roleRef, t.roleFallback, t.assignmentId, t.jobRef, t.model, t.thinkingLevel,
         t.modelContext, t.harness, t.replyAttention, t.status, t.owner,
         t.adapterGen, t.requestRef, t.error, t.createdAt, t.startedAt,
         t.endedAt, t.publishedAt
  FROM turns AS t
  """

  @message_select """
  SELECT m.seq, m.id, m.sessionKey, m.role, m.messageType, m.content,
         m.timestamp, m.sender, m.deviceId, m.clientMessageId,
         m.replyToMessageId, m.replyToClientMessageId, m.llmVisibleMessageId,
         m.attachments, m.attentionTier,
         t.seq, t.assignmentId, t.jobRef, t.harness, t.model,
         t.thinkingLevel, t.modelContext
  FROM messages AS m
  LEFT JOIN turns AS t
    ON t.messageId = CASE m.role WHEN 'user' THEN m.id ELSE m.replyToMessageId END
  """

  alias Tightbeam.{
    AdminProjection,
    Artifacts,
    Assignments,
    DB,
    Devices,
    Identity,
    Harness,
    ModelCatalog,
    Org,
    ReadMarkers,
    StateVisibility,
    Wakes,
    WorkItems
  }

  alias Tightbeam.DB.Txn

  @admin_field_order %{
    "config" => ~w(key value updatedAt rowVersion),
    "host environment" => ~w(host harness name value valuePresent updatedAt rowVersion),
    "hosts" => ~w(host rowVersion),
    "users" => ~w(userId isAdmin createdAt rowVersion),
    "identity" => ~w(name liveRevision state sessionRevisions staleness conflicts rowVersion),
    "kungfu" =>
      ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion)
  }

  @item_field_order %{
    "work items" =>
      ~w(id title specRefName specRefSha256 isBug ownerUserId state failReason routingWakeId slateWakeId createdByUser createdBySession createdInTurnSeq createdContextKnown createdAt priority rowVersion),
    "assignments" =>
      ~w(id subject holderKey holderRole holderFallback openedByUser openedBySession openedAt state outcome closedAt closedByUser closedBySession closedByProcess closingAttestId revocationReason workItemId reviewsAssignmentId holderHarness holderProvider files effectKind derivedStatus rowVersion),
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

  @item_resource_aliases %{
    "work-items" => "work items",
    "decision-requests" => "decision requests",
    "read-markers" => "read markers",
    "messages" => "transcript messages",
    "condition-facts" => "condition facts",
    "critical-state" => "critical state"
  }

  # The normative R7/R7a value schema. Field order remains owned by
  # @item_field_order; these categories own JSON type and nullability.
  @item_wire_categories %{
    "work items" => %{
      strings:
        ~w(id title specRefName specRefSha256 ownerUserId state failReason routingWakeId slateWakeId createdByUser createdBySession),
      integers: ~w(createdInTurnSeq createdAt priority rowVersion),
      booleans: ~w(isBug createdContextKnown),
      nullable:
        ~w(specRefName specRefSha256 ownerUserId failReason routingWakeId slateWakeId createdByUser createdBySession createdInTurnSeq)
    },
    "assignments" => %{
      strings:
        ~w(id subject holderKey holderRole openedByUser openedBySession state outcome closedByUser closedBySession closedByProcess closingAttestId revocationReason workItemId reviewsAssignmentId holderHarness holderProvider effectKind derivedStatus),
      integers: ~w(openedAt closedAt rowVersion),
      booleans: ~w(holderFallback),
      nullable:
        ~w(holderRole openedByUser openedBySession outcome closedAt closedByUser closedBySession closedByProcess closingAttestId revocationReason workItemId reviewsAssignmentId holderHarness holderProvider)
    },
    "attests" => %{
      strings:
        ~w(id assignmentId kind verdictKind note bySession byUser producer producerCommand byHarness byProvider),
      integers: ~w(ts rowVersion),
      booleans: [],
      nullable:
        ~w(verdictKind note bySession byUser producer producerCommand byHarness byProvider commitRefs)
    },
    "wakes" => %{
      strings:
        ~w(wakeId sessionKey targetRole origin prompt consumer state reresolve reresolveSeed conditionKind conditionScope firedBy creatorSessionKey workItemId assignmentId class classElection deliveryRule),
      integers:
        ~w(dueAt createdAt firedAt reresolveRung conditionAfterId canceledAt targetGate rowVersion),
      booleans: ~w(rumination digest summon),
      nullable:
        ~w(targetRole prompt firedAt reresolve reresolveSeed reresolveRung conditionKind conditionScope conditionAfterId firedBy creatorSessionKey workItemId assignmentId canceledAt class classElection deliveryRule)
    },
    "turns" => %{
      strings:
        ~w(sessionKey messageId wakeId origin prompt roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness status owner requestRef error),
      integers:
        ~w(seq replyAttention adapterGen createdAt startedAt endedAt publishedAt rowVersion),
      booleans: [],
      nullable:
        ~w(messageId wakeId roleRef roleFallback assignmentId jobRef model thinkingLevel modelContext harness owner adapterGen requestRef error startedAt endedAt publishedAt)
    },
    "decision requests" => %{
      strings:
        ~w(id kind raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId deadlineWakeId statuteName question status decision rationale ruledBy withdrawnBy withdrawnReason askedOfRole answer answeredBy returnedBy returnReason),
      integers:
        ~w(lineageRung effortGeneration raisedAt deadlineAt ruledAt consumedAt withdrawnAt answeredAt returnedAt rowVersion),
      booleans: [],
      nullable:
        ~w(raiserId raiserSessionKey ownerUserId assignmentId expecterSessionKey expecterUserId deadlineWakeId statuteName decision rationale ruledBy ruledAt consumedAt withdrawnBy withdrawnReason withdrawnAt askedOfRole answer answeredBy answeredAt returnedBy returnReason returnedAt deadlineAt context)
    },
    "sessions" => %{
      strings:
        ~w(sessionKey displayName kind ownerUserId origin spawnedBy handle archetype identityName identityRevision harness provider model thinkingLevel modelContext host state mechanicalStatus),
      integers: ~w(orderIndex clearedThroughSeq createdAt updatedAt rowVersion),
      booleans: ~w(isBuiltIn adopted),
      nullable:
        ~w(ownerUserId spawnedBy handle identityName identityRevision provider model thinkingLevel modelContext host clearedThroughSeq overrides)
    },
    "roles" => %{
      strings: ~w(name boundSessionKey ownerUserId),
      integers: ~w(createdAt updatedAt rowVersion),
      booleans: [],
      nullable: ~w(boundSessionKey ownerUserId)
    },
    "users" => %{
      strings: ~w(userId),
      integers: ~w(createdAt rowVersion),
      booleans: ~w(isAdmin),
      nullable: []
    },
    "devices" => %{
      strings: ~w(deviceId userId claimedName status platform model),
      integers: ~w(createdAt rowVersion),
      booleans: [],
      nullable: ~w(claimedName platform model)
    },
    "artifacts" => %{
      strings:
        ~w(artifactId kind title description createdBySession workItemId parentSession originPath contentSha256 recordedMessageId recordedTurnEvidence state home),
      integers: ~w(createdAt updatedAt rowVersion),
      booleans: [],
      nullable: ~w(description parentSession contentSha256 recordedMessageId home)
    },
    "read markers" => %{
      strings: ~w(userId scopeKey marker),
      integers: ~w(updatedAt rowVersion),
      booleans: [],
      nullable: []
    },
    "transcript messages" => %{
      strings:
        ~w(id sessionKey role messageType content sender deviceId clientMessageId replyToMessageId replyToClientMessageId llmVisibleMessageId assignmentId jobRef harness provider model effort),
      integers: ~w(seq at attentionTier turnSeq rowVersion),
      booleans: [],
      nullable:
        ~w(sender deviceId clientMessageId replyToMessageId replyToClientMessageId assignmentId jobRef harness provider model effort turnSeq context)
    },
    "condition facts" => %{
      strings: ~w(kind scope origin),
      integers: ~w(id ts rowVersion),
      booleans: [],
      nullable: ~w(scope)
    },
    "critical state" => %{
      strings: ~w(sessionKey reason),
      integers: ~w(startedAt expiresAt hardDeadline updatedAt rowVersion),
      booleans: [],
      nullable: []
    },
    "config" => %{
      strings: ~w(key value),
      integers: ~w(updatedAt rowVersion),
      booleans: [],
      nullable: ~w(value)
    },
    "host environment" => %{
      strings: ~w(host harness name value),
      integers: ~w(updatedAt rowVersion),
      booleans: ~w(valuePresent),
      nullable: ~w(value)
    },
    "hosts" => %{
      strings: ~w(host),
      integers: ~w(rowVersion),
      booleans: [],
      nullable: []
    },
    "identity" => %{
      strings: ~w(name liveRevision state),
      integers: ~w(rowVersion),
      booleans: [],
      nullable: []
    },
    "kungfu" => %{
      strings: ~w(name purpose rootArchetype installedRevision status),
      integers: ~w(rowVersion),
      booleans: [],
      nullable: ~w(installedRevision)
    }
  }

  @item_complex_types %{
    {"assignments", "files"} => {:array, :string, :preserve},
    {"attests", "commitRefs"} => {:array, :commit_ref, :preserve},
    {"decision requests", "options"} => {:array, :decision_option, :preserve},
    {"decision requests", "context"} => :json,
    {"sessions", "overrides"} => :session_overrides,
    {"transcript messages", "attachments"} => {:array, :attachment, :preserve},
    {"transcript messages", "context"} => :json,
    {"identity", "sessionRevisions"} => :string_map,
    {"identity", "staleness"} => {:array, :string, :sort},
    {"identity", "conflicts"} => {:array, :string, :sort},
    {"kungfu", "phrases"} => {:array, :string, :sort},
    {"kungfu", "documents"} => {:array, :document, :sort_by_path}
  }

  @item_catalog_fields %{
    {"assignments", "holderHarness"} => :harness,
    {"assignments", "holderProvider"} => :provider,
    {"attests", "byHarness"} => :harness,
    {"attests", "byProvider"} => :provider,
    {"turns", "harness"} => :harness,
    {"turns", "model"} => :model,
    {"turns", "thinkingLevel"} => :effort,
    {"turns", "modelContext"} => :context,
    {"sessions", "harness"} => :harness,
    {"sessions", "provider"} => :provider,
    {"sessions", "model"} => :model,
    {"sessions", "thinkingLevel"} => :effort,
    {"sessions", "modelContext"} => :context,
    {"transcript messages", "harness"} => :harness,
    {"transcript messages", "provider"} => :provider,
    {"transcript messages", "model"} => :model,
    {"transcript messages", "effort"} => :effort,
    {"transcript messages", "context"} => :context,
    {"host environment", "harness"} => :harness
  }

  @item_catalog_selections %{
    "assignments" => %{harness: "holderHarness", provider: "holderProvider"},
    "attests" => %{harness: "byHarness", provider: "byProvider"},
    "turns" => %{
      harness: "harness",
      model: "model",
      effort: "thinkingLevel",
      context: "modelContext"
    },
    "sessions" => %{
      host: "host",
      harness: "harness",
      provider: "provider",
      model: "model",
      effort: "thinkingLevel",
      context: "modelContext"
    },
    "transcript messages" => %{
      harness: "harness",
      provider: "provider",
      model: "model",
      effort: "effort",
      context: "context"
    },
    "host environment" => %{host: "host", harness: "harness"}
  }

  @item_enums %{
    {"work items", "state"} => ~w(open iceboxed closed failed),
    {"assignments", "state"} => ~w(open closed),
    {"assignments", "outcome"} => ~w(completed surrendered revoked),
    {"attests", "kind"} => ~w(progress completion surrender verdict),
    {"wakes", "state"} => ~w(pending fired canceled),
    {"wakes", "reresolve"} => ~w(lineage),
    {"wakes", "firedBy"} => ~w(condition fallback),
    {"wakes", "classElection"} => ~w(sender classifier batcher),
    {"turns", "status"} => ~w(queued running delivered canceled failed failed_unknown),
    {"decision requests", "kind"} => ~w(statute effort agent),
    {"decision requests", "status"} =>
      ~w(open ruled consumed withdrawn superseded answered returned),
    {"sessions", "kind"} => ~w(main dm custom),
    {"sessions", "state"} => ~w(active retired),
    {"sessions", "mechanicalStatus"} => ~w(idle running),
    {"devices", "status"} => ~w(allowlisted pending denied),
    {"artifacts", "kind"} => ~w(spec report doc data other),
    {"artifacts", "recordedTurnEvidence"} => ~w(tool-call-observed session-concurrent none),
    {"artifacts", "state"} => ~w(in-workspace archived released),
    {"transcript messages", "role"} => ~w(user assistant),
    {"transcript messages", "attentionTier"} => [-1, 0, 1],
    {"identity", "state"} => ~w(ready relearn_conflicted),
    {"kungfu", "status"} => ~w(available installed)
  }

  def query_work_item(db, selection, call) do
    {id, filters} = if is_map(selection), do: {nil, selection}, else: {selection, %{}}
    {principal_kind, principal_id, is_admin} = detail_principal(call)
    principal = Map.get(call, :rest_principal)
    trace_core_detail(principal, {:au4_visibility, "work items"})

    rows =
      observed_query(
        db,
        principal,
        """
        SELECT wi.id, wi.title, wi.specRefName, wi.specRefSha256, wi.isBug,
               wi.ownerUserId, wi.state, wi.failReason, wi.routingWakeId,
               wi.slateWakeId, wi.createdByUser, wi.createdBySession,
               wi.createdInTurnSeq, wi.createdContextKnown, wi.createdAt,
               CASE WHEN p.workItemId IS NULL THEN
                 CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)
               ELSE p.priority END,
               COALESCE(v.rowVersion, wi.createdAt)
        FROM work_items AS wi
        LEFT JOIN work_item_versions AS v ON v.workItemId = wi.id
        LEFT JOIN work_item_priorities AS p ON p.workItemId = wi.id
        WHERE (?1 IS NULL OR wi.id = ?1) AND (
          ?2 = 1 OR
          (?3 = 'user' AND wi.ownerUserId = ?4) OR
          (?3 = 'session' AND (
            wi.createdBySession = ?4 OR EXISTS (
              SELECT 1 FROM assignments AS held
              WHERE held.workItemId = wi.id AND held.holderKey = ?4
            )
          ))
        )
        AND (?5 IS NULL OR wi.state = ?5)
        AND (?6 IS NULL OR wi.ownerUserId = ?6)
        AND (?7 IS NULL OR wi.createdBySession = ?7)
        AND (?8 IS NULL OR wi.createdByUser = ?8)
        AND (?9 IS NULL OR wi.isBug = ?9)
        AND (?10 IS NULL OR wi.specRefName = ?10)
        AND (?11 IS NULL OR EXISTS (
          SELECT 1 FROM assignments AS selected_holder
          WHERE selected_holder.workItemId = wi.id AND selected_holder.holderKey = ?11
        ))
        ORDER BY wi.createdAt, wi.id
        """,
        [
          id,
          bool_int(is_admin),
          principal_kind,
          principal_id,
          filters["state"],
          filters["ownerUserId"],
          filters["createdBySession"],
          filters["createdByUser"],
          filters["isBug"],
          filters["specRefName"],
          filters["holderKey"]
        ]
      )
      |> Enum.map(&work_item_query_row/1)

    if is_map(selection), do: rows, else: List.first(rows)
  end

  def query_assignment(db, id, call) do
    {principal_kind, principal_id, is_admin} = detail_principal(call)
    principal = Map.get(call, :rest_principal)
    trace_core_detail(principal, {:au4_visibility, "assignments"})

    case observed_query(
           db,
           principal,
           """
           SELECT a.id, a.subject, a.holderKey, a.holderRole, a.holderFallback,
                  a.openedByUser, a.openedBySession, a.openedAt, a.state, a.outcome,
                  a.closedAt, a.closedByUser, a.closedBySession, a.closedByProcess, a.closingAttestId,
                  (SELECT r.reason FROM assignment_revocation_generations g
                   JOIN assignment_revocations r ON r.id = g.revocationId
                   WHERE g.assignmentId = a.id AND g.reopeningId IS
                     (SELECT reopening.id FROM assignment_reopenings reopening
                      WHERE reopening.assignmentId = a.id ORDER BY reopening.id DESC LIMIT 1)),
                  a.workItemId, a.reviewsAssignmentId, a.holderHarness, a.holderProvider,
                  COALESCE(
                    (SELECT json_group_array(path) FROM (
                      SELECT path FROM assignment_files
                      WHERE assignmentId = a.id ORDER BY path
                    )),
                    '[]'
                  ),
                  COALESCE(
                    (SELECT effectKind FROM assignment_effects WHERE assignmentId = a.id),
                    CASE WHEN a.reviewsAssignmentId IS NULL THEN 'code' ELSE 'review' END
                  ),
                  CASE
                    WHEN a.state = 'closed' AND a.outcome IN ('surrendered','revoked') THEN 'abandoned'
                    WHEN a.state = 'closed' AND a.outcome = 'completed' AND EXISTS (
                      SELECT 1 FROM attests AS verdict
                      WHERE verdict.assignmentId = a.id AND verdict.kind = 'verdict'
                        AND verdict.verdictKind = 'verified'
                    ) THEN 'verified'
                    WHEN a.state = 'closed' AND a.outcome = 'completed' THEN 'claims-done'
                    WHEN a.state = 'open' AND (
                      SELECT state FROM sessions WHERE sessionKey = a.holderKey
                    ) = 'retired' THEN 'stranded'
                    WHEN a.state = 'open' AND NOT EXISTS (
                      SELECT 1 FROM attests AS filed WHERE filed.assignmentId = a.id
                    ) THEN 'open'
                    ELSE 'active'
                  END
           FROM assignments AS a
           LEFT JOIN work_items AS wi ON wi.id = a.workItemId
           WHERE a.id = ?1 AND (
             ?2 = 1 OR
             (?3 = 'session' AND (a.holderKey = ?4 OR a.openedBySession = ?4)) OR
             (?3 = 'user' AND (wi.ownerUserId = ?4 OR a.openedByUser = ?4))
           )
           """,
           [id, bool_int(is_admin), principal_kind, principal_id]
         ) do
      [row] -> assignment_query_row(row)
      [] -> nil
    end
  end

  def query_wake(db, %{key: id, principal: principal}) do
    detail_selection(db, "wakes", principal, &Wakes.get_in_txn(&1, id))
  end

  def query_wake(db, id), do: Wakes.get(db, id)

  def query_session(
        db,
        %{key: id, principal: %{kind: kind, id: principal_id, is_admin: is_admin} = principal}
      )
      when is_binary(id) and kind in ["user", "session"] and is_binary(principal_id) and
             is_boolean(is_admin) do
    trace_core_detail(principal, {:au4_visibility, "sessions"})

    case observed_query(
           db,
           principal,
           @session_select <>
             """
              WHERE sessionKey = ?1 AND (
                ?2 = 1 OR
                (?3 = 'session' AND sessionKey = ?4) OR
                (?3 = 'user' AND ownerUserId = ?4)
              )
             """,
           [id, if(is_admin, do: 1, else: 0), kind, principal_id]
         ) do
      [row] -> session_query_row(row)
      [] -> nil
    end
  end

  def query_session(db, id) when is_binary(id) do
    case query(db, @session_select <> " WHERE sessionKey = ?1", [id]) do
      [row] -> session_query_row(row)
      [] -> nil
    end
  end

  defp session_query_row([
         session_key,
         display_name,
         kind,
         order_index,
         is_built_in,
         adopted,
         owner_user_id,
         origin,
         spawned_by,
         handle,
         archetype,
         overrides,
         identity_name,
         identity_revision,
         harness,
         provider,
         model,
         thinking_level,
         model_context,
         host,
         cleared_through_seq,
         state,
         created_at,
         updated_at,
         mechanical_status,
         row_version
       ]) do
    %{
      session_key: session_key,
      display_name: display_name,
      kind: kind,
      order_index: order_index,
      is_built_in: is_built_in == 1,
      adopted: adopted == 1,
      owner_user_id: owner_user_id,
      origin: origin,
      spawned_by: spawned_by,
      handle: handle,
      archetype: archetype,
      overrides: if(is_binary(overrides), do: JSON.decode!(overrides), else: overrides),
      identity_name: identity_name,
      identity_revision: identity_revision,
      harness: harness,
      provider: provider,
      model: model,
      thinking_level: thinking_level,
      model_context: model_context,
      host: host,
      cleared_through_seq: cleared_through_seq,
      state: state,
      created_at: created_at,
      updated_at: updated_at,
      mechanical_status: mechanical_status,
      row_version: row_version
    }
  end

  def query_role(db, id) do
    case Tightbeam.DB.query(
           db,
           "SELECT name, boundSessionKey, ownerUserId, createdAt, updatedAt FROM roles WHERE name = ?1",
           [id]
         ) do
      {:ok, [[name, bound_session_key, owner_user_id, created_at, updated_at]]} ->
        %{
          name: name,
          bound_session_key: bound_session_key,
          owner_user_id: owner_user_id,
          created_at: created_at,
          updated_at: updated_at
        }

      {:ok, []} ->
        nil
    end
  end

  def query_artifact(db, %{key: id, principal: principal}) do
    detail_selection(db, "artifacts", principal, &Artifacts.canonical_in_txn(&1, id))
  end

  def query_artifact(%Txn{} = txn, id), do: Artifacts.canonical_in_txn(txn, id)

  def query_artifact(db, id) do
    case DB.transaction(db, &Artifacts.canonical_in_txn(&1, id)) do
      {:ok, row} -> row
      {:error, error} -> raise error
    end
  end

  def query_attest(db, id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, kind, verdictKind, note, bySession, byUser,
               producer, producerCommand, byHarness, byProvider, commitRefs, ts
        FROM attests WHERE id = ?1
        """,
        [id]
      )

    case rows do
      [
        [
          id,
          assignment_id,
          kind,
          verdict_kind,
          note,
          by_session,
          by_user,
          producer,
          producer_command,
          by_harness,
          by_provider,
          commit_refs,
          ts
        ]
      ] ->
        %{
          id: id,
          assignment_id: assignment_id,
          kind: kind,
          verdict_kind: verdict_kind,
          note: note,
          by_session: by_session,
          by_user: by_user,
          producer: producer,
          producer_command: producer_command,
          by_harness: by_harness,
          by_provider: by_provider,
          commit_refs: if(is_binary(commit_refs), do: JSON.decode!(commit_refs), else: nil),
          ts: ts
        }

      [] ->
        nil
    end
  end

  def query_condition_fact(db, id) do
    {:ok, rows} =
      DB.query(db, "SELECT id, ts, kind, scope, origin FROM condition_facts WHERE id = ?1", [id])

    case rows do
      [[fact_id, ts, kind, scope, origin]] ->
        %{fact_id: fact_id, ts: ts, kind: kind, scope: scope, origin: origin}

      [] ->
        nil
    end
  end

  # This is the same pinned relationship the transcript reader uses: the user
  # message owns the turn and an assistant message points back to it. The
  # production enqueue path is the sole turn-bearing writer, so one message
  # resolves to zero or one turn. Refuse duplicate dirt instead of selecting a
  # row by timing or count.
  def query_message(source, id) do
    case query(source, @message_select <> " WHERE m.id = ?1", [id]) do
      [row] -> message_row(row)
      [] -> nil
      _rows -> raise ArgumentError, "transcript message resolves to more than one turn"
    end
  end

  def query_device(db, %{key: id, principal: principal}) do
    detail_selection(db, "devices", principal, &Devices.detail_in_txn(&1, id))
  end

  def query_device(db, id) do
    case Devices.by_id(db, id) do
      nil -> nil
      device -> Map.put(device, :row_version, Devices.version(db, id) || device.created_at)
    end
  end

  @doc "Canonical config detail query; accepts the DB owner or its live transaction."
  def query_config(source, key) do
    case query(
           source,
           """
           SELECT s.key, s.value, s.updatedAt, v.rowVersion
           FROM org_settings AS s
           JOIN admin_projection_versions AS v
             ON v.resource = 'config' AND v.primaryKey = s.key
           WHERE s.key = ?1
           """,
           [key]
         ) do
      [[row_key, value, updated_at, row_version]] ->
        %{
          key: row_key,
          value: if(row_key == "default-archetype", do: value, else: nil),
          updated_at: updated_at,
          row_version: row_version
        }

      [] ->
        nil
    end
  end

  @doc "Canonical host-environment detail query. It never selects the secret value table."
  def query_host_environment(source, filters) when is_map(filters) do
    host = filters[:host] || filters["host"]
    harness = filters[:harness] || filters["harness"]
    name = filters[:name] || filters["name"]

    {where, params} =
      [
        {"host", host},
        {"harness", harness},
        {"name", name}
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{field, value}, index}, params ->
        {"#{field} = ?#{index}", params ++ [value]}
      end)
      |> then(fn {clauses, params} ->
        suffix = if clauses == [], do: "", else: " WHERE " <> Enum.join(clauses, " AND ")
        {suffix, params}
      end)

    query(
      source,
      """
      SELECT host, harness, name, valuePresent, updatedAt, rowVersion
      FROM host_environment_projection#{where}
      ORDER BY host, harness, name
      """,
      params
    )
    |> Enum.map(fn [row_host, row_harness, row_name, value_present, updated_at, row_version] ->
      %{
        host: row_host,
        harness: row_harness,
        name: row_name,
        value: nil,
        value_present: value_present == 1,
        updated_at: updated_at,
        row_version: row_version
      }
    end)
  end

  def query_host_environment(source, host, harness, name) do
    case query(
           source,
           """
           SELECT host, harness, name, valuePresent, updatedAt, rowVersion
           FROM host_environment_projection
           WHERE host = ?1 AND harness = ?2 AND name = ?3
           """,
           [host, harness, name]
         ) do
      [[row_host, row_harness, row_name, value_present, updated_at, row_version]] ->
        %{
          host: row_host,
          harness: row_harness,
          name: row_name,
          value: nil,
          value_present: value_present == 1,
          updated_at: updated_at,
          row_version: row_version
        }

      [] ->
        nil
    end
  end

  @doc "Canonical host detail query. No connection or filesystem field is selected."
  def query_host(source, host) do
    case query(
           source,
           """
           SELECT h.name, v.rowVersion
           FROM hosts AS h
           JOIN admin_projection_versions AS v
             ON v.resource = 'hosts' AND v.primaryKey = h.name
           WHERE h.name = ?1
           """,
           [host]
         ) do
      [[name, row_version]] -> %{host: name, row_version: row_version}
      [] -> nil
    end
  end

  @doc "Canonical user detail query shared by user.added and user.promoted."
  def query_user(source, id) do
    case query(
           source,
           """
           SELECT u.userId, u.isAdmin, u.createdAt, v.rowVersion
           FROM users AS u
           JOIN admin_projection_versions AS v
             ON v.resource = 'users' AND v.primaryKey = u.userId
           WHERE u.userId = ?1
           """,
           [id]
         ) do
      [[user_id, is_admin, created_at, row_version]] ->
        %{
          user_id: user_id,
          is_admin: is_admin == 1,
          created_at: created_at,
          row_version: row_version
        }

      [] ->
        nil
    end
  end

  @doc "Canonical served-identity detail query. Only a committed stamp is readable."
  def query_identity(source, "served"),
    do: AdminProjection.stamped_item(source, "identity", "served")

  def query_identity(_source, _name), do: nil

  @doc "Canonical kungfu detail query. Only a committed stamp is readable."
  def query_kungfu(source, name), do: AdminProjection.stamped_item(source, "kungfu", name)

  @doc false
  def identity_snapshot(db, base_dir) do
    status = Identity.status(base_dir)
    live = status.live_revision

    session_revisions =
      db
      |> Org.list_for_user("", true)
      |> Enum.flat_map(fn session ->
        if is_binary(session.identity_revision),
          do: [{session.session_key, session.identity_revision}],
          else: []
      end)
      |> Map.new()

    %{
      "name" => "served",
      "liveRevision" => live,
      "state" => state_name(status.state),
      "sessionRevisions" => session_revisions,
      "staleness" =>
        session_revisions
        |> Enum.flat_map(fn {session_key, revision} ->
          if revision == live, do: [], else: [session_key]
        end)
        |> Enum.sort(),
      "conflicts" => Enum.sort(status.conflicting_paths)
    }
  end

  @doc false
  def kungfu_snapshot(base_dir, name), do: Identity.public_kungfu(base_dir, name)

  @doc false
  def kungfu_names(base_dir), do: Identity.public_kungfu_names(base_dir)

  def query_read_marker(db, %{key: scope_key, principal: principal}, _opts) do
    user_id = if principal.kind == "user", do: principal.id, else: nil

    detail_selection(db, "read markers", principal, fn txn ->
      ReadMarkers.get_in_txn(txn, user_id, scope_key)
    end)
  end

  def query_read_marker(db, user_id, scope_key), do: ReadMarkers.get(db, user_id, scope_key)
  def query_critical_state(db, session_key), do: Tightbeam.CriticalLeases.get(db, session_key)

  def query_production(db, seq) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        """
        SELECT seq, at, jobRef, assignmentId, sessionKey, kind, detail
        FROM causal_events WHERE seq = ?1 AND kind = 'prod_fired'
        """,
        [seq]
      )

    case rows do
      [[event_seq, at, job_ref, assignment_id, session_key, kind, detail]] ->
        %{
          seq: event_seq,
          at: at,
          job_ref: job_ref,
          assignment_id: assignment_id,
          session_key: session_key,
          kind: kind,
          detail: JSON.decode!(detail)
        }

      [] ->
        nil
    end
  end

  def query_turn(db, session_key, message_id) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        @turn_select <>
          """
          LEFT JOIN messages AS m ON m.id = t.messageId
          WHERE t.sessionKey = ?1 AND (t.messageId = ?2 OR m.clientMessageId = ?2)
          ORDER BY t.seq DESC LIMIT 1
          """,
        [session_key, message_id]
      )

    case rows do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  def query_turn_in_txn(txn, seq) do
    case Tightbeam.DB.Txn.q(txn, @turn_select <> " WHERE t.seq = ?1", [seq]) do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  def query_turn_by_seq(db, %{key: seq, principal: principal}) do
    detail_selection(db, "turns", principal, &query_turn_in_txn(&1, seq))
  end

  def query_turn_by_seq(db, seq) do
    case DB.transaction(db, &query_turn_in_txn(&1, seq)) do
      {:ok, row} -> row
      {:error, error} -> raise error
    end
  end

  def query_decision_request(db, %{key: id, principal: principal}) do
    detail_selection(db, "decision requests", principal, fn txn ->
      txn
      |> Tightbeam.Escalation.raw_by_id_in_txn(id)
      |> decision_request_query_row()
    end)
  end

  def query_decision_request(db, id) do
    db |> Tightbeam.Escalation.raw_by_id(id) |> decision_request_query_row()
  end

  defp decision_request_query_row(nil), do: nil

  defp decision_request_query_row(row) do
    row =
      Map.drop(row, [
        :action_key,
        :ruled_via_session_key,
        :ruled_via_principal,
        :ruled_via_session_state,
        :ruling_fact_id,
        :park_wake_id
      ])

    row =
      if value(row, :kind) == "agent",
        do: row,
        else: Map.drop(row, [:returned_by, :return_reason, :returned_at])

    row
  end

  defp detail_principal(%{rest_principal: %{kind: kind, id: id, is_admin: is_admin}}),
    do: {kind, id, is_admin}

  defp detail_principal(%{principal: {:user, id}}), do: {"user", id, false}
  defp detail_principal(%{principal: {:session, id}}), do: {"session", id, false}
  defp detail_principal(%{principal: {:remedy, %{owner: id}}}), do: {"user", id, false}

  defp work_item_query_row([
         id,
         title,
         spec_ref_name,
         spec_ref_sha256,
         is_bug,
         owner_user_id,
         state,
         fail_reason,
         routing_wake_id,
         slate_wake_id,
         created_by_user,
         created_by_session,
         created_in_turn_seq,
         created_context_known,
         created_at,
         priority,
         row_version
       ]) do
    %{
      id: id,
      title: title,
      spec_ref_name: spec_ref_name,
      spec_ref_sha256: spec_ref_sha256,
      is_bug: is_bug == 1,
      owner_user_id: owner_user_id,
      state: state,
      fail_reason: fail_reason,
      routing_wake_id: routing_wake_id,
      slate_wake_id: slate_wake_id,
      created_by_user: created_by_user,
      created_by_session: created_by_session,
      created_in_turn_seq: created_in_turn_seq,
      created_context_known: created_context_known == 1,
      created_at: created_at,
      priority: priority,
      row_version: row_version
    }
  end

  defp assignment_query_row([
         id,
         subject,
         holder_key,
         holder_role,
         holder_fallback,
         opened_by_user,
         opened_by_session,
         opened_at,
         state,
         outcome,
         closed_at,
         closed_by_user,
         closed_by_session,
         closed_by_process,
         closing_attest_id,
         revocation_reason,
         work_item_id,
         reviews_assignment_id,
         holder_harness,
         holder_provider,
         files,
         effect_kind,
         derived_status
       ]) do
    %{
      id: id,
      subject: subject,
      holder_key: holder_key,
      holder_role: holder_role,
      holder_fallback: holder_fallback == 1,
      opened_by_user: opened_by_user,
      opened_by_session: opened_by_session,
      opened_at: opened_at,
      state: state,
      outcome: outcome,
      closed_at: closed_at,
      closed_by_user: closed_by_user,
      closed_by_session: closed_by_session,
      closed_by_process: closed_by_process,
      closing_attest_id: closing_attest_id,
      revocation_reason: revocation_reason,
      work_item_id: work_item_id,
      reviews_assignment_id: reviews_assignment_id,
      holder_harness: holder_harness,
      holder_provider: holder_provider,
      files: JSON.decode!(files),
      effect_kind: effect_kind,
      derived_status: derived_status
    }
  end

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

  defp trace_core_detail(%{core_detail_trace: nil}, _event), do: :ok

  defp trace_core_detail(%{core_detail_trace: pid}, event) when is_pid(pid) do
    send(pid, {:core_detail_trace, event})
    :ok
  end

  defp trace_core_detail(%{core_detail_trace: trace}, event) when is_function(trace, 1) do
    trace.(event)
    :ok
  end

  defp trace_core_detail(_principal, _event), do: :ok

  defp observed_query(%Txn{} = txn, principal, sql, params) do
    txn
    |> Txn.observe_queries(principal_trace(principal))
    |> query(sql, params)
  end

  defp observed_query(db, principal, sql, params) do
    case DB.transaction(db, fn txn ->
           txn
           |> Txn.observe_queries(principal_trace(principal))
           |> query(sql, params)
         end) do
      {:ok, rows} -> rows
      {:error, error} -> raise error
    end
  end

  defp principal_trace(principal) when is_map(principal),
    do: Map.get(principal, :core_detail_trace)

  defp principal_trace(_principal), do: nil

  defp detail_selection(db, resource, principal, lookup) do
    case DB.transaction(db, fn txn ->
           txn = Txn.observe_queries(txn, Map.get(principal, :core_detail_trace))
           row = lookup.(txn)

           if StateVisibility.core_detail_visible?(txn, resource, row, principal),
             do: row,
             else: nil
         end) do
      {:ok, row} -> row
      {:error, error} -> raise error
    end
  end

  def work_item(row), do: public(row)
  def assignment(row), do: public(row)

  def attest(row) do
    reject_public_shape_drift!(row, "attests")
    row |> public() |> closed_projection("attests")
  end

  def wake(nil), do: nil

  def wake(row) do
    reject_public_shape_drift!(row, "wakes")
    row |> public() |> closed_projection("wakes")
  end

  def production(row), do: row |> public() |> correlate("eventId", "seq")

  def turn(row) do
    case value(row, :prompt) do
      prompt when is_binary(prompt) ->
        row = public(row)

        role_fallback =
          case row["roleFallback"] do
            0 -> nil
            1 -> "owner"
            _invalid -> raise ArgumentError, "roleFallback is projection_invalid"
          end

        row |> Map.put("roleFallback", role_fallback) |> closed_projection("turns")

      _other ->
        raise ArgumentError, "prompt must be a string"
    end
  end

  def decision_request(%{kind: "operator"} = row), do: public(row)
  def decision_request(row), do: decision_request_projection(row)

  def session(row) do
    reject_public_shape_drift!(row, "sessions")

    row = row |> session_wire_overrides() |> session_model_selection()

    exact!(
      "sessions",
      %{
        "sessionKey" => session_wire_value!(row, :session_key, "sessionKey"),
        "displayName" => session_wire_value!(row, :display_name, "displayName"),
        "kind" => session_wire_value!(row, :kind, "kind"),
        "orderIndex" => session_wire_value!(row, :order_index, "orderIndex"),
        "isBuiltIn" => session_wire_value!(row, :is_built_in, "isBuiltIn"),
        "adopted" => session_wire_value!(row, :adopted, "adopted"),
        "ownerUserId" => session_wire_value!(row, :owner_user_id, "ownerUserId"),
        "origin" => session_wire_value!(row, :origin, "origin"),
        "spawnedBy" => session_wire_value!(row, :spawned_by, "spawnedBy"),
        "handle" => session_wire_value!(row, :handle, "handle"),
        "archetype" => session_wire_value!(row, :archetype, "archetype"),
        "overrides" => session_wire_value!(row, :overrides, "overrides"),
        "identityName" => session_wire_value!(row, :identity_name, "identityName"),
        "identityRevision" => session_wire_value!(row, :identity_revision, "identityRevision"),
        "harness" => session_wire_value!(row, :harness, "harness"),
        "provider" => session_wire_value!(row, :provider, "provider"),
        "model" => session_wire_value!(row, :model, "model"),
        "thinkingLevel" => session_wire_value!(row, :thinking_level, "thinkingLevel"),
        "modelContext" => session_wire_value!(row, :model_context, "modelContext"),
        "host" => session_wire_value!(row, :host, "host"),
        "clearedThroughSeq" =>
          session_wire_value!(row, :cleared_through_seq, "clearedThroughSeq"),
        "state" => session_wire_value!(row, :state, "state"),
        "createdAt" => session_wire_value!(row, :created_at, "createdAt"),
        "updatedAt" => session_wire_value!(row, :updated_at, "updatedAt"),
        "mechanicalStatus" => session_wire_value!(row, :mechanical_status, "mechanicalStatus"),
        "rowVersion" => session_wire_value!(row, :row_version, "rowVersion")
      }
    )
  end

  def role(row), do: row |> public() |> correlate("role", "name")

  def artifact(row) do
    reject_public_shape_drift!(row, "artifacts")
    version = value(row, :row_version)

    unless is_integer(version) and version > 0,
      do: raise(ArgumentError, "artifact rowVersion is projection_invalid")

    row |> public() |> closed_projection("artifacts")
  end

  def message(row) do
    stored_type = value(row, :message_type)
    message_type = nullable_string!(stored_type, "messageType")

    item =
      %{
        "id" => required_string!(row, :id),
        "seq" => required_integer!(row, :seq),
        "sessionKey" => required_string!(row, :session_key),
        "role" => required_string!(row, :role),
        "messageType" => message_type,
        "content" => required_wire_string!(value(row, :content), "content"),
        "at" => message_at!(row),
        "sender" => nullable_string!(value(row, :sender), "sender"),
        "deviceId" => nullable_string!(value(row, :device_id), "deviceId"),
        "clientMessageId" => nullable_string!(value(row, :client_message_id), "clientMessageId"),
        "replyToMessageId" =>
          nullable_string!(value(row, :reply_to_message_id), "replyToMessageId"),
        "replyToClientMessageId" =>
          nullable_string!(value(row, :reply_to_client_message_id), "replyToClientMessageId"),
        "llmVisibleMessageId" => required_string!(row, :llm_visible_message_id),
        "attachments" => required_list!(value(row, :attachments), "attachments"),
        "attentionTier" => required_integer!(row, :attention_tier),
        "turnSeq" => nullable_integer!(value(row, :turn_seq), "turnSeq"),
        "assignmentId" => nullable_string!(value(row, :assignment_id), "assignmentId"),
        "jobRef" => nullable_string!(value(row, :job_ref), "jobRef"),
        "harness" => nullable_string!(value(row, :harness), "harness"),
        "provider" => message_provider(row),
        "model" => nullable_string!(value(row, :model), "model"),
        "effort" => message_effort(row),
        "context" => message_context(row),
        "rowVersion" => message_row_version!(row)
      }

    item = if is_nil(message_type), do: Map.delete(item, "messageType"), else: item
    exact!("transcript messages", item)
  end

  def condition_fact(row) do
    fields = ~w(factId ts kind scope origin rowVersion)

    if Enum.all?(Map.keys(row), &is_binary/1) do
      exact_item_keys!("condition-facts notice", row, fields)
    end

    row = public(row)
    fact_id = row["factId"] || row["id"]

    item =
      row
      |> Map.put_new("factId", fact_id)
      |> Map.put("rowVersion", fact_id)
      |> Map.take(fields)

    exact_item_keys!("condition-facts notice", item, fields)
    item
  end

  def critical_state(row), do: public(row)

  def device(row) do
    row = row |> public() |> Map.delete("isAdmin")
    device_id = row["deviceId"] || row["id"]
    row |> Map.put("deviceId", device_id) |> Map.delete("id")
  end

  @doc "Closed config serializer."
  def config(row) do
    reject_public_shape_drift!(row, "config")

    exact!(
      "config",
      %{
        "key" => required_string!(row, :key),
        "value" => nullable_string!(value(row, :value), "value"),
        "updatedAt" => required_integer!(row, :updated_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed, value-free host-environment serializer."
  def host_environment(row) do
    reject_public_shape_drift!(row, "host environment")

    exact!(
      "host environment",
      %{
        "host" => required_string!(row, :host),
        "harness" => required_string!(row, :harness),
        "name" => required_string!(row, :name),
        "value" => nil,
        "valuePresent" => required_boolean!(row, :value_present),
        "updatedAt" => required_integer!(row, :updated_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed host serializer."
  def host(row) do
    reject_public_shape_drift!(row, "hosts")

    exact!(
      "hosts",
      %{"host" => required_string!(row, :host), "rowVersion" => required_version!(row)}
    )
  end

  @doc "Closed user serializer shared by user.added and user.promoted."
  def user(row) do
    reject_public_shape_drift!(row, "users")

    exact!(
      "users",
      %{
        "userId" => required_string!(row, :user_id),
        "isAdmin" => required_boolean!(row, :is_admin),
        "createdAt" => required_integer!(row, :created_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed served-identity serializer."
  def identity(row) do
    reject_public_shape_drift!(row, "identity")
    state = required_string!(row, :state)

    unless state in ~w(ready relearn_conflicted) do
      raise ArgumentError, "identity state must be ready or relearn_conflicted"
    end

    exact!(
      "identity",
      %{
        "name" => required_string!(row, :name),
        "liveRevision" => required_string!(row, :live_revision),
        "state" => state,
        "sessionRevisions" => sorted_string_map!(value(row, :session_revisions)),
        "staleness" => sorted_strings!(value(row, :staleness), "staleness"),
        "conflicts" => sorted_strings!(value(row, :conflicts), "conflicts"),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed raw-byte kungfu serializer with exact served-content hashes."
  def kungfu(row) when is_map(row) do
    row = normalize(row)

    valid =
      Enum.sort(Map.keys(row)) == Enum.sort(@fields) and
        Enum.all?(~w(name purpose rootArchetype), &nonempty?(row[&1])) and
        row["status"] in ~w(available installed) and
        (is_nil(row["installedRevision"]) or nonempty?(row["installedRevision"])) and
        is_integer(row["rowVersion"]) and row["rowVersion"] > 0 and
        is_list(row["phrases"]) and Enum.all?(row["phrases"], &nonempty?/1) and
        is_list(row["documents"]) and Enum.all?(row["documents"], &document?/1)

    unless valid, do: raise(ArgumentError, "invalid kungfu projection shape")
    documents = Enum.map(row["documents"], &normalize/1)

    unless Enum.uniq_by(documents, & &1["path"]) == documents,
      do: raise(ArgumentError, "invalid kungfu projection shape")

    Map.put(row, "documents", documents)
  end

  def kungfu(_), do: raise(ArgumentError, "invalid kungfu projection shape")

  defp normalize(row) do
    Enum.reduce(row, %{}, fn {key, value}, acc ->
      key = Map.get(@aliases, key, if(is_atom(key), do: Atom.to_string(key), else: key))
      if Map.has_key?(acc, key), do: raise(ArgumentError, "invalid kungfu projection shape")
      Map.put(acc, key, value)
    end)
  end

  defp document?(document) when is_map(document) do
    document = normalize(document)

    Enum.sort(Map.keys(document)) == ~w(content path sha256) and
      document["path"] in ~w(README.md capabilities.md preferred-models.md) and
      is_binary(document["content"]) and
      document["sha256"] ==
        :crypto.hash(:sha256, document["content"]) |> Base.encode16(case: :lower)
  end

  defp document?(_), do: false
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  @doc "Encode one rebuildable R7/R7a item in its ruled order with compact UTF-8 JSON."
  def encode_item(resource, item) when is_binary(resource) and is_map(item) do
    encode_item(resource, item, served_catalog(resource, item))
  end

  @doc "Encode one item against an already-served model-catalog snapshot."
  def encode_item(resource, item, catalog)
      when is_binary(resource) and is_map(item) and is_map(catalog) do
    resource = Map.get(@item_resource_aliases, resource, resource)
    fields = Map.fetch!(@item_field_order, resource)
    fields = conditional_fields!(resource, fields, item)
    exact_item_keys!(resource, item, fields)
    validate_item_values!(resource, item, fields, catalog)

    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <>
          ":" <> encode_item_field(resource, field, Map.fetch!(item, field))
      end)

    "{" <> encoded <> "}"
  end

  @doc false
  def item_shape_complete?(resource, item) when is_binary(resource) and is_map(item) do
    resource = Map.get(@item_resource_aliases, resource, resource)

    case Map.fetch(@item_field_order, resource) do
      {:ok, fields} ->
        fields = conditional_fields!(resource, fields, item)
        Enum.sort(Map.keys(item)) == Enum.sort(fields)

      :error ->
        false
    end
  end

  @doc false
  def item_has_secret_fields?(item) when is_map(item) do
    Enum.any?(item, fn {key, value} ->
      MapSet.member?(@secret_keys, key) or item_has_secret_fields?(value)
    end)
  end

  def item_has_secret_fields?(items) when is_list(items),
    do: Enum.any?(items, &item_has_secret_fields?/1)

  def item_has_secret_fields?(_value), do: false

  defp conditional_fields!("decision requests", fields, %{"kind" => "agent"}) do
    List.insert_at(fields, Enum.find_index(fields, &(&1 == "rowVersion")), "returnedBy")
    |> then(
      &List.insert_at(
        &1,
        Enum.find_index(&1, fn field -> field == "rowVersion" end),
        "returnReason"
      )
    )
    |> then(
      &List.insert_at(
        &1,
        Enum.find_index(&1, fn field -> field == "rowVersion" end),
        "returnedAt"
      )
    )
  end

  defp conditional_fields!("transcript messages", fields, item) do
    case Map.fetch(item, "messageType") do
      {:ok, value} when is_binary(value) ->
        fields

      {:ok, _value} ->
        raise ArgumentError, "messageType must be a string when present"

      :error ->
        List.delete(fields, "messageType")
    end
  end

  defp conditional_fields!(_resource, fields, _item), do: fields

  defp exact_item_keys!(resource, item, fields) do
    unless Enum.sort(Map.keys(item)) == Enum.sort(fields) do
      raise ArgumentError, "#{resource} item has an extra or missing field"
    end
  end

  defp validate_item_values!(resource, item, fields, catalog) do
    Enum.each(fields, fn field ->
      validate_wire_value!(
        Map.fetch!(item, field),
        item_field_type!(resource, field),
        "#{resource}.#{field}"
      )
    end)

    validate_item_relationships!(resource, item, catalog)
  end

  defp item_field_type!(resource, field) do
    category = Map.fetch!(@item_wire_categories, resource)

    type =
      cond do
        field == "rowVersion" ->
          :positive_integer

        resource == "condition facts" and field == "id" ->
          :positive_integer

        type = Map.get(@item_complex_types, {resource, field}) ->
          type

        catalog_field = Map.get(@item_catalog_fields, {resource, field}) ->
          {:catalog, catalog_field}

        values = Map.get(@item_enums, {resource, field}) ->
          {:enum, values}

        field in category.strings ->
          :string

        field in category.integers ->
          :integer

        field in category.booleans ->
          :boolean

        true ->
          raise ArgumentError, "#{resource}.#{field} has no normative wire type"
      end

    if field in category.nullable, do: {:nullable, type}, else: type
  end

  defp validate_wire_value!(nil, {:nullable, _type}, _label), do: :ok

  defp validate_wire_value!(value, {:nullable, type}, label),
    do: validate_wire_value!(value, type, label)

  defp validate_wire_value!(value, :string, _label) when is_binary(value), do: :ok
  defp validate_wire_value!(value, :integer, _label) when is_integer(value), do: :ok

  defp validate_wire_value!(value, :positive_integer, _label)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_wire_value!(value, :boolean, _label) when is_boolean(value), do: :ok
  defp validate_wire_value!(value, {:catalog, _field}, _label) when is_binary(value), do: :ok

  defp validate_wire_value!(value, {:enum, values}, label) do
    if value in values,
      do: :ok,
      else: raise(ArgumentError, "#{label} is outside its normative enum domain")
  end

  defp validate_wire_value!(value, {:array, type, _order}, label) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {item, index} ->
      validate_wire_value!(item, type, "#{label}[#{index}]")
    end)
  end

  defp validate_wire_value!(value, :session_overrides, label) do
    validate_closed_wire_object!(
      value,
      %{
        "skillsAdd" => {:array, :string, :sort},
        "guidanceExtra" => {:nullable, :string}
      },
      label
    )
  end

  defp validate_wire_value!(value, :attachment, label) do
    validate_closed_wire_object!(
      value,
      %{"assetId" => :string, "mimeType" => :string, "filename" => :string, "size" => :integer},
      label
    )
  end

  defp validate_wire_value!(value, :commit_ref, label) do
    validate_closed_wire_object!(value, %{"repo" => :string, "commit" => :string}, label)
  end

  defp validate_wire_value!(value, :decision_option, label) do
    validate_closed_wire_object!(value, %{"label" => :string}, label)
  end

  defp validate_wire_value!(value, :document, label) do
    validate_closed_wire_object!(
      value,
      %{"path" => :string, "content" => :string, "sha256" => :string},
      label
    )
  end

  defp validate_wire_value!(value, :string_map, label) when is_map(value) do
    unless Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end) do
      raise ArgumentError, "#{label} must be a string-to-string map"
    end

    :ok
  end

  defp validate_wire_value!(value, :json, label), do: validate_json_value!(value, label)

  defp validate_wire_value!(_value, _type, label),
    do: raise(ArgumentError, "#{label} does not match its normative wire type")

  defp validate_closed_wire_object!(value, types, label) when is_map(value) do
    unless Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(types)) do
      raise ArgumentError, "#{label} has an extra or missing field"
    end

    Enum.each(types, fn {field, type} ->
      validate_wire_value!(Map.fetch!(value, field), type, "#{label}.#{field}")
    end)
  end

  defp validate_closed_wire_object!(_value, _types, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp validate_json_value!(value, _label)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_integer(value) or
              is_float(value),
       do: :ok

  defp validate_json_value!(value, label) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {item, index} -> validate_json_value!(item, "#{label}[#{index}]") end)
  end

  defp validate_json_value!(value, label) when is_map(value) do
    unless Enum.all?(Map.keys(value), &is_binary/1) do
      raise ArgumentError, "#{label} JSON object keys must be strings"
    end

    Enum.each(value, fn {key, item} -> validate_json_value!(item, "#{label}.#{key}") end)
  end

  defp validate_json_value!(_value, label),
    do: raise(ArgumentError, "#{label} must be a JSON value")

  defp validate_item_relationships!(resource, item, catalog) do
    if Map.has_key?(@item_catalog_selections, resource) do
      validate_catalog_selection!(resource, item, catalog)
    end

    validate_item_invariants!(resource, item)
  end

  defp validate_item_invariants!("work items", item) do
    unless is_integer(item["priority"]) and item["priority"] in 0..8 do
      raise ArgumentError, "work items priority must be an integer from 0 through 8"
    end
  end

  defp validate_item_invariants!("condition facts", item) do
    unless item["id"] == item["rowVersion"] do
      raise ArgumentError, "condition facts id must equal rowVersion"
    end
  end

  defp validate_item_invariants!(
         "attests",
         %{
           "kind" => "verdict",
           "verdictKind" => verdict_kind
         }
       )
       when is_binary(verdict_kind),
       do: :ok

  defp validate_item_invariants!(
         "attests",
         %{"kind" => kind, "verdictKind" => nil}
       )
       when kind != "verdict",
       do: :ok

  defp validate_item_invariants!("attests", _item),
    do: raise(ArgumentError, "attests verdictKind does not match kind")

  defp validate_item_invariants!(
         "decision requests",
         %{"kind" => "agent", "status" => "returned"} = item
       ) do
    unless is_binary(item["returnedBy"]) and is_binary(item["returnReason"]) and
             String.trim(item["returnedBy"]) != "" and String.trim(item["returnReason"]) != "" and
             is_integer(item["returnedAt"]) and item["returnedAt"] > 0 do
      raise ArgumentError, "returned agent request requires its stored return triplet"
    end
  end

  defp validate_item_invariants!("decision requests", %{"status" => "returned"}),
    do: raise(ArgumentError, "returned is valid only for agent requests")

  defp validate_item_invariants!("decision requests", %{"kind" => "agent"} = item) do
    unless Enum.all?(~w(returnedBy returnReason returnedAt), &is_nil(item[&1])) do
      raise ArgumentError, "non-returned agent request requires a null return triplet"
    end
  end

  defp validate_item_invariants!(_resource, _item), do: :ok

  defp served_catalog(resource, item) do
    resource = Map.get(@item_resource_aliases, resource, resource)

    if catalog_selection_present?(resource, item) do
      ModelCatalog.get()
    else
      %{}
    end
  end

  defp catalog_selection_present?(resource, item) do
    case Map.get(@item_catalog_selections, resource) do
      nil -> false
      fields -> Enum.any?(Map.values(fields), &is_binary(item[&1]))
    end
  end

  defp validate_catalog_selection!(resource, item, catalog) do
    fields = Map.fetch!(@item_catalog_selections, resource)

    selection =
      fields
      |> Map.take([:harness, :provider, :model, :effort, :context])
      |> Map.new(fn {kind, field} -> {kind, binary_or_nil(item[field])} end)

    host = fields[:host] && binary_or_nil(item[fields.host])
    harness = selection[:harness]

    if is_binary(harness) do
      try do
        Harness.parse!(harness)
      rescue
        ArgumentError ->
          raise ArgumentError, "#{resource}.harness is absent from the served harness catalog"
      end

      unless Enum.any?(Map.keys(catalog), fn {_host, catalog_harness} ->
               harness == catalog_harness
             end) do
        raise ArgumentError, "#{resource}.harness is absent from the served harness catalog"
      end
    end

    keys =
      Enum.filter(Map.keys(catalog), fn {catalog_host, catalog_harness} ->
        (is_nil(host) or host == catalog_host) and
          (is_nil(harness) or harness == catalog_harness)
      end)

    dynamic = Map.drop(selection, [:harness])

    if Enum.any?(Map.values(dynamic), &is_binary/1) do
      entries = Enum.flat_map(keys, &Map.fetch!(catalog, &1))

      unless Enum.any?(entries, &catalog_entry_matches?(&1, dynamic)) do
        raise ArgumentError,
              "#{resource} harness, provider, model, effort, and context must match one served catalog entry"
      end
    end

    :ok
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp catalog_entry_matches?(entry, selection) do
    provider = entry.provider |> Atom.to_string()

    (is_nil(selection[:provider]) or selection.provider == provider) and
      (is_nil(selection[:model]) or selection.model == entry.family) and
      (is_nil(selection[:effort]) or selection.effort in entry.efforts) and
      (is_nil(selection[:context]) or selection.context == entry.context)
  end

  defp encode_item_field("sessions", "overrides", nil), do: "null"

  defp encode_item_field("sessions", "overrides", value) do
    "{" <>
      JSON.encode!("skillsAdd") <>
      ":" <>
      JSON.encode!(Enum.sort(Map.fetch!(value, "skillsAdd"))) <>
      "," <>
      JSON.encode!("guidanceExtra") <>
      ":" <> JSON.encode!(Map.fetch!(value, "guidanceExtra")) <> "}"
  end

  defp encode_item_field("transcript messages", "attachments", value) do
    encode_closed_list!(
      value,
      ~w(assetId mimeType filename size),
      "transcript messages.attachments"
    )
  end

  defp encode_item_field("transcript messages", "context", value), do: encode_j!(value)

  defp encode_item_field("attests", "commitRefs", nil), do: "null"

  defp encode_item_field("attests", "commitRefs", value) do
    encode_closed_list!(value, ~w(repo commit), "attests.commitRefs")
  end

  defp encode_item_field("decision requests", "options", value) do
    encode_closed_list!(value, ~w(label), "decision requests.options")
  end

  defp encode_item_field("decision requests", "context", value), do: encode_j!(value)

  defp encode_item_field("identity", "sessionRevisions", value) do
    encoded =
      value
      |> sorted_string_pairs!()
      |> Enum.map_join(",", fn {key, item} ->
        JSON.encode!(key) <> ":" <> JSON.encode!(item)
      end)

    "{" <> encoded <> "}"
  end

  defp encode_item_field("identity", field, value) when field in ~w(staleness conflicts),
    do: value |> Enum.sort() |> JSON.encode!()

  defp encode_item_field("kungfu", "phrases", value),
    do: value |> Enum.sort() |> JSON.encode!()

  defp encode_item_field("kungfu", "documents", value) do
    value
    |> Enum.sort_by(&Map.fetch!(&1, "path"))
    |> encode_closed_list!(~w(path content sha256), "kungfu.documents")
  end

  defp encode_item_field(_resource, _field, value), do: JSON.encode!(value)

  defp encode_closed_list!(value, fields, label) when is_list(value) do
    encoded = Enum.map_join(value, ",", &encode_closed_object!(&1, fields, label))
    "[" <> encoded <> "]"
  end

  defp encode_closed_list!(_value, _fields, label),
    do: raise(ArgumentError, "#{label} must be an array")

  defp encode_closed_object!(value, fields, label) when is_map(value) do
    unless Enum.sort(Map.keys(value)) == Enum.sort(fields) do
      raise ArgumentError, "#{label} has an extra or missing field"
    end

    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <> ":" <> JSON.encode!(Map.fetch!(value, field))
      end)

    "{" <> encoded <> "}"
  end

  defp encode_closed_object!(_value, _fields, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp encode_j!(value) when is_map(value) do
    unless Enum.all?(Map.keys(value), &is_binary/1) do
      raise ArgumentError, "opaque JSON object keys must be strings"
    end

    encoded =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} ->
        JSON.encode!(key) <> ":" <> encode_j!(item)
      end)

    "{" <> encoded <> "}"
  end

  defp encode_j!(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_j!/1) <> "]"
  end

  defp encode_j!(value), do: JSON.encode!(value)

  @doc "Encode one admin item in its ruled field order with compact UTF-8 JSON."
  def encode_admin_item(resource, item) do
    item = if resource == "kungfu", do: kungfu(item), else: item
    fields = Map.fetch!(@admin_field_order, resource)

    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <>
          ":" <> encode_admin_field(resource, field, Map.fetch!(item, field))
      end)

    "{" <> encoded <> "}"
  end

  @doc false
  def admin_resource?(resource), do: Map.has_key?(@admin_field_order, resource)
  def read_marker(row), do: public(row)
  def observation(row), do: public(row)

  defp turn_row([
         seq,
         session_key,
         message_id,
         wake_id,
         origin,
         prompt,
         role_ref,
         role_fallback,
         assignment_id,
         job_ref,
         model,
         thinking_level,
         model_context,
         harness,
         reply_attention,
         status,
         owner,
         adapter_gen,
         request_ref,
         error,
         created_at,
         started_at,
         ended_at,
         published_at
       ]) do
    %{
      seq: seq,
      session_key: session_key,
      message_id: message_id,
      wake_id: wake_id,
      origin: origin,
      prompt: prompt,
      role_ref: role_ref,
      role_fallback: role_fallback,
      assignment_id: assignment_id,
      job_ref: job_ref,
      model: model,
      thinking_level: thinking_level,
      model_context: model_context,
      harness: harness,
      reply_attention: reply_attention,
      status: status,
      owner: owner,
      adapter_gen: adapter_gen,
      request_ref: request_ref,
      error: error,
      created_at: created_at,
      started_at: started_at,
      ended_at: ended_at,
      published_at: published_at
    }
  end

  defp message_row([
         seq,
         id,
         session_key,
         role,
         message_type,
         content,
         at,
         sender,
         device_id,
         client_message_id,
         reply_to_message_id,
         reply_to_client_message_id,
         llm_visible_message_id,
         attachments,
         attention_tier,
         turn_seq,
         assignment_id,
         job_ref,
         harness,
         model,
         effort,
         context
       ]) do
    {harness, model, effort, context} =
      if role == "assistant",
        do: {harness, model, effort, context},
        else: {nil, nil, nil, nil}

    %{
      seq: seq,
      id: id,
      session_key: session_key,
      role: role,
      message_type: message_type,
      content: content,
      at: at,
      sender: sender,
      device_id: device_id,
      client_message_id: client_message_id,
      reply_to_message_id: reply_to_message_id,
      reply_to_client_message_id: reply_to_client_message_id,
      llm_visible_message_id: llm_visible_message_id,
      attachments: JSON.decode!(attachments),
      attention_tier: attention_tier,
      turn_seq: turn_seq,
      assignment_id: assignment_id,
      job_ref: job_ref,
      harness: harness,
      model: model,
      effort: effort,
      context: context,
      row_version: seq
    }
  end

  defp correlate(row, primary, source) do
    case row[source] do
      nil -> row
      value -> Map.put_new(row, primary, value)
    end
  end

  defp closed_projection(row, resource) do
    fields = conditional_fields!(resource, Map.fetch!(@item_field_order, resource), row)
    item = Map.take(row, fields)
    exact_item_keys!(resource, item, fields)
    item
  end

  defp decision_request_projection(row) do
    row_version = value(row, :row_version)

    unless is_integer(row_version) and row_version > 0 do
      raise ArgumentError, "decision request rowVersion is projection_invalid"
    end

    row =
      row
      |> Map.put(:row_version, row_version)
      |> public()
      |> Map.update!("options", &decision_options!/1)

    validate_decision_deadline!(row)

    row =
      case row["kind"] do
        kind when kind in ~w(statute agent) ->
          case {row["lineageRung"], row["effortGeneration"]} do
            {nil, nil} ->
              row
              |> Map.put("lineageRung", 0)
              |> Map.put("effortGeneration", 0)

            _stored_values ->
              raise ArgumentError,
                    "lineageRung and effortGeneration must be null when not applicable"
          end

        "effort" ->
          if is_integer(row["lineageRung"]) and is_integer(row["effortGeneration"]) do
            row
          else
            raise ArgumentError,
                  "lineageRung and effortGeneration must be stored integers for effort"
          end

        _other_kind ->
          row
      end

    row =
      if row["kind"] == "agent" do
        Enum.reduce(~w(returnedBy returnReason returnedAt), row, &Map.put_new(&2, &1, nil))
      else
        Map.drop(row, ~w(returnedBy returnReason returnedAt))
      end

    validate_item_invariants!("decision requests", row)
    closed_projection(row, "decision requests")
  end

  defp validate_decision_deadline!(%{"kind" => "agent", "deadlineAt" => nil}), do: :ok

  defp validate_decision_deadline!(%{"kind" => kind, "deadlineAt" => deadline_at})
       when kind in ~w(statute effort) and is_integer(deadline_at) and deadline_at > 0,
       do: :ok

  defp validate_decision_deadline!(%{"kind" => kind}) when kind in ~w(statute effort agent),
    do: raise(ArgumentError, "decision request deadlineAt is projection_invalid")

  defp validate_decision_deadline!(_row), do: :ok

  defp decision_options!(nil), do: []

  defp decision_options!(options) when is_list(options) do
    Enum.map(options, fn
      label when is_binary(label) ->
        %{"label" => label}

      %{"label" => label} = option when map_size(option) == 1 and is_binary(label) ->
        option

      _invalid ->
        raise ArgumentError, "decision request options are projection_invalid"
    end)
  end

  defp decision_options!(_invalid),
    do: raise(ArgumentError, "decision request options are projection_invalid")

  defp session_model_selection(row) do
    row = Map.put(row, :row_version, value(row, :row_version) || value(row, :updated_at))

    case value(row, :model) do
      %Tightbeam.Model{family: family, effort: effort, context: context} ->
        row
        |> Map.put(:model, family)
        |> Map.put(:thinking_level, effort)
        |> Map.put(:model_context, context)

      _scalar_or_nil ->
        row
    end
  end

  defp session_wire_overrides(row) do
    overrides = value(row, :overrides)

    wire_overrides =
      if Enum.all?(Map.keys(row), &is_binary/1) do
        overrides
      else
        case overrides do
          nil ->
            nil

          storage when is_map(storage) ->
            if map_size(storage) > 0 and
                 Enum.all?(Map.keys(storage), &(&1 in ["skills_add", "guidance_extra"])) do
              %{
                "skillsAdd" => Map.get(storage, "skills_add", []),
                "guidanceExtra" => Map.get(storage, "guidance_extra")
              }
            else
              storage
            end

          invalid ->
            invalid
        end
      end

    Map.put(row, :overrides, wire_overrides)
  end

  defp session_wire_value!(row, field, wire_field) do
    value = row |> value(field) |> normalize_session_wire_value()

    validate_wire_value!(
      value,
      item_field_type!("sessions", wire_field),
      "sessions.#{wire_field}"
    )

    value
  end

  defp normalize_session_wire_value(nil), do: nil
  defp normalize_session_wire_value(value) when is_boolean(value), do: value
  defp normalize_session_wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_session_wire_value(value), do: value

  defp exact!(resource, item) do
    expected = Map.fetch!(@item_field_order, resource)
    expected = conditional_fields!(resource, expected, item)

    if Enum.sort(Map.keys(item)) == Enum.sort(expected) do
      item
    else
      raise ArgumentError, "#{resource} projection fields do not match the ruled contract"
    end
  end

  defp reject_public_shape_drift!(row, resource) when is_map(row) do
    keys = Map.keys(row)

    if keys != [] and Enum.all?(keys, &is_binary/1) do
      expected = Map.fetch!(@item_field_order, resource)

      unless Enum.sort(keys) == Enum.sort(expected) do
        raise ArgumentError, "#{resource} public item has an extra or missing field"
      end
    end

    :ok
  end

  defp value(row, field) when is_map(row) do
    camel = field |> Atom.to_string() |> camel_key()

    [field, Atom.to_string(field), camel]
    |> Enum.find_value(fn key ->
      if Map.has_key?(row, key), do: {:found, Map.fetch!(row, key)}, else: nil
    end)
    |> case do
      {:found, found} -> found
      nil -> nil
    end
  end

  defp required_string!(row, field) do
    case value(row, field) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{field} must be a non-empty string"
    end
  end

  defp nullable_string!(nil, _field), do: nil
  defp nullable_string!(value, _field) when is_binary(value), do: value

  defp nullable_string!(_value, field),
    do: raise(ArgumentError, "#{field} must be a string or null")

  defp required_integer!(row, field) do
    case value(row, field) do
      value when is_integer(value) -> value
      _ -> raise ArgumentError, "#{field} must be an integer"
    end
  end

  defp nullable_integer!(nil, _field), do: nil
  defp nullable_integer!(value, _field) when is_integer(value), do: value

  defp nullable_integer!(_value, field),
    do: raise(ArgumentError, "#{field} must be an integer or null")

  defp message_at!(row) do
    case value(row, :at) || value(row, :timestamp) do
      at when is_integer(at) -> at
      _ -> raise ArgumentError, "at must be an integer"
    end
  end

  defp message_provider(row) do
    case value(row, :provider) do
      nil ->
        case value(row, :harness) do
          nil ->
            nil

          harness when is_binary(harness) ->
            Harness.parse!(harness).credential_provider() |> to_string()

          _other ->
            raise ArgumentError, "harness must be a string or null"
        end

      provider ->
        nullable_string!(provider, "provider")
    end
  end

  defp message_effort(row),
    do: nullable_string!(value(row, :effort) || value(row, :thinking_level), "effort")

  defp message_context(row) do
    case value(row, :context) do
      nil -> value(row, :model_context)
      context -> context
    end
  end

  defp message_row_version!(row) do
    case value(row, :row_version) || value(row, :seq) do
      version when is_integer(version) and version > 0 -> version
      _ -> raise ArgumentError, "rowVersion must be a positive integer"
    end
  end

  defp required_version!(row) do
    case value(row, :row_version) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "rowVersion must be a positive integer"
    end
  end

  defp required_boolean!(row, field) do
    case value(row, field) do
      value when is_boolean(value) -> value
      _ -> raise ArgumentError, "#{field} must be a boolean"
    end
  end

  defp required_list!(value, _field) when is_list(value), do: value
  defp required_list!(_value, field), do: raise(ArgumentError, "#{field} must be an array")

  defp required_wire_string!(value, _field) when is_binary(value), do: value
  defp required_wire_string!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  defp sorted_strings!(value, field) do
    value
    |> required_list!(field)
    |> then(fn values ->
      if Enum.all?(values, &is_binary/1),
        do: Enum.sort(values),
        else: raise(ArgumentError, "#{field} must contain only strings")
    end)
  end

  defp sorted_string_map!(value) when is_map(value) do
    value |> sorted_string_pairs!() |> Map.new()
  end

  defp sorted_string_map!(_value),
    do: raise(ArgumentError, "sessionRevisions must be a string-to-string map")

  defp encode_admin_field("identity", "sessionRevisions", value) do
    encoded =
      value
      |> sorted_string_pairs!()
      |> Enum.map_join(",", fn {key, item} ->
        JSON.encode!(key) <> ":" <> JSON.encode!(item)
      end)

    "{" <> encoded <> "}"
  end

  defp encode_admin_field(_resource, _field, value), do: JSON.encode!(value)

  defp sorted_string_pairs!(value) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end) do
      Enum.sort_by(value, &elem(&1, 0))
    else
      raise ArgumentError, "sessionRevisions must be a string-to-string map"
    end
  end

  defp sorted_string_pairs!(_value),
    do: raise(ArgumentError, "sessionRevisions must be a string-to-string map")

  defp state_name(:ready), do: "ready"
  defp state_name(:relearn_conflicted), do: "relearn_conflicted"
  defp state_name(value) when is_binary(value), do: value
  defp state_name(_value), do: raise(ArgumentError, "unknown identity state")

  defp camel_key(field) do
    field
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
      [] -> ""
    end
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp public(row) when is_struct(row), do: row |> Map.from_struct() |> public()

  defp public(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {wire_key(key), public(value)} end)
    |> Map.reject(fn {key, _value} -> MapSet.member?(@secret_keys, key) end)
    |> ensure_row_version()
  end

  defp public(rows) when is_list(rows), do: Enum.map(rows, &public/1)
  defp public(nil), do: nil
  defp public(value) when is_boolean(value), do: value
  defp public(value) when is_atom(value), do: Atom.to_string(value)
  defp public(value), do: value

  defp ensure_row_version(row) do
    version = row["rowVersion"] || natural_version(row)

    if is_integer(version), do: Map.put_new(row, "rowVersion", version), else: row
  end

  defp natural_version(row) do
    ~w(updatedAt endedAt firedAt canceledAt closedAt retiredAt ruledAt withdrawnAt startedAt createdAt openedAt ts seq id)
    |> Enum.map(&row[&1])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp wire_key(key) when is_binary(key), do: key

  defp wire_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
      [] -> ""
    end
  end

  defp wire_key(key), do: to_string(key)
end
