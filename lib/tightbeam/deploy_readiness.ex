defmodule Tightbeam.DeployReadiness do
  @moduledoc """
  Explicit deploy-smoke proof, never part of boot readiness.
  Only the newly spawned session is woken and retired. Observations are read-only.
  """

  def route!(mode, readiness, full) do
    case mode!(mode) do
      :readiness -> readiness.()
      :full -> full.()
    end
  end

  def mode!(nil), do: :full
  def mode!("full"), do: :full
  def mode!("readiness"), do: :readiness
  def mode!(other), do: raise(ArgumentError, "unknown smoke mode: #{inspect(other)}")

  def run!(call, observe, opts \\ []) do
    nonce = Keyword.get_lazy(opts, :nonce, fn -> Base.encode16(:crypto.strong_rand_bytes(16)) end)
    marker = "DEPLOY READY #{nonce}"

    spawn =
      request!(call, "spawn", %{
        "archetype" => "reviewer-code",
        "displayName" => "smoke-readiness-#{nonce}",
        "idempotencyKey" => "readiness-spawn-#{nonce}"
      })

    session = session_key!(spawn)

    # Capture the original failure so cleanup cannot hide it. Retirement failure
    # is independently fatal, including when the reply proof also failed.
    outcome =
      attempt(fn ->
        wake =
          request!(call, "wake", %{
            "sessionKey" => session,
            "prompt" => "Reply with exactly: #{marker}",
            "idempotencyKey" => "readiness-wake-#{nonce}"
          })

        wake_id = nonempty!(wake["wakeId"], "wakeId")
        reply = await_reply!(observe, session, wake_id, marker, opts)
        Map.merge(reply, %{"sessionKey" => session, "wakeId" => wake_id})
      end)

    cleanup = attempt(fn -> retire!(call, spawn) end)

    case {outcome, cleanup} do
      {{:ok, proof}, {:ok, retired}} ->
        Map.put(proof, "retirement", retired)

      {{:error, reason}, {:ok, _}} ->
        raise reason

      {{:ok, _}, {:error, reason}} ->
        raise "retirement failed: #{Exception.message(reason)}"

      {{:error, first}, {:error, last}} ->
        raise "reply proof failed: #{Exception.message(first)}; retirement failed: #{Exception.message(last)}"
    end
  end

  def retire!(call, spawn) do
    session = session_key!(spawn)
    result = request!(call, "retire", %{"sessionKey" => session})

    unless session in (result["retiredSessionKeys"] || []) do
      raise "retirement did not confirm owned session #{session}: #{inspect(result)}"
    end

    result
  end

  def await_reply!(observe, session, wake, marker, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 600_000)
    poll(observe, session, wake, marker, deadline, Keyword.get(opts, :poll_ms, 100))
  end

  defp poll(observe, session, wake, marker, deadline, step) do
    rows = observe.(session, wake)

    case classify(rows, marker) do
      {:ok, row} ->
        row

      {:error, reason} ->
        raise reason

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "readiness reply timeout for session #{session}, wake #{wake}: #{inspect(rows)}"
        end

        Process.sleep(step)
        poll(observe, session, wake, marker, deadline, step)
    end
  end

  defp classify([], _marker), do: :pending

  defp classify(rows, marker) do
    cond do
      Enum.any?(rows, &(&1["status"] in ~w(failed failed_unknown canceled))) ->
        {:error, "readiness turn failed: #{inspect(rows)}"}

      Enum.any?(rows, &(&1["status"] not in ~w(queued running delivered))) ->
        {:error, "unknown readiness turn status: #{inspect(rows)}"}

      true ->
        case Enum.find(rows, fn row ->
               row["status"] == "delivered" and is_binary(row["replyId"]) and
                 is_binary(row["content"]) and String.trim(row["content"]) == marker
             end) do
          nil -> :pending
          row -> {:ok, row}
        end
    end
  end

  @doc "Reads the same turn-to-assistant linkage used by Transcript, bound to one wake and session."
  def observe!(db_path, session, wake) do
    sql = """
    SELECT t.seq AS turnSeq, t.messageId, t.status, m.id AS replyId, m.content
    FROM turns t LEFT JOIN messages m
      ON m.replyToMessageId = t.messageId AND m.sessionKey = t.sessionKey AND m.role = 'assistant'
    WHERE t.sessionKey = #{quote_sql(session)} AND t.wakeId = #{quote_sql(wake)};
    """

    case System.cmd("sqlite3", ["-readonly", "-json", db_path, sql], stderr_to_stdout: true) do
      {out, 0} -> if String.trim(out) == "", do: [], else: JSON.decode!(out)
      {out, status} -> raise "readiness observation failed (#{status}): #{out}"
    end
  end

  defp quote_sql(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp request!(call, verb, params) do
    case call.(verb, params) do
      %{"error" => error} -> raise "#{verb} refused: #{inspect(error)}"
      %{"result" => result} when is_map(result) -> result
      result when is_map(result) -> result
      other -> raise "#{verb} invalid response: #{inspect(other)}"
    end
  end

  defp session_key!(spawn),
    do: nonempty!(get_in(spawn, ["stream", "sessionKey"]) || spawn["sessionKey"], "sessionKey")

  defp nonempty!(value, _label) when is_binary(value) and byte_size(value) > 0, do: value
  defp nonempty!(_value, label), do: raise("missing #{label}")

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end
end
