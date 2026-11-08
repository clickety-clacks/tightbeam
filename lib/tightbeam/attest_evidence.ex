defmodule Tightbeam.AttestEvidence do
  @moduledoc false

  alias Tightbeam.{FileEffectEvidence, Mementos, OperationalReceipts, Rules}
  alias Tightbeam.DB.Txn

  # This is called with the dispatch snapshot pinned in the transaction owner.
  # Selection uses stored assignment scope; submitted evidence never selects a route.
  def prepare_in_txn!(%Txn{} = txn, original) do
    call = Mementos.prepare_call!(original)
    call = prepare_receipts!(txn, call)

    if call.params[:kind] == "verdict" and call.params[:verdict_kind] == "verified" do
      case producing_assignment(txn, call.params[:assignment_id]) do
        nil -> call
        assignment -> prepare_verified!(txn, call, assignment)
      end
    else
      call
    end
  end

  # Receipts are producer evidence for operational assignments only. The
  # recorded effect kind decides; review state is never read here.
  defp prepare_receipts!(txn, call) do
    if is_nil(call.params[:receipts]) do
      call
    else
      case Txn.q(
             txn,
             """
             SELECT a.reviewsAssignmentId, a.holderKey, a.workItemId, a.state,
                    COALESCE(e.effectKind, 'code')
             FROM assignments a
             LEFT JOIN assignment_effects e ON e.assignmentId = a.id
             WHERE a.id = ?1
             """,
             [call.params[:assignment_id]]
           ) do
        [[nil, holder, work_item_id, "open", effect_kind]] ->
          receipts =
            OperationalReceipts.prepare!(txn, call, %{
              holder_key: holder,
              work_item_id: work_item_id,
              effect_kind: effect_kind
            })

          Map.put(call, :validated_receipts, receipts)

        [[review_of, _holder, _item, "open", _effect_kind]] when is_binary(review_of) ->
          OperationalReceipts.prepare!(txn, call, nil)

        # Unknown and closed assignments keep their existing refusals.
        _ ->
          call
      end
    end
  end

  defp producing_assignment(txn, id) do
    case Txn.q(
           txn,
           """
           SELECT COALESCE(e.effectKind, 'code'),
                  EXISTS(SELECT 1 FROM assignment_files WHERE assignmentId = a.id)
           FROM assignments a
           LEFT JOIN assignment_effects e ON e.assignmentId = a.id
           WHERE a.id=?1 AND a.reviewsAssignmentId IS NULL
           """,
           [id]
         ) do
      [[effect_kind, files_present]] ->
        %{effect_kind: effect_kind, files_present: files_present == 1}

      [] ->
        nil
    end
  end

  defp prepare_verified!(txn, call, assignment) do
    file_policy = Rules.select_policy(txn, "attest-file-effect-evidence", call)
    phase = Rules.active_admission_contract("attest")

    artifact_supplied? =
      not is_nil(call.params[:artifact_id]) or
        not is_nil(call.params[:content_sha256])

    file_manifest_supplied? =
      case file_policy do
        {:ok, %{evidence_memento: name}} ->
          call.memento_writes |> Map.new() |> Map.get(name, []) |> Enum.any?()

        :none ->
          false
      end

    cond do
      # Receipts verify the operation; declared files never select or block that
      # route. A file-effect manifest submitted with receipts is validated too.
      Map.has_key?(call, :validated_receipts) ->
        if assignment.files_present and phase == "replacement" and file_manifest_supplied?,
          do: validate_file_effect!(txn, call, file_policy),
          else: call

      phase == "legacy" and assignment.effect_kind == "code" and not file_manifest_supplied? ->
        call

      assignment.files_present and phase == "replacement" ->
        validate_file_effect!(txn, call, file_policy)

      assignment.files_present and artifact_supplied? ->
        refuse!(
          "file_effect_evidence_policy_inactive",
          "file evidence requires replacement policy"
        )

      true ->
        call
    end
  end

  defp validate_file_effect!(txn, call, file_policy) do
    case file_policy do
      {:ok, policy} ->
        result =
          FileEffectEvidence.validate!(
            txn,
            call,
            policy.evidence_memento,
            Rules.effective_snapshot().revision
          )

        call
        |> Map.put(:validated_file_effect, result)
        |> Map.put(:file_effect_manifest, %{valid: true})
        |> Map.put(:memento_comparison_value, result.comparison_value)

      :none ->
        refuse!("file_effect_evidence_policy_inactive", "no file evidence policy selected")
    end
  end

  defp refuse!(code, message), do: raise(Mementos.Refusal, code: code, message: message)
end
