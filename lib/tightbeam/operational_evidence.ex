defmodule Tightbeam.OperationalEvidence do
  @moduledoc false

  alias Tightbeam.{ArtifactContent, Artifacts, Mementos}
  alias Tightbeam.DB.Txn

  # Eligibility and the applicable evidence route belong to the loaded policy.
  # This checks only the submitted artifact and its original producer.
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

    unless artifact.produced_by_assignment_id == assignment_id and
             artifact.work_item_id == work_item_id and
             artifact.created_by_session == holder,
           do: invalid!("artifact attribution", "must match the original holder and assignment")

    content = ArtifactContent.fetch(txn, artifact_id)
    unless content, do: unavailable!(artifact_id)

    actual = :crypto.hash(:sha256, content.content) |> Base.encode16(case: :lower)

    unless is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) and
             digest == artifact.content_sha256 and digest == content.content_sha256 and
             digest == actual,
           do: invalid!("contentSha256", "does not match the captured artifact bytes")

    %{assignment_id: assignment_id, artifact_id: artifact_id, sha256: digest}
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
