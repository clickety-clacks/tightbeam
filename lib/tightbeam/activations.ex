defmodule Tightbeam.Activations do
  @moduledoc "Inert storage and closed value validation for activation-events-v1."

  alias Tightbeam.DB

  @kinds ~w(declared authority-attached attempted observed reconciled withdrawn notice-requeued acknowledged)
  @opaque_token_regex ~r/\A[A-Za-z0-9._:\/@+=-]{1,512}\z/
  @namespace_regex ~r/\A[a-z0-9._-]{1,64}\z/
  @sha256_regex ~r/\A[0-9a-f]{64}\z/
  @max_external_time 9_223_372_036_854_775_807

  @ddl """
  CREATE TABLE IF NOT EXISTS activation_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    eventId TEXT UNIQUE NOT NULL CHECK(eventId GLOB 'aev_*' AND length(eventId) > 4),
    activationId TEXT NOT NULL CHECK(activationId GLOB 'act_*' AND length(activationId) > 4),
    kind TEXT NOT NULL CHECK(kind IN ('declared','authority-attached','attempted','observed','reconciled','withdrawn','notice-requeued','acknowledged')),
    predecessorEventId TEXT REFERENCES activation_events(eventId),
    rootAssignmentId TEXT NOT NULL REFERENCES assignments(id),
    workItemId TEXT NOT NULL REFERENCES work_items(id),
    actorAssignmentId TEXT REFERENCES assignments(id),
    bySession TEXT REFERENCES sessions(sessionKey),
    byUser TEXT REFERENCES users(userId),
    idempotencyKey TEXT NOT NULL CHECK(
      length(idempotencyKey) BETWEEN 1 AND 200 AND
      idempotencyKey NOT GLOB '*[^A-Za-z0-9._:/@+=-]*'
    ),
    requestSha256 TEXT NOT NULL CHECK(
      length(requestSha256) = 64 AND requestSha256 NOT GLOB '*[^0-9a-f]*'
    ),
    payload TEXT NOT NULL CHECK(json_valid(payload)),
    noticeWakeId TEXT REFERENCES wakes(wakeId),
    ts INTEGER NOT NULL CHECK(ts >= 0),
    CHECK((bySession IS NOT NULL) != (byUser IS NOT NULL)),
    CHECK(
      (kind = 'declared' AND predecessorEventId IS NULL) OR
      (kind != 'declared' AND predecessorEventId IS NOT NULL)
    )
  );
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_declared ON activation_events(activationId) WHERE kind='declared';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_attempted ON activation_events(activationId) WHERE kind='attempted';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_observed ON activation_events(activationId) WHERE kind='observed';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_reconciled ON activation_events(activationId) WHERE kind='reconciled';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_withdrawn ON activation_events(activationId) WHERE kind='withdrawn';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_one_acknowledgement ON activation_events(json_extract(payload, '$.noticedEventId')) WHERE kind='acknowledged';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_notice_requeue ON activation_events(json_extract(payload, '$.replacesWakeId')) WHERE kind='notice-requeued';
  CREATE UNIQUE INDEX IF NOT EXISTS activation_session_idempotency ON activation_events(bySession, kind, idempotencyKey) WHERE bySession IS NOT NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS activation_user_idempotency ON activation_events(byUser, kind, idempotencyKey) WHERE byUser IS NOT NULL;
  CREATE INDEX IF NOT EXISTS activation_stream ON activation_events(activationId, seq, eventId);
  CREATE INDEX IF NOT EXISTS activation_work_item ON activation_events(workItemId, seq, eventId);
  """

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec opaque_token?(term(), pos_integer()) :: boolean()
  def opaque_token?(value, max \\ 512),
    do: is_binary(value) and byte_size(value) <= max and value =~ @opaque_token_regex

  @spec namespace?(term()) :: boolean()
  def namespace?(value), do: is_binary(value) and value =~ @namespace_regex

  @spec sha256?(term()) :: boolean()
  def sha256?(value), do: is_binary(value) and value =~ @sha256_regex

  @spec resource_ref?(term()) :: boolean()
  def resource_ref?(%{"namespace" => namespace, "id" => id, "sha256" => digest} = ref)
      when map_size(ref) == 3,
      do:
        namespace?(namespace) and opaque_token?(id) and
          (is_nil(digest) or sha256?(digest))

  def resource_ref?(_value), do: false

  @spec domain_identity?(term()) :: boolean()
  def domain_identity?(%{"namespace" => namespace, "id" => id} = identity)
      when map_size(identity) == 2,
      do: namespace?(namespace) and opaque_token?(id)

  def domain_identity?(_value), do: false

  @spec domain_code?(term()) :: boolean()
  def domain_code?(%{"namespace" => namespace, "code" => code} = value)
      when map_size(value) == 2,
      do: namespace?(namespace) and opaque_token?(code, 64)

  def domain_code?(_value), do: false

  @doc "Validates one closed per-kind payload without performing an append."
  @spec payload?(String.t(), term()) :: boolean()
  def payload?("declared", payload) do
    exact_keys?(payload, ~w(ownerUserId domain correlationKey preparedInput target prior)) and
      nonempty_string?(payload["ownerUserId"]) and namespace?(payload["domain"]) and
      opaque_token?(payload["correlationKey"], 200) and
      content_ref?(payload["preparedInput"]) and resource_ref?(payload["target"]) and
      prior?(payload["prior"])
  end

  def payload?("authority-attached", payload) do
    exact_keys?(payload, ~w(authorizer basis decision)) and
      domain_identity?(payload["authorizer"]) and content_ref?(payload["basis"]) and
      domain_code?(payload["decision"])
  end

  def payload?("attempted", payload) do
    exact_keys?(payload, ~w(authorityEventIds executor externalAttempt targetStateBefore)) and
      bounded_distinct_ids?(payload["authorityEventIds"], "aev_", 1, 32) and
      domain_identity?(payload["executor"]) and resource_ref?(payload["externalAttempt"]) and
      optional_content_ref?(payload["targetStateBefore"])
  end

  def payload?("observed", payload) do
    exact_keys?(
      payload,
      ~w(attemptEventId certainty result targetStateAfter outputs evidence externalOccurredAtMs)
    ) and event_id?(payload["attemptEventId"]) and
      payload["certainty"] in ~w(determinate indeterminate) and
      observation_fields?(payload)
  end

  def payload?("reconciled", payload) do
    exact_keys?(
      payload,
      ~w(observedEventId certainty result targetStateAfter outputs evidence externalOccurredAtMs)
    ) and event_id?(payload["observedEventId"]) and
      payload["certainty"] in ~w(determinate irrecoverable) and
      observation_fields?(payload)
  end

  def payload?("withdrawn", payload) do
    exact_keys?(payload, ~w(reason basis)) and domain_code?(payload["reason"]) and
      content_ref?(payload["basis"])
  end

  def payload?("notice-requeued", payload) do
    exact_keys?(payload, ~w(noticedEventId replacesWakeId)) and
      event_id?(payload["noticedEventId"]) and wake_id?(payload["replacesWakeId"])
  end

  def payload?("acknowledged", payload) do
    exact_keys?(payload, ~w(noticedEventId acknowledgedWakeId)) and
      event_id?(payload["noticedEventId"]) and wake_id?(payload["acknowledgedWakeId"])
  end

  def payload?(_kind, _payload), do: false

  @doc "RFC 8785 JSON Canonicalization Scheme bytes for activation semantic requests."
  @spec canonical_json!(term()) :: String.t()
  def canonical_json!(value) when is_binary(value), do: JSON.encode!(value)

  def canonical_json!(value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: JSON.encode!(value)

  def canonical_json!(value) when is_float(value),
    do: raise(ArgumentError, "floating-point values are not canonical activation JSON")

  def canonical_json!(values) when is_list(values),
    do: "[" <> Enum.map_join(values, ",", &canonical_json!/1) <> "]"

  def canonical_json!(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.map(fn key ->
      if not is_binary(key), do: raise(ArgumentError, "activation JSON keys must be strings")
      {utf16_sort_key!(key), key}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {_sort_key, key} ->
      JSON.encode!(key) <> ":" <> canonical_json!(Map.fetch!(map, key))
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  def canonical_json!(_value),
    do: raise(ArgumentError, "activation JSON accepts only closed JSON values")

  @spec canonical_sha256!(term()) :: String.t()
  def canonical_sha256!(term),
    do: :crypto.hash(:sha256, canonical_json!(term)) |> Base.encode16(case: :lower)

  @doc "Internal relation only; Slice 1 exposes no route or public activation reader."
  @spec readable?(DB.server(), String.t(), {:user | :session, String.t()}) :: boolean()
  def readable?(db, activation_id, {:user, user_id})
      when is_binary(activation_id) and is_binary(user_id),
      do: readable_by?(db, activation_id, user_id, nil)

  def readable?(db, activation_id, {:session, session_key})
      when is_binary(activation_id) and is_binary(session_key),
      do: readable_by?(db, activation_id, nil, session_key)

  defp readable_by?(db, activation_id, user_id, session_key) do
    {:ok, [[visible]]} =
      DB.query(
        db,
        """
        WITH principal AS (
          SELECT
            ?2 AS directUserId,
            ?3 AS sessionKey,
            owner.ownerUserId AS sessionOwnerId,
            COALESCE(directAdmin.isAdmin, ownerAdmin.isAdmin, 0) AS isAdmin
          FROM (SELECT 1)
          LEFT JOIN sessions owner ON owner.sessionKey=?3
          LEFT JOIN users directAdmin ON directAdmin.userId=?2
          LEFT JOIN users ownerAdmin ON ownerAdmin.userId=owner.ownerUserId
        )
        SELECT EXISTS(
          SELECT 1
          FROM activation_events event
          CROSS JOIN principal
          LEFT JOIN work_items item ON item.id=event.workItemId
          LEFT JOIN assignments root ON root.id=event.rootAssignmentId
          LEFT JOIN sessions rootHolder ON rootHolder.sessionKey=root.holderKey
          LEFT JOIN assignments actor ON actor.id=event.actorAssignmentId
          LEFT JOIN sessions actorHolder ON actorHolder.sessionKey=actor.holderKey
          WHERE event.activationId=?1 AND (
            principal.isAdmin=1 OR
            (event.kind='declared' AND
             json_extract(event.payload, '$.ownerUserId')=COALESCE(principal.directUserId, principal.sessionOwnerId)) OR
            item.ownerUserId=COALESCE(principal.directUserId, principal.sessionOwnerId) OR
            root.holderKey=principal.sessionKey OR rootHolder.ownerUserId=principal.directUserId OR
            actor.holderKey=principal.sessionKey OR actorHolder.ownerUserId=principal.directUserId OR
            event.byUser=principal.directUserId OR event.bySession=principal.sessionKey
          )
        )
        """,
        [activation_id, user_id, session_key]
      )

    visible == 1
  end

  defp exact_keys?(value, keys) when is_map(value),
    do: Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp content_ref?(value),
    do: resource_ref?(value) and sha256?(value["sha256"])

  defp optional_content_ref?(nil), do: true
  defp optional_content_ref?(value), do: content_ref?(value)

  defp prior?(nil), do: true

  defp prior?(%{"activationId" => activation_id, "relation" => relation} = prior)
       when map_size(prior) == 2,
       do: activation_id?(activation_id) and relation in ~w(retry-of compensates supersedes)

  defp prior?(_value), do: false

  defp observation_fields?(payload) do
    domain_code?(payload["result"]) and optional_content_ref?(payload["targetStateAfter"]) and
      output_refs?(payload["outputs"]) and content_ref?(payload["evidence"]) and
      external_time?(payload["externalOccurredAtMs"])
  end

  defp output_refs?(outputs) when is_list(outputs) and length(outputs) <= 32,
    do: Enum.all?(outputs, &resource_ref?/1)

  defp output_refs?(_value), do: false

  defp external_time?(nil), do: true

  defp external_time?(value),
    do: is_integer(value) and value >= 0 and value <= @max_external_time

  defp bounded_distinct_ids?(values, prefix, minimum, maximum) when is_list(values) do
    length(values) in minimum..maximum and Enum.uniq(values) == values and
      Enum.all?(values, &prefixed_token?(&1, prefix))
  end

  defp bounded_distinct_ids?(_values, _prefix, _minimum, _maximum), do: false

  defp activation_id?(value), do: prefixed_token?(value, "act_")
  defp event_id?(value), do: prefixed_token?(value, "aev_")
  defp wake_id?(value), do: prefixed_token?(value, "w_")

  defp prefixed_token?(value, prefix),
    do: opaque_token?(value) and String.starts_with?(value, prefix) and value != prefix

  defp utf16_sort_key!(value) do
    case :unicode.characters_to_binary(value, :utf8, {:utf16, :big}) do
      bytes when is_binary(bytes) -> bytes
      _error -> raise ArgumentError, "activation JSON strings must be valid Unicode"
    end
  end
end
