defmodule Tightbeam.EffortCheckin do
  @moduledoc """
  Event-driven effort-without-effect brackets for dispatched assignments.

  EFFECT is any of, since the bracket armed: writes in the workdir, an artifact
  the holder recorded, an attest on the assignment, or an update to the
  assignment's work item. Turns are effort, never effect — a spinning session
  has turns. Git is a change-management system an org may or may not use; it is
  never a requirement for observation, and work done elsewhere (another machine,
  a service, a person) is surfaced by RECORDING AN ARTIFACT, not by probing for
  it.

  Zero effect on every channel prods the AGENT first — one wake naming the four
  channels. Continued silence climbs the holder's active operational parents
  and terminates at Main. This production reports agent inactivity to agents;
  it never manufactures an operator decision.

  Filesystem observation is performed before the callback transaction. The
  transaction then CASes the exact generation/wake pair and either re-arms,
  prods, or schedules the next parent escalation.
  """

  alias Tightbeam.{
    CausalEvents,
    ConditionFacts,
    DB,
    Escalation,
    Org,
    Placement,
    Supervision,
    Wakes
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @origin "process:tightbeam"
  @default_horizon_ms 14_400_000
  @default_priority 4
  @default_deadline_ms 86_400_000

  @ddl """
  CREATE TABLE IF NOT EXISTS effort_checkin_generations (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    generation INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('armed','probed','canceled')),
    baseHorizonMs INTEGER NOT NULL,
    multiplier INTEGER NOT NULL CHECK (multiplier IN (1,2,4)),
    armedAt INTEGER NOT NULL,
    terminalSeqWatermark INTEGER NOT NULL,
    holderKey TEXT NOT NULL,
    host TEXT NOT NULL,
    root TEXT NOT NULL,
    baseline TEXT NOT NULL,
    wakeId TEXT NOT NULL,
    evidence TEXT,
    agentProdded INTEGER NOT NULL DEFAULT 0,
    artifactWatermark INTEGER NOT NULL DEFAULT 0,
    attestWatermark INTEGER NOT NULL DEFAULT 0,
    workItemWatermark INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (assignmentId, generation)
  );
  CREATE INDEX IF NOT EXISTS effort_checkin_wake
    ON effort_checkin_generations (wakeId, state);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @spec valid_workdir_root(term()) :: :ok | {:error, map()}
  def valid_workdir_root(nil), do: :ok
  def valid_workdir_root(""), do: :ok

  def valid_workdir_root(root) when is_binary(root) do
    segments = Path.split(root)

    cond do
      Path.type(root) == :absolute ->
        invalid_root()

      ".." in segments ->
        invalid_root()

      true ->
        :ok
    end
  end

  def valid_workdir_root(_), do: invalid_root()

  @doc "Capture an arm baseline without holding the DB transaction."
  @spec prepare_arm(map(), map(), String.t() | nil) :: map()
  def prepare_arm(config, session, workdir_root \\ nil) do
    root = root_path(config, session, workdir_root)

    %{
      session_key: session.session_key,
      host: session.host,
      root: root,
      baseline: observe(config, session, root)
    }
  end

  @spec arm_in_txn(Txn.t(), map(), map(), map()) :: map()
  def arm_in_txn(%Txn{} = txn, config, assignment, prepared) do
    session = session_in_txn(txn, assignment.holderKey)

    {root, baseline} =
      case prepared do
        %{session_key: key, host: host, root: root, baseline: baseline}
        when key == session.session_key and host == session.host ->
          {root, baseline}

        %{session_key: _key} ->
          raise "effort arm placement changed before commit"
      end

    [[generation]] =
      Txn.q(
        txn,
        "SELECT COALESCE(MAX(generation), 0) + 1 FROM effort_checkin_generations WHERE assignmentId = ?1",
        [assignment.id]
      )

    insert_generation(txn, config, assignment.id, session, root, baseline, generation, 1, 0)
  end

  @doc "Capture a fresh workspace baseline before reopening a monitored assignment."
  @spec prepare_reopen_arm(DB.server(), map(), String.t()) :: map() | nil
  def prepare_reopen_arm(db, config, assignment_id) do
    case generation_for_assignment(db, assignment_id, :current) do
      nil ->
        nil

      generation ->
        session = Org.get(db, generation.holder_key)

        %{
          prior_generation: generation.generation,
          arm: prepare_arm(config, session, relative_root(config, generation))
        }
    end
  end

  @doc "Arm a fresh inactivity generation when a formerly monitored assignment reopens."
  @spec arm_reopened_in_txn(Txn.t(), map(), map(), map() | nil) :: :ok
  def arm_reopened_in_txn(_txn, _config, _assignment, nil), do: :ok

  def arm_reopened_in_txn(%Txn{} = txn, config, assignment, prepared) do
    case current_generation(txn, assignment.id) do
      %{generation: generation} when generation == prepared.prior_generation ->
        arm_in_txn(txn, config, assignment, prepared.arm)
        :ok

      _ ->
        raise "effort generation changed before reopen commit"
    end
  end

  @doc "Capture monitored assignments on a holder against a destination placement."
  @spec prepare_holder_rearms(DB.server(), map(), map()) :: [map()]
  def prepare_holder_rearms(db, config, destination_session) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT a.id,g.generation,g.wakeId,g.root,g.holderKey,g.host
        FROM assignments a
        JOIN effort_checkin_generations g ON g.assignmentId=a.id
        WHERE a.holderKey=?1 AND a.state='open'
          AND g.generation=(
            SELECT MAX(g2.generation) FROM effort_checkin_generations g2
            WHERE g2.assignmentId=a.id
          )
        ORDER BY a.openedAt,a.id
        """,
        [destination_session.session_key]
      )

    Enum.map(rows, fn [assignment_id, generation, wake_id, root, holder_key, host] ->
      prior = %{holder_key: holder_key, host: host, root: root}
      relative = relative_root(config, prior)

      %{
        assignment_id: assignment_id,
        prior_generation: generation,
        prior_wake_id: wake_id,
        arm: prepare_arm(config, destination_session, relative)
      }
    end)
  end

  @doc "Capture selected monitored assignments against a new holder."
  @spec prepare_transferred_rearms(DB.server(), map(), map(), [String.t()]) :: [map()]
  def prepare_transferred_rearms(db, config, destination_session, assignment_ids) do
    Enum.flat_map(assignment_ids, fn assignment_id ->
      case generation_for_assignment(db, assignment_id, :current) do
        nil ->
          []

        prior ->
          [
            %{
              assignment_id: assignment_id,
              prior_generation: prior.generation,
              prior_wake_id: prior.wake_id,
              arm:
                prepare_arm(
                  config,
                  destination_session,
                  relative_root(config, prior)
                )
            }
          ]
      end
    end)
  end

  @spec cancel_in_txn(Txn.t(), String.t(), map()) :: :ok
  def cancel_in_txn(%Txn{} = txn, assignment_id, command) do
    case current_generation(txn, assignment_id) do
      nil ->
        :ok

      generation ->
        if generation.state == "armed" do
          cancel_pending_wake_in_txn!(txn, generation.wake_id, command)
        end

        Txn.q(
          txn,
          "UPDATE effort_checkin_generations SET state = 'canceled' WHERE assignmentId = ?1 AND generation = ?2 AND state IN ('armed','probed')",
          [assignment_id, generation.generation]
        )

        :ok
    end

    dispose_requests_in_txn(txn, assignment_id, command)
    :ok
  end

  @spec apply_prepared_rearms_in_txn(Txn.t(), map(), String.t(), [map()]) :: :ok
  def apply_prepared_rearms_in_txn(%Txn{} = txn, config, holder_key, prepared) do
    Enum.each(prepared, fn item ->
      case current_generation(txn, item.assignment_id) do
        %{generation: generation, wake_id: wake_id}
        when generation == item.prior_generation and wake_id == item.prior_wake_id ->
          case Txn.q(
                 txn,
                 "SELECT 1 FROM assignments WHERE id=?1 AND holderKey=?2 AND state='open'",
                 [item.assignment_id, holder_key]
               ) do
            [[1]] ->
              replacement =
                arm_in_txn(
                  txn,
                  config,
                  %{id: item.assignment_id, holderKey: holder_key},
                  item.arm
                )

              replace_monitor_in_txn(
                txn,
                item.assignment_id,
                current_generation_number: generation,
                current_wake_id: wake_id,
                replacement: replacement
              )

            [] ->
              :ok
          end

        _ ->
          raise "effort generation changed before workspace-motion commit"
      end
    end)

    :ok
  end

  defp replace_monitor_in_txn(txn, assignment_id, opts) do
    replacement = Keyword.fetch!(opts, :replacement)
    current_generation_number = Keyword.fetch!(opts, :current_generation_number)
    current_wake_id = Keyword.fetch!(opts, :current_wake_id)
    source_id = "#{assignment_id}##{replacement.generation}"

    command = %{
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "superseded",
      causal_source: %{kind: "monitor_generation", id: source_id},
      outcome: %{kind: "replacement", replacement_wake_id: replacement.wake_id}
    }

    cancel_pending_wake_in_txn!(txn, current_wake_id, command)

    Txn.q(
      txn,
      "UPDATE effort_checkin_generations SET state = 'canceled' WHERE assignmentId = ?1 AND generation = ?2 AND state IN ('armed','probed')",
      [assignment_id, current_generation_number]
    )

    supersede_requests_in_txn(txn, assignment_id, command)
    :ok
  end

  @spec prepared_rearms_current?(Txn.t(), String.t(), [map()]) :: boolean()
  def prepared_rearms_current?(%Txn{} = txn, holder_key, prepared) do
    current =
      Txn.q(
        txn,
        """
        SELECT a.id,g.generation,g.wakeId
        FROM assignments a
        JOIN effort_checkin_generations g ON g.assignmentId=a.id
        WHERE a.holderKey=?1 AND a.state='open'
          AND g.generation=(
            SELECT MAX(g2.generation) FROM effort_checkin_generations g2
            WHERE g2.assignmentId=a.id
          )
        ORDER BY a.id
        """,
        [holder_key]
      )

    expected =
      prepared
      |> Enum.map(&[&1.assignment_id, &1.prior_generation, &1.prior_wake_id])
      |> Enum.sort()

    current == expected
  end

  @spec probe(DB.server(), map(), Wakes.wake()) :: :ok
  def probe(db, config, wake) do
    snapshot = generation_for_wake(db, wake.wake_id)

    # Only an ARMED generation is observed: an observation consumes the stamp it
    # probed and lays the next one, so replaying a probe against an already
    # probed generation would destroy the stamp its row still points at.
    inspection =
      case snapshot do
        %{state: "armed"} = generation ->
          observe(
            config,
            %{session_key: generation.holder_key, host: generation.host},
            generation.root,
            generation.baseline
          )

        _ ->
          {:error, "generation unavailable"}
      end

    case DB.transaction(db, fn txn -> probe_in_txn(txn, config, wake, inspection) end) do
      {:ok, _request} -> :ok
      {:error, error} -> raise error
    end
  end

  @spec deadline(DB.server(), map(), Wakes.wake()) :: :ok
  def deadline(db, config, wake) do
    case DB.transaction(db, fn txn -> deadline_in_txn(txn, config, wake) end) do
      {:ok, _request} -> :ok
      {:error, error} -> raise error
    end
  end

  @spec rule(DB.server(), map(), map()) :: map()
  def rule(db, config, call) do
    request_id = call.params[:request_id] || call.params[:request]
    action = call.params[:action]
    request = request_row(db, request_id)
    actor = Escalation.principal_id(call)

    cond do
      is_nil(request) ->
        error("not_found", "decision request not found")

      request.kind != "effort" and not visible_request?(db, call, request) ->
        error("not_found", "decision request not found")

      request.kind != "effort" ->
        error("invalid", "effort-rule requires an effort request")

      action not in ["continue", "dismiss"] ->
        error("invalid_action", "action must be continue or dismiss")

      not authorized?(call.principal, request) ->
        error("not_authorized", "current expecter required")

      request.status == "ruled" and request.decision == action and request.ruled_by == actor ->
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            Publisher.maybe_observed_accepted_in_txn(txn, call)
          end)

        request

      request.status != "open" ->
        error("not_open", "decision request is not open")

      true ->
        fresh =
          if action == "dismiss" do
            generation =
              generation_for_assignment(db, request.assignment_id, request.effort_generation)

            session =
              Org.get(db, generation.holder_key)

            prepare_holder_rearms(
              db,
              config,
              session
            )
          end

        case DB.transaction(db, fn txn ->
               result =
                 rule_in_txn(
                   txn,
                   config,
                   request,
                   action,
                   actor,
                   call.principal,
                   fresh
                 )

               if is_map(result) and not Map.has_key?(result, :code),
                 do: Publisher.maybe_accepted_in_txn(txn, call, result)

               result
             end) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end
    end
  end

  @doc "Exact ordinary-power menu for the request's current expecter."
  @spec menu_in_txn(Txn.t(), map(), map()) :: [String.t()]
  def menu_in_txn(txn, assignment, expecter) do
    base = ["wake", "continue", "dismiss"]

    revocation =
      cond do
        expecter.session_key && assignment.opened_by_session == expecter.session_key ->
          ["revoke-assignment", "dispatch"]

        expecter.user_id && assignment.opened_by_user == expecter.user_id ->
          ["revoke-assignment", "dispatch"]

        expecter.user_id && admin_user?(txn, expecter.user_id) ->
          ["revoke-assignment", "dispatch"]

        true ->
          []
      end

    # Per effort-without-effect-checkin-v1: the menu is computed PER POWER, and
    # retire appears iff the RETIRE HANDLER authorizes this rung's principal —
    # never from a role label, and authority is never widened to make a menu item.
    # The gate was `expecter.user_id &&`, i.e. user rungs only, which agreed with
    # the handler only because the handler was broken for every agent origin. Now
    # that it resolves the caller's owner, a SESSION rung whose owner owns the
    # holder can retire it, so the menu widens to match — following the handler,
    # not leading it.
    retire =
      if holder_owner(txn, assignment.holder_key) == expecter.principal_user_id &&
           not built_in?(txn, assignment.holder_key),
         do: ["retire"],
         else: []

    base ++ revocation ++ retire
  end

  defp probe_in_txn(txn, config, wake, inspection) do
    case generation_for_wake_in_txn(txn, wake.wake_id) do
      %{state: "armed"} = generation ->
        eligible? =
          Txn.q(
            txn,
            """
            SELECT 1
            FROM assignments AS a
            LEFT JOIN work_items AS w ON w.id=a.workItemId
            WHERE a.id=?1 AND a.state='open'
              AND (a.workItemId IS NULL OR w.state!='iceboxed')
            """,
            [generation.assignment_id]
          ) == [[1]]

        if eligible? do
          Txn.q(
            txn,
            "UPDATE effort_checkin_generations SET state = 'probed' WHERE assignmentId = ?1 AND generation = ?2 AND wakeId = ?3 AND state = 'armed'",
            [generation.assignment_id, generation.generation, wake.wake_id]
          )

          if Txn.changes(txn) == 1 do
            mark_wake_fired(txn, wake.wake_id)
            session = session_in_txn(txn, generation.holder_key)

            if ConditionFacts.standing_in_txn?(
                 txn,
                 "work-blocked",
                 generation.holder_key
               ) do
              insert_generation(
                txn,
                config,
                generation.assignment_id,
                session,
                generation.root,
                advanced_baseline(generation.baseline, inspection),
                generation.generation + 1,
                generation.multiplier,
                generation.agent_prodded
              )

              nil
            else
              channels = channels(txn, generation, inspection)

              if effect?(channels) do
                insert_generation(
                  txn,
                  config,
                  generation.assignment_id,
                  session,
                  generation.root,
                  inspection,
                  generation.generation + 1,
                  1,
                  0
                )

                nil
              else
                evidence = evidence(generation, channels)

                # The observation consumed this generation's stamp and laid the
                # next one, so the row advances to it even when nothing moved:
                # a later `continue` re-arms against a stamp that still exists.
                Txn.q(
                  txn,
                  "UPDATE effort_checkin_generations SET evidence = ?3, baseline = ?4 WHERE assignmentId = ?1 AND generation = ?2",
                  [
                    generation.assignment_id,
                    generation.generation,
                    JSON.encode!(evidence),
                    encode_observation(advanced_baseline(generation.baseline, inspection))
                  ]
                )

                if generation.agent_prodded == 0 do
                  prod_holder_in_txn(txn, generation, evidence)

                  insert_generation(
                    txn,
                    config,
                    generation.assignment_id,
                    session,
                    generation.root,
                    advanced_baseline(generation.baseline, inspection),
                    generation.generation + 1,
                    generation.multiplier,
                    1
                  )

                  nil
                else
                  escalate_parent_in_txn(
                    txn,
                    config,
                    generation,
                    evidence,
                    session,
                    advanced_baseline(generation.baseline, inspection)
                  )
                end
              end
            end
          end
        else
          mark_wake_fired(txn, wake.wake_id)

          Txn.q(
            txn,
            "UPDATE effort_checkin_generations SET state='canceled' WHERE assignmentId=?1 AND generation=?2 AND wakeId=?3 AND state='armed'",
            [generation.assignment_id, generation.generation, wake.wake_id]
          )
        end

      _ ->
        nil
    end
  end

  defp deadline_in_txn(txn, config, wake) do
    case request_for_deadline(txn, wake.wake_id) do
      nil ->
        nil

      request ->
        next = advance_expecter(txn, request)
        deadline = now() + deadline_ms(config)
        assignment = assignment_in_txn(txn, request.assignment_id)
        menu = menu_in_txn(txn, assignment, next)
        context = Map.put(request.context, "actions", menu)

        replacement =
          Wakes.schedule_in_txn(txn, %{
            session_key: next.session_key || Org.personal_session_key(next.user_id),
            origin: @origin,
            consumer: "effort_deadline",
            due_at: deadline,
            assignment_id: request.assignment_id
          })

        outcome =
          Escalation.effort_update_generation_in_txn(txn, request.id, wake.wake_id, %{
            expecter_session_key: next.session_key,
            expecter_user_id: next.user_id,
            lineage_rung: next.rung,
            deadline_at: deadline,
            deadline_wake_id: replacement.wake_id,
            options_json: JSON.encode!(menu),
            context_json: JSON.encode!(context)
          })

        case outcome do
          {:advanced, advanced} ->
            mark_wake_fired(txn, wake.wake_id)

            # The request row is overwritten in place and the replacement deadline
            # wake carries no rung, so the rung it advanced FROM has no other home.
            CausalEvents.append_in_txn(txn, %{
              kind: "effort_rung_advance",
              assignment_id: request.assignment_id,
              job_ref: job_ref_in_txn(txn, request.assignment_id),
              session_key: next.session_key,
              detail: %{
                requestId: request.id,
                fromRung: request.lineage_rung,
                toRung: next.rung,
                fromExpecter:
                  expecter_ref(request.expecter_session_key, request.expecter_user_id),
                toExpecter: expecter_ref(next.session_key, next.user_id)
              }
            })

            advanced

          :lost ->
            winner = request_for_id(txn, request.id)

            command =
              if winner.status == "open" and winner.deadline_wake_id != replacement.wake_id do
                %{
                  requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                  reason_kind: "superseded",
                  causal_source: %{kind: "wake", id: winner.deadline_wake_id},
                  outcome: %{
                    kind: "replacement",
                    replacement_wake_id: winner.deadline_wake_id
                  }
                }
              else
                decision_disposition_command(
                  txn,
                  winner,
                  liveness_trigger_in_txn!(txn, winner.assignment_id)
                )
              end

            cancel_pending_wake_in_txn!(txn, replacement.wake_id, command)
            nil
        end
    end
  end

  defp rule_in_txn(txn, config, request, action, actor, principal, fresh) do
    current = request_for_id(txn, request.id)

    cond do
      not authorized?(principal, current) ->
        error("not_authorized", "current expecter required")

      current.status == "ruled" and current.decision == action and
          current.ruled_by == actor ->
        current

      action == "dismiss" and
          not prepared_rearms_current?(
            txn,
            generation_for_assignment_in_txn(
              txn,
              current.assignment_id,
              current.effort_generation
            ).holder_key,
            fresh
          ) ->
        error("stale_effort_snapshot", "holder effort state changed; retry the ruling")

      current.status == "open" ->
        ruled_at = now()

        if Escalation.effort_rule_in_txn(txn, current.id, action, actor, ruled_at) do
          ruled = request_for_id(txn, current.id)

          cancel_pending_wake_in_txn!(
            txn,
            current.deadline_wake_id,
            decision_disposition_command(
              txn,
              ruled,
              liveness_trigger_in_txn!(txn, ruled.assignment_id)
            )
          )

          generation =
            generation_for_assignment_in_txn(
              txn,
              current.assignment_id,
              current.effort_generation
            )

          case action do
            "continue" ->
              session = session_in_txn(txn, generation.holder_key)

              insert_generation(
                txn,
                config,
                current.assignment_id,
                session,
                generation.root,
                generation.baseline,
                generation.generation + 1,
                min(generation.multiplier * 2, 4),
                generation.agent_prodded
              )

            "dismiss" ->
              apply_prepared_rearms_in_txn(
                txn,
                config,
                generation.holder_key,
                fresh
              )
          end

          request_for_id(txn, current.id)
        else
          error("not_open", "decision request is not open")
        end

      true ->
        error("not_open", "decision request is not open")
    end
  end

  defp insert_generation(
         txn,
         config,
         assignment_id,
         session,
         root,
         baseline,
         generation,
         multiplier,
         agent_prodded
       ) do
    armed_at = now()
    horizon = horizon_ms(txn, config, assignment_id)

    [[watermark]] =
      Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) FROM turns WHERE sessionKey = ?1", [
        session.session_key
      ])

    # One cursor per channel, captured with the arm — the same shape the turns
    # watermark has always had. A timestamp would tie with its own bracket.
    artifacts = cursor(txn, "artifacts", "rowid")
    attests = cursor(txn, "attests", "rowid")
    work_items = cursor(txn, "work_item_events", "id")

    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: session.session_key,
        origin: @origin,
        consumer: "effort_probe",
        due_at: armed_at + horizon * multiplier,
        assignment_id: assignment_id
      })

    Txn.q(
      txn,
      """
      INSERT INTO effort_checkin_generations
        (assignmentId, generation, state, baseHorizonMs, multiplier, armedAt,
         terminalSeqWatermark, holderKey, host, root, baseline, wakeId,
         agentProdded, artifactWatermark, attestWatermark, workItemWatermark)
      VALUES (?1, ?2, 'armed', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
      """,
      [
        assignment_id,
        generation,
        horizon,
        multiplier,
        armed_at,
        watermark,
        session.session_key,
        session.host,
        root,
        encode_observation(baseline),
        wake.wake_id,
        agent_prodded,
        artifacts,
        attests,
        work_items
      ]
    )

    generation_for_assignment_in_txn(txn, assignment_id, generation)
  end

  @doc "Apply a work-item priority change to its inherited assignment priorities and live probes."
  @spec reprioritize_work_item_in_txn(Txn.t(), map(), String.t(), integer()) :: :ok
  def reprioritize_work_item_in_txn(%Txn{} = txn, config, work_item_id, priority) do
    Txn.q(
      txn,
      """
      INSERT INTO assignment_priorities (assignmentId, priority)
      SELECT id, ?2 FROM assignments WHERE workItemId=?1
      ON CONFLICT(assignmentId) DO UPDATE SET priority=excluded.priority
      """,
      [work_item_id, priority]
    )

    horizon = horizon_for_priority(txn, config, priority)

    Txn.q(
      txn,
      """
      UPDATE wakes
      SET dueAt=(
        SELECT g.armedAt + (?2 * g.multiplier)
        FROM effort_checkin_generations AS g
        WHERE g.wakeId=wakes.wakeId AND g.state='armed'
      )
      WHERE wakeId IN (
        SELECT g.wakeId
        FROM effort_checkin_generations AS g
        JOIN assignments AS a ON a.id=g.assignmentId
        WHERE a.workItemId=?1 AND a.state='open' AND g.state='armed'
          AND g.generation=(
            SELECT MAX(g2.generation) FROM effort_checkin_generations AS g2
            WHERE g2.assignmentId=g.assignmentId
          )
      ) AND state='pending'
      """,
      [work_item_id, horizon]
    )

    Txn.q(
      txn,
      """
      UPDATE effort_checkin_generations
      SET baseHorizonMs=?2
      WHERE assignmentId IN (
        SELECT id FROM assignments WHERE workItemId=?1 AND state='open'
      ) AND state='armed'
        AND generation=(
          SELECT MAX(g2.generation) FROM effort_checkin_generations AS g2
          WHERE g2.assignmentId=effort_checkin_generations.assignmentId
        )
      """,
      [work_item_id, horizon]
    )

    :ok
  end

  defp supersede_requests_in_txn(txn, assignment_id, command) do
    txn
    |> Escalation.effort_supersede_open_in_txn(assignment_id)
    |> Enum.each(&cancel_pending_wake_in_txn!(txn, &1, command))

    :ok
  end

  defp dispose_requests_in_txn(txn, assignment_id, command) do
    txn
    |> Escalation.effort_supersede_open_in_txn(assignment_id)
    |> Enum.each(&cancel_pending_wake_in_txn!(txn, &1, command))

    :ok
  end

  defp cancel_pending_wake_in_txn!(txn, wake_id, command) do
    case Txn.q(txn, "SELECT state FROM wakes WHERE wakeId = ?1", [wake_id]) do
      [["pending"]] ->
        if not Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id)) do
          raise "typed effort cancellation refused for #{wake_id}"
        end

      [[state]] when state in ["fired", "canceled"] ->
        :ok

      [] ->
        raise "effort state references missing wake #{wake_id}"
    end
  end

  defp decision_disposition_command(_txn, request, liveness_trigger) do
    outcome = %{
      kind: "disposition",
      disposition_kind: "decision_request_transition",
      disposition_id: request.id
    }

    %{
      requester: %{kind: "process", id: "tightbeam:effort-checkin"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "decision_request", id: request.id},
      outcome: put_liveness_trigger(outcome, liveness_trigger)
    }
  end

  defp put_liveness_trigger(outcome, trigger) when is_map(trigger),
    do: Map.put(outcome, :liveness_trigger, trigger)

  defp put_liveness_trigger(outcome, nil), do: outcome

  defp liveness_trigger_in_txn!(txn, assignment_id) do
    primary = decision_liveness_primary_in_txn(txn, assignment_id)

    case primary do
      nil ->
        nil

      primary ->
        fetch_liveness_trigger_in_txn!(txn, primary)
    end
  end

  defp decision_liveness_primary_in_txn(txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT state,workItemId FROM assignments WHERE id=?1",
           [assignment_id]
         ) do
      [["open", _work_item_id]] ->
        {:assignment, assignment_id}

      [[_state, work_item_id]] when is_binary(work_item_id) ->
        case Txn.q(txn, "SELECT state FROM work_items WHERE id=?1", [work_item_id]) do
          [["open"]] -> {:work_item, work_item_id}
          [[_terminal]] -> nil
          [] -> raise "assignment #{assignment_id} references missing work item #{work_item_id}"
        end

      [[_state, nil]] ->
        nil

      [] ->
        raise "decision request references missing assignment #{assignment_id}"
    end
  end

  defp fetch_liveness_trigger_in_txn!(txn, primary) do
    case Supervision.liveness_trigger_in_txn(txn, primary) do
      {:ok, trigger} when is_map(trigger) -> trigger
      :none -> raise "#{inspect(primary)} has no liveness trigger"
      {:error, reason} -> raise "invalid liveness trigger: #{inspect(reason)}"
    end
  end

  defp advance_expecter(_txn, %{expecter_user_id: user, lineage_rung: rung})
       when is_binary(user) do
    %{
      session_key: nil,
      user_id: user,
      owner_user_id: user,
      principal_user_id: user,
      rung: rung
    }
  end

  defp advance_expecter(txn, request) do
    current = session_in_txn(txn, request.expecter_session_key)
    assignment = assignment_in_txn(txn, request.assignment_id)

    if current.kind != "main" do
      route_session(
        txn,
        current.effective_parent,
        request.owner_user_id,
        request.lineage_rung + 1,
        assignment.holder_key
      )
    else
      %{
        session_key: nil,
        user_id: request.owner_user_id,
        owner_user_id: request.owner_user_id,
        principal_user_id: request.owner_user_id,
        rung: request.lineage_rung + 1
      }
    end
  end

  defp route_session(txn, key, owner_user_id, rung, holder_key) do
    session = session_in_txn(txn, key)

    cond do
      key == holder_key and session.kind != "main" ->
        route_session(txn, session.effective_parent, owner_user_id, rung + 1, holder_key)

      key == holder_key ->
        %{
          session_key: nil,
          user_id: owner_user_id,
          owner_user_id: owner_user_id,
          principal_user_id: owner_user_id,
          rung: rung + 1
        }

      session.state == "active" ->
        %{
          session_key: key,
          user_id: nil,
          owner_user_id: owner_user_id,
          principal_user_id: session.owner_user_id,
          rung: rung
        }

      session.kind != "main" ->
        route_session(txn, session.effective_parent, owner_user_id, rung + 1, holder_key)

      true ->
        %{
          session_key: nil,
          user_id: owner_user_id,
          owner_user_id: owner_user_id,
          principal_user_id: owner_user_id,
          rung: rung + 1
        }
    end
  end

  # The four channels, all read in the verdict's own transaction. Turns ride
  # along as EFFORT — they are reported, never counted as effect.
  defp channels(txn, generation, inspection) do
    %{
      workspace: workspace_channel(generation.baseline, inspection),
      artifacts:
        count_since(
          txn,
          "SELECT COUNT(*) FROM artifacts WHERE createdBySession = ?1 AND rowid > ?2",
          [generation.holder_key, generation.artifact_watermark]
        ),
      attests:
        count_since(
          txn,
          "SELECT COUNT(*) FROM attests WHERE assignmentId = ?1 AND rowid > ?2",
          [generation.assignment_id, generation.attest_watermark]
        ),
      workItems: work_item_updates(txn, generation),
      turns: terminal_turns(txn, generation)
    }
  end

  defp effect?(channels) do
    channels.workspace == :writes or channels.artifacts > 0 or channels.attests > 0 or
      channels.workItems > 0
  end

  defp workspace_channel({:error, _}, _inspection), do: :unobservable
  defp workspace_channel(_baseline, {:error, _}), do: :unobservable

  defp workspace_channel({:ok, baseline}, {:ok, current}) do
    cond do
      current.prior != "observed" -> :unobservable
      current.writes > 0 -> :writes
      current.digest != baseline.digest -> :writes
      true -> :none
    end
  end

  defp work_item_updates(txn, generation) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id = ?1", [
           generation.assignment_id
         ]) do
      [[item]] when is_binary(item) ->
        # 'metadata' only. A 'composition' doorbell says the item gained or lost
        # an assignment — substrate structure, not the holder updating anything,
        # and the DISPATCH THAT ARMS THIS BRACKET emits one after the arming
        # transaction commits. Counting it would let every bracket read its own
        # arming as effect and swallow the first prod on the production path.
        count_since(
          txn,
          "SELECT COUNT(*) FROM work_item_events WHERE workItemId = ?1 AND id > ?2 AND kind = 'metadata'",
          [item, generation.work_item_watermark]
        )

      _ ->
        0
    end
  end

  defp terminal_turns(txn, generation) do
    [[turns]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(*) FROM turns
        WHERE sessionKey = ?1 AND seq > ?2
          AND status IN ('delivered','failed','failed_unknown')
        """,
        [generation.holder_key, generation.terminal_seq_watermark]
      )

    turns
  end

  # No table guards. A channel whose table is missing is a broken substrate, not
  # a channel that observed nothing — reading it as zero would fire a prod off
  # the breakage. The gateway creates all four tables at boot.
  defp count_since(txn, sql, params) do
    [[count]] = Txn.q(txn, sql, params)
    count
  end

  defp cursor(txn, table, column) do
    [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(#{column}), 0) FROM #{table}")
    cursor
  end

  defp evidence(generation, channels) do
    %{
      assignmentId: generation.assignment_id,
      effortGeneration: generation.generation,
      outcome: "zero_effect",
      channels: %{
        writes: Atom.to_string(channels.workspace),
        artifacts: channels.artifacts,
        attests: channels.attests,
        workItems: channels.workItems
      },
      workspace: generation.root,
      agentProdded: generation.agent_prodded > 0,
      turnsSinceArmed: channels.turns,
      minutesSinceArmed: div(max(now() - generation.armed_at, 0), 60_000)
    }
  end

  # The agent prod: one wake to the HOLDER naming every channel that was checked.
  # It rides the ordinary active-session gate — a holder that is not there to
  # answer is the owner's decision at the next bracket, not a second prod.
  defp prod_holder_in_txn(txn, generation, evidence) do
    Wakes.schedule_in_txn(txn, %{
      session_key: generation.holder_key,
      origin: @origin,
      prompt:
        "[effort check-in] Assignment #{generation.assignment_id}: " <>
          channel_sentence(evidence) <>
          " Record only a new material result or evidence, an exact new blocker or refusal, " <>
          "a bounded decision request, or one new, unexpired bounded checkpoint. " <>
          "A checkpoint must name the next action or condition and its deadline. " <>
          "Use `artifact-record` for anything produced outside this workdir " <>
          "(another machine, a service, a conversation). Do not file generic or duplicate status. " <>
          "If no reporting exception applies, schedule a concrete continuation wake that names " <>
          "the next action or dependency condition and when to resume.",
      due_at: now(),
      assignment_id: generation.assignment_id
    })
  end

  defp escalate_parent_in_txn(_txn, _config, _generation, _evidence, %{kind: "main"}, _baseline),
    do: nil

  defp escalate_parent_in_txn(txn, config, generation, evidence, session, baseline) do
    chain = active_operational_chain!(txn, session)
    visited = parent_targets_in_streak(txn, generation)

    case Enum.find(chain, &(not MapSet.member?(visited, &1))) do
      nil ->
        nil

      target ->
        target_session = session_in_txn(txn, target)

        Wakes.schedule_in_txn(txn, %{
          session_key: target,
          origin: @origin,
          prompt:
            "[effort escalation] Child session #{generation.holder_key} remains inactive on " <>
              "assignment #{generation.assignment_id} after its prod: " <>
              channel_sentence(evidence) <>
              " Act through your ordinary session powers. Main is the terminal agent rung; " <>
              "only Main may ask its operator for a real decision.",
          due_at: now(),
          assignment_id: generation.assignment_id
        })

        if target_session.kind == "main" do
          nil
        else
          insert_generation(
            txn,
            config,
            generation.assignment_id,
            session,
            generation.root,
            baseline,
            generation.generation + 1,
            generation.multiplier,
            generation.agent_prodded + 1
          )
        end
    end
  end

  # The count brackets the current silent streak; the wake rows preserve the
  # identities already notified in it. Re-reading the live chain and choosing
  # its first unvisited member makes a concurrent reparent observable here.
  defp parent_targets_in_streak(txn, generation) do
    count = generation.agent_prodded - 1

    if count > 0 do
      txn
      |> Txn.q(
        """
        SELECT sessionKey
        FROM wakes
        WHERE assignmentId=?1 AND prompt LIKE '[effort escalation]%'
        ORDER BY rowid DESC
        LIMIT ?2
        """,
        [generation.assignment_id, count]
      )
      |> Enum.map(fn [session_key] -> session_key end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp active_operational_chain!(txn, session) do
    operational_chain!(
      txn,
      session.effective_parent,
      MapSet.new([session.session_key]),
      []
    )
  end

  defp operational_chain!(txn, key, visited, acc) do
    if MapSet.member?(visited, key) do
      raise "incompatible_nullable_effective_parent_v1: cycle before Main at #{key}"
    end

    parent = session_in_txn(txn, key)
    next_acc = if parent.state == "active", do: [key | acc], else: acc

    cond do
      parent.effective_parent == key and parent.state == "active" ->
        Enum.reverse(next_acc)

      parent.effective_parent == key ->
        raise "incompatible_nullable_effective_parent_v1: fixed parent #{key} is not active"

      true ->
        operational_chain!(
          txn,
          parent.effective_parent,
          MapSet.put(visited, key),
          next_acc
        )
    end
  end

  defp channel_sentence(evidence) do
    "no writes, artifacts, attests, or work-item updates observed since " <>
      "#{evidence.minutesSinceArmed}m ago (#{evidence.turnsSinceArmed} turns taken; " <>
      "workspace #{evidence.workspace}: #{evidence.channels.writes})."
  end

  defp advanced_baseline(_baseline, {:ok, _observation} = inspection), do: inspection
  defp advanced_baseline(baseline, _inspection), do: baseline

  defp observe(config, session, root, baseline \\ nil) do
    case Placement.effort_observation(config, session, root, baseline) do
      {:ok, observation} -> {:ok, observation}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_observation({:ok, observation}),
    do: JSON.encode!(%{status: "available", observation: observation})

  defp encode_observation({:error, reason}),
    do: JSON.encode!(%{status: "unavailable", reason: reason})

  defp decode_observation(encoded) do
    case JSON.decode!(encoded) do
      %{"status" => "available", "observation" => observation} ->
        {:ok,
         %{
           stamp: observation["stamp"],
           prior: observation["prior"],
           writes: observation["writes"],
           entries: observation["entries"],
           digest: observation["digest"]
         }}

      %{"reason" => reason} ->
        {:error, reason}
    end
  end

  defp root_path(config, session, root) do
    base = Placement.workdir_path(config, session)
    if root in [nil, ""], do: base, else: Path.join(base, root)
  end

  defp relative_root(config, generation) do
    base =
      Placement.workdir_path(config, %{
        session_key: generation.holder_key,
        host: generation.host
      })

    case Path.relative_to(generation.root, base) do
      "." -> nil
      relative -> relative
    end
  end

  defp authorized?({:session, _key}, _request), do: true
  defp authorized?({:user, user}, request), do: request.expecter_user_id == user
  defp authorized?(_, _request), do: false

  defp visible_request?(_db, %{principal: {:session, _key}}, %{kind: "agent"}), do: true

  defp visible_request?(db, call, request) do
    owner_user_id =
      case call.principal do
        {:session, key} ->
          case Org.get(db, key) do
            %{owner_user_id: owner} -> owner
            _ -> nil
          end

        {:user, user_id} ->
          user_id

        _ ->
          nil
      end

    not is_nil(Escalation.get(db, call, request.id, owner_user_id: owner_user_id))
  end

  defp invalid_root,
    do: {:error, error("invalid_workdir_root", "workdirRoot must be relative and contain no ..")}

  defp horizon_ms(txn, config, assignment_id) do
    priority = assignment_priority_in_txn(txn, assignment_id)
    horizon_for_priority(txn, config, priority)
  end

  defp horizon_for_priority(txn, config, priority) do
    base =
      Map.get(
        config,
        :effort_checkin_horizon_ms,
        Application.get_env(:tightbeam, :effort_checkin_horizon_ms, @default_horizon_ms)
      )

    default_priority = default_priority_in_txn(txn)
    steps = priority - default_priority

    if steps >= 0,
      do: max(div(base, Integer.pow(2, steps)), 1),
      else: base * Integer.pow(2, -steps)
  end

  defp assignment_priority_in_txn(txn, assignment_id) do
    case Txn.q(
           txn,
           """
           SELECT COALESCE(
             (SELECT priority FROM assignment_priorities WHERE assignmentId=a.id),
             (SELECT priority FROM work_item_priorities WHERE workItemId=a.workItemId),
             CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)
           )
           FROM assignments AS a WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [[priority]] -> priority
      [] -> default_priority_in_txn(txn)
    end
  end

  defp default_priority_in_txn(txn) do
    case Txn.q(txn, "SELECT value FROM org_settings WHERE key='default-priority'") do
      [[value]] -> String.to_integer(value)
      [] -> @default_priority
    end
  end

  defp deadline_ms(config),
    do:
      Map.get(
        config,
        :escalation_decision_deadline_ms,
        Application.get_env(
          :tightbeam,
          :escalation_decision_deadline_ms,
          @default_deadline_ms
        )
      )

  defp assignment_in_txn(txn, id) do
    [[id, holder, opened_user, opened_session]] =
      Txn.q(
        txn,
        "SELECT id, holderKey, openedByUser, openedBySession FROM assignments WHERE id = ?1",
        [id]
      )

    %{
      id: id,
      holder_key: holder,
      opened_by_user: opened_user,
      opened_by_session: opened_session
    }
  end

  defp session_in_txn(txn, key) do
    Org.get_in_txn(txn, key) || raise ArgumentError, "unknown session: #{key}"
  end

  defp holder_owner(txn, key) do
    [[owner]] = Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [key])
    owner
  end

  defp built_in?(txn, key) do
    Txn.q(txn, "SELECT isBuiltIn FROM sessions WHERE sessionKey = ?1", [key]) == [[1]]
  end

  defp admin_user?(txn, user) do
    Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]) == [[1]]
  end

  defp current_generation(txn, assignment_id) do
    case Txn.q(
           txn,
           generation_select() <> " WHERE assignmentId = ?1 ORDER BY generation DESC LIMIT 1",
           [assignment_id]
         ) do
      [row] -> generation(row)
      [] -> nil
    end
  end

  defp generation_for_wake(db, wake_id) do
    {:ok, rows} = DB.query(db, generation_select() <> " WHERE wakeId = ?1", [wake_id])

    case rows do
      [row] -> generation(row)
      [] -> nil
    end
  end

  defp generation_for_wake_in_txn(txn, wake_id) do
    case Txn.q(txn, generation_select() <> " WHERE wakeId = ?1", [wake_id]) do
      [row] -> generation(row)
      [] -> nil
    end
  end

  defp generation_for_assignment(db, assignment_id, :current) do
    {:ok, rows} =
      DB.query(
        db,
        generation_select() <>
          " WHERE assignmentId = ?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    case rows do
      [row] -> generation(row)
      [] -> nil
    end
  end

  defp generation_for_assignment(db, assignment_id, generation) do
    {:ok, [row]} =
      DB.query(
        db,
        generation_select() <> " WHERE assignmentId = ?1 AND generation = ?2",
        [assignment_id, generation]
      )

    generation(row)
  end

  defp generation_for_assignment_in_txn(txn, assignment_id, generation_number) do
    [row] =
      Txn.q(
        txn,
        generation_select() <> " WHERE assignmentId = ?1 AND generation = ?2",
        [assignment_id, generation_number]
      )

    generation(row)
  end

  defp generation_select do
    "SELECT assignmentId, generation, state, baseHorizonMs, multiplier, armedAt, terminalSeqWatermark, holderKey, host, root, baseline, wakeId, evidence, agentProdded, artifactWatermark, attestWatermark, workItemWatermark FROM effort_checkin_generations"
  end

  defp generation([
         assignment_id,
         generation,
         state,
         base_horizon_ms,
         multiplier,
         armed_at,
         watermark,
         holder_key,
         host,
         root,
         baseline,
         wake_id,
         evidence,
         agent_prodded,
         artifact_watermark,
         attest_watermark,
         work_item_watermark
       ]) do
    %{
      assignment_id: assignment_id,
      generation: generation,
      state: state,
      base_horizon_ms: base_horizon_ms,
      multiplier: multiplier,
      armed_at: armed_at,
      terminal_seq_watermark: watermark,
      holder_key: holder_key,
      host: host,
      root: root,
      baseline: decode_observation(baseline),
      wake_id: wake_id,
      evidence: evidence && JSON.decode!(evidence),
      agent_prodded: agent_prodded,
      artifact_watermark: artifact_watermark,
      attest_watermark: attest_watermark,
      work_item_watermark: work_item_watermark
    }
  end

  # Thin wrappers, kept under their existing local names so the (many) call
  # sites below are untouched — the SQL itself now lives nowhere in this file
  # (Sol xhigh review round 2, finding 1). `Escalation.request_from_row/1`'s
  # map already carries every field this module ever read from its own
  # narrower 18-column parser (`owner_user_id`, `assignment_id`,
  # `expecter_session_key`, `expecter_user_id`, `lineage_rung`,
  # `effort_generation`, `deadline_wake_id`, `raised_at`, `deadline_at`,
  # `question`, `options` decoded, `context` decoded, `status`, `decision`,
  # `ruled_by`, `ruled_at`) under the identical names, plus the columns only
  # the other two arms use — harmless extras, never read here.
  defp request_for_deadline(txn, wake_id),
    do: Escalation.effort_open_by_deadline_wake_in_txn(txn, wake_id)

  defp request_for_id(txn, id), do: Escalation.raw_by_id_in_txn!(txn, id)

  defp request_row(db, id), do: Escalation.raw_by_id(db, id)

  defp mark_wake_fired(txn, wake_id) do
    Txn.q(
      txn,
      "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
      [wake_id, now()]
    )
  end

  defp job_ref_in_txn(txn, assignment_id) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id = ?1", [assignment_id]) do
      [[job_ref]] -> job_ref
      [] -> nil
    end
  end

  # The expecter is a session OR a user; one ref renders either without losing
  # which it was.
  defp expecter_ref(session_key, _user_id) when is_binary(session_key),
    do: "session:" <> session_key

  defp expecter_ref(_session_key, user_id) when is_binary(user_id), do: "user:" <> user_id
  defp expecter_ref(_session_key, _user_id), do: nil

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: System.system_time(:millisecond)
end
