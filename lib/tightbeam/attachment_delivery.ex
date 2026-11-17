defmodule Tightbeam.AttachmentDelivery do
  @moduledoc false

  alias Tightbeam.{Assets, DB, Harness}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @max_deliverable_bytes 25_000_000
  @assessment_unavailable_message "Attachment delivery could not be confirmed."

  @ddl """
  CREATE TABLE IF NOT EXISTS message_attachment_delivery_results (
    seq            INTEGER PRIMARY KEY AUTOINCREMENT,
    messageId      TEXT NOT NULL REFERENCES messages(id),
    sessionKey     TEXT NOT NULL,
    clientMessageId TEXT NOT NULL,
    assetId        TEXT NOT NULL,
    outcome        TEXT NOT NULL CHECK (outcome IN ('pending','delivered','not-delivered','unknown')),
    reason         TEXT,
    recordedAt     INTEGER NOT NULL,
    CHECK (
      (outcome IN ('pending','delivered') AND reason IS NULL) OR
      (outcome IN ('not-delivered','unknown') AND reason IS NOT NULL)
    )
  );
  CREATE INDEX IF NOT EXISTS message_attachment_delivery_latest
    ON message_attachment_delivery_results (messageId, assetId, seq DESC);
  """

  @doc false
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  def max_deliverable_bytes, do: @max_deliverable_bytes

  def assessment_unavailable_message, do: @assessment_unavailable_message

  @doc false
  def validate_post(db, base_dir, user_id, attachments) do
    assets = Enum.map(attachments, &Assets.get(db, &1["assetId"]))

    if Enum.any?(assets, fn
         nil -> true
         %{owner_user_id: owner} -> owner != user_id
       end) do
      {:error, :invalid_asset}
    else
      offending_asset_ids =
        attachments
        |> Enum.zip(assets)
        |> Enum.filter(fn {_attachment, asset} ->
          post_asset_size(base_dir, asset) > @max_deliverable_bytes
        end)
        |> Enum.map(fn {attachment, _asset} -> attachment["assetId"] end)

      if offending_asset_ids == [], do: :ok, else: {:over_limit, offending_asset_ids}
    end
  end

  @doc false
  def assess(db, base_dir, user_id, session, client_message_id, asset_ids) do
    assets = Enum.map(asset_ids, &Assets.get(db, &1))

    if Enum.any?(assets, fn
         nil -> true
         %{owner_user_id: owner} -> owner != user_id
       end) do
      {:error, %{code: "invalid_message", message: "attachment asset is unavailable"}}
    else
      attachments =
        Enum.zip(asset_ids, assets)
        |> Enum.map(fn {asset_id, asset} ->
          assess_asset(base_dir, session, asset_id, asset)
        end)

      {:ok,
       %{
         sessionKey: session.session_key,
         clientMessageId: client_message_id,
         maxDeliverableAttachmentBytes: @max_deliverable_bytes,
         attachments: attachments
       }}
    end
  rescue
    _error ->
      {:error, %{code: "assessment-unavailable", message: @assessment_unavailable_message}}
  end

  @doc false
  def unknown_assessments(asset_ids) do
    reason = %{
      code: "assessment-unavailable",
      message: @assessment_unavailable_message
    }

    Enum.map(asset_ids, fn asset_id ->
      %{assetId: asset_id, assessment: "unknown", reason: reason}
    end)
  end

  @doc false
  def append_pending_in_txn(%Txn{} = txn, message_id, session_key, client_message_id, attachments) do
    if is_binary(client_message_id) do
      Enum.each(attachments, fn
        %{"assetId" => asset_id} when is_binary(asset_id) and asset_id != "" ->
          Txn.q(
            txn,
            """
            INSERT INTO message_attachment_delivery_results
              (messageId, sessionKey, clientMessageId, assetId, outcome, reason, recordedAt)
            VALUES (?1, ?2, ?3, ?4, 'pending', NULL, ?5)
            """,
            [message_id, session_key, client_message_id, asset_id, now_ms()]
          )

        _attachment ->
          :ok
      end)
    end

    :ok
  end

  @doc false
  def record_attempts(db, attempts, result) do
    {:ok, :ok} = DB.transaction(db, fn txn -> record_attempts_in_txn(txn, attempts, result) end)
    :ok
  end

  @doc false
  def record_attempts_in_txn(%Txn{} = txn, attempts, result) do
    Enum.each(attempts, fn attempt ->
      {outcome, reason} = attempt_result(attempt, result)

      append_result_in_txn(
        txn,
        attempt.message_id,
        attempt.session_key,
        attempt.client_message_id,
        attempt.asset_id,
        outcome,
        reason
      )
    end)

    :ok
  end

  @doc false
  defp append_result_in_txn(
         %Txn{} = txn,
         message_id,
         session_key,
         client_message_id,
         asset_id,
         outcome,
         reason
       ) do
    reason_json = if is_nil(reason), do: nil, else: JSON.encode!(reason)

    case Txn.q(
           txn,
           """
           SELECT outcome, reason
           FROM message_attachment_delivery_results
           WHERE messageId=?1 AND assetId=?2
           ORDER BY seq DESC LIMIT 1
           """,
           [message_id, asset_id]
         ) do
      [[^outcome, ^reason_json]] ->
        :ok

      _ ->
        occurred_at = now_ms()

        Txn.q(
          txn,
          """
          INSERT INTO message_attachment_delivery_results
            (messageId, sessionKey, clientMessageId, assetId, outcome, reason, recordedAt)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
          """,
          [
            message_id,
            session_key,
            client_message_id,
            asset_id,
            outcome,
            reason_json,
            occurred_at
          ]
        )

        case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [session_key]) do
          [[owner_user_id]] when is_binary(owner_user_id) ->
            delivery = %{outcome: outcome, reason: reason}

            Publisher.observation_in_txn(
              txn,
              "message.attachment_delivery.updated",
              %{
                messageId: message_id,
                sessionKey: session_key,
                clientMessageId: client_message_id,
                assetId: asset_id,
                delivery: delivery
              },
              %{"messageId" => message_id, "sessionKey" => session_key},
              occurred_at
            )

          _ ->
            :ok
        end
    end
  end

  defp assess_asset(base_dir, session, asset_id, asset) do
    result = fn assessment, reason ->
      %{assetId: asset_id, assessment: assessment, reason: reason}
    end

    cond do
      asset_size(base_dir, asset) > @max_deliverable_bytes ->
        result.("will-not-deliver", reason("over-limit", "This file exceeds the delivery limit."))

      image_inline?(asset.mime_type) and not Harness.inline_attachments?(session.harness) ->
        result.(
          "will-not-deliver",
          reason("unsupported-delivery", "This file will not reach the agent.")
        )

      not Harness.original_file_attachments?(session.harness) ->
        result.(
          "will-not-deliver",
          reason("unsupported-delivery", "This file will not reach the agent.")
        )

      true ->
        case verified_source(base_dir, asset) do
          {:ok, _path, _size} ->
            result.("will-deliver", nil)

          {:missing, _path} ->
            result.(
              "will-not-deliver",
              reason("attachment-unavailable", "The stored attachment bytes are unavailable.")
            )

          :unknown ->
            result.("unknown", reason("assessment-unavailable", @assessment_unavailable_message))
        end
    end
  end

  defp image_inline?(mime_type), do: mime_type in ["image/jpeg", "image/png"]

  defp attempt_result(%{outcome: "not-delivered", reason: reason}, _result),
    do: {"not-delivered", reason}

  defp attempt_result(%{outcome: "unknown", reason: reason}, _result),
    do: {"unknown", reason}

  defp attempt_result(%{outcome: "delivered"}, :accepted), do: {"delivered", nil}

  defp attempt_result(_attempt, :failed),
    do:
      {"not-delivered",
       reason("handoff-failed", "The message could not be delivered to the agent.")}

  defp attempt_result(_attempt, :unknown),
    do:
      {"unknown", reason("handoff-unknown", "The Gateway could not confirm attachment delivery.")}

  defp reason(code, message), do: %{code: code, message: message}

  defp post_asset_size(base_dir, asset) do
    case File.stat(Assets.file_path(base_dir, asset.asset_id)) do
      {:ok, %{size: size}} -> size
      {:error, _} -> asset.size
    end
  end

  defp asset_size(base_dir, asset), do: post_asset_size(base_dir, asset)

  defp verified_source(base_dir, asset) do
    path = Assets.file_path(base_dir, asset.asset_id)

    case File.stat(path) do
      {:ok, %{size: size}} when size == asset.size -> {:ok, path, size}
      {:ok, _stat} -> :unknown
      {:error, :enoent} -> {:missing, path}
      {:error, _reason} -> :unknown
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
