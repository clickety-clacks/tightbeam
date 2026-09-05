defmodule Tightbeam.DeliverableContract do
  @moduledoc """
  Immutable card and assignment deliverables, completion claims, and card closures.

  The contract lives in companion tables so activation never rewrites historical
  work-item, assignment, or attest rows.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @shape "coordination-fabric-v1-phase1-v21"
  @artifact_digest_previous_shape "coordination-fabric-v1-phase1-v20"
  @previous_shape "coordination-fabric-v1-phase1-v19"

  defmodule Inconsistent do
    @moduledoc false
    defexception [:detail]
    def message(%__MODULE__{detail: detail}), do: "deliverable_contract_inconsistent: #{detail}"
  end

  defmodule MutationError do
    @moduledoc false
    defexception [:response]
    def message(%__MODULE__{response: response}), do: response.message
  end

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS deliverables (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 2000 AND length(trim(name)) >= 1),
      sha256 TEXT NOT NULL CHECK(length(sha256)=64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
      createdAt INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS work_item_deliverables (
      workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
      deliverableId TEXT NOT NULL UNIQUE REFERENCES deliverables(id),
      UNIQUE(workItemId, deliverableId)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS assignment_deliverables (
      assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
      deliverableId TEXT NOT NULL REFERENCES deliverables(id),
      sourceKind TEXT NOT NULL CHECK(sourceKind IN ('assignment','work_item')),
      sourceWorkItemId TEXT NULL REFERENCES work_items(id),
      CHECK(
        (sourceKind='assignment' AND sourceWorkItemId IS NULL) OR
        (sourceKind='work_item' AND sourceWorkItemId IS NOT NULL)
      ),
      UNIQUE(assignmentId, deliverableId),
      FOREIGN KEY(sourceWorkItemId, deliverableId)
        REFERENCES work_item_deliverables(workItemId, deliverableId)
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS assignment_own_deliverable
      ON assignment_deliverables(deliverableId)
      WHERE sourceKind='assignment'
    """,
    """
    CREATE TABLE IF NOT EXISTS assignment_product_lineage_captures (
      assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
      workItemId TEXT NOT NULL REFERENCES work_items(id),
      holderSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
      captureKind TEXT NOT NULL CHECK(captureKind IN ('assignment_open','activation')),
      UNIQUE(assignmentId, workItemId)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS assignment_product_owner_ancestry (
      assignmentId TEXT NOT NULL REFERENCES assignment_product_lineage_captures(assignmentId),
      productOwnerSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
      distance INTEGER NOT NULL CHECK(distance >= 0),
      PRIMARY KEY(assignmentId, productOwnerSessionKey),
      UNIQUE(assignmentId, distance)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS completion_claims (
      attestId TEXT PRIMARY KEY REFERENCES attests(id),
      assignmentId TEXT NOT NULL REFERENCES assignments(id),
      deliverableId TEXT NOT NULL REFERENCES deliverables(id),
      claimedAt INTEGER NOT NULL,
      UNIQUE(attestId, deliverableId),
      FOREIGN KEY(assignmentId, deliverableId)
        REFERENCES assignment_deliverables(assignmentId, deliverableId)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS work_item_closures (
      workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
      completionAttestId TEXT NOT NULL UNIQUE REFERENCES attests(id),
      cardDeliverableId TEXT NOT NULL REFERENCES deliverables(id),
      acceptedDeliverableId TEXT NOT NULL REFERENCES deliverables(id),
      basis TEXT NOT NULL CHECK(basis IN ('exact','owner_narrowing')),
      ownerRulingReason TEXT NULL CHECK(ownerRulingReason IS NULL OR length(trim(ownerRulingReason)) BETWEEN 1 AND 2000),
      ownerRulingProductOwnerSessionKey TEXT NULL REFERENCES sessions(sessionKey),
      closedByUser TEXT NULL,
      closedBySession TEXT NULL,
      requestFingerprint TEXT NOT NULL CHECK(length(requestFingerprint)=64 AND requestFingerprint NOT GLOB '*[^0-9a-f]*'),
      closedAt INTEGER NOT NULL,
      CHECK((closedByUser IS NOT NULL) != (closedBySession IS NOT NULL)),
      CHECK(
        (basis='exact' AND cardDeliverableId=acceptedDeliverableId AND
          ownerRulingReason IS NULL AND ownerRulingProductOwnerSessionKey IS NULL) OR
        (basis='owner_narrowing' AND cardDeliverableId<>acceptedDeliverableId AND
          ownerRulingReason IS NOT NULL AND ownerRulingProductOwnerSessionKey IS NOT NULL AND
          closedByUser IS NULL AND closedBySession=ownerRulingProductOwnerSessionKey)
      ),
      FOREIGN KEY(workItemId, cardDeliverableId)
        REFERENCES work_item_deliverables(workItemId, deliverableId),
      FOREIGN KEY(completionAttestId, acceptedDeliverableId)
        REFERENCES completion_claims(attestId, deliverableId)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS deliverable_contract_idempotency (
      actorKind TEXT NOT NULL CHECK(actorKind IN ('user','session')),
      actorRef TEXT NOT NULL CHECK(length(trim(actorRef)) >= 1),
      operation TEXT NOT NULL CHECK(operation IN ('attest-completion','work-item-close')),
      idempotencyKey TEXT NOT NULL CHECK(length(trim(idempotencyKey)) BETWEEN 1 AND 200),
      requestFingerprint TEXT NOT NULL CHECK(length(requestFingerprint)=64 AND requestFingerprint NOT GLOB '*[^0-9a-f]*'),
      canonicalResponse TEXT NOT NULL CHECK(json_valid(canonicalResponse)),
      completionAttestId TEXT NULL REFERENCES completion_claims(attestId),
      workItemId TEXT NULL REFERENCES work_item_closures(workItemId),
      PRIMARY KEY(actorKind, actorRef, operation, idempotencyKey),
      CHECK(
        (operation='attest-completion' AND completionAttestId IS NOT NULL AND workItemId IS NULL) OR
        (operation='work-item-close' AND completionAttestId IS NULL AND workItemId IS NOT NULL)
      )
    )
    """
  ]

  @contract_objects ~w(
    deliverables
    work_item_deliverables
    assignment_deliverables
    assignment_own_deliverable
    assignment_product_lineage_captures
    assignment_product_owner_ancestry
    completion_claims
    work_item_closures
    deliverable_contract_idempotency
  )

  @doc "Create the companion schema and validate all existing contract rows."
  def ensure_schema(db \\ Tightbeam.DB) do
    case DB.query(db, "SELECT shape FROM schema_stamp") do
      {:ok, [[shape]]} when shape in [@previous_shape, @artifact_digest_previous_shape, @shape] ->
        validate_existing_schema!(db)

      {:ok, [[_predecessor]]} ->
        :ok

      {:ok, []} ->
        create_and_validate_schema!(db)

      {:error, _missing_stamp} ->
        create_and_validate_schema!(db)
    end
  end

  @doc false
  def bootstrap_schema(db \\ Tightbeam.DB), do: create_and_validate_schema!(db)

  defp create_and_validate_schema!(db) do
    Enum.each(@ddl, fn ddl -> :ok = DB.execute(db, ddl) end)
    validate_existing_schema!(db)
  end

  defp validate_existing_schema!(db) do
    case DB.transaction(db, fn txn ->
           require_complete_schema!(txn)
           validate_in_txn!(txn)
         end) do
      {:ok, :ok} -> :ok
      {:error, %Inconsistent{} = error} -> raise error
      {:error, error} -> raise Inconsistent, detail: Exception.message(error)
    end
  end

  @doc false
  def upgrade_v1(db, previous_shape, next_shape, opts \\ []) do
    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT shape FROM schema_stamp") do
             [[^previous_shape]] -> :ok
             rows -> inconsistent!("schema_stamp predecessor #{inspect(rows)}")
           end

           refuse_partial_schema!(txn)
           Enum.each(@ddl, &Txn.exec(txn, &1))
           interrupt!(opts, :after_table_creation)
           backfill_cards(txn)
           interrupt!(opts, :after_card_backfill)
           backfill_assignments(txn)
           interrupt!(opts, :after_assignment_backfill)
           backfill_lineage(txn)
           interrupt!(opts, :after_product_lineage_capture)
           validate_in_txn!(txn)
           interrupt!(opts, :after_validation)
           interrupt!(opts, :before_stamp_update)

           Txn.q(txn, "UPDATE schema_stamp SET shape=?2, stampedAt=?3 WHERE shape=?1", [
             previous_shape,
             next_shape,
             System.system_time(:millisecond)
           ])

           if Txn.changes(txn) != 1, do: inconsistent!("schema_stamp race")
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, %Inconsistent{} = error} -> raise error
      {:error, error} -> raise Inconsistent, detail: Exception.message(error)
    end
  end

  @doc "Encode a supported value with the normative TBCD1 tuple encoding."
  def tbcd1(value), do: "TBCD1" <> encode(value)

  @doc "Return the lowercase SHA-256 fingerprint of one TBCD1 value."
  def fingerprint(value), do: value |> tbcd1() |> sha256()

  def completion_fingerprint(assignment_id, note, commit_refs) do
    refs =
      case commit_refs do
        nil -> nil
        refs -> Enum.map(refs, fn ref -> [map_value(ref, :repo), map_value(ref, :commit)] end)
      end

    fingerprint(["attest-completion", assignment_id, "completion", note, refs])
  end

  def close_fingerprint(work_item_id, attest_id, reason) do
    fingerprint(["work-item-close", work_item_id, attest_id, reason])
  end

  @doc false
  def completion_receipt_in_txn(txn, principal, key, fingerprint) do
    {actor_kind, actor_ref} = receipt_actor(principal)

    case Txn.q(
           txn,
           """
           SELECT requestFingerprint,canonicalResponse
           FROM deliverable_contract_idempotency
           WHERE actorKind=?1 AND actorRef=?2 AND operation='attest-completion' AND idempotencyKey=?3
           """,
           [actor_kind, actor_ref, key]
         ) do
      [] ->
        :miss

      [[^fingerprint, response]] ->
        {:replay, response |> JSON.decode!() |> atomize_keys()}

      [[_other, _response]] ->
        error("idempotency_conflict", "idempotency key was used with another completion request")
    end
  end

  @doc false
  def store_completion_receipt_in_txn(txn, principal, key, fingerprint, response) do
    {actor_kind, actor_ref} = receipt_actor(principal)

    Txn.q(
      txn,
      """
      INSERT INTO deliverable_contract_idempotency
        (actorKind,actorRef,operation,idempotencyKey,requestFingerprint,canonicalResponse,
         completionAttestId,workItemId)
      VALUES (?1,?2,'attest-completion',?3,?4,?5,?6,NULL)
      """,
      [actor_kind, actor_ref, key, fingerprint, JSON.encode!(response), response.attest.id]
    )

    :ok
  end

  @doc false
  def close_receipt_in_txn(_txn, _principal, nil, _fingerprint), do: :miss

  def close_receipt_in_txn(txn, principal, key, fingerprint) do
    {actor_kind, actor_ref} = receipt_actor(principal)

    case Txn.q(
           txn,
           """
           SELECT requestFingerprint,canonicalResponse
           FROM deliverable_contract_idempotency
           WHERE actorKind=?1 AND actorRef=?2 AND operation='work-item-close' AND idempotencyKey=?3
           """,
           [actor_kind, actor_ref, key]
         ) do
      [] ->
        :miss

      [[^fingerprint, response]] ->
        {:replay, response |> JSON.decode!() |> atomize_keys()}

      [[_other, _response]] ->
        error("idempotency_conflict", "idempotency key was used with another close request")
    end
  end

  @doc false
  def store_close_receipt_in_txn(txn, principal, key, fingerprint, work_item_id, response) do
    if key do
      {actor_kind, actor_ref} = receipt_actor(principal)

      Txn.q(
        txn,
        """
        INSERT INTO deliverable_contract_idempotency
          (actorKind,actorRef,operation,idempotencyKey,requestFingerprint,canonicalResponse,
           completionAttestId,workItemId)
        VALUES (?1,?2,'work-item-close',?3,?4,?5,NULL,?6)
        """,
        [actor_kind, actor_ref, key, fingerprint, JSON.encode!(response), work_item_id]
      )
    end

    :ok
  end

  @doc false
  def create_work_item_in_txn(txn, work_item_id, title, created_at) do
    id = "dlv_" <> Tightbeam.Id.uuid4()
    insert_deliverable(txn, id, title, created_at)

    Txn.q(txn, "INSERT INTO work_item_deliverables (workItemId, deliverableId) VALUES (?1, ?2)", [
      work_item_id,
      id
    ])

    id
  end

  @doc false
  def bind_assignment_in_txn(
        txn,
        assignment,
        delivers_work_item,
        capture_kind \\ "assignment_open"
      ) do
    bind_assignment(txn, assignment, delivers_work_item, capture_kind, true)
  end

  defp bind_assignment(txn, assignment, delivers_work_item, capture_kind, capture_lineage?) do
    assignment_id = map_value(assignment, :id)
    work_item_id = map_value(assignment, :workItemId)
    holder = map_value(assignment, :holderKey)

    cond do
      delivers_work_item and is_nil(work_item_id) ->
        error("deliverable_work_item_required", "a card-bound assignment requires a work item")

      delivers_work_item ->
        case Txn.q(txn, "SELECT deliverableId FROM work_item_deliverables WHERE workItemId=?1", [
               work_item_id
             ]) do
          [[deliverable_id]] ->
            Txn.q(
              txn,
              "INSERT INTO assignment_deliverables (assignmentId,deliverableId,sourceKind,sourceWorkItemId) VALUES (?1,?2,'work_item',?3)",
              [assignment_id, deliverable_id, work_item_id]
            )

            if capture_lineage?,
              do: capture_lineage!(txn, assignment_id, work_item_id, holder, capture_kind)

            :ok

          _ ->
            error(
              "deliverable_contract_inconsistent",
              "card deliverable missing for #{work_item_id}"
            )
        end

      true ->
        id = "dlv_" <> Tightbeam.Id.uuid4()

        insert_deliverable(
          txn,
          id,
          map_value(assignment, :subject),
          map_value(assignment, :openedAt)
        )

        Txn.q(
          txn,
          "INSERT INTO assignment_deliverables (assignmentId,deliverableId,sourceKind,sourceWorkItemId) VALUES (?1,?2,'assignment',NULL)",
          [assignment_id, id]
        )

        if not is_nil(work_item_id) and capture_lineage?,
          do: capture_lineage!(txn, assignment_id, work_item_id, holder, capture_kind)

        :ok
    end
  end

  @doc false
  def ensure_reopen_binding_in_txn(txn, assignment) do
    assignment_id = map_value(assignment, :id)
    work_item_id = map_value(assignment, :workItemId)

    if Txn.q(txn, "SELECT 1 FROM assignment_deliverables WHERE assignmentId=?1", [assignment_id]) ==
         [] do
      capture_lineage? = reopen_capture_required?(txn, assignment_id, work_item_id)

      case bind_assignment(txn, assignment, false, "assignment_open", capture_lineage?) do
        :ok -> :ok
        error -> raise MutationError, response: error
      end
    else
      :ok
    end
  end

  defp reopen_capture_required?(_txn, _assignment_id, nil), do: false

  defp reopen_capture_required?(txn, assignment_id, work_item_id) do
    case Txn.q(
           txn,
           "SELECT workItemId FROM assignment_product_lineage_captures WHERE assignmentId=?1",
           [assignment_id]
         ) do
      [] ->
        true

      [[^work_item_id]] ->
        false

      _ ->
        raise MutationError,
          response:
            error(
              "deliverable_contract_inconsistent",
              "lineage capture does not match #{assignment_id}"
            )
    end
  end

  @doc false
  def record_completion_claim_in_txn(txn, assignment_id, attest) do
    case Txn.q(txn, "SELECT deliverableId FROM assignment_deliverables WHERE assignmentId=?1", [
           assignment_id
         ]) do
      [[deliverable_id]] ->
        Txn.q(
          txn,
          "INSERT INTO completion_claims (attestId,assignmentId,deliverableId,claimedAt) VALUES (?1,?2,?3,?4)",
          [attest.id, assignment_id, deliverable_id, attest.ts]
        )

        :ok

      [] ->
        error("assignment_deliverable_missing", "assignment has no stored deliverable")

      _ ->
        error("deliverable_contract_inconsistent", "ambiguous deliverable for #{assignment_id}")
    end
  end

  def work_item_projection(db, work_item_id) do
    query_projection(db, fn txn -> work_item_projection_in_txn(txn, work_item_id) end)
  end

  def work_item_projection_in_txn(txn, work_item_id) do
    case Txn.q(
           txn,
           "SELECT d.id,d.name,d.sha256 FROM work_item_deliverables w JOIN deliverables d ON d.id=w.deliverableId WHERE w.workItemId=?1",
           [work_item_id]
         ) do
      [[id, name, hash]] ->
        %{
          deliverableContract: "v1",
          deliverable: deliverable(id, name, hash),
          cardProductOwner: card_product_owner(txn, work_item_id),
          closure: closure_projection(txn, work_item_id)
        }

      [] ->
        %{deliverableContract: "legacy", deliverable: nil, cardProductOwner: nil, closure: nil}

      _ ->
        inconsistent!("ambiguous work-item deliverable #{work_item_id}")
    end
  end

  def assignment_projection(db, assignment_id) do
    query_projection(db, fn txn -> assignment_projection_in_txn(txn, assignment_id) end)
  end

  def assignment_projection_in_txn(txn, assignment_id) do
    deliverable_projection =
      case Txn.q(
             txn,
             "SELECT d.id,d.name,d.sha256,a.sourceKind,a.sourceWorkItemId FROM assignment_deliverables a JOIN deliverables d ON d.id=a.deliverableId WHERE a.assignmentId=?1",
             [assignment_id]
           ) do
        [[id, name, hash, source, source_work_item]] ->
          %{
            deliverableContract: "v1",
            deliverable:
              deliverable(id, name, hash)
              |> Map.merge(%{sourceKind: source, sourceWorkItemId: source_work_item})
          }

        [] ->
          %{deliverableContract: "legacy", deliverable: nil}

        _ ->
          inconsistent!("ambiguous assignment deliverable #{assignment_id}")
      end

    Map.put(deliverable_projection, :productLineage, lineage_projection(txn, assignment_id))
  end

  def attest_claim_projection(db, attest_id) do
    query_projection(db, fn txn -> attest_claim_projection_in_txn(txn, attest_id) end)
  end

  def attest_claim_projection_in_txn(txn, attest_id) do
    case Txn.q(
           txn,
           "SELECT d.id,d.name,d.sha256,c.claimedAt FROM completion_claims c JOIN deliverables d ON d.id=c.deliverableId WHERE c.attestId=?1",
           [attest_id]
         ) do
      [[id, name, hash, claimed_at]] ->
        deliverable(id, name, hash) |> Map.put(:claimedAt, claimed_at)

      [] ->
        nil

      _ ->
        inconsistent!("ambiguous completion claim #{attest_id}")
    end
  end

  @doc false
  def prepare_close_in_txn(txn, work_item_id, principal, completion_attest_id, reason) do
    with :ok <- required_attest(completion_attest_id),
         {:ok, resolved_attest_id} <- resolve_completion_attest(txn, completion_attest_id),
         {:ok, claim} <- selected_claim(txn, work_item_id, resolved_attest_id),
         :ok <- no_open_assignments(txn, work_item_id),
         {:ok, card_deliverable_id} <- card_deliverable_id(txn, work_item_id) do
      fingerprint = close_fingerprint(work_item_id, resolved_attest_id, reason)

      if claim.deliverable_id == card_deliverable_id do
        if is_nil(reason) do
          {:ok,
           %{
             basis: "exact",
             card_deliverable_id: card_deliverable_id,
             accepted_deliverable_id: claim.deliverable_id,
             completion_attest_id: resolved_attest_id,
             reason: nil,
             product_owner: nil,
             fingerprint: fingerprint
           }}
        else
          error("owner_ruling_not_applicable", "an exact close cannot carry an owner ruling")
        end
      else
        prepare_narrowing(
          txn,
          work_item_id,
          principal,
          resolved_attest_id,
          reason,
          card_deliverable_id,
          claim.deliverable_id,
          fingerprint
        )
      end
    end
  end

  @doc false
  def insert_closure_in_txn(txn, work_item_id, principal, plan, closed_at) do
    {closed_user, closed_session} = actor(principal)

    Txn.q(
      txn,
      """
      INSERT INTO work_item_closures
        (workItemId,completionAttestId,cardDeliverableId,acceptedDeliverableId,basis,
         ownerRulingReason,ownerRulingProductOwnerSessionKey,closedByUser,closedBySession,
         requestFingerprint,closedAt)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
      """,
      [
        work_item_id,
        plan.completion_attest_id,
        plan.card_deliverable_id,
        plan.accepted_deliverable_id,
        plan.basis,
        plan.reason,
        plan.product_owner,
        closed_user,
        closed_session,
        plan.fingerprint,
        closed_at
      ]
    )

    :ok
  end

  def existing_close_replay_in_txn(txn, work_item_id, _principal, attest_id, reason) do
    case Txn.q(txn, "SELECT requestFingerprint FROM work_item_closures WHERE workItemId=?1", [
           work_item_id
         ]) do
      [[stored]] ->
        case Tightbeam.IdPrefix.resolve_in_txn(txn, :attest, attest_id) do
          {:ok, resolved_attest_id} ->
            if stored == close_fingerprint(work_item_id, resolved_attest_id, reason),
              do: {:ok, closure_projection(txn, work_item_id)},
              else: error("work_item_closed", "work item already has a different closure")

          {:ambiguous, error} ->
            error

          :unknown ->
            error("work_item_closed", "work item already has a different closure")
        end

      [] ->
        :legacy
    end
  end

  defp prepare_narrowing(_txn, _work_item_id, _principal, _attest_id, nil, _card, _accepted, _fp),
    do: error("completion_deliverable_mismatch", "completion claims a different deliverable")

  defp prepare_narrowing(txn, work_item_id, principal, attest_id, reason, card, accepted, fp) do
    owner = card_product_owner(txn, work_item_id)

    cond do
      owner.status in ["unavailable", "retired"] ->
        error("product_owner_unavailable", "card product owner is unavailable")

      principal != {:session, owner.sessionKey} ->
        error("owner_ruling_forbidden", "only the exact card product-owner session can narrow")

      not valid_reason?(reason) ->
        error("owner_ruling_required", "owner ruling reason must be 1..2000 non-blank characters")

      true ->
        {:ok,
         %{
           basis: "owner_narrowing",
           card_deliverable_id: card,
           accepted_deliverable_id: accepted,
           completion_attest_id: attest_id,
           reason: reason,
           product_owner: owner.sessionKey,
           fingerprint: fp
         }}
    end
  end

  defp selected_claim(txn, work_item_id, attest_id) do
    case Txn.q(
           txn,
           """
           SELECT c.assignmentId,c.deliverableId,a.closingAttestId,a.outcome,a.workItemId
           FROM completion_claims c JOIN attests t ON t.id=c.attestId
           JOIN assignments a ON a.id=c.assignmentId
           WHERE c.attestId=?1 AND t.kind='completion'
           """,
           [attest_id]
         ) do
      [] ->
        error("completion_claim_not_found", "completion claim not found")

      [[_assignment, _deliverable, closing, _outcome, _card]] when closing != attest_id ->
        error("completion_claim_stale", "completion is not the current closing attest")

      [[_assignment, _deliverable, _closing, outcome, _card]] when outcome != "completed" ->
        error("completion_claim_stale", "assignment is not completed by this attest")

      [[_assignment, _deliverable, _closing, _outcome, card]] when card != work_item_id ->
        error("completion_claim_wrong_card", "completion claim belongs to another work item")

      [[assignment, deliverable_id, ^attest_id, "completed", ^work_item_id]] ->
        {:ok, %{assignment_id: assignment, deliverable_id: deliverable_id}}

      _ ->
        error("deliverable_contract_inconsistent", "ambiguous completion claim #{attest_id}")
    end
  end

  defp resolve_completion_attest(txn, supplied) do
    case Tightbeam.IdPrefix.resolve_in_txn(txn, :attest, supplied) do
      {:ok, id} -> {:ok, id}
      :unknown -> error("completion_claim_not_found", "completion claim not found")
      {:ambiguous, error} -> error
    end
  end

  defp no_open_assignments(txn, work_item_id) do
    if Txn.q(txn, "SELECT 1 FROM assignments WHERE workItemId=?1 AND state='open' LIMIT 1", [
         work_item_id
       ]) == [], do: :ok, else: error("assignments_open", "work item still has open assignments")
  end

  defp card_deliverable_id(txn, work_item_id) do
    case Txn.q(txn, "SELECT deliverableId FROM work_item_deliverables WHERE workItemId=?1", [
           work_item_id
         ]) do
      [[id]] ->
        {:ok, id}

      _ ->
        error("deliverable_contract_inconsistent", "card deliverable missing for #{work_item_id}")
    end
  end

  defp required_attest(id) when is_binary(id) and id != "", do: :ok

  defp required_attest(_),
    do: error("completion_attest_required", "work-item close requires a completion attest")

  defp closure_projection(txn, work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT c.completionAttestId,c.basis,c.ownerRulingReason,c.ownerRulingProductOwnerSessionKey,
                  c.closedByUser,c.closedBySession,c.closedAt,
                  cd.id,cd.name,cd.sha256,ad.id,ad.name,ad.sha256
           FROM work_item_closures c
           JOIN deliverables cd ON cd.id=c.cardDeliverableId
           JOIN deliverables ad ON ad.id=c.acceptedDeliverableId
           WHERE c.workItemId=?1
           """,
           [work_item_id]
         ) do
      [] ->
        nil

      [
        [
          attest,
          basis,
          reason,
          owner,
          by_user,
          by_session,
          at,
          cid,
          cname,
          chash,
          aid,
          aname,
          ahash
        ]
      ] ->
        %{
          completionAttestId: attest,
          cardDeliverable: deliverable(cid, cname, chash),
          acceptedDeliverable: deliverable(aid, aname, ahash),
          basis: basis,
          ownerRulingReason: reason,
          ownerRulingProductOwnerSessionKey: owner,
          closedByUser: by_user,
          closedBySession: by_session,
          closedAt: at
        }

      _ ->
        inconsistent!("ambiguous closure #{work_item_id}")
    end
  end

  defp lineage_projection(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT workItemId,holderSessionKey,captureKind FROM assignment_product_lineage_captures WHERE assignmentId=?1",
           [assignment_id]
         ) do
      [] ->
        nil

      [[_work_item_id, holder, kind]] ->
        ancestors =
          Txn.q(
            txn,
            "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
            [assignment_id]
          )
          |> Enum.map(fn [key, distance] -> %{sessionKey: key, distance: distance} end)

        %{holderSessionKey: holder, captureKind: kind, productOwnerAncestors: ancestors}

      _ ->
        inconsistent!("ambiguous lineage capture #{assignment_id}")
    end
  end

  defp card_product_owner(txn, work_item_id) do
    assignment_ids =
      Txn.q(txn, "SELECT id FROM assignments WHERE workItemId=?1 ORDER BY id", [work_item_id])
      |> List.flatten()

    captures =
      Enum.map(assignment_ids, fn assignment_id ->
        case Txn.q(
               txn,
               "SELECT workItemId,holderSessionKey FROM assignment_product_lineage_captures WHERE assignmentId=?1",
               [assignment_id]
             ) do
          [[^work_item_id, holder]] ->
            chain = session_chain_for_validation!(txn, holder)

            ancestry =
              Txn.q(
                txn,
                "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
                [assignment_id]
              )

            distances = Map.new(chain, &{&1.key, &1.distance})

            Enum.each(ancestry, fn [key, distance] ->
              if distances[key] != distance,
                do: inconsistent!("assignment_product_owner_ancestry #{assignment_id}")
            end)

            ancestry

          [] ->
            inconsistent!("missing lineage capture #{assignment_id}")

          _ ->
            inconsistent!("assignment_product_lineage_captures #{assignment_id}")
        end
      end)

    common =
      case captures do
        [] ->
          []

        [first | rest] ->
          Enum.filter(first, fn [key, _] ->
            Enum.all?(rest, &Enum.any?(&1, fn [candidate, _] -> candidate == key end))
          end)
      end

    case Enum.min_by(common, fn [_key, distance] -> distance end, fn -> nil end) do
      nil ->
        %{sessionKey: nil, status: "unavailable"}

      [key, _distance] ->
        case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [key]) do
          [[state]] -> %{sessionKey: key, status: state}
          [] -> inconsistent!("missing product-owner session #{key}")
        end
    end
  end

  defp capture_lineage!(txn, assignment_id, work_item_id, holder, kind) do
    chain = session_chain!(txn, holder)

    Txn.q(
      txn,
      "INSERT INTO assignment_product_lineage_captures (assignmentId,workItemId,holderSessionKey,captureKind) VALUES (?1,?2,?3,?4)",
      [assignment_id, work_item_id, holder, kind]
    )

    chain
    |> Enum.filter(fn %{kind: session_kind, archetype: archetype} ->
      session_kind == "custom" and archetype == "product-owner"
    end)
    |> Enum.each(fn %{key: key, distance: distance} ->
      Txn.q(
        txn,
        "INSERT INTO assignment_product_owner_ancestry (assignmentId,productOwnerSessionKey,distance) VALUES (?1,?2,?3)",
        [assignment_id, key, distance]
      )
    end)
  end

  defp session_chain!(txn, holder), do: session_chain!(txn, holder, 0, nil, MapSet.new(), [])

  defp session_chain_for_validation!(txn, holder) do
    session_chain!(txn, holder)
  rescue
    error in MutationError -> inconsistent!(error.response.message)
  end

  defp session_chain!(txn, key, distance, owner, seen, acc) do
    if MapSet.member?(seen, key),
      do:
        raise(MutationError,
          response: error("product_owner_lineage_invalid", "session ancestry cycle")
        )

    case Txn.q(
           txn,
           "SELECT spawnedBy,ownerUserId,kind,archetype FROM sessions WHERE sessionKey=?1",
           [key]
         ) do
      [] ->
        raise MutationError,
          response: error("product_owner_lineage_invalid", "missing session #{key}")

      [[parent, row_owner, kind, archetype]] ->
        if owner && owner != row_owner,
          do:
            raise(MutationError,
              response: error("product_owner_lineage_invalid", "cross-owner session ancestry")
            )

        entry = %{
          key: key,
          distance: distance,
          owner: row_owner,
          kind: kind,
          archetype: archetype
        }

        if parent,
          do:
            session_chain!(txn, parent, distance + 1, row_owner, MapSet.put(seen, key), [
              entry | acc
            ]),
          else: Enum.reverse([entry | acc])
    end
  end

  defp backfill_cards(txn) do
    Txn.q(
      txn,
      "SELECT id,title,createdAt FROM work_items WHERE state IN ('open','iceboxed') ORDER BY id"
    )
    |> Enum.each(fn [id, title, created_at] ->
      deliverable_id = deterministic_id("work_item", id)
      insert_deliverable(txn, deliverable_id, title, created_at)

      Txn.q(txn, "INSERT INTO work_item_deliverables (workItemId,deliverableId) VALUES (?1,?2)", [
        id,
        deliverable_id
      ])
    end)
  end

  defp backfill_assignments(txn) do
    Txn.q(txn, "SELECT id,subject,openedAt FROM assignments WHERE state='open' ORDER BY id")
    |> Enum.each(fn [id, subject, opened_at] ->
      deliverable_id = deterministic_id("assignment", id)
      insert_deliverable(txn, deliverable_id, subject, opened_at)

      Txn.q(
        txn,
        "INSERT INTO assignment_deliverables (assignmentId,deliverableId,sourceKind,sourceWorkItemId) VALUES (?1,?2,'assignment',NULL)",
        [id, deliverable_id]
      )
    end)
  end

  defp backfill_lineage(txn) do
    Txn.q(txn, """
    SELECT a.id,a.workItemId,a.holderKey
    FROM assignments a JOIN work_item_deliverables w ON w.workItemId=a.workItemId
    ORDER BY a.id
    """)
    |> Enum.each(fn [assignment_id, work_item_id, holder] ->
      capture_lineage!(txn, assignment_id, work_item_id, holder, "activation")
    end)
  rescue
    error in MutationError -> inconsistent!(error.response.message)
  end

  defp validate_in_txn!(txn) do
    validate_hashes!(txn)
    validate_cardinality!(txn)
    validate_bindings!(txn)
    validate_lineage!(txn)
    validate_claims_and_closures!(txn)
    :ok
  end

  defp refuse_partial_schema!(txn) do
    placeholders = Enum.map_join(@contract_objects, ",", fn _ -> "?" end)

    case Txn.q(
           txn,
           "SELECT name FROM sqlite_master WHERE name IN (#{placeholders}) ORDER BY name",
           @contract_objects
         ) do
      [] -> :ok
      [[name] | _] -> inconsistent!("partial contract object #{name}")
    end
  end

  defp require_complete_schema!(txn) do
    placeholders = Enum.map_join(@contract_objects, ",", fn _ -> "?" end)

    found =
      Txn.q(
        txn,
        "SELECT name FROM sqlite_master WHERE name IN (#{placeholders}) ORDER BY name",
        @contract_objects
      )
      |> List.flatten()
      |> MapSet.new()

    case Enum.find(@contract_objects, &(not MapSet.member?(found, &1))) do
      nil -> :ok
      name -> inconsistent!("missing contract object #{name}")
    end
  end

  defp validate_hashes!(txn) do
    Enum.each(Txn.q(txn, "SELECT id,name,sha256 FROM deliverables ORDER BY id"), fn [
                                                                                      id,
                                                                                      name,
                                                                                      hash
                                                                                    ] ->
      if sha256(name) != hash, do: inconsistent!("deliverables #{id} wrong hash")
    end)
  end

  defp validate_cardinality!(txn) do
    required_cards =
      Txn.q(txn, "SELECT id FROM work_items WHERE state IN ('open','iceboxed') ORDER BY id")
      |> List.flatten()

    Enum.each(required_cards, fn id ->
      if Txn.q(txn, "SELECT count(*) FROM work_item_deliverables WHERE workItemId=?1", [id]) != [
           [1]
         ],
         do: inconsistent!("work_item_deliverables #{id}")
    end)

    required_assignments =
      Txn.q(txn, "SELECT id FROM assignments WHERE state='open' ORDER BY id") |> List.flatten()

    Enum.each(required_assignments, fn id ->
      if Txn.q(txn, "SELECT count(*) FROM assignment_deliverables WHERE assignmentId=?1", [id]) !=
           [[1]],
         do: inconsistent!("assignment_deliverables #{id}")
    end)
  end

  defp validate_bindings!(txn) do
    Txn.q(
      txn,
      "SELECT a.assignmentId,a.sourceKind,a.sourceWorkItemId,x.workItemId FROM assignment_deliverables a JOIN assignments x ON x.id=a.assignmentId ORDER BY a.assignmentId"
    )
    |> Enum.each(fn [assignment_id, source, source_work_item, linked_work_item] ->
      if source == "work_item" and
           (is_nil(linked_work_item) or source_work_item != linked_work_item),
         do: inconsistent!("assignment_deliverables #{assignment_id} wrong source")
    end)
  end

  defp validate_claims_and_closures!(txn) do
    Txn.q(
      txn,
      """
      SELECT c.attestId,c.assignmentId,c.deliverableId,c.claimedAt,
             t.assignmentId,t.kind,t.ts,a.deliverableId
      FROM completion_claims c
      LEFT JOIN attests t ON t.id=c.attestId
      LEFT JOIN assignment_deliverables a ON a.assignmentId=c.assignmentId
      ORDER BY c.attestId
      """
    )
    |> Enum.each(fn
      [
        _attest_id,
        assignment_id,
        deliverable_id,
        claimed_at,
        assignment_id,
        "completion",
        claimed_at,
        deliverable_id
      ] ->
        :ok

      [attest_id | _] ->
        inconsistent!("completion_claims #{attest_id}")
    end)

    Txn.q(
      txn,
      """
      SELECT c.workItemId,c.completionAttestId,c.cardDeliverableId,c.acceptedDeliverableId,
             c.ownerRulingReason,c.requestFingerprint,w.state,wd.deliverableId,
             cc.deliverableId,a.workItemId
      FROM work_item_closures c
      LEFT JOIN work_items w ON w.id=c.workItemId
      LEFT JOIN work_item_deliverables wd ON wd.workItemId=c.workItemId
      LEFT JOIN completion_claims cc ON cc.attestId=c.completionAttestId
      LEFT JOIN assignments a ON a.id=cc.assignmentId
      ORDER BY c.workItemId
      """
    )
    |> Enum.each(fn
      [
        work_item_id,
        attest_id,
        card_deliverable_id,
        accepted_deliverable_id,
        reason,
        request_fingerprint,
        "closed",
        card_deliverable_id,
        accepted_deliverable_id,
        work_item_id
      ] ->
        if request_fingerprint != close_fingerprint(work_item_id, attest_id, reason),
          do: inconsistent!("work_item_closures #{work_item_id}")

      [work_item_id | _] ->
        inconsistent!("work_item_closures #{work_item_id}")
    end)

    Txn.q(
      txn,
      """
      SELECT i.actorKind,i.actorRef,i.operation,i.idempotencyKey,i.requestFingerprint,
             i.completionAttestId,i.workItemId,cc.attestId,c.requestFingerprint
      FROM deliverable_contract_idempotency i
      LEFT JOIN completion_claims cc ON cc.attestId=i.completionAttestId
      LEFT JOIN work_item_closures c ON c.workItemId=i.workItemId
      ORDER BY i.actorKind,i.actorRef,i.operation,i.idempotencyKey
      """
    )
    |> Enum.each(fn
      [_kind, _ref, "attest-completion", _key, _fingerprint, attest_id, nil, attest_id, nil]
      when not is_nil(attest_id) ->
        :ok

      [_kind, _ref, "work-item-close", _key, fingerprint, nil, work_item_id, nil, fingerprint]
      when not is_nil(work_item_id) ->
        :ok

      [kind, ref, operation, key | _] ->
        inconsistent!("deliverable_contract_idempotency #{kind}:#{ref}:#{operation}:#{key}")
    end)
  end

  defp validate_lineage!(txn) do
    required =
      Txn.q(
        txn,
        "SELECT a.id FROM assignments a JOIN work_item_deliverables w ON w.workItemId=a.workItemId ORDER BY a.id"
      )
      |> List.flatten()

    Enum.each(required, fn assignment_id ->
      if Txn.q(
           txn,
           "SELECT count(*) FROM assignment_product_lineage_captures WHERE assignmentId=?1",
           [assignment_id]
         ) != [[1]],
         do: inconsistent!("assignment_product_lineage_captures #{assignment_id}")
    end)

    Txn.q(
      txn,
      "SELECT assignmentId,workItemId,holderSessionKey FROM assignment_product_lineage_captures ORDER BY assignmentId"
    )
    |> Enum.each(fn [assignment_id, work_item_id, holder] ->
      case Txn.q(txn, "SELECT workItemId,holderKey FROM assignments WHERE id=?1", [assignment_id]) do
        [[^work_item_id, ^holder]] -> :ok
        _ -> inconsistent!("assignment_product_lineage_captures #{assignment_id}")
      end

      chain = session_chain!(txn, holder)

      expected_by_key =
        Map.new(chain, fn entry -> {entry.key, entry.distance} end)

      actual =
        Txn.q(
          txn,
          "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
          [assignment_id]
        )

      Enum.each(actual, fn [key, distance] ->
        if expected_by_key[key] != distance,
          do: inconsistent!("assignment_product_owner_ancestry #{assignment_id}")
      end)
    end)
  rescue
    error in MutationError -> inconsistent!(error.response.message)
  end

  defp insert_deliverable(txn, id, name, created_at) do
    Txn.q(txn, "INSERT INTO deliverables (id,name,sha256,createdAt) VALUES (?1,?2,?3,?4)", [
      id,
      name,
      sha256(name),
      created_at
    ])
  end

  defp deterministic_id(kind, source_id),
    do: "dlv_" <> fingerprint(["completion-attest-card-deliverable-v1", kind, source_id])

  defp deliverable(id, name, hash), do: %{id: id, name: name, sha256: hash}
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp encode(nil), do: <<0>>

  defp encode(value) when is_binary(value),
    do: <<1, byte_size(value)::unsigned-big-64, value::binary>>

  defp encode(value) when is_list(value),
    do: <<2, length(value)::unsigned-big-64>> <> IO.iodata_to_binary(Enum.map(value, &encode/1))

  defp encode(value), do: raise(ArgumentError, "unsupported TBCD1 value: #{inspect(value)}")
  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp actor({:user, id}), do: {id, nil}
  defp actor({:session, id}), do: {nil, id}
  defp receipt_actor({:user, id}), do: {"user", id}
  defp receipt_actor({:session, id}), do: {"session", id}

  defp atomize_keys(value) when is_list(value), do: Enum.map(value, &atomize_keys/1)

  defp atomize_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      atom_key = if is_binary(key), do: String.to_atom(key), else: key
      {atom_key, atomize_keys(item)}
    end)
  end

  defp atomize_keys(value), do: value

  defp valid_reason?(reason),
    do: is_binary(reason) and String.length(String.trim(reason)) in 1..2000

  defp interrupt!(opts, point),
    do:
      if(Keyword.get(opts, :fail_at) == point,
        do: raise("forced deliverable-contract migration interruption"),
        else: :ok
      )

  defp inconsistent!(detail), do: raise(Inconsistent, detail: detail)
  defp error(code, message), do: %{code: code, message: message}

  defp query_projection(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end
end
