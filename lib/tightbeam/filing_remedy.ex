defmodule Tightbeam.FilingRemedy do
  @moduledoc false

  alias Tightbeam.{DB, EventLog, RailRemedy, Recognition, RuleRuntime, Wakes}
  alias Tightbeam.DB.Txn

  @lease_ms 60_000

  @doc false
  def install_handlers(db, handlers) when is_map(handlers) do
    owner = GenServer.whereis(db) || raise "filing remedy database owner is unavailable"
    :persistent_term.put({__MODULE__, owner}, handlers)
    :ok
  end

  @doc false
  def enqueue_in_txn(%Txn{} = txn, rule, call) do
    request_id = Map.get(call.params, :decision_request_id)

    unless is_binary(request_id),
      do: raise("filing remedy #{rule.name} has no decision request binding")

    case Txn.q(
           txn,
           "SELECT status,producerKey FROM rail_remedy_episodes WHERE statute=?1 AND subject=?2",
           [rule.name, request_id]
         ) do
      [[status, key]] when status in ["live", "closed"] and is_binary(key) ->
        :ok

      [[status, nil]] when status in ["live", "closed"] ->
        raise "filing remedy #{rule.name} has a settled episode without producer identity"

      _ ->
        id = occurrence_id(rule.name, request_id)
        callback = fn db, _recognition_id, _ -> run(db, rule, request_id, call) end
        Recognition.record(txn, callback, :ok, [], id: id, next_at: now())
        :ok
    end
  end

  defp run(db, rule, request_id, call) do
    unless RuleRuntime.loaded?() and handlers(db),
      do: raise(Wakes.RuleEvaluationUnavailable)

    case episode(db, rule.name, request_id) do
      %{status: status, producer_key: key}
      when status in ["live", "closed"] and is_binary(key) ->
        :ok

      %{status: status} when status in ["live", "closed"] ->
        raise "filing remedy #{rule.name} has a settled episode without producer identity"

      %{status: status, opened_at: opened_at}
      when status in ["claimed", "dispatched"] ->
        if opened_at + @lease_ms >= now(),
          do: {:defer_until, opened_at + @lease_ms + 1},
          else: dispatch(db, rule, request_id, call)

      _ ->
        dispatch(db, rule, request_id, call)
    end
  rescue
    error in Wakes.RuleEvaluationUnavailable ->
      reraise error, __STACKTRACE__

    error ->
      detail =
        JSON.encode!(%{
          request_id: request_id,
          cause: get_in(call, [:transition, :cause]),
          creator: get_in(call, [:transition, :principal]),
          error: inspect(error.__struct__),
          message: String.slice(Exception.message(error), 0, 256)
        })

      try do
        EventLog.lifecycle(db, "filing_remedy_failed", rule.name, detail)
      rescue
        _ -> :ok
      end

      reraise error, __STACKTRACE__
  end

  defp dispatch(db, rule, request_id, call) do
    result = RailRemedy.fire(db, handlers(db), rule, request_id, call)

    case result do
      %{pending_decision_id: id} when is_binary(id) ->
        {:await_fact, "escalation-ruled", id}

      _ ->
        case episode(db, rule.name, request_id) do
          %{status: status, producer_key: key}
          when status in ["live", "closed"] and is_binary(key) ->
            :ok

          %{status: status} when status in ["live", "closed"] ->
            raise "filing remedy #{rule.name} has a settled episode without producer identity"

          %{status: status, opened_at: opened_at}
          when status in ["claimed", "dispatched"] ->
            {:defer_until, opened_at + @lease_ms + 1}

          _ ->
            raise "filing remedy #{rule.name} for #{request_id} failed: #{result.outcome}"
        end
    end
  end

  defp episode(db, statute, subject) do
    case DB.query(
           db,
           "SELECT status,producerKey,openedAt FROM rail_remedy_episodes WHERE statute=?1 AND subject=?2",
           [statute, subject]
         ) do
      {:ok, [[status, producer_key, opened_at]]} ->
        %{status: status, producer_key: producer_key, opened_at: opened_at}

      {:ok, []} ->
        nil

      {:error, error} ->
        raise error
    end
  end

  defp occurrence_id(statute, request_id) do
    "filing-remedy:" <>
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({statute, request_id})),
        case: :lower
      )
  end

  defp handlers(db), do: :persistent_term.get({__MODULE__, GenServer.whereis(db)}, nil)

  defp now, do: System.system_time(:millisecond)
end
