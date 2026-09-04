defmodule Tightbeam.StaleTurnSettlement do
  @moduledoc """
  Operator-only settlement for a proven stale running turn.

  The session lane owns the live/stale decision. This module owns correlation,
  the guarded terminal transaction, and durable idempotent replay.
  """

  alias Tightbeam.{AdapterCoordinator, DB, Harness, Idempotency, Org, TurnLifecycle}
  alias Tightbeam.Acp.{Adapter, Conn}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  defmodule FenceLost do
    @moduledoc false
    defexception message: "generation fence owner was lost"
  end

  @terminal ~w(delivered canceled failed failed_unknown)

  @type request :: %{
          session_key: String.t(),
          turn_seq: pos_integer(),
          outcome: String.t(),
          reason: String.t(),
          idempotency_key: String.t(),
          principal: String.t(),
          gateway_pid: pid()
        }

  @doc "Validate and normalize the public settle-turn request."
  @spec request(map(), term()) :: {:ok, request()} | {:error, map()}
  def request(params, {:user, user_id}) when is_binary(user_id) do
    with {:ok, session_key} <- nonempty(params[:session_key], "sessionKey"),
         {:ok, turn_seq} <- positive_integer(params[:turn_seq], "turnSeq"),
         {:ok, outcome} <- outcome(params[:outcome]),
         {:ok, reason} <- bounded(params[:reason], "reason", 512),
         {:ok, idempotency_key} <- bounded(params[:idempotency_key], "idempotencyKey", 200) do
      {:ok,
       %{
         session_key: session_key,
         turn_seq: turn_seq,
         outcome: outcome,
         reason: reason,
         idempotency_key: idempotency_key,
         principal: "user:#{user_id}",
         gateway_pid: self()
       }}
    end
  end

  def request(_params, _principal), do: error("not_authorized", "admin user required")

  @doc "Canonical request fingerprint required by the settle-turn replay contract."
  @spec fingerprint(request()) :: String.t()
  def fingerprint(request) do
    canonical =
      "{" <>
        "\"outcome\":" <>
        JSON.encode!(request.outcome) <>
        "," <>
        "\"reason\":" <>
        JSON.encode!(request.reason) <>
        "," <>
        "\"sessionKey\":" <>
        JSON.encode!(request.session_key) <>
        "," <>
        "\"turnSeq\":" <>
        Integer.to_string(request.turn_seq) <>
        "," <>
        "\"verb\":\"settle-turn\"}"

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc "Return a durable replay/conflict before runtime inspection, or continue."
  @spec replay_precheck(DB.server(), request()) :: :continue | {:ok, map()} | {:error, map()}
  def replay_precheck(db, request) do
    case Idempotency.settlement(db, request.principal, request.idempotency_key) do
      nil ->
        :continue

      %{request_fingerprint: fingerprint, response_json: response_json} ->
        if fingerprint == fingerprint(request) do
          {:ok, response(response_json, true)}
        else
          error("idempotency_key_conflict", "idempotency key belongs to another request")
        end
    end
  end

  @doc "Classify and, only after an absent exact provider request, settle the target."
  @spec settle(DB.server(), request(), (-> boolean())) :: {:ok, map()} | {:error, map()}
  def settle(db, request, fence_valid? \\ fn -> true end) do
    case preliminary(db, request) do
      {:ok, %{adapter_gen: adapter_gen, harness: harness, host: host}} ->
        key = {Harness.parse!(harness).id(), "shared", host}

        callback = fn adapter, connection_generation, coordinator_fence_valid? ->
          valid? = fn -> fence_valid?.() and coordinator_fence_valid?.() end

          with :ok <- require_fence(valid?),
               {:ok, correlation} <- correlation(db, request, adapter_gen),
               {:ok, conn} <- adapter_conn(adapter),
               probe <-
                 Conn.probe_request(
                   conn,
                   correlation.acp_request_id,
                   correlation.harness_session_id,
                   connection_generation,
                   1_000
                 ) do
            case probe do
              {:live, _request_id} -> error("turn_live", "the provider request is live")
              :absent -> commit(db, request, correlation, valid?)
              {:unknown, _reason} -> ambiguous()
            end
          else
            {:error, %{code: _} = refusal} -> {:error, refusal}
            _ -> ambiguous()
          end
        end

        owner_scope = %{
          lane_pid: self(),
          gateway_pid: request.gateway_pid,
          callback: callback
        }

        case AdapterCoordinator.with_generation_fence(
               Tightbeam.AdapterCoordinator,
               key,
               adapter_gen,
               owner_scope
             ) do
          {:ok, result} -> result
          {:error, _reason} -> ambiguous()
        end

      {:terminal, result} ->
        {:ok, result}

      other ->
        other
    end
  end

  defp preliminary(db, request) do
    with :continue <- replay_precheck(db, request),
         {:ok, session} <- session(db, request.session_key),
         :ok <- active(session),
         {:ok, turn} <- turn(db, request.session_key, request.turn_seq) do
      cond do
        turn.status in @terminal ->
          store_existing_truth(db, request)

        turn.status == "running" and is_nil(turn.ended_at) and is_integer(turn.adapter_gen) and
            turn.adapter_gen > 0 ->
          {:ok, %{adapter_gen: turn.adapter_gen, harness: session.harness, host: session.host}}

        turn.status == "running" ->
          ambiguous()

        true ->
          error("turn_not_running", "turn is not running")
      end
    end
  end

  defp store_existing_truth(db, request) do
    case DB.transaction(db, fn txn ->
           case Idempotency.settlement_in_txn(txn, request.principal, request.idempotency_key) do
             %{request_fingerprint: stored, response_json: json} ->
               if stored == fingerprint(request),
                 do: {:ok, response(json, true)},
                 else:
                   error("idempotency_key_conflict", "idempotency key belongs to another request")

             nil ->
               case turn_in_txn(txn, request.session_key, request.turn_seq) do
                 {:ok, %{status: status, error: stored_error, message_id: message_id}}
                 when status in @terminal ->
                   result = result(request, status, false, true, message_id, stored_error)
                   put_replay_in_txn(txn, request, result)
                   {:ok, result}

                 {:ok, _turn} ->
                   ambiguous()

                 other ->
                   other
               end
           end
         end) do
      {:ok, {:ok, result}} -> {:terminal, result}
      {:ok, {:error, refusal}} -> {:error, refusal}
      {:error, _reason} -> ambiguous()
    end
  end

  defp correlation(db, request, adapter_gen) do
    with {:ok, turn} <- turn(db, request.session_key, request.turn_seq),
         true <- turn.status == "running" and is_nil(turn.ended_at),
         true <- turn.adapter_gen == adapter_gen,
         {:ok, acp_request_id} <- dispatch_request(db, request.turn_seq),
         %{id: pointer_id, harness_session_id: harness_session_id} <-
           Org.current_pointer_snapshot(db, request.session_key) do
      {:ok,
       %{
         adapter_gen: adapter_gen,
         acp_request_id: acp_request_id,
         pointer_id: pointer_id,
         harness_session_id: harness_session_id
       }}
    else
      _ -> ambiguous()
    end
  end

  defp commit(db, request, correlation, valid?) do
    case DB.transaction(db, fn txn -> commit_in_txn(txn, request, correlation, valid?) end) do
      {:ok, result} -> result
      {:error, %FenceLost{}} -> ambiguous()
      {:error, _reason} -> ambiguous()
    end
  end

  defp commit_in_txn(txn, request, correlation, valid?) do
    require_fence!(valid?)

    case Idempotency.settlement_in_txn(txn, request.principal, request.idempotency_key) do
      %{request_fingerprint: stored, response_json: json} ->
        if stored == fingerprint(request) do
          {:ok, response(json, true)}
        else
          error("idempotency_key_conflict", "idempotency key belongs to another request")
        end

      nil ->
        do_commit_in_txn(txn, request, correlation, valid?)
    end
  end

  defp do_commit_in_txn(txn, request, correlation, valid?) do
    with :ok <- active_in_txn(txn, request.session_key),
         {:ok, turn} <- turn_in_txn(txn, request.session_key, request.turn_seq),
         :ok <- running(turn),
         {:ok, acp_request_id} <- dispatch_request_in_txn(txn, request.turn_seq),
         %{id: pointer_id, harness_session_id: harness_session_id} <-
           Org.current_pointer_snapshot_in_txn(txn, request.session_key),
         true <-
           acp_request_id == correlation.acp_request_id and
             pointer_id == correlation.pointer_id and
             harness_session_id == correlation.harness_session_id and
             turn.adapter_gen == correlation.adapter_gen do
      now = System.system_time(:millisecond)
      status = if request.outcome == "cancel", do: "canceled", else: "failed"
      stored_error = if status == "failed", do: request.reason, else: nil

      Txn.q(
        txn,
        """
        UPDATE turns SET status=?3, endedAt=?4, error=?5
        WHERE seq=?1 AND sessionKey=?2 AND status='running' AND endedAt IS NULL
          AND adapterGen=?6
          AND EXISTS (
            SELECT 1 FROM sessions s
            WHERE s.sessionKey=?2 AND s.state='active'
          )
          AND EXISTS (
            SELECT 1 FROM harness_pointers p
            WHERE p.id=?7 AND p.sessionKey=?2 AND p.harnessSessionId=?8
              AND NOT EXISTS (
                SELECT 1 FROM harness_pointers newer
                WHERE newer.sessionKey=?2 AND newer.id > p.id
              )
          )
        """,
        [
          request.turn_seq,
          request.session_key,
          status,
          now,
          stored_error,
          correlation.adapter_gen,
          correlation.pointer_id,
          correlation.harness_session_id
        ]
      )

      if Txn.changes(txn) == 1 do
        TurnLifecycle.append_in_txn(txn, request.turn_seq, %{
          event_key: "terminal:committed",
          producer_event_id: "settle-turn:#{fingerprint(request)}",
          kind: "terminal_committed",
          outcome: status,
          cause: "operator:stale-running-turn",
          principal: request.principal,
          detail: %{v: 1, status: status},
          at: now
        })

        Publisher.turn_in_txn(txn, "turn.ended", request.turn_seq)
        Org.sync_mechanical_status_in_txn(txn, request.session_key)

        result = result(request, status, true, false, turn.message_id, stored_error)
        put_replay_in_txn(txn, request, result)
        require_fence!(valid?)
        {:ok, result}
      else
        existing_truth_in_txn(txn, request)
      end
    else
      false -> ambiguous()
      {:error, %{code: _} = refusal} -> {:error, refusal}
      _ -> ambiguous()
    end
  end

  defp existing_truth_in_txn(txn, request) do
    case turn_in_txn(txn, request.session_key, request.turn_seq) do
      {:ok, %{status: status, error: stored_error}} when status in @terminal ->
        {:ok, turn} = turn_in_txn(txn, request.session_key, request.turn_seq)
        result = result(request, status, false, true, turn.message_id, stored_error)
        put_replay_in_txn(txn, request, result)
        {:ok, result}

      {:ok, _turn} ->
        ambiguous()

      other ->
        other
    end
  end

  defp put_replay_in_txn(txn, request, result) do
    Idempotency.put_settlement_in_txn(txn, %{
      principal: request.principal,
      idempotency_key: request.idempotency_key,
      session_key: request.session_key,
      request_fingerprint: fingerprint(request),
      response_json: encode_response(result)
    })
  end

  defp session(db, session_key) do
    case DB.query(db, "SELECT state,harness,host FROM sessions WHERE sessionKey=?1", [session_key]) do
      {:ok, [[state, harness, host]]} -> {:ok, %{state: state, harness: harness, host: host}}
      {:ok, []} -> error("session_not_found", "session not found")
      _ -> ambiguous()
    end
  end

  defp active(%{state: "active"}), do: :ok
  defp active(_session), do: error("session_retired", "session is not active")

  defp active_in_txn(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey=?1", [session_key]) do
      [["active"]] -> :ok
      [[_state]] -> error("session_retired", "session is not active")
      [] -> error("session_not_found", "session not found")
    end
  end

  defp turn(db, session_key, turn_seq) do
    case DB.query(
           db,
           "SELECT status,endedAt,adapterGen,messageId,error FROM turns WHERE seq=?1 AND sessionKey=?2",
           [turn_seq, session_key]
         ) do
      {:ok, [row]} -> {:ok, turn_row(row)}
      {:ok, []} -> error("turn_not_found", "turn not found")
      _ -> ambiguous()
    end
  end

  defp turn_in_txn(txn, session_key, turn_seq) do
    case Txn.q(
           txn,
           "SELECT status,endedAt,adapterGen,messageId,error FROM turns WHERE seq=?1 AND sessionKey=?2",
           [turn_seq, session_key]
         ) do
      [row] -> {:ok, turn_row(row)}
      [] -> error("turn_not_found", "turn not found")
    end
  end

  defp turn_row([status, ended_at, adapter_gen, message_id, error]) do
    %{
      status: status,
      ended_at: ended_at,
      adapter_gen: adapter_gen,
      message_id: message_id,
      error: error
    }
  end

  defp running(%{status: "running", ended_at: nil}), do: :ok

  defp running(%{status: status}) when status in @terminal,
    do: error("turn_not_running", "turn is already terminal")

  defp running(_turn), do: error("turn_not_running", "turn is not running")

  defp dispatch_request(db, turn_seq) do
    case DB.query(
           db,
           "SELECT acpRequestId FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'",
           [turn_seq]
         ) do
      {:ok, [[request_id]]} when is_integer(request_id) and request_id > 0 -> {:ok, request_id}
      _ -> ambiguous()
    end
  end

  defp dispatch_request_in_txn(txn, turn_seq) do
    case Txn.q(
           txn,
           "SELECT acpRequestId FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='prompt_dispatched'",
           [turn_seq]
         ) do
      [[request_id]] when is_integer(request_id) and request_id > 0 -> {:ok, request_id}
      _ -> ambiguous()
    end
  end

  defp adapter_conn(adapter) do
    case Adapter.conn(adapter) do
      conn when is_pid(conn) -> {:ok, conn}
      _ -> ambiguous()
    end
  catch
    :exit, _ -> ambiguous()
  end

  defp result(request, status, won, replayed, message_id, stored_error) do
    %{
      session_key: request.session_key,
      turn_seq: request.turn_seq,
      status: status,
      won: won,
      replayed: replayed,
      message_id: message_id,
      stored_error: stored_error
    }
  end

  defp encode_response(result) do
    JSON.encode!(%{
      "sessionKey" => result.session_key,
      "turnSeq" => result.turn_seq,
      "status" => result.status,
      "won" => result.won,
      "replayed" => result.replayed,
      "storedError" => result.stored_error
    })
  end

  defp response(json, replayed) do
    decoded = JSON.decode!(json)

    %{
      session_key: decoded["sessionKey"],
      turn_seq: decoded["turnSeq"],
      status: decoded["status"],
      won: false,
      replayed: replayed,
      message_id: nil,
      stored_error: decoded["storedError"]
    }
  end

  defp require_fence(valid?) do
    if valid?.(), do: :ok, else: ambiguous()
  end

  defp require_fence!(valid?) do
    if not valid?.(), do: raise(FenceLost)
    :ok
  end

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, name), do: error("invalid", "#{name} must be a positive integer")

  defp outcome(value) when value in ["cancel", "fail"], do: {:ok, value}
  defp outcome(_value), do: error("invalid", "outcome must be cancel or fail")

  defp nonempty(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty(_value, name), do: error("invalid", "#{name} must be a non-empty string")

  defp bounded(value, name, max) when is_binary(value) do
    if String.trim(value) != "" and String.length(value) <= max,
      do: {:ok, value},
      else: error("invalid", "#{name} must contain 1-#{max} characters")
  end

  defp bounded(_value, name, max),
    do: error("invalid", "#{name} must contain 1-#{max} characters")

  defp ambiguous, do: error("turn_status_ambiguous", "turn liveness is ambiguous")
  defp error(code, message), do: {:error, %{code: code, message: message}}
end
