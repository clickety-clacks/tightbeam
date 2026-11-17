defmodule Tightbeam.AttestEvidence do
  @moduledoc false

  alias Tightbeam.{FileEffectEvidence, Mementos, OperationalEvidence, RecordFyis, Rules}
  alias Tightbeam.DB.Txn

  # This is called with the dispatch snapshot pinned in the transaction owner.
  # Selection uses stored assignment scope; submitted evidence never selects a route.
  def prepare_in_txn!(%Txn{} = txn, original) do
    call = Mementos.prepare_call!(original)

    if call.params[:kind] == "verdict" do
      case {call.params[:verdict_kind], producing_assignment(txn, call.params[:assignment_id])} do
        {"verified", assignment} when not is_nil(assignment) ->
          prepare_verified!(txn, call, assignment)

        {"reviewed-clean", nil} ->
          prepare_review!(txn, call)

        _ ->
          call
      end
    else
      call
    end
  end

  defp prepare_review!(txn, call) do
    case Txn.q(txn, "SELECT reviewsAssignmentId FROM assignments WHERE id=?1", [
           call.params[:assignment_id]
         ]) do
      [[source_id]] when is_binary(source_id) ->
        case producing_assignment(txn, source_id) do
          nil -> call
          source -> bind_review_evidence!(txn, call, source_id, source)
        end

      _ ->
        call
    end
  end

  defp bind_review_evidence!(txn, call, source_id, source) do
    source_call = put_in(call, [:params, :assignment_id], source_id)
    selected = Rules.select_policy(txn, "attest-operational-evidence", source_call)
    phase = Rules.active_admission_contract("attest")

    if not source.files_present and
         not (phase == "legacy" and source.effect_kind == "code") and
         match?({:ok, _}, selected) do
      require_pair!(call)

      case Txn.q(
             txn,
             """
             SELECT artifactId,contentSha256 FROM attests
             WHERE assignmentId=?1 AND kind='verdict' AND verdictKind='verified'
             ORDER BY ts DESC,rowid DESC LIMIT 1
             """,
             [source_id]
           ) do
        [[artifact_id, digest]] when is_binary(artifact_id) ->
          if artifact_id == call.params[:artifact_id] and digest == call.params[:content_sha256] do
            Map.put(call, :validated_review_evidence, %{artifact_id: artifact_id, sha256: digest})
          else
            # Spec row A10: a different pair is recorded with an FYI.
            RecordFyis.note(
              call,
              "#{cited_pair(call)}; the producer's latest verified verdict cites " <>
                "artifact #{artifact_id} sha256 #{digest}"
            )
          end

        _ ->
          RecordFyis.note(
            call,
            "#{cited_pair(call)}; the producer has no verified verdict with an artifact"
          )
      end
    else
      call
    end
  end

  defp cited_pair(call),
    do:
      "this review cites artifact #{call.params[:artifact_id]} " <>
        "sha256 #{call.params[:content_sha256]}"

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
    operational_policy = Rules.select_policy(txn, "attest-operational-evidence", call)
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
      phase == "legacy" and assignment.effect_kind == "code" and not file_manifest_supplied? ->
        call

      # Spec row A12: when the artifact does not fit the selected evidence
      # route, the pair is recorded without route validation and an FYI says so.
      assignment.files_present and artifact_supplied? and
        match?({:ok, _}, operational_policy) and not file_manifest_supplied? ->
        unchecked_route(call, "operational", "declared files are present")

      assignment.files_present and phase == "replacement" ->
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

          :none when artifact_supplied? ->
            unchecked_route(call, "operational", "declared files are present")

          :none ->
            call
        end

      assignment.files_present and artifact_supplied? ->
        unchecked_route(call, "operational", "declared files are present")

      not assignment.files_present and
        not (phase == "legacy" and assignment.effect_kind == "code") and
          match?({:ok, _}, operational_policy) ->
        require_pair!(call)
        validated_operational_evidence(txn, call)

      not assignment.files_present and assignment.effect_kind != "code" and artifact_supplied? ->
        # A captured artifact can substantiate non-code work even when no
        # operational evidence policy is selected. Keep validating its bytes
        # and attribution, and leave code verification on its commit-ref path.
        require_pair!(call)
        validated_operational_evidence(txn, call)

      not assignment.files_present and artifact_supplied? ->
        unchecked_route(call, "operational", "no operational evidence policy is selected")

      true ->
        call
    end
  end

  # Mismatches the operational evidence check finds are recorded as FYIs with
  # the verdict (spec rows A13 to A15).
  defp validated_operational_evidence(txn, call) do
    {validated, facts} = OperationalEvidence.validate!(txn, call)

    facts
    |> Enum.reduce(call, &RecordFyis.note(&2, &1))
    |> Map.put(:validated_operational_evidence, validated)
  end

  defp unchecked_route(call, route, reason),
    do:
      RecordFyis.note(
        call,
        "the artifact on this verdict was not checked as #{route} evidence because " <>
          "#{reason} for this assignment"
      )

  defp require_pair!(call) do
    unless is_binary(call.params[:artifact_id]) and call.params[:artifact_id] != "" and
             is_binary(call.params[:content_sha256]) and call.params[:content_sha256] != "" do
      refuse!(
        "operational_evidence_invalid",
        "artifactId and contentSha256 are required together"
      )
    end
  end

  defp refuse!(code, message), do: raise(Mementos.Refusal, code: code, message: message)
end
