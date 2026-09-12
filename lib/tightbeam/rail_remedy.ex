defmodule Tightbeam.RailRemedy do
  @moduledoc "Active rail remedy execution and durable remedy-episode lifecycle."

  alias Tightbeam.{
    DB,
    Dispatch,
    EventLog,
    Idempotency,
    Org,
    RecurrenceSuppression,
    Roles,
    Rules,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @ttl_ms 60_000
  @token_re ~r/\{([^{}]+)\}/

  @ddl """
  CREATE TABLE IF NOT EXISTS rail_remedy_episodes (
    statute     TEXT    NOT NULL,
    subject     TEXT    NOT NULL,
    status      TEXT    NOT NULL CHECK (status IN ('claimed','dispatched','live','closed')),
    producerKey TEXT,
    noticeState TEXT NULL,
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

  @doc false
  def resolve_notice(db, notice, bindings) when is_map(notice) and is_map(bindings) do
    target = Map.take(notice, [:target_role, :target_session])
    params = Map.take(notice, [:prompt])

    with {:ok, resolved_target} <- resolve_map(target, bindings),
         {:ok, resolved_params} <- resolve_map(params, bindings),
         {:ok, resolved} <-
           bind_target(db, "wake", %{target: resolved_target, params: resolved_params}) do
      {:ok, resolved}
    end
  end

  @doc "Fire one remedy decision through the episode CAS and producer dispatch."
  @spec fire(DB.server(), Dispatch.handlers(), map(), String.t(), map()) :: outcome()
  def fire(db, handlers, rule, subject, call) do
    if rule.name == "completion-requires-review" and rule.remedy.action == "wake" do
      fire_review_notice(db, rule, subject, call)
    else
      fire_legacy(db, handlers, rule, subject, call)
    end
  end

  defp fire_legacy(db, handlers, rule, subject, call) do
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

  defp fire_review_notice(db, rule, subject, call) do
    now = now()
    refs = get_in(call, [:params, :commit_refs])
    interval = Map.get(call, :supervision_interval_ms, 1_000)

    result =
      case DB.transaction(db, fn txn ->
             row =
               Txn.q(
                 txn,
                 "SELECT status,occurrence,noticeState FROM rail_remedy_episodes WHERE statute=?1 AND subject=?2",
                 [rule.name, subject]
               )

             case row do
               [["live", _occurrence, nil]] ->
                 %{
                   outcome: "blocked-legacy-producer",
                   producer_id: nil
                 }

               [["live", _occurrence, encoded]] ->
                 state = decode_notice_state(encoded)

                 if state["need"]["state"] in ["withdrawn", "terminal"] do
                   %{
                     outcome: "notification-stopped",
                     producer_id: get_in(state, ["root", "wakeId"])
                   }
                 else
                   state = put_in(state, ["need", "resultRefs"], refs)
                   state = put_in(state, ["need", "state"], "requested")
                   state = put_in(state, ["need", "changedAt"], now)

                   Txn.q(
                     txn,
                     "UPDATE rail_remedy_episodes SET noticeState=?3 WHERE statute=?1 AND subject=?2",
                     [
                       rule.name,
                       subject,
                       JSON.encode!(state)
                     ]
                   )

                   %{
                     outcome: "recurrence-suppressed",
                     producer_id: get_in(state, ["root", "wakeId"])
                   }
                 end

               [["closed", occurrence, encoded]] when is_binary(encoded) ->
                 state = decode_notice_state(encoded)

                 if state["need"]["state"] in ["withdrawn", "terminal"] do
                   %{
                     outcome: "notification-stopped",
                     producer_id: get_in(state, ["root", "wakeId"])
                   }
                 else
                   open_review_notice(
                     txn,
                     rule.name,
                     subject,
                     occurrence + 1,
                     refs,
                     now,
                     interval
                   )
                 end

               prior ->
                 occurrence = next_occurrence(prior)
                 open_review_notice(txn, rule.name, subject, occurrence, refs, now, interval)
             end
           end) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end

    lifecycle(db, rule, subject, call, result)
    result
  end

  defp open_review_notice(txn, statute, subject, occurrence, refs, now, interval) do
    case Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject) do
      {:ok, recipient} ->
        root_id = notice_wake_id(statute, subject, occurrence, 0)
        reassess_id = notice_wake_id(statute, subject, occurrence, 1)

        root =
          Tightbeam.Gateway.schedule_review_notice_in_txn(txn, recipient, %{
            wake_id: root_id,
            assignment_id: subject,
            due_at: now,
            prompt:
              "Review is required for assignment #{subject} at immutable result #{format_refs(refs)}."
          })

        _reassessment =
          Tightbeam.Gateway.schedule_review_notice_in_txn(txn, recipient, %{
            wake_id: reassess_id,
            assignment_id: subject,
            due_at: now + interval,
            consumer: "review_remedy_reconcile",
            prompt:
              JSON.encode!(%{
                statute: statute,
                subject: subject,
                occurrence: occurrence,
                generation: 1
              })
          })

        state =
          notice_state(
            refs,
            root.wake_id,
            recipient.session_key,
            reassess_id,
            now,
            interval
          )

        upsert_notice_episode(
          txn,
          statute,
          subject,
          occurrence,
          root.wake_id,
          state,
          now
        )

        %{outcome: "claimed-dispatched", producer_id: root.wake_id}

      {:error, missing} ->
        state = notice_state(refs, nil, nil, nil, now, interval)
        state = Map.put(state, "blocked", Atom.to_string(missing.reason))
        upsert_notice_episode(txn, statute, subject, occurrence, nil, state, now)
        %{outcome: "missing-owner", producer_id: nil}
    end
  end

  @doc false
  def reconcile_pending_episodes(db, interval) do
    DB.transaction(db, fn txn ->
      Txn.q(txn, """
      SELECT subject,occurrence,producerKey,noticeState FROM rail_remedy_episodes
      WHERE statute='completion-requires-review' AND status='live'
        AND (noticeState IS NULL OR json_extract(noticeState,'$.reassessment') IS NULL)
      ORDER BY openedAt,subject LIMIT 100
      """)
      |> Enum.each(fn [subject, occurrence, producer, encoded] ->
        state =
          if encoded,
            do: decode_notice_state(encoded),
            else:
              notice_state(nil, nil, nil, nil, now(), interval)
              |> Map.put("legacyProducer", producer)

        cond do
          state["need"]["state"] == "withdrawn" ->
            :ok

          state["blocked"] == "accountable_owner_chain_exhausted" ->
            :ok

          true ->
            case Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject) do
              {:ok, recipient} ->
                state =
                  if is_nil(state["root"]) do
                    legacy? = Map.has_key?(state, "legacyProducer")

                    root_id =
                      if legacy?,
                        do:
                          notice_recovery_wake_id(
                            "completion-requires-review",
                            subject,
                            occurrence,
                            1,
                            "legacy-reconcile"
                          ),
                        else: notice_wake_id("completion-requires-review", subject, occurrence, 0)

                    prompt =
                      if legacy?,
                        do:
                          "Reconcile preserved legacy review producer #{inspect(producer)} for #{subject}; retain existing review custody and do not assume delivery or restaff.",
                        else:
                          "Independent review remains required for assignment #{subject}; resolve its recorded need."

                    root =
                      schedule_protocol_notice(txn, recipient, state, %{
                        wake_id: root_id,
                        assignment_id: subject,
                        due_at: now(),
                        prompt: prompt
                      })

                    next =
                      put_in(state, ["root"], %{
                        "wakeId" => root.wake_id,
                        "recipient" => recipient.session_key,
                        "purpose" => if(legacy?, do: "legacy-reconcile", else: "review-needed")
                      })

                    Txn.q(
                      txn,
                      "UPDATE rail_remedy_episodes SET producerKey=?3 WHERE statute=?1 AND subject=?2",
                      ["completion-requires-review", subject, root.wake_id]
                    )

                    next
                  else
                    state
                  end

                old_generations =
                  Txn.q(
                    txn,
                    """
                    SELECT wakeId,json_extract(prompt,'$.generation') FROM wakes
                    WHERE consumer='review_remedy_reconcile' AND json_valid(prompt)
                      AND json_extract(prompt,'$.statute')='completion-requires-review'
                      AND json_extract(prompt,'$.subject')=?1 AND json_extract(prompt,'$.occurrence')=?2
                    """,
                    [subject, occurrence]
                  )

                if is_nil(encoded) do
                  Enum.each(old_generations, fn [id, _] ->
                    Txn.q(
                      txn,
                      "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending' AND consumer='review_remedy_reconcile'",
                      [id, now()]
                    )
                  end)
                end

                generation =
                  Enum.max([
                    state["lastGeneration"] || 0 | Enum.map(old_generations, &Enum.at(&1, 1))
                  ])

                schedule_next_reassessment(
                  txn,
                  "completion-requires-review",
                  subject,
                  occurrence,
                  generation,
                  interval,
                  Map.put(state, "intervalMs", interval),
                  now()
                )

              {:error, _} ->
                persist_notice_state(
                  txn,
                  "completion-requires-review",
                  subject,
                  Map.put(state, "blocked", "missing_accountable_owner")
                )
            end
        end
      end)

      :ok
    end)
  end

  @doc false
  def reconcile_notice(db, config, wake) do
    interval = Map.get(config, :supervision_interval_ms, 1_000)

    case JSON.decode(wake.prompt || "") do
      {:ok,
       %{
         "statute" => statute,
         "subject" => subject,
         "occurrence" => occurrence,
         "generation" => generation
       }} ->
        case DB.transaction(db, fn txn ->
               case Txn.q(
                      txn,
                      "SELECT noticeState FROM rail_remedy_episodes WHERE statute=?1 AND subject=?2 AND status='live' AND occurrence=?3",
                      [statute, subject, occurrence]
                    ) do
                 [[encoded]] ->
                   state = decode_notice_state(encoded)

                   if get_in(state, ["reassessment", "wakeId"]) == wake.wake_id and
                        get_in(state, ["reassessment", "generation"]) == generation do
                     root_id = get_in(state, ["root", "wakeId"])

                     recovery_ids =
                       Enum.map(state["recoveries"], & &1["wakeId"])

                     outcomes =
                       Tightbeam.Wakes.delivery_outcomes_in_txn(txn, %{
                         root_wake_id: root_id,
                         recovery_wake_ids: recovery_ids,
                         assignment_id: subject
                       })

                     observed_at = now()
                     state = record_delivery_observations(state, outcomes, observed_at)
                     Tightbeam.Wakes.consume_internal_in_txn(txn, wake.wake_id)

                     case review_need_in_txn(txn, subject, state, outcomes) do
                       {:stopped, cause} ->
                         state = put_in(state, ["need", "state"], cause)

                         stop_notice_work(
                           txn,
                           statute,
                           subject,
                           occurrence,
                           state,
                           outcomes,
                           observed_at,
                           cause
                         )

                       {:ok, review_attest_id} ->
                         state = put_in(state, ["need", "state"], "satisfied")
                         state = put_in(state, ["need", "reviewAttestId"], review_attest_id)
                         state = put_in(state, ["need", "changedAt"], observed_at)

                         stop_notice_work(
                           txn,
                           statute,
                           subject,
                           occurrence,
                           state,
                           outcomes,
                           observed_at,
                           "satisfied"
                         )

                       :missing ->
                         if episode_subject_terminal_in_txn?(txn, subject) do
                           state = put_in(state, ["need", "state"], "terminal")
                           state = put_in(state, ["need", "changedAt"], observed_at)

                           stop_notice_work(
                             txn,
                             statute,
                             subject,
                             occurrence,
                             state,
                             outcomes,
                             observed_at,
                             "terminal"
                           )
                         else
                           state =
                             reconcile_requested_notice(
                               txn,
                               statute,
                               subject,
                               occurrence,
                               state,
                               outcomes,
                               observed_at
                             )

                           schedule_next_reassessment(
                             txn,
                             statute,
                             subject,
                             occurrence,
                             generation,
                             interval,
                             state,
                             observed_at
                           )
                         end
                     end
                   else
                     raise ArgumentError, "stale review remedy reassessment"
                   end

                 _ ->
                   raise ArgumentError, "review remedy episode is not live"
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, error} -> raise error
        end

      _ ->
        raise ArgumentError, "invalid review remedy reassessment payload"
    end
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
         call,
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
           :ok <- prepare_first_recurrence(db, rule, subject, call, key),
           {:ok, result} <- Dispatch.dispatch(db, handlers, producer_call),
           producer_id when is_binary(producer_id) <-
             producer_id(rule.remedy.action, result, producer_hint),
           :ok <-
             record_first_recurrence(db, rule, subject, call, resolved, producer_id, key) do
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
          target =
            rewake_target(db, rule.remedy.action, subject, context, resolved, row.producer_key)

          case repeat_recurrence(db, rule, subject, call, target) do
            :suppressed ->
              %{outcome: "recurrence-suppressed", producer_id: row.producer_key}

            :deliver ->
              %{outcome: "recurrence-suppressed", producer_id: row.producer_key}

            {:rearmed, _generation} ->
              if close(db, rule.name, subject, occurrence) do
                route_episode(db, handlers, rule, subject, call, context, resolved)
              else
                %{outcome: "recurrence-suppressed", producer_id: row.producer_key}
              end

            _ ->
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
          end
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
  defp producer_id("wake", %{wake_id: id}, _hint) when is_binary(id), do: id
  defp producer_id("wake", %{"wakeId" => id}, _hint) when is_binary(id), do: id
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

  defp producer_live?(db, "wake", producer_key) do
    match?(
      {:ok, [[1]]},
      DB.query(
        db,
        """
        SELECT 1
        FROM wakes w
        JOIN sessions s ON s.sessionKey = w.sessionKey
        WHERE w.wakeId = ?1 AND s.state = 'active'
        """,
        [producer_key]
      )
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
      %{session_key: ^producer_key} when rule.remedy.action == "wake" ->
        not is_nil(Wakes.get(db, producer_key))

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
           SELECT status, producerKey, noticeState, occurrence, rewakeCount, claimToken, openedAt, closedAt
           FROM rail_remedy_episodes WHERE statute = ?1 AND subject = ?2
           """,
           [statute, subject]
         ) do
      {:ok,
       [
         [
           status,
           producer_key,
           notice_state,
           occurrence,
           rewake_count,
           token,
           opened_at,
           closed_at
         ]
       ]} ->
        %{
          status: status,
          producer_key: producer_key,
          notice_state:
            if(is_binary(notice_state), do: decode_notice_state(notice_state), else: nil),
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

  defp next_occurrence([]), do: 1
  defp next_occurrence([["closed", occurrence, _]]), do: occurrence + 1
  defp next_occurrence([[_status, occurrence, _]]), do: occurrence

  defp notice_state(refs, root_id, recipient, reassess_id, now, interval) do
    %{
      "version" => 1,
      "intervalMs" => interval,
      "need" => %{
        "state" => "requested",
        "resultRefs" => refs,
        "reviewAttestId" => nil,
        "changedAt" => now
      },
      "root" =>
        if(is_binary(root_id),
          do: %{"wakeId" => root_id, "recipient" => recipient, "purpose" => "review-needed"},
          else: nil
        ),
      "recoveries" => [],
      "observations" => [],
      "reassessment" =>
        if(is_binary(reassess_id),
          do: %{"generation" => 1, "wakeId" => reassess_id, "dueAt" => now + interval},
          else: nil
        )
    }
  end

  defp decode_notice_state(encoded) when is_binary(encoded) do
    with {:ok, %{"version" => 1} = state} <- JSON.decode(encoded),
         true <- is_map(state["need"]),
         true <- state["need"]["state"] in ~w(requested satisfied terminal withdrawn),
         true <- is_list(state["recoveries"]),
         true <- is_list(state["observations"]) do
      state
    else
      _ -> raise ArgumentError, "unsupported or invalid rail remedy noticeState"
    end
  end

  defp upsert_notice_episode(txn, statute, subject, occurrence, producer_key, state, opened_at) do
    Txn.q(
      txn,
      """
      INSERT INTO rail_remedy_episodes
        (statute,subject,status,producerKey,noticeState,occurrence,rewakeCount,claimToken,openedAt,closedAt)
      VALUES (?1,?2,'live',?3,?4,?5,0,?6,?7,NULL)
      ON CONFLICT(statute,subject) DO UPDATE SET
        status='live', producerKey=excluded.producerKey, noticeState=excluded.noticeState,
        occurrence=excluded.occurrence, rewakeCount=0, claimToken=excluded.claimToken,
        openedAt=excluded.openedAt, closedAt=NULL
      """,
      [statute, subject, producer_key, JSON.encode!(state), occurrence, claim_token(), opened_at]
    )
  end

  defp latest_satisfied_review_in_txn(txn, subject, refs) do
    case Txn.q(
           txn,
           """
           SELECT v.verdictKind,r.holderKey,a.holderKey,
             COALESCE(e.effectKind,'code'),v.commitRefs,v.id
           FROM attests v
           JOIN assignments r ON r.id=v.assignmentId
           JOIN assignments a ON a.id=r.reviewsAssignmentId
           LEFT JOIN assignment_effects e ON e.assignmentId=a.id
           WHERE r.reviewsAssignmentId=?1 AND v.kind='verdict'
             AND v.bySession=r.holderKey
             AND v.verdictKind IN ('reviewed-clean','changes-requested')
           ORDER BY v.ts DESC,v.rowid DESC LIMIT 1
           """,
           [subject]
         ) do
      [["reviewed-clean", review_holder, producer_holder, effect_kind, encoded, attest_id]] ->
        if review_holder != producer_holder and
             review_result_applicable?(effect_kind, encoded, refs),
           do: {:ok, attest_id},
           else: :missing

      _ ->
        :missing
    end
  end

  defp review_need_in_txn(txn, subject, state, outcomes) do
    withdrawn? =
      Enum.any?(outcomes.terminal, fn item ->
        Enum.any?(item.cancellations, fn [reason, _, _, _] ->
          reason in ~w(requester_withdrew obligation_disposed production_unmatched)
        end)
      end)

    cond do
      state["need"]["state"] == "withdrawn" or withdrawn? -> {:stopped, "withdrawn"}
      state["need"]["state"] == "terminal" -> {:stopped, "terminal"}
      true -> latest_satisfied_review_in_txn(txn, subject, state["need"]["resultRefs"])
    end
  end

  defp review_result_applicable?("code", encoded, [_ | _] = refs),
    do: decoded_refs(encoded) == refs

  defp review_result_applicable?("code", _encoded, _refs), do: false
  defp review_result_applicable?(_effect_kind, _encoded, _refs), do: true

  defp episode_subject_terminal_in_txn?(txn, subject) do
    case Txn.q(
           txn,
           """
           SELECT a.state,w.state FROM assignments a
           LEFT JOIN work_items w ON w.id=a.workItemId WHERE a.id=?1
           """,
           [subject]
         ) do
      [["open", work_state]] when work_state in [nil, "open"] -> false
      _ -> true
    end
  end

  defp record_delivery_observations(state, outcomes, observed_at) do
    observations =
      Enum.flat_map(~w(delivered outstanding terminal inconsistencies)a, fn kind ->
        Enum.map(outcomes[kind], fn item ->
          %{
            "attemptId" => item.wake_id,
            "outcome" => Atom.to_string(kind),
            "states" => delivery_states(item),
            "cancellations" => item.cancellations,
            "retries" => item.retries,
            "observedAt" => observed_at
          }
        end)
      end)

    known =
      MapSet.new(state["observations"], fn observation ->
        {observation["attemptId"], observation["outcome"], observation["states"] || [],
         observation["cancellations"] || [], observation["retries"] || []}
      end)

    additions =
      Enum.reject(observations, fn observation ->
        MapSet.member?(
          known,
          {observation["attemptId"], observation["outcome"], observation["states"],
           observation["cancellations"], observation["retries"]}
        )
      end)

    put_in(state, ["observations"], state["observations"] ++ additions)
  end

  defp delivery_states(item) do
    wake_states = Enum.map(item.wake, &hd/1)
    turn_states = Enum.map(item.turns, &Enum.at(&1, 1))
    repair_states = Enum.map(item.repairs, & &1.status)
    Enum.sort(Enum.uniq(wake_states ++ turn_states ++ repair_states))
  end

  defp reconcile_requested_notice(
         txn,
         statute,
         subject,
         occurrence,
         state,
         outcomes,
         observed_at
       ) do
    with {:ok, recipient} <- Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject),
         {:recover, parent, purpose, cause} <-
           selected_recovery(txn, subject, state, outcomes, recipient.session_key),
         {:ok, state, recovery_id} <-
           schedule_notice_recovery(
             txn,
             statute,
             subject,
             occurrence,
             state,
             parent,
             recipient,
             purpose,
             cause,
             observed_at
           ) do
      if pending_delivery?(parent) and purpose == "routing-reconcile" do
        persist_notice_state(txn, statute, subject, state)

        cancel_replaced_notice!(txn, parent.wake_id, recovery_id)
      end

      state
    else
      :none ->
        state

      {:existing, state} ->
        state

      {:error, _} ->
        Map.put(state, "blocked", "missing_accountable_owner")
    end
  end

  defp selected_recovery(txn, subject, state, outcomes, accountable_recipient) do
    unresolved =
      Enum.find(outcomes.inconsistencies, fn item ->
        not recovery_recorded?(state, item, "effects-reconcile")
      end) ||
        Enum.find(outcomes.terminal, fn item ->
          failed_unknown?(item) and not recovery_recorded?(state, item, "effects-reconcile")
        end)

    unroutable =
      Enum.find(outcomes.outstanding, fn item ->
        pending_delivery?(item) and
          item.turns == [] and item.repairs == [] and not item.pending_retry? and
          not pending_recipient_routable?(txn, subject, state, item, accountable_recipient) and
          not recovery_recorded?(state, item, "routing-reconcile")
      end)

    delivered =
      outcomes.delivered
      |> Enum.flat_map(fn item -> [item.wake_id | item.retry_roots] end)
      |> MapSet.new()

    retried_roots =
      (outcomes.delivered ++ outcomes.outstanding ++ outcomes.terminal ++ outcomes.inconsistencies)
      |> Enum.flat_map(fn item -> Enum.reject(item.retry_roots, &(&1 == item.wake_id)) end)
      |> MapSet.new()

    failed =
      Enum.find(outcomes.terminal, fn item ->
        not MapSet.member?(delivered, item.wake_id) and not failed_unknown?(item) and
          not MapSet.member?(retried_roots, item.wake_id) and
          not item.pending_retry? and item.cancellations == [] and
          not recovery_recorded?(state, item, "routing-reconcile")
      end)

    cond do
      unresolved -> {:recover, unresolved, "effects-reconcile", "delivery-effect-unknown"}
      unroutable -> {:recover, unroutable, "routing-reconcile", "target-unresolvable"}
      failed -> {:recover, failed, "routing-reconcile", "delivery-terminal"}
      true -> :none
    end
  end

  defp pending_recipient_routable?(txn, subject, state, item, accountable_recipient) do
    case Enum.find(state["recoveries"], &(&1["wakeId"] == item.wake_id)) do
      nil ->
        wake_target(item) == accountable_recipient

      recovery ->
        wake_target(item) == recovery["recipient"] and
          Txn.q(
            txn,
            """
            SELECT 1 FROM sessions s JOIN assignments a ON a.id=?1
            JOIN work_items w ON w.id=a.workItemId
            WHERE s.sessionKey=?2 AND s.state='active' AND s.ownerUserId=w.ownerUserId
            """,
            [subject, recovery["recipient"]]
          ) == [[1]]
    end
  end

  defp recovery_recorded?(state, item, purpose) do
    Enum.any?(state["recoveries"], fn recovery ->
      recovery["parentWakeId"] == item.wake_id and recovery["purpose"] == purpose
    end)
  end

  defp stop_notice_work(
         txn,
         statute,
         subject,
         occurrence,
         state,
         outcomes,
         observed_at,
         stop_cause
       ) do
    state =
      case selected_recovery(txn, subject, state, outcomes, get_in(state, ["root", "recipient"])) do
        {:recover, parent, _purpose, cause} ->
          if Enum.any?(state["recoveries"], &(&1["wakeId"] == parent.wake_id)) do
            case Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject) do
              {:ok, recipient} ->
                case schedule_notice_recovery(
                       txn,
                       statute,
                       subject,
                       occurrence,
                       state,
                       parent,
                       recipient,
                       "effects-reconcile",
                       cause,
                       observed_at
                     ) do
                  {:ok, next, replacement_id} ->
                    if pending_delivery?(parent) do
                      persist_notice_state(txn, statute, subject, next)
                      cancel_replaced_notice!(txn, parent.wake_id, replacement_id)
                    end

                    next

                  {:existing, next} ->
                    next
                end

              {:error, _} ->
                Map.put(state, "blocked", "missing_accountable_owner")
            end
          else
            state
          end

        :none ->
          state
      end

    state =
      case unresolved_effect(outcomes) do
        nil ->
          state

        item ->
          case Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject) do
            {:ok, recipient} ->
              case schedule_notice_recovery(
                     txn,
                     statute,
                     subject,
                     occurrence,
                     state,
                     item,
                     recipient,
                     "effects-reconcile",
                     "#{stop_cause}-with-unresolved-effects",
                     observed_at
                   ) do
                {:ok, next, _wake_id} -> next
                {:existing, next} -> next
              end

            {:error, _} ->
              Map.put(state, "blocked", "missing_accountable_owner")
          end
      end

    persist_notice_state(txn, statute, subject, state)
    dispose_pending_review_notices(txn, state)

    effects = Enum.filter(state["recoveries"], &(&1["purpose"] == "effects-reconcile"))
    delivered = MapSet.new(outcomes.delivered, & &1.wake_id)

    canceled =
      MapSet.new(outcomes.terminal |> Enum.filter(&(&1.cancellations != [])), & &1.wake_id)

    tracking? =
      Enum.any?(effects, fn recovery ->
        not MapSet.member?(delivered, recovery["wakeId"]) and
          not MapSet.member?(canceled, recovery["wakeId"]) and
          not Enum.any?(state["recoveries"], &(&1["parentWakeId"] == recovery["wakeId"])) and
          state["blocked"] != "accountable_owner_chain_exhausted"
      end)

    if tracking? or (unresolved_effect(outcomes) != nil and effects == []) do
      generation = get_in(state, ["reassessment", "generation"]) || 0

      schedule_next_reassessment(
        txn,
        statute,
        subject,
        occurrence,
        generation,
        state["intervalMs"] || 1_000,
        state,
        observed_at
      )
    else
      persist_notice_state(txn, statute, subject, put_in(state, ["reassessment"], nil))

      Txn.q(
        txn,
        "UPDATE rail_remedy_episodes SET status='closed',closedAt=?4 WHERE statute=?1 AND subject=?2 AND occurrence=?3 AND status='live'",
        [statute, subject, occurrence, observed_at]
      )
    end

    :ok
  end

  defp unresolved_effect(outcomes) do
    List.first(outcomes.inconsistencies) ||
      Enum.find(outcomes.terminal, &failed_unknown?/1) ||
      Enum.find(outcomes.outstanding, fn item ->
        not pending_delivery?(item) and
          Enum.any?(delivery_states(item), &(&1 in ["queued", "running"]))
      end)
  end

  defp failed_unknown?(item), do: "failed_unknown" in delivery_states(item)

  defp pending_delivery?(%{wake: [["pending", _consumer, _session_key]]}), do: true
  defp pending_delivery?(_item), do: false

  defp wake_target(%{wake: [[_state, _consumer, session_key]]}), do: session_key
  defp wake_target(_item), do: nil

  defp schedule_notice_recovery(
         txn,
         statute,
         subject,
         occurrence,
         state,
         parent,
         recipient,
         purpose,
         cause,
         now
       ) do
    prior =
      Enum.find(state["recoveries"], fn recovery ->
        recovery["parentWakeId"] == parent.wake_id and recovery["purpose"] == purpose and
          recovery["cause"] == cause
      end)

    recipient = next_recovery_recipient(txn, recipient, state, purpose)

    if prior do
      {:existing, state}
    else
      if is_nil(recipient) do
        {:existing, Map.put(state, "blocked", "accountable_owner_chain_exhausted")}
      else
        recovery_id =
          notice_recovery_wake_id(
            statute,
            subject,
            occurrence,
            length(state["recoveries"]) + 1,
            purpose
          )

        recovery = %{
          "wakeId" => recovery_id,
          "parentWakeId" => parent.wake_id,
          "recipient" => recipient.session_key,
          "purpose" => purpose,
          "cause" => cause
        }

        prompt =
          case purpose do
            "effects-reconcile" ->
              "Review-notice attempt #{parent.wake_id} for assignment #{subject} has unresolved effects (#{cause}); reconcile that exact attempt without replaying it."

            "routing-reconcile" ->
              "Review remains required for assignment #{subject}; notice #{parent.wake_id} could not complete (#{cause})."
          end

        schedule_protocol_notice(txn, recipient, state, %{
          wake_id: recovery_id,
          assignment_id: subject,
          due_at: now,
          prompt: prompt
        })

        {:ok, put_in(state, ["recoveries"], state["recoveries"] ++ [recovery]), recovery_id}
      end
    end
  end

  defp next_recovery_recipient(txn, recipient, state, purpose) do
    used =
      state["recoveries"]
      |> Enum.filter(&(&1["purpose"] == purpose))
      |> MapSet.new(& &1["recipient"])

    ancestors =
      Txn.q(
        txn,
        """
        WITH RECURSIVE chain(sessionKey,spawnedBy) AS (
          SELECT sessionKey,#{Tightbeam.Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2
          UNION
          SELECT s.sessionKey,#{Tightbeam.Org.current_parent_sql("s")} FROM sessions s JOIN chain c ON s.sessionKey=c.spawnedBy
          WHERE s.ownerUserId=?2
        ) SELECT c.sessionKey FROM chain c JOIN sessions s ON s.sessionKey=c.sessionKey
        WHERE s.state='active'
        """,
        [recipient.session_key, recipient.owner_user_id]
      )
      |> Enum.map(&hd/1)

    candidates =
      Enum.uniq(
        [recipient.session_key | ancestors] ++ [Org.personal_session_key(recipient.owner_user_id)]
      )

    case Enum.find(candidates, fn key ->
           not MapSet.member?(used, key) and
             Txn.q(
               txn,
               "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
               [key, recipient.owner_user_id]
             ) == [[1]]
         end) do
      nil -> nil
      key -> %{recipient | session_key: key}
    end
  end

  defp schedule_protocol_notice(txn, recipient, state, attrs) do
    if state["need"]["state"] in ~w(satisfied terminal withdrawn) do
      # The closed producer is causal context in the payload, not an active obligation.
      Wakes.schedule_in_txn(txn, %{
        wake_id: attrs.wake_id,
        session_key: recipient.session_key,
        owner_user_id: recipient.owner_user_id,
        origin: "remedy:completion-requires-review",
        prompt: attrs.prompt,
        consumer: Map.get(attrs, :consumer, "prompt"),
        due_at: attrs.due_at,
        target_gate: 1,
        sender_scheduled: true
      })
    else
      Tightbeam.Gateway.schedule_review_notice_in_txn(txn, recipient, attrs)
    end
  end

  defp cancel_replaced_notice!(txn, wake_id, replacement_id) do
    command = %{
      wake_id: wake_id,
      requester: %{kind: "process", id: "tightbeam:rail-remedy"},
      reason_kind: "target_unresolvable",
      causal_source: %{kind: "scheduler_delivery", id: wake_id},
      outcome: %{kind: "replacement", replacement_wake_id: replacement_id}
    }

    if Tightbeam.Wakes.cancel_in_txn(txn, command),
      do: :ok,
      else: raise(ArgumentError, "review notice replacement cancellation refused")
  end

  defp dispose_pending_review_notices(txn, state) do
    review_wake_ids =
      [get_in(state, ["root", "wakeId"])] ++
        (state["recoveries"]
         |> Enum.reject(&(&1["purpose"] == "effects-reconcile"))
         |> Enum.map(& &1["wakeId"]))

    Enum.each(Enum.filter(review_wake_ids, &is_binary/1), fn wake_id ->
      if pending_notice_lineage?(txn, wake_id) do
        canceled =
          Tightbeam.Wakes.cancel_in_txn(txn, %{
            wake_id: wake_id,
            requester: %{kind: "process", id: "tightbeam:rail-remedy"},
            reason_kind: "superseded",
            causal_source: %{kind: "wake", id: wake_id},
            outcome: %{kind: "no_replacement"}
          })

        if not canceled,
          do: raise(ArgumentError, "review notice disposal cancellation refused")
      end
    end)
  end

  defp pending_notice_lineage?(txn, wake_id) do
    Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1 AND state='pending'", [wake_id]) == [[1]] or
      Txn.q(
        txn,
        """
        SELECT 1
        FROM wake_retry_attempts r JOIN wakes w ON w.wakeId=r.wakeId
        WHERE r.rootWakeId=?1 AND r.outcome='pending' AND w.state='pending'
        LIMIT 1
        """,
        [wake_id]
      ) == [[1]]
  end

  defp schedule_next_reassessment(
         txn,
         statute,
         subject,
         occurrence,
         generation,
         interval,
         state,
         now
       ) do
    if state["blocked"] == "accountable_owner_chain_exhausted" do
      persist_notice_state(txn, statute, subject, put_in(state, ["reassessment"], nil))
    else
      case Tightbeam.Gateway.review_notice_recipient_in_txn(txn, subject) do
        {:ok, recipient} ->
          next_id = notice_wake_id(statute, subject, occurrence, generation + 1)

          schedule_protocol_notice(txn, recipient, state, %{
            wake_id: next_id,
            assignment_id: subject,
            due_at: now + interval,
            consumer: "review_remedy_reconcile",
            prompt:
              JSON.encode!(%{
                statute: statute,
                subject: subject,
                occurrence: occurrence,
                generation: generation + 1
              })
          })

          state =
            put_in(state, ["reassessment"], %{
              "generation" => generation + 1,
              "wakeId" => next_id,
              "dueAt" => now + interval
            })

          state = Map.put(state, "lastGeneration", generation + 1)

          persist_notice_state(txn, statute, subject, state)

        {:error, _} ->
          state = Map.put(state, "blocked", "missing_accountable_owner")
          persist_notice_state(txn, statute, subject, put_in(state, ["reassessment"], nil))
      end
    end
  end

  defp persist_notice_state(txn, statute, subject, state) do
    Txn.q(
      txn,
      "UPDATE rail_remedy_episodes SET noticeState=?3 WHERE statute=?1 AND subject=?2",
      [statute, subject, JSON.encode!(state)]
    )

    :ok
  end

  defp decoded_refs(encoded) do
    case JSON.decode(encoded || "") do
      {:ok, refs} when is_list(refs) ->
        refs
        |> Enum.map(fn ref ->
          %{"repo" => ref["repo"], "commit" => String.downcase(ref["commit"])}
        end)
        |> Enum.sort_by(&{&1["repo"], &1["commit"]})

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp notice_wake_id(statute, subject, occurrence, generation) do
    digest = :crypto.hash(:sha256, "#{statute}\0#{subject}\0#{occurrence}\0#{generation}")
    "w_" <> (Base.encode16(digest, case: :lower) |> binary_part(0, 32))
  end

  defp notice_recovery_wake_id(statute, subject, occurrence, attempt, purpose) do
    digest =
      :crypto.hash(
        :sha256,
        "#{statute}\0#{subject}\0#{occurrence}\0recovery\0#{attempt}\0#{purpose}"
      )

    "w_" <> (Base.encode16(digest, case: :lower) |> binary_part(0, 32))
  end

  defp format_refs(refs) when refs in [nil, []], do: "the current result"
  defp format_refs(refs), do: Enum.map_join(refs, ", ", &"#{&1["repo"]}@#{&1["commit"]}")

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

  defp prepare_first_recurrence(
         _db,
         %{recurrence_suppression: nil},
         _subject,
         _call,
         _dispatch_key
       ),
       do: :ok

  defp prepare_first_recurrence(db, rule, subject, call, dispatch_key) do
    case RecurrenceSuppression.prepare_first(
           db,
           recurrence_occurrence(rule, subject, call, nil),
           dispatch_key
         ) do
      result when result in [:dispatch, :delivered] -> :ok
      :unavailable -> :ok
      :conflict -> {:error, :recurrence_dispatch_conflict}
    end
  end

  defp record_first_recurrence(
         _db,
         %{recurrence_suppression: nil},
         _subject,
         _call,
         _resolved,
         _producer_id,
         _dispatch_key
       ),
       do: :ok

  defp record_first_recurrence(db, rule, subject, call, resolved, producer_id, dispatch_key) do
    case delivery_target(db, rule.remedy.action, resolved, producer_id) do
      target when is_binary(target) ->
        _ =
          RecurrenceSuppression.record_first(
            db,
            rule.recurrence_suppression,
            recurrence_occurrence(rule, subject, call, target),
            dispatch_key,
            Rules.condition_evidence(
              db,
              call,
              rule.recurrence_suppression.rearm.recovered_when
            )
          )

        :ok

      _ ->
        {:error, :unresolved_delivery_target}
    end
  end

  defp repeat_recurrence(_db, %{recurrence_suppression: nil}, _subject, _call, _target),
    do: :disabled

  defp repeat_recurrence(db, rule, subject, call, target) do
    config = rule.recurrence_suppression

    RecurrenceSuppression.repeat(
      db,
      config,
      recurrence_occurrence(rule, subject, call, target),
      Rules.condition_evidence(db, call, config.rearm.recovered_when),
      Rules.condition_evidence(db, call, config.rearm.recurred_when)
    )
  end

  defp delivery_target(db, "assign", _resolved, assignment_id) do
    case DB.query(db, "SELECT holderKey FROM assignments WHERE id=?1", [assignment_id]) do
      {:ok, [[session_key]]} -> session_key
      _ -> nil
    end
  end

  defp delivery_target(_db, "wake", %{bound_session: session_key}, _producer_id),
    do: session_key

  defp delivery_target(_db, "spawn", _resolved, session_key), do: session_key
  defp delivery_target(_db, _action, _resolved, _producer_id), do: nil

  defp recurrence_occurrence(rule, subject, call, target) do
    params = call.params

    %{
      statute: rule.name,
      target_session: target,
      subject: subject,
      failure_class:
        call[:recurrence_failure_class] || params[:failure_class] || params["failure_class"],
      failure_code:
        call[:recurrence_failure_code] || params[:failure_code] || params["failure_code"],
      receipt_id:
        call[:recurrence_receipt_id] || params[:recurrence_receipt_id] ||
          params["recurrence_receipt_id"],
      sequence:
        call[:recurrence_sequence] || params[:recurrence_sequence] ||
          params["recurrence_sequence"],
      cause: "rail-remedy",
      principal: principal_label(call.principal)
    }
  end

  defp principal_label({:session, key}), do: "session:#{key}"
  defp principal_label({:user, id}), do: "user:#{id}"
  defp principal_label({:process, id}), do: "process:#{id}"
  defp principal_label({:remedy, %{statute: statute}}), do: "remedy:#{statute}"
  defp principal_label(_principal), do: "unknown"

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
