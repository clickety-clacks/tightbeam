defmodule Tightbeam.OperationalEvidence do
  @moduledoc false

  alias Tightbeam.{ArtifactEvidence, Artifacts, Mementos}
  alias Tightbeam.DB.Txn

  # Eligibility and the applicable evidence route belong to the loaded policy.
  # This checks only the submitted artifact and its original producer. It
  # returns the validated pair and the plain facts of any mismatch it found.
  def validate!(%Txn{} = txn, call) do
    assignment_id = call.params[:assignment_id]
    artifact_id = call.params[:artifact_id]
    digest = call.params[:content_sha256]

    {holder, work_item_id} =
      case Txn.q(
             txn,
             """
             SELECT a.holderKey,a.workItemId
             FROM assignments a
             JOIN sessions s ON s.sessionKey=a.holderKey
             JOIN work_items w ON w.id=a.workItemId
             WHERE a.id=?1 AND a.state='open' AND a.reviewsAssignmentId IS NULL
               AND s.state='active' AND s.ownerUserId=w.ownerUserId
             """,
             [assignment_id]
           ) do
        [[holder, item]] when call.principal == {:session, holder} ->
          {holder, item}

        _ ->
          invalid!(
            "assignment",
            "requires the active original holder of an open producing assignment"
          )
      end

    artifact = Artifacts.get_in_txn(txn, artifact_id)
    unless artifact, do: unavailable!(artifact_id)

    unless same_owner?(txn, artifact, work_item_id),
      do: invalid!("artifact attribution", "must belong to the same owner user")

    unless is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: invalid!("contentSha256", "does not match the captured artifact bytes")

    # Spec row A14: attribution differences within one owner user are facts.
    attribution =
      [
        artifact.created_by_session != holder &&
          "by #{artifact.created_by_session || "no session"}",
        artifact.produced_by_assignment_id != assignment_id &&
          "for assignment #{artifact.produced_by_assignment_id || "none"}",
        artifact.work_item_id != work_item_id && "on work item #{artifact.work_item_id || "none"}"
      ]
      |> Enum.filter(& &1)

    facts =
      if attribution == [],
        do: [],
        else: ["artifact #{artifact_id} was recorded " <> Enum.join(attribution, " ")]

    content = ArtifactEvidence.get(call, artifact)

    # Spec rows A13 and A15: missing captured content and differing digests
    # are recorded as facts.
    {facts, actual} =
      case content do
        nil ->
          {facts ++
             [
               "artifact #{artifact_id} has no captured content, so its sha256 was not " <>
                 "compared with its bytes"
             ], nil}

        %{actual: actual} ->
          if digest == actual,
            do: {facts, actual},
            else:
              {facts ++
                 [
                   "the captured bytes of artifact #{artifact_id} have sha256 #{actual}; " <>
                     "this verdict cites #{digest}"
                 ], actual}
      end

    recorded = artifact.content_sha256

    facts =
      if digest != recorded and recorded != actual,
        do:
          facts ++
            [
              "artifact #{artifact_id} is recorded with sha256 #{recorded || "none"}; " <>
                "this verdict cites sha256 #{digest}"
            ],
        else: facts

    {%{assignment_id: assignment_id, artifact_id: artifact_id, sha256: digest}, facts}
  end

  # The artifact belongs to the owner user of its work item, or of the session
  # that recorded it when it names no work item.
  defp same_owner?(txn, artifact, work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT COALESCE(aw.ownerUserId, creator.ownerUserId), w.ownerUserId
           FROM work_items w
           LEFT JOIN work_items aw ON aw.id=?2
           LEFT JOIN sessions creator ON creator.sessionKey=?3
           WHERE w.id=?1
           """,
           [work_item_id, artifact.work_item_id, artifact.created_by_session]
         ) do
      [[owner, owner]] when is_binary(owner) -> true
      _ -> false
    end
  end

  defp unavailable!(id),
    do:
      raise(Mementos.Refusal,
        code: "content_not_captured",
        message: "captured content unavailable for #{id}; record a corrected immutable artifact"
      )

  defp invalid!(field, reason),
    do:
      raise(Mementos.Refusal,
        code: "operational_evidence_invalid",
        message: "#{field}: #{reason}; record a corrected immutable artifact"
      )
end
