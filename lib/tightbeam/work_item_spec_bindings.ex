defmodule Tightbeam.WorkItemSpecBindings do
  @moduledoc """
  Immutable provenance for the reviewed spec revision bound to a work item.

  The owner selects structured evidence. This module verifies only the stored
  row relationships and commits the selected association without interpreting
  artifact or review prose.
  """

  alias Tightbeam.{DB, EventLog, IdPrefix, WorkItems}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.Schema.ShapeError

  @table "work_item_spec_bindings"
  @ddl """
  CREATE TABLE IF NOT EXISTS work_item_spec_bindings (
    workItemId             TEXT PRIMARY KEY REFERENCES work_items(id),
    specRefName            TEXT NOT NULL
                           CHECK(length(trim(specRefName)) BETWEEN 1 AND 2000),
    specRefSha256          TEXT NOT NULL
                           CHECK(length(specRefSha256) = 64 AND
                                 specRefSha256 NOT GLOB '*[^0-9a-f]*'),
    specArtifactId         TEXT NOT NULL REFERENCES artifacts(artifactId),
    producerAssignmentId   TEXT NOT NULL REFERENCES assignments(id),
    reviewAssignmentId     TEXT NOT NULL REFERENCES assignments(id),
    reviewAttestId         TEXT NOT NULL REFERENCES attests(id),
    reviewReportArtifactId TEXT NOT NULL REFERENCES artifacts(artifactId),
    boundByUser            TEXT NULL REFERENCES users(userId),
    boundBySession         TEXT NULL REFERENCES sessions(sessionKey),
    boundAt                INTEGER NOT NULL CHECK(boundAt >= 0),
    CHECK((boundByUser IS NOT NULL) != (boundBySession IS NOT NULL))
  )
  """

  @identity_fields ~w(spec_ref_name spec_ref_sha256 spec_artifact_id review_attest_id review_report_artifact_id)a

  @doc "Create or validate the exact reviewed-spec binding sidecar."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    case DB.transaction(db, fn txn ->
           case Txn.q(txn, "SELECT type, sql FROM sqlite_master WHERE name = ?1", [@table]) do
             [] ->
               :ok = Txn.exec(txn, @ddl)
               validate_schema_in_txn!(txn)

             [["table", _sql]] ->
               validate_schema_in_txn!(txn)

             rows ->
               incompatible!("expected one table, found #{inspect(rows)}")
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, %ShapeError{} = error} -> raise error
      {:error, error} -> incompatible!("activation failed: #{Exception.message(error)}")
    end
  end

  @doc "Bind or exactly replay one reviewed spec association."
  @spec bind(DB.server(), map()) :: map() | Tightbeam.Dispatch.accepted_effect_in_txn()
  def bind(db \\ Tightbeam.DB, call) do
    result =
      case DB.transaction(db, fn txn -> bind_in_txn(txn, call) end) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end

    case result do
      {:accepted_effect_in_txn, _event_id, %{changed: true} = response} = accepted ->
        best_effort(fn -> on_change(call).(response.workItem.id, "metadata") end)
        accepted

      other ->
        other
    end
  end

  @doc "The immutable binding descriptor for one item, or nil."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ Tightbeam.DB, work_item_id) do
    case DB.query(db, "SELECT #{columns()} FROM #{@table} WHERE workItemId = ?1", [work_item_id]) do
      {:ok, [row]} -> binding_descriptor(row)
      {:ok, []} -> nil
    end
  end

  @doc false
  @spec get_in_txn(Txn.t(), String.t()) :: map() | nil
  def get_in_txn(%Txn{} = txn, work_item_id) do
    case Txn.q(txn, "SELECT #{columns()} FROM #{@table} WHERE workItemId = ?1", [work_item_id]) do
      [row] -> binding_descriptor(row)
      [] -> nil
    end
  end

  @doc "Protect a reviewed projection from raw metadata replacement or clearing."
  @spec guard_metadata_update_in_txn(Txn.t(), map(), map(), {term(), term()}) ::
          {:ok, map()} | map()
  def guard_metadata_update_in_txn(%Txn{} = txn, item, params, resulting_pair) do
    spec_fields? =
      Map.has_key?(params, :spec_ref_name) or Map.has_key?(params, :spec_ref_sha256)

    if spec_fields? do
      case get_in_txn(txn, item.id) do
        nil ->
          {:ok, params}

        binding when resulting_pair == {binding.specRefName, binding.specRefSha256} ->
          {:ok, Map.drop(params, [:spec_ref_name, :spec_ref_sha256])}

        _binding ->
          conflict()
      end
    else
      {:ok, params}
    end
  end

  defp bind_in_txn(txn, call) do
    with :ok <- principal_allowed(call.principal),
         :ok <- valid_params(call.params),
         {:ok, item} <- resolve_owned_item(txn, call),
         :ok <- owner_or_admin_recheck(txn, call.principal, item) do
      case get_in_txn(txn, item.id) do
        binding when not is_nil(binding) ->
          replay_or_conflict(txn, call, item, binding)

        nil ->
          first_bind(txn, call, item)
      end
    end
  end

  defp first_bind(txn, call, item) do
    params = call.params

    with :ok <- require_open(item),
         :ok <- require_compatible_projection(item, params),
         :ok <- invoke_injection(call, :on_spec_binding_before_provenance, txn),
         {:ok, provenance} <- verify_provenance(txn, item.id, params) do
      bound_at = now()
      {bound_by_user, bound_by_session} = binding_principal(call.principal)

      if is_nil(item.specRefName) do
        Txn.q(
          txn,
          "UPDATE work_items SET specRefName = ?2, specRefSha256 = ?3 WHERE id = ?1",
          [item.id, params.spec_ref_name, params.spec_ref_sha256]
        )
      end

      Txn.q(
        txn,
        """
        INSERT INTO work_item_spec_bindings
          (workItemId, specRefName, specRefSha256, specArtifactId,
           producerAssignmentId, reviewAssignmentId, reviewAttestId,
           reviewReportArtifactId, boundByUser, boundBySession, boundAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          item.id,
          params.spec_ref_name,
          params.spec_ref_sha256,
          params.spec_artifact_id,
          provenance.producer_assignment_id,
          provenance.review_assignment_id,
          params.review_attest_id,
          params.review_report_artifact_id,
          bound_by_user,
          bound_by_session,
          bound_at
        ]
      )

      invoke_injection(call, :on_spec_binding_before_audit, txn)

      response = response_in_txn(txn, item.id, true)
      accepted(txn, call, response, bound_at)
    end
  end

  defp replay_or_conflict(txn, call, item, binding) do
    if Enum.all?(@identity_fields, &identity_field_equal?(call.params, binding, &1)) do
      response = %{
        changed: false,
        workItem: WorkItems.fetch_public_in_txn(txn, item.id),
        specBinding: binding
      }

      accepted(txn, call, response, now())
    else
      conflict()
    end
  end

  defp accepted(txn, call, response, timestamp) do
    event_id =
      EventLog.append_event_in_txn(
        txn,
        "verb",
        call.verb,
        call.origin,
        call.session_key,
        response,
        call.principal,
        timestamp
      )

    Publisher.accepted_in_txn(txn, call, response)
    {:accepted_effect_in_txn, event_id, response}
  end

  defp response_in_txn(txn, work_item_id, changed) do
    %{
      changed: changed,
      workItem: WorkItems.fetch_public_in_txn(txn, work_item_id),
      specBinding: get_in_txn(txn, work_item_id)
    }
  end

  defp resolve_owned_item(txn, call) do
    visible? = fn id ->
      case WorkItems.fetch_in_txn(txn, id) do
        nil -> false
        item -> owner_or_admin?(txn, call.principal, item)
      end
    end

    case IdPrefix.resolve_in_txn(txn, :work_item, call.params.work_item_id, visible?) do
      {:ok, id} ->
        WorkItems.id_resolved_in_txn(call, txn, :work_item, id)

        case WorkItems.fetch_in_txn(txn, id) do
          nil -> not_found()
          item -> {:ok, item}
        end

      :unknown ->
        not_found()

      {:ambiguous, error} ->
        error
    end
  end

  defp owner_or_admin_recheck(txn, principal, item) do
    if owner_or_admin?(txn, principal, item), do: :ok, else: not_found()
  end

  defp owner_or_admin?(txn, {:user, user}, item),
    do: user == item.ownerUserId or admin_user?(txn, user)

  defp owner_or_admin?(txn, {:session, session}, item) do
    case Txn.q(
           txn,
           "SELECT u.userId, u.isAdmin FROM sessions s JOIN users u ON u.userId = s.ownerUserId WHERE s.sessionKey = ?1",
           [session]
         ) do
      [[owner, admin]] -> owner == item.ownerUserId or admin == 1
      _ -> false
    end
  end

  defp owner_or_admin?(_txn, _principal, _item), do: false

  defp admin_user?(txn, user),
    do: Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) == [[1]]

  defp verify_provenance(txn, work_item_id, params) do
    with {:ok, review} <- verified_review(txn, params.review_attest_id),
         :ok <- producer_on_item(txn, review.producer_assignment_id, work_item_id),
         :ok <- verified_spec_artifact(txn, work_item_id, params, review),
         :ok <- verified_review_report(txn, work_item_id, params, review) do
      {:ok,
       %{
         producer_assignment_id: review.producer_assignment_id,
         review_assignment_id: review.review_assignment_id
       }}
    end
  end

  defp verified_review(txn, review_attest_id) do
    rows =
      Txn.q(
        txn,
        """
        SELECT a.id, a.kind, a.verdictKind, a.bySession, a.ts,
               r.id, r.holderKey, r.openedAt, r.state, r.outcome,
               r.reviewsAssignmentId, e.effectKind,
               p.holderKey
        FROM attests a
        JOIN assignments r ON r.id = a.assignmentId
        LEFT JOIN assignment_effects e ON e.assignmentId = r.id
        LEFT JOIN assignments p ON p.id = r.reviewsAssignmentId
        WHERE a.id = ?1
        """,
        [review_attest_id]
      )

    case rows do
      [
        [
          ^review_attest_id,
          "verdict",
          "reviewed-clean",
          reviewer,
          verdict_at,
          review_assignment_id,
          reviewer,
          opened_at,
          "closed",
          "completed",
          producer_assignment_id,
          "review",
          producer
        ]
      ]
      when is_binary(reviewer) and is_binary(producer) and reviewer != producer ->
        latest =
          Txn.q(
            txn,
            """
            SELECT id FROM attests
            WHERE assignmentId = ?1 AND kind = 'verdict' AND bySession = ?2
            ORDER BY ts DESC, rowid DESC LIMIT 1
            """,
            [review_assignment_id, reviewer]
          )

        if latest == [[review_attest_id]] do
          {:ok,
           %{
             review_assignment_id: review_assignment_id,
             producer_assignment_id: producer_assignment_id,
             reviewer: reviewer,
             producer: producer,
             opened_at: opened_at,
             verdict_at: verdict_at
           }}
        else
          unverified("reviewAttestId")
        end

      _ ->
        unverified("reviewAttestId")
    end
  end

  defp producer_on_item(txn, producer_assignment_id, work_item_id) do
    if Tightbeam.Assignments.resolved_work_item_id_in_txn(txn, producer_assignment_id) ==
         work_item_id,
       do: :ok,
       else: unverified("reviewAttestId")
  end

  defp verified_spec_artifact(txn, work_item_id, params, review) do
    rows =
      Txn.q(
        txn,
        """
        SELECT artifactId, kind, workItemId, contentSha256, createdBySession,
               originPath, home, createdAt
        FROM artifacts WHERE artifactId = ?1
        """,
        [params.spec_artifact_id]
      )

    case rows do
      [
        [
          artifact_id,
          "spec",
          ^work_item_id,
          digest,
          producer,
          origin_path,
          home,
          created_at
        ]
      ]
      when artifact_id == params.spec_artifact_id and digest == params.spec_ref_sha256 and
             producer == review.producer and created_at <= review.opened_at ->
        newest =
          Txn.q(
            txn,
            """
            SELECT artifactId FROM artifacts
            WHERE workItemId = ?1 AND kind = 'spec' AND createdBySession = ?2
              AND createdAt <= ?3
            ORDER BY createdAt DESC, artifactId DESC LIMIT 1
            """,
            [work_item_id, producer, review.opened_at]
          )

        path_matches =
          path_matches?(origin_path, params.spec_ref_name) or
            (is_binary(home) and path_matches?(home, params.spec_ref_name))

        if newest == [[artifact_id]] and path_matches do
          :ok
        else
          unverified("specArtifactId")
        end

      _ ->
        unverified("specArtifactId")
    end
  end

  defp verified_review_report(txn, work_item_id, params, review) do
    rows =
      Txn.q(
        txn,
        """
        SELECT artifactId, kind, workItemId, createdBySession, createdAt
        FROM artifacts WHERE artifactId = ?1
        """,
        [params.review_report_artifact_id]
      )

    case rows do
      [[artifact_id, "report", ^work_item_id, reviewer, created_at]]
      when artifact_id == params.review_report_artifact_id and reviewer == review.reviewer and
             created_at >= review.opened_at and created_at <= review.verdict_at ->
        newest =
          Txn.q(
            txn,
            """
            SELECT artifactId FROM artifacts
            WHERE workItemId = ?1 AND kind = 'report' AND createdBySession = ?2
              AND createdAt >= ?3 AND createdAt <= ?4
            ORDER BY createdAt DESC, artifactId DESC LIMIT 1
            """,
            [work_item_id, reviewer, review.opened_at, review.verdict_at]
          )

        if newest == [[artifact_id]], do: :ok, else: unverified("reviewReportArtifactId")

      _ ->
        unverified("reviewReportArtifactId")
    end
  end

  defp path_matches?(path, name) when is_binary(path) do
    path == name or String.ends_with?(path, "/" <> name) or String.ends_with?(path, ":" <> name)
  end

  defp path_matches?(_path, _name), do: false

  defp require_open(%{state: "open"}), do: :ok

  defp require_open(_item),
    do: error("work_item_not_open", "work item must be open for its first reviewed spec binding")

  defp require_compatible_projection(%{specRefName: nil, specRefSha256: nil}, _params), do: :ok

  defp require_compatible_projection(item, params) do
    if item.specRefName == params.spec_ref_name and item.specRefSha256 == params.spec_ref_sha256,
      do: :ok,
      else: conflict()
  end

  defp identity_field_equal?(params, binding, field) do
    binding_field =
      %{
        spec_ref_name: :specRefName,
        spec_ref_sha256: :specRefSha256,
        spec_artifact_id: :specArtifactId,
        review_attest_id: :reviewAttestId,
        review_report_artifact_id: :reviewReportArtifactId
      }[field]

    params[field] == binding[binding_field]
  end

  defp valid_params(params) when is_map(params) do
    values =
      ~w(work_item_id spec_ref_name spec_ref_sha256 spec_artifact_id review_attest_id review_report_artifact_id)a
      |> Enum.map(&params[&1])

    valid =
      Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) and
        String.length(String.trim(params.spec_ref_name)) in 1..2000 and
        String.match?(params.spec_ref_sha256, ~r/^[0-9a-f]{64}$/)

    if valid,
      do: :ok,
      else: error("invalid_spec_binding", "reviewed spec binding fields are invalid")
  end

  defp valid_params(_),
    do: error("invalid_spec_binding", "reviewed spec binding fields are invalid")

  defp principal_allowed({:process, _}),
    do: error("process_denied", "process principals cannot bind reviewed specs")

  defp principal_allowed(nil),
    do: error("principal_required", "reviewed spec binding requires a user or session principal")

  defp principal_allowed({kind, value}) when kind in [:user, :session] and is_binary(value),
    do: :ok

  defp principal_allowed(_),
    do: error("principal_required", "reviewed spec binding requires a user or session principal")

  defp binding_principal({:user, user}), do: {user, nil}
  defp binding_principal({:session, session}), do: {nil, session}

  defp binding_descriptor([
         _work_item_id,
         spec_ref_name,
         spec_ref_sha256,
         spec_artifact_id,
         producer_assignment_id,
         review_assignment_id,
         review_attest_id,
         review_report_artifact_id,
         bound_by_user,
         bound_by_session,
         bound_at
       ]) do
    %{
      specRefName: spec_ref_name,
      specRefSha256: spec_ref_sha256,
      specArtifactId: spec_artifact_id,
      producerAssignmentId: producer_assignment_id,
      reviewAssignmentId: review_assignment_id,
      reviewAttestId: review_attest_id,
      reviewReportArtifactId: review_report_artifact_id,
      boundByUser: bound_by_user,
      boundBySession: bound_by_session,
      boundAt: bound_at
    }
  end

  defp columns do
    "workItemId, specRefName, specRefSha256, specArtifactId, producerAssignmentId, " <>
      "reviewAssignmentId, reviewAttestId, reviewReportArtifactId, boundByUser, " <>
      "boundBySession, boundAt"
  end

  defp validate_schema_in_txn!(txn) do
    case Txn.q(txn, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1", [@table]) do
      [[actual]] when is_binary(actual) ->
        if normalize_sql(actual) == normalize_sql(@ddl),
          do: :ok,
          else: incompatible!("malformed #{@table}")

      rows ->
        incompatible!("expected one #{@table} table, found #{inspect(rows)}")
    end
  end

  defp normalize_sql(sql) do
    sql
    |> String.downcase()
    |> String.replace(~r/\bif\s+not\s+exists\b/u, "")
    |> String.replace(~r/\s+/u, "")
    |> String.trim_trailing(";")
  end

  defp incompatible!(detail),
    do: raise(ShapeError, message: "incompatible_work_item_spec_binding_v1: #{detail}")

  defp conflict do
    error(
      "spec_binding_conflict",
      "reviewed spec binding is immutable; read it and open an owner decision for a new governing spec"
    )
  end

  defp unverified(field) do
    error(
      "spec_provenance_unverified",
      "#{field} does not identify verified same-item evidence; supply same-item structured evidence"
    )
  end

  defp not_found, do: error("not_found", "work item not found")
  defp error(code, message), do: %{code: code, message: message}

  defp invoke_injection(call, key, txn) do
    case call[key] do
      fun when is_function(fun, 1) -> fun.(txn)
      _ -> :ok
    end
  end

  defp on_change(call), do: Map.get(call, :on_work_item_change, fn _, _ -> :ok end)

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp now, do: System.system_time(:millisecond)
end
