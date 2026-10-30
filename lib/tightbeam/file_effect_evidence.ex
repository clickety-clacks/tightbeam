defmodule Tightbeam.FileEffectEvidence do
  @moduledoc false
  alias Tightbeam.{ArtifactContent, Artifacts, DB.Txn, Mementos}

  # The caller supplies the selected declaration and policy revision, then
  # validates and writes the inline value inside the attest transaction.
  # Captured bytes identify the claim; they do not prove an observation occurred.
  def validate!(%Txn{} = txn, call, name, revision) do
    id = call.params[:assignment_id]
    artifact_id = call.params[:artifact_id]
    hash = call.params[:content_sha256]

    assignment =
      case Txn.q(
             txn,
             "SELECT holderKey,workItemId,reviewsAssignmentId,state FROM assignments WHERE id=?1",
             [id]
           ) do
        [[holder, item, nil, "open"]] when call.principal == {:session, holder} ->
          %{id: id, holder: holder, item: item}

        _ ->
          invalid!("assignment.producer", "requires the holder of an open producing assignment")
      end

    {_, bytes} = captured!(txn, artifact_id, hash, "manifest", assignment, :producer)

    manifest =
      case JSON.decode(bytes) do
        {:ok, value} when is_map(value) -> value
        _ -> invalid!("manifest", "requires a JSON object")
      end

    exact!(manifest["schema"], "file-effect-evidence/v1", "schema")
    exact!(manifest["assignmentId"], id, "assignmentId")
    target = text!(manifest["target"], "target")
    before = file!(txn, manifest["before"], target, "before", assignment)
    after_file = file!(txn, manifest["after"], target, "after", assignment)

    observations =
      case manifest["observations"] do
        [_ | _] = observations -> observations
        _ -> invalid!("observations", "requires at least one observation")
      end

    authors =
      observations
      |> Enum.with_index()
      |> Enum.map(fn {observation, index} ->
        observation!(
          txn,
          observation,
          target,
          after_file.sha256,
          "observations[#{index}]",
          assignment
        )
      end)

    comparison = "file-evidence/v1:#{artifact_id}:#{hash}"
    proposed = Map.get(Map.new(call.memento_writes), name, [])

    unless comparison in proposed,
      do:
        invalid!(
          "memento.#{name}",
          "proposed values must contain the exact manifest evidence reference"
        )

    %{
      assignment_id: id,
      artifact_id: artifact_id,
      sha256: hash,
      policy_revision: revision,
      comparison_value: comparison,
      target: target,
      before: before,
      after: after_file,
      observation_authors: authors
    }
  end

  defp file!(txn, value, target, field, assignment) when is_map(value) do
    exact!(value["target"], target, field <> ".target")
    captured!(txn, value["artifactId"], value["sha256"], field, assignment, :producer)
    %{artifact_id: value["artifactId"], sha256: value["sha256"]}
  end

  defp file!(_, _, _, field, _), do: invalid!(field, "requires a file identity")

  defp observation!(txn, value, target, after_hash, field, assignment) when is_map(value) do
    exact!(value["target"], target, field <> ".target")
    subject = text!(value["subject"], field <> ".subject")
    result = text!(value["resultIdentity"], field <> ".resultIdentity")

    {artifact, _} =
      captured!(txn, value["artifactId"], value["sha256"], field, assignment, :observation)

    case value["scope"] do
      "disk-bytes" ->
        exact!(subject, target, field <> ".subject")
        exact!(result, after_hash, field <> ".resultIdentity")

      "loaded-state" ->
        :ok

      _ ->
        invalid!(field <> ".scope", "expected disk-bytes or loaded-state")
    end

    %{
      scope: value["scope"],
      subject: subject,
      result_identity: result,
      artifact_id: artifact.artifact_id,
      author: artifact.created_by_session
    }
  end

  defp observation!(_, _, _, _, field, _), do: invalid!(field, "requires an observation object")

  defp captured!(txn, artifact_id, hash, field, assignment, relation) do
    text!(artifact_id, field <> ".artifactId")

    unless is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
      do: invalid!(field <> ".sha256", "requires a lowercase SHA-256")

    artifact = Artifacts.get_in_txn(txn, artifact_id)
    unless artifact, do: unavailable!(artifact_id, field)
    content = ArtifactContent.fetch(txn, artifact_id)
    unless content, do: unavailable!(artifact_id, field)
    actual = :crypto.hash(:sha256, content.content) |> Base.encode16(case: :lower)
    exact!(artifact.content_sha256, hash, field <> ".artifact.contentSha256")
    exact!(content.content_sha256, hash, field <> ".captured.contentSha256")
    exact!(actual, hash, field <> ".captured.bytes")
    exact!(artifact.work_item_id, assignment.item, field <> ".workItemId")

    case Txn.q(txn, "SELECT holderKey,reviewsAssignmentId FROM assignments WHERE id=?1", [
           artifact.produced_by_assignment_id
         ]) do
      [[holder, reviewed]] ->
        producer? =
          artifact.produced_by_assignment_id == assignment.id and holder == assignment.holder

        reviewer? = relation == :observation and reviewed == assignment.id

        unless producer? or reviewer?,
          do:
            invalid!(
              field <> ".producedByAssignmentId",
              "must identify this producer or its linked observation reviewer"
            )

        exact!(artifact.created_by_session, holder, field <> ".createdBySession")

      _ ->
        invalid!(
          field <> ".producedByAssignmentId",
          "requires an attributable producing assignment"
        )
    end

    {artifact, content.content}
  end

  defp text!(value, _field) when is_binary(value) and byte_size(value) > 0, do: value
  defp text!(_, field), do: invalid!(field, "requires nonempty text")
  defp exact!(value, value, _field), do: :ok
  defp exact!(_, _, field), do: invalid!(field, "does not match the declared subject or artifact")

  defp unavailable!(id, field),
    do:
      raise(Mementos.Refusal,
        code: "file_effect_evidence_unavailable",
        message:
          "#{field}: captured content unavailable for #{id}; capture and record corrected immutable artifacts"
      )

  defp invalid!(field, reason),
    do:
      raise(Mementos.Refusal,
        code: "file_effect_evidence_invalid",
        message: "#{field}: #{reason}; capture and record corrected immutable artifacts"
      )
end
