defmodule Tightbeam.RailRemedy do
  @moduledoc "Active rail remedy execution and durable remedy-episode lifecycle."

  alias Tightbeam.{DB, Dispatch, EventLog, Idempotency, Org, Roles, Wakes}
  alias Tightbeam.DB.Txn

  @ttl_ms 60_000
  @token_re ~r/\{([^{}]+)\}/

  @ddl """
  CREATE TABLE IF NOT EXISTS rail_remedy_episodes (
    statute     TEXT    NOT NULL,
    subject     TEXT    NOT NULL,
    status      TEXT    NOT NULL CHECK (status IN ('claimed','dispatched','live','closed')),
    producerKey TEXT,
    occurrence  INTEGER NOT NULL,
    rewakeCount INTEGER NOT NULL,
    claimToken  TEXT    NOT NULL,
    openedAt    INTEGER NOT NULL,
    closedAt    INTEGER,
    PRIMARY KEY (statute, subject)
  );
  """

  @type outcome :: %{
          optional(:denial) => map(),
          outcome: String.t(),
          producer_id: String.t() | nil
        }

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Fire one remedy decision through the episode CAS and producer dispatch."
  @spec fire(DB.server(), Dispatch.handlers(), map(), String.t(), map()) :: outcome()
  def fire(db, handlers, rule, subject, call) do
    result =
      with {:ok, context} <- binding_context(db, subject, call),
           {:ok, resolved} <- resolve_remedy(rule.remedy, context),
           {:ok, resolved} <- bind_target(db, rule.remedy.action, resolved) do
        route_episode(db, handlers, rule, subject, call, context, resolved)
      else
        {:error, _unbound} -> %{outcome: "unbound", producer_id: nil}
      end

    lifecycle(db, rule, subject, call, result)
    result
  end

  @doc "Return the occurrence when one statute/subject episode is live."
  @spec live?(DB.server(), String.t(), String.t()) :: pos_integer() | nil
  def live?(db, statute, subject) do
    case DB.query(
           db,
           "SELECT occurrence FROM rail_remedy_episodes WHERE statute = ?1 AND subject = ?2 AND status = 'live'",
           [statute, subject]
         ) do
      {:ok, [[occurrence]]} -> occurrence
      _ -> nil
    end
  end

  @doc "Actor-owned live-to-closed CAS for one passed statute occurrence."
  @spec close(DB.server(), String.t(), String.t(), pos_integer()) :: boolean()
  def close(db, statute, subject, occurrence) do
    cas(
      db,
      """
      UPDATE rail_remedy_episodes SET status = 'closed', closedAt = ?4
      WHERE statute = ?1 AND subject = ?2 AND occurrence = ?3 AND status = 'live'
      """,
      [statute, subject, occurrence, now()]
    )
  end

  @doc false
  def episode(db, statute, subject) do
    read_episode(db, statute, subject)
  end

  defp route_episode(db, handlers, rule, subject, call, context, resolved) do
    row = read_episode(db, rule.name, subject)

    case claim(db, rule, subject, context, row) do
      {:claimed, token, occurrence, reopened?} ->
        lease_and_dispatch(
          db,
          handlers,
          rule,
          subject,
          call,
          context,
          resolved,
          token,
          occurrence,
          reopened?
        )

      :occupied ->
        occupied_episode(db, handlers, rule, subject, call, context, resolved)
    end
  end

  defp claim(db, rule, subject, _context, nil) do
    token = claim_token()

    if cas(
         db,
         """
         INSERT INTO rail_remedy_episodes
           (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
         VALUES (?1, ?2, 'claimed', 1, 0, ?3, ?4)
         ON CONFLICT DO NOTHING
         """,
         [rule.name, subject, token, now()]
       ) do
      {:claimed, token, 1, false}
    else
      :occupied
    end
  end

  defp claim(db, rule, subject, _context, %{status: "closed", occurrence: occurrence}) do
    token = claim_token()

    if cas(
         db,
         """
         UPDATE rail_remedy_episodes
         SET status = 'claimed', producerKey = NULL, occurrence = occurrence + 1,
             rewakeCount = 0, claimToken = ?4, openedAt = ?5, closedAt = NULL
         WHERE statute = ?1 AND subject = ?2 AND status = 'closed' AND occurrence = ?3
         """,
         [rule.name, subject, occurrence, token, now()]
       ) do
      {:claimed, token, occurrence + 1, true}
    else
      :occupied
    end
  end

  defp claim(
         db,
         rule,
         subject,
         _context,
         %{status: status, occurrence: occurrence, opened_at: opened_at}
       )
       when status in ["claimed", "dispatched"] do
    token = claim_token()
    current = now()

    if opened_at < current - @ttl_ms and
         cas(
           db,
           """
           UPDATE rail_remedy_episodes
           SET status = 'claimed', producerKey = NULL, claimToken = ?5, openedAt = ?6
           WHERE statute = ?1 AND subject = ?2
             AND status IN ('claimed','dispatched') AND openedAt < ?3
             AND occurrence = ?4
           """,
           [rule.name, subject, current - @ttl_ms, occurrence, token, current]
         ) do
      {:claimed, token, occurrence, false}
    else
      :occupied
    end
  end

  defp claim(
         db,
         rule,
         subject,
         context,
         %{status: "live", occurrence: occurrence, producer_key: producer_key}
       ) do
    if producer_dead?(db, rule, context, subject, occurrence, producer_key) do
      token = claim_token()

      if cas(
           db,
           """
           UPDATE rail_remedy_episodes
           SET status = 'claimed', producerKey = NULL, occurrence = occurrence + 1,
               rewakeCount = 0, claimToken = ?4, openedAt = ?5, closedAt = NULL
           WHERE statute = ?1 AND subject = ?2 AND status = 'live' AND occurrence = ?3
           """,
           [rule.name, subject, occurrence, token, now()]
         ) do
        {:claimed, token, occurrence + 1, true}
      else
        :occupied
      end
    else
      :occupied
    end
  end

  defp lease_and_dispatch(
         db,
         handlers,
         rule,
         subject,
         _call,
         context,
         resolved,
         token,
         occurrence,
         reopened?
       ) do
    won? =
      cas(
        db,
        """
        UPDATE rail_remedy_episodes
        SET status = 'dispatched'
        WHERE statute = ?1 AND subject = ?2 AND status = 'claimed' AND claimToken = ?3
        """,
        [rule.name, subject, token]
      )

    if won? do
      key = dispatch_key(rule.name, subject, occurrence)

      with {:ok, producer_call, producer_hint} <-
             producer_call(db, rule, context, resolved, key),
           {:ok, result} <- Dispatch.dispatch(db, handlers, producer_call),
           producer_id when is_binary(producer_id) <-
             producer_id(rule.remedy.action, result, producer_hint) do
        if cas(
             db,
             """
             UPDATE rail_remedy_episodes
             SET status = 'live', producerKey = ?4
             WHERE statute = ?1 AND subject = ?2
               AND status = 'dispatched' AND claimToken = ?3
             """,
             [rule.name, subject, token, producer_id]
           ) do
          %{
            outcome: if(reopened?, do: "reopened-dispatched", else: "claimed-dispatched"),
            producer_id: producer_id
          }
        else
          %{outcome: "claimed-dispatched", producer_id: nil}
        end
      else
        {:error, %{code: "rule_denied"} = denial}
        when rule.remedy.on_rule_denied == "surface" ->
          release_dispatch(db, rule.name, subject, token)
          %{outcome: "blocked", producer_id: nil, denial: denial}

        _ ->
          release_dispatch(db, rule.name, subject, token)
          %{outcome: "blocked", producer_id: nil}
      end
    else
      %{outcome: "claimed-dispatched", producer_id: nil}
    end
  end

  defp occupied_episode(db, handlers, rule, subject, call, context, resolved) do
    case read_episode(db, rule.name, subject) do
      %{status: "live", claim_token: token, occurrence: occurrence} = row ->
        if producer_live?(db, rule.remedy.action, row.producer_key) do
          rewake(
            db,
            handlers,
            rule,
            subject,
            call,
            context,
            resolved,
            token,
            occurrence,
            row.producer_key
          )
        else
          %{outcome: "blocked", producer_id: row.producer_key}
        end

      %{producer_key: producer_key} ->
        %{outcome: "claimed-dispatched", producer_id: producer_key}

      nil ->
        %{outcome: "claimed-dispatched", producer_id: nil}
    end
  end

  defp rewake(
         db,
         handlers,
         rule,
         subject,
         _call,
         context,
         resolved,
         token,
         occurrence,
         producer_key
       ) do
    case increment_rewake(db, rule.name, subject, token) do
      {:ok, rewake_count} ->
        target =
          rewake_target(db, rule.remedy.action, subject, context, resolved, producer_key)

        key = rewake_key(rule.name, subject, occurrence, rewake_count)

        if is_binary(target) do
          principal = remedy_principal(rule.name, "wake", context.owner)

          wake_call = %{
            verb: "wake",
            origin: "remedy:#{rule.name}",
            principal: principal,
            session_key: target,
            params: %{
              prompt: "Remedy #{rule.name} remains pending for #{subject}.",
              after_ms: 0,
              nudge: false,
              idempotency_key: key
            }
          }

          _ = Dispatch.dispatch(db, handlers, wake_call)
        end

        %{outcome: "rewake", producer_id: producer_key}

      :lost ->
        %{outcome: "claimed-dispatched", producer_id: nil}
    end
  end

  defp increment_rewake(db, statute, subject, token) do
    case DB.transaction(db, fn txn ->
           Txn.q(
             txn,
             """
             UPDATE rail_remedy_episodes
             SET rewakeCount = rewakeCount + 1
             WHERE statute = ?1 AND subject = ?2 AND status = 'live' AND claimToken = ?3
             """,
             [statute, subject, token]
           )

           if Txn.changes(txn) == 1 do
             [[count]] =
               Txn.q(
                 txn,
                 "SELECT rewakeCount FROM rail_remedy_episodes WHERE statute = ?1 AND subject = ?2",
                 [statute, subject]
               )

             {:ok, count}
           else
             :lost
           end
         end) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp producer_call(_db, rule, context, resolved, key) do
    action = rule.remedy.action
    principal = remedy_principal(rule.name, action, context.owner)
    origin = "remedy:#{rule.name}"

    case action do
      "assign" ->
        params =
          resolved.params
          |> rename_param(:reviews, :reviews_assignment_id)
          |> rename_param(:work_item, :work_item_id)
          |> Map.put(:idempotency_key, key)

        call = %{
          verb: "assign",
          origin: origin,
          principal: principal,
          session_key: resolved.bound_session,
          target_role: resolved.target.target_role,
          role_fallback: false,
          params: params
        }

        {:ok, call, nil}

      "wake" ->
        params =
          resolved.params
          |> rename_param(:after, :after_ms)
          |> Map.put(:idempotency_key, key)

        call = %{
          verb: "wake",
          origin: origin,
          principal: principal,
          session_key: resolved.bound_session,
          target_role: resolved.target[:target_role],
          params: params
        }

        {:ok, call, resolved.bound_session}

      "spawn" ->
        target = resolved.target

        params =
          %{
            display_name: resolved.params[:display] || target.name,
            handle: target.name,
            harness: target.harness,
            model: target.model,
            idempotency_key: key
          }
          |> maybe_put(:effort, target[:effort])
          |> maybe_put(:context, target[:context])
          |> maybe_put(:archetype, target[:archetype])
          |> maybe_put(:host, target[:host])

        {:ok,
         %{
           verb: "spawn",
           origin: origin,
           principal: principal,
           session_key: nil,
           params: params
         }, nil}
    end
  end

  defp bind_target(db, "assign", %{target: %{target_role: role}} = resolved) do
    case Roles.resolve(db, role) do
      {:ok, key, false} -> {:ok, Map.put(resolved, :bound_session, key)}
      _ -> {:error, :unbound_role}
    end
  end

  defp bind_target(db, "wake", %{target: %{target_role: role}} = resolved) do
    case Roles.resolve(db, role) do
      {:ok, key, false} -> {:ok, Map.put(resolved, :bound_session, key)}
      _ -> {:error, :unbound_role}
    end
  end

  defp bind_target(_db, "wake", %{target: %{target_session: key}} = resolved)
       when is_binary(key),
       do: {:ok, Map.put(resolved, :bound_session, key)}

  defp bind_target(_db, "spawn", resolved), do: {:ok, resolved}

  defp producer_id("assign", %{id: id}, _hint), do: id
  defp producer_id("spawn", %{session_key: key}, _hint), do: key
  defp producer_id("wake", _result, hint), do: hint
  defp producer_id(_action, _result, _hint), do: nil

  defp rewake_target(db, "assign", subject, context, _resolved, producer_key) do
    if latest_episode_review_holder_verdict(db, subject, producer_key) do
      context.holder_key
    else
      case DB.query(db, "SELECT holderKey FROM assignments WHERE id = ?1", [producer_key]) do
        {:ok, [[holder_key]]} -> holder_key
        _ -> nil
      end
    end
  end

  defp rewake_target(
         _db,
         _action,
         _subject,
         _context,
         %{target: %{target_session: key}},
         _producer_key
       ),
       do: key

  defp rewake_target(_db, _action, _subject, _context, _resolved, producer_key),
    do: producer_key

  defp latest_episode_review_holder_verdict(db, subject, producer_key) do
    case DB.query(
           db,
           """
           SELECT v.verdictKind
           FROM assignments r
           JOIN attests v ON v.assignmentId = r.id
           WHERE r.id = ?2
             AND r.reviewsAssignmentId = ?1
             AND v.kind = 'verdict'
             AND v.bySession = r.holderKey
             AND (
               SELECT COUNT(*)
               FROM assignments linked
               WHERE linked.reviewsAssignmentId = ?1
             ) = 1
           ORDER BY v.ts DESC, v.rowid DESC LIMIT 1
           """,
           [subject, producer_key]
         ) do
      {:ok, [[kind]]} -> kind
      _ -> nil
    end
  end

  defp producer_dead?(db, rule, context, subject, occurrence, producer_key) do
    not producer_live?(db, rule.remedy.action, producer_key) and
      idempotency_points_to?(
        db,
        rule,
        context,
        dispatch_key(rule.name, subject, occurrence),
        producer_key
      )
  end

  defp producer_live?(_db, _action, nil), do: false

  defp producer_live?(db, "assign", producer_key) do
    match?(
      {:ok, [["open"]]},
      DB.query(db, "SELECT state FROM assignments WHERE id = ?1", [producer_key])
    )
  end

  defp producer_live?(db, _action, producer_key) do
    match?(%{state: "active"}, Org.get(db, producer_key))
  end

  defp idempotency_points_to?(db, rule, context, key, producer_key) do
    owner =
      case rule.remedy.action do
        "assign" -> "user:" <> context.owner
        "spawn" -> context.owner
        "wake" -> "remedy:" <> rule.name
      end

    case Idempotency.get(db, owner, rule.remedy.action, key) do
      %{session_key: wake_id} when rule.remedy.action == "wake" ->
        match?(%{session_key: ^producer_key}, Wakes.get(db, wake_id))

      %{session_key: ^producer_key} ->
        true

      _ ->
        false
    end
  end

  defp release_dispatch(db, statute, subject, token) do
    cas(
      db,
      """
      DELETE FROM rail_remedy_episodes
      WHERE statute = ?1 AND subject = ?2 AND status = 'dispatched' AND claimToken = ?3
      """,
      [statute, subject, token]
    )
  end

  defp binding_context(db, subject, call) do
    assignment_id = binding_assignment_id(db, subject, call)

    case DB.query(
           db,
           """
           SELECT a.id, a.workItemId, a.holderKey, a.holderRole, s.archetype, s.ownerUserId
           FROM assignments a
           JOIN sessions s ON s.sessionKey = a.holderKey
           WHERE a.id = ?1
           """,
           [assignment_id]
         ) do
      {:ok, [[assignment_id, work_item_id, holder_key, holder_role, archetype, owner]]} ->
        {:ok,
         %{
           assignment_id: assignment_id,
           work_item_id: work_item_id,
           holder_key: holder_key,
           holder_role: holder_role,
           holder_archetype: archetype,
           caller_origin: call.origin,
           owner: owner
         }}

      _ ->
        {:error, :unbound_assignment}
    end
  end

  defp binding_assignment_id(db, subject, call) do
    case Map.get(call.params, :assignment_id) do
      assignment_id when is_binary(assignment_id) ->
        assignment_id

      _ ->
        case {call.verb, Map.get(call.params, :work_item_id)} do
          {"dispatch", work_item_id} when is_binary(work_item_id) ->
            case DB.query(
                   db,
                   """
                   SELECT id
                   FROM assignments
                   WHERE workItemId = ?1
                     AND reviewsAssignmentId IS NULL
                     AND state = 'closed'
                     AND outcome = 'completed'
                   ORDER BY closedAt DESC, id DESC
                   LIMIT 1
                   """,
                   [work_item_id]
                 ) do
              {:ok, [[assignment_id]]} -> assignment_id
              _ -> subject
            end

          _ ->
            subject
        end
    end
  end

  defp resolve_remedy(remedy, context) do
    bindings =
      Map.take(
        context,
        ~w(assignment_id work_item_id holder_key holder_role holder_archetype caller_origin)a
      )

    with {:ok, target} <- resolve_map(remedy.target, bindings),
         {:ok, params} <- resolve_map(remedy.params, bindings) do
      {:ok, %{target: target, params: params}}
    end
  end

  defp resolve_map(map, bindings) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, values}, {:ok, acc} when key == :files and is_list(values) ->
        case resolve_list(values, bindings) do
          {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
          error -> {:halt, error}
        end

      {key, value}, {:ok, acc} ->
        embedded? = key in [:subject, :prompt, :display]

        case resolve_value(value, bindings, embedded?) do
          {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
          error -> {:halt, error}
        end
    end)
  end

  defp resolve_list(values, bindings) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_value(value, bindings, false) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp resolve_value(value, _bindings, _embedded?) when not is_binary(value), do: {:ok, value}

  defp resolve_value(value, bindings, false) do
    case Regex.run(~r/^\{([^{}]+)\}$/, value, capture: :all_but_first) do
      [token] -> fetch_binding(bindings, token)
      nil -> {:ok, value}
    end
  end

  defp resolve_value(value, bindings, true) do
    @token_re
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reduce_while({:ok, value}, fn token, {:ok, acc} ->
      case fetch_binding(bindings, token) do
        {:ok, replacement} when is_binary(replacement) ->
          {:cont, {:ok, String.replace(acc, "{#{token}}", replacement)}}

        _ ->
          {:halt, {:error, token}}
      end
    end)
  end

  defp fetch_binding(bindings, token) do
    value = Map.get(bindings, String.to_existing_atom(token))
    if is_nil(value), do: {:error, token}, else: {:ok, value}
  end

  defp read_episode(db, statute, subject) do
    case DB.query(
           db,
           """
           SELECT status, producerKey, occurrence, rewakeCount, claimToken, openedAt, closedAt
           FROM rail_remedy_episodes WHERE statute = ?1 AND subject = ?2
           """,
           [statute, subject]
         ) do
      {:ok, [[status, producer_key, occurrence, rewake_count, token, opened_at, closed_at]]} ->
        %{
          status: status,
          producer_key: producer_key,
          occurrence: occurrence,
          rewake_count: rewake_count,
          claim_token: token,
          opened_at: opened_at,
          closed_at: closed_at
        }

      _ ->
        nil
    end
  end

  defp cas(db, sql, params) do
    case DB.transaction(db, fn txn ->
           Txn.q(txn, sql, params)
           Txn.changes(txn) == 1
         end) do
      {:ok, won?} -> won?
      {:error, error} -> raise error
    end
  end

  defp lifecycle(db, rule, subject, call, result) do
    detail =
      JSON.encode!(%{
        edge: if(Map.get(call, :edge, :verb) == :turn_end, do: "turn-end", else: "verb"),
        ref: subject,
        action: rule.remedy.action,
        producer_id: result.producer_id,
        outcome: result.outcome,
        origin: call.origin
      })

    try do
      EventLog.lifecycle(db, "rail_remedy", rule.name, detail)
    rescue
      _reason -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp remedy_principal(statute, action, owner),
    do: {:remedy, %{statute: statute, action: action, owner: owner}}

  defp dispatch_key(statute, subject, occurrence),
    do: "rail-dispatch:#{statute}:#{subject}:#{occurrence}"

  defp rewake_key(statute, subject, occurrence, rewake_count),
    do: "rail-rewake:#{statute}:#{subject}:#{occurrence}:#{rewake_count}"

  defp rename_param(map, from, to) do
    case Map.pop(map, from) do
      {nil, map} -> map
      {value, map} -> Map.put(map, to, value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp claim_token,
    do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp now, do: System.system_time(:millisecond)
end
