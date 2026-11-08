defmodule Tightbeam.OperationalReceipts do
  @moduledoc """
  Receipt verification for operational assignments.

  An assignment whose recorded effect kind is `live_mutation` or `evidence` does
  its work outside a repository, so its producer cannot cite commits. Its holder
  verifies it instead by citing recorded artifacts as receipts,
  `<artifactId>:<sha256>`. Each receipt must be in tracked custody, recorded on
  the assignment's work item, and match the hash recorded on its row (and the
  captured bytes, where they were captured). The receipts are stored with the
  verdict in the same transaction and shown with it.

  The effect kind is the opener's recorded choice; offered evidence never
  changes it. Code work keeps its commit evidence, and receipts never read or
  require a review.
  """

  alias Tightbeam.{DB, Mementos}
  alias Tightbeam.DB.Txn

  @operational_kinds ~w(live_mutation evidence)
  @receipt ~r/\A([^:\s]+):([0-9a-f]{64})\z/

  @ddl """
  CREATE TABLE IF NOT EXISTS attest_receipts (
    attestId   TEXT NOT NULL REFERENCES attests(id),
    ordinal    INTEGER NOT NULL CHECK (ordinal >= 1),
    artifactId TEXT NOT NULL REFERENCES artifacts(artifactId),
    sha256     TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 = lower(sha256)),
    PRIMARY KEY (attestId, ordinal),
    UNIQUE (attestId, artifactId)
  );
  """

  @doc "Install the additive receipt store."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "The effect kinds whose producers verify from receipts."
  def operational_kinds, do: @operational_kinds

  @doc "Whether a recorded effect kind is operational."
  def operational?(effect_kind), do: effect_kind in @operational_kinds

  @doc """
  Validate the submitted receipts for a holder `verified` verdict on an open
  operational producing assignment and return them in submission order.

  Raises `Mementos.Refusal` with `operational_receipts_not_applicable` when the
  attest is anything else, or with one `operational_receipt_*` code naming every
  failing receipt.
  """
  def prepare!(%Txn{} = txn, call, assignment) do
    receipts = call.params[:receipts]
    not_applicable!(call, assignment)

    unless is_list(receipts) and receipts != [] do
      refuse!(
        "operational_receipt_malformed",
        "at least one receipt is required, each as <artifactId>:<sha256>"
      )
    end

    {checked, _seen} =
      Enum.map_reduce(receipts, MapSet.new(), fn raw, seen ->
        case parse(raw) do
          {:ok, id, digest} ->
            if MapSet.member?(seen, id),
              do:
                {{:error, display(raw), "operational_receipt_malformed", "duplicate receipt"},
                 seen},
              else: {check(txn, id, digest, assignment.work_item_id), MapSet.put(seen, id)}

          :error ->
            {{:error, display(raw), "operational_receipt_malformed",
              "expected <artifactId>:<64 lowercase hex sha256>"}, seen}
        end
      end)

    case Enum.filter(checked, &match?({:error, _, _, _}, &1)) do
      [] ->
        Enum.map(checked, fn {:ok, id, digest} -> %{artifactId: id, sha256: digest} end)

      [{:error, _, code, _} | _] = failures ->
        refuse!(
          code,
          "receipt verification refused, nothing was recorded: " <>
            Enum.map_join(failures, "; ", fn {:error, receipt, failure, reason} ->
              "#{receipt}: #{failure}: #{reason}"
            end)
        )
    end
  end

  @doc """
  Refuse receipts on anything but a `verified` verdict, whatever the
  assignment's state.
  """
  def verified_verdict!(call) do
    unless call.params[:kind] == "verdict" and call.params[:verdict_kind] == "verified" do
      refuse!(
        "operational_receipts_not_applicable",
        "receipts are accepted only on a `--kind verdict --verdict verified` attest"
      )
    end

    :ok
  end

  defp not_applicable!(call, assignment) do
    verified_verdict!(call)

    reason =
      cond do
        is_nil(assignment) ->
          "receipts verify only producing assignments, not review cards"

        call.principal != {:session, assignment.holder_key} ->
          "only the assignment's holder #{assignment.holder_key} may verify it from receipts"

        not operational?(assignment.effect_kind) ->
          "effect kind #{assignment.effect_kind} is not operational; receipts verify " <>
            "live_mutation and evidence assignments, and code requires commitRefs"

        true ->
          nil
      end

    if reason, do: refuse!("operational_receipts_not_applicable", reason)
  end

  defp parse(raw) when is_binary(raw) do
    case Regex.run(@receipt, raw) do
      [_, id, digest] -> {:ok, id, digest}
      nil -> :error
    end
  end

  defp parse(_raw), do: :error

  defp display(raw), do: inspect(raw)

  defp check(txn, id, digest, work_item_id) do
    case Txn.q(txn, "SELECT state,workItemId,contentSha256 FROM artifacts WHERE artifactId=?1", [
           id
         ]) do
      [[state, _item, _hash]] when state == "released" ->
        missing(id, work_item_id, "artifact #{id} has been released from custody")

      [] ->
        missing(id, work_item_id, "no artifact #{id} is on record")

      [[_state, item, hash]] ->
        cond do
          is_nil(item) or is_nil(work_item_id) or item != work_item_id ->
            {:error, id, "operational_receipt_unlinked",
             "artifact is on work item #{item || "none"}, the assignment is on " <>
               "#{work_item_id || "none"}; cite a receipt recorded on " <>
               "#{work_item_id || "the assignment's work item"}"}

          is_nil(hash) ->
            {:error, id, "operational_receipt_hash_mismatch",
             "the artifact row records no hash; record a corrected artifact, " <>
               "never re-run the operation"}

          hash != digest ->
            {:error, id, "operational_receipt_hash_mismatch",
             "recorded hash is #{hash}; cite #{id}:#{hash} if that is the receipt you mean, " <>
               "otherwise record a corrected artifact, never re-run the operation"}

          not captured_bytes_match?(txn, id, hash) ->
            {:error, id, "operational_receipt_hash_mismatch",
             "the captured bytes do not hash to the recorded #{hash}; record a corrected " <>
               "artifact, never re-run the operation"}

          true ->
            {:ok, id, digest}
        end
    end
  end

  defp missing(id, work_item_id, reason) do
    {:error, id, "operational_receipt_missing",
     "#{reason}; cite an artifact recorded on this work item and still in custody " <>
       "(tightbeam artifacts --work-item #{work_item_id || "<workItemId>"})"}
  end

  # Captured bytes, where this line stores them, must hash to the row's hash.
  defp captured_bytes_match?(txn, id, hash) do
    case Txn.q(txn, "SELECT contentSha256,content FROM artifact_contents WHERE artifactId=?1", [
           id
         ]) do
      [] ->
        true

      [[stored, bytes]] ->
        stored == hash and Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
    end
  end

  @doc "Store an accepted verdict's receipts in submission order."
  def write_in_txn(%Txn{} = txn, attest_id, receipts) do
    receipts
    |> Enum.with_index(1)
    |> Enum.each(fn {%{artifactId: id, sha256: digest}, ordinal} ->
      Txn.q(
        txn,
        "INSERT INTO attest_receipts(attestId,ordinal,artifactId,sha256) VALUES(?1,?2,?3,?4)",
        [attest_id, ordinal, id, digest]
      )
    end)
  end

  @doc "Add `receipts` to each listed attest that has any."
  def attach(db, attests) do
    ids = Enum.map(attests, & &1.id)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT attestId,artifactId,sha256 FROM attest_receipts
        WHERE attestId IN (SELECT value FROM json_each(?1))
        ORDER BY attestId,ordinal
        """,
        [JSON.encode!(ids)]
      )

    by_attest =
      Enum.group_by(rows, &hd/1, fn [_attest, id, digest] -> %{artifactId: id, sha256: digest} end)

    Enum.map(attests, fn attest ->
      case Map.get(by_attest, attest.id) do
        nil -> attest
        receipts -> Map.put(attest, :receipts, receipts)
      end
    end)
  end

  @doc """
  The operational verification shown with an operational assignment whose
  latest holder `verified` is receipt-verified, or nil.

  `review` is the review conclusion the line's existing selector chose, shown
  for context only; it is never producer verification.
  """
  def verification(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT v.id, v.verdictKind, a.holderKey, COALESCE(e.effectKind,'code')
        FROM assignments a
        LEFT JOIN assignment_effects e ON e.assignmentId = a.id
        JOIN attests v ON v.assignmentId = a.id
        WHERE a.id = ?1 AND a.reviewsAssignmentId IS NULL
          AND v.kind = 'verdict' AND v.bySession = a.holderKey
          AND v.verdictKind IN ('verified','verification-failed')
        ORDER BY v.ts DESC, v.rowid DESC
        LIMIT 1
        """,
        [assignment_id]
      )

    with [[attest_id, "verified", holder, effect_kind]] <- rows,
         true <- operational?(effect_kind),
         {:ok, [_ | _] = receipts} <-
           DB.query(
             db,
             "SELECT artifactId,sha256 FROM attest_receipts WHERE attestId=?1 ORDER BY ordinal",
             [attest_id]
           ) do
      %{
        verifiedAttestId: attest_id,
        receipts: Enum.map(receipts, fn [id, digest] -> %{artifactId: id, sha256: digest} end),
        review: Tightbeam.Assignments.review_conclusion(db, assignment_id, holder)
      }
    else
      _ -> nil
    end
  end

  defp refuse!(code, message), do: raise(Mementos.Refusal, code: code, message: message)
end
