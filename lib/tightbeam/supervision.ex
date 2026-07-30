defmodule Tightbeam.Supervision do
  @moduledoc "The serialized, durable reaction executor for stalled assignments."

  use GenServer

  alias Tightbeam.{
    Adjudication,
    Assignments,
    CausalEvents,
    DB,
    Dispatch,
    Escalation,
    EventLog,
    Gateway,
    Ledger,
    Org,
    RailEpisodes,
    RailRemedy,
    Rules,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @prods_ddl """
  CREATE TABLE IF NOT EXISTS assignment_prods (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    attemptCount INTEGER NOT NULL DEFAULT 0,
    prodCount INTEGER NOT NULL DEFAULT 0,
    deniedStreak INTEGER NOT NULL DEFAULT 0,
    attestCount INTEGER NOT NULL DEFAULT 0,
    lastProdAt INTEGER,
    stalledAt INTEGER,
    strandedAt INTEGER NULL
  )
  """

  @watermarks_ddl """
  CREATE TABLE IF NOT EXISTS supervision_watermarks (
    sessionKey TEXT PRIMARY KEY,
    lastEvaluatedTerminal INTEGER NOT NULL,
    pendingBranch TEXT CHECK (pendingBranch IN ('prod','escalation','terminus')),
    pendingAssignment TEXT,
    pendingK INTEGER NULL,
    pendingN INTEGER NULL
  )
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec notify_terminal(GenServer.server(), String.t(), integer()) :: :ok
  def notify_terminal(server \\ __MODULE__, session_key, terminal_seq) do
    GenServer.cast(server, {:terminal, session_key, terminal_seq})
  end

  @spec notify_retired(GenServer.server(), String.t()) :: :ok
  def notify_retired(server \\ __MODULE__, session_key) do
    GenServer.cast(server, {:retired, session_key})
  end

  @spec request_sweep(GenServer.server()) :: :ok
  def request_sweep(server \\ __MODULE__), do: GenServer.cast(server, :sweep)

  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB) do
    :ok = DB.execute(db, @prods_ddl)
    :ok = DB.execute(db, @watermarks_ddl)
  end

  @spec prod_state(DB.server(), String.t()) :: map() | nil
  def prod_state(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT assignmentId, attemptCount, prodCount, deniedStreak, attestCount, lastProdAt, stalledAt, strandedAt FROM assignment_prods WHERE assignmentId = ?1",
        [assignment_id]
      )

    case rows do
      [[id, attempts, prods, denied, attests, last_prod, stalled, stranded]] ->
        %{
          assignmentId: id,
          attemptCount: attempts,
          prodCount: prods,
          deniedStreak: denied,
          attestCount: attests,
          lastProdAt: last_prod,
          stalledAt: stalled,
          strandedAt: stranded
        }

      [] ->
        nil
    end
  end

  @spec watermark(DB.server(), String.t()) :: map() | nil
  def watermark(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN FROM supervision_watermarks WHERE sessionKey = ?1",
        [session_key]
      )

    case rows do
      [[key, terminal, branch, assignment, k, n]] ->
        %{
          sessionKey: key,
          lastEvaluatedTerminal: terminal,
          pendingBranch: branch,
          pendingAssignment: assignment,
          pendingK: k,
          pendingN: n
        }

      [] ->
        nil
    end
  end

  @spec ladder_target(DB.server() | Txn.t(), String.t(), pos_integer()) :: String.t()
  def ladder_target(db_or_txn, holder_key, rung) do
    [[owner, spawned_by]] =
      query(db_or_txn, "SELECT ownerUserId, spawnedBy FROM sessions WHERE sessionKey = ?1", [
        holder_key
      ])

    chain = lineage(db_or_txn, spawned_by, MapSet.new([holder_key]), [])
    Enum.at(chain, rung - 1) || Org.personal_session_key(owner)
  end

  @spec evaluate(DB.server(), Dispatch.handlers(), non_neg_integer(), String.t(), integer() | nil) ::
          :busy
          | :continuation
          | :idle
          | :duplicate
          | :coalesced
          | {:prodded, pos_integer()}
          | {:escalated, pos_integer(), String.t()}
          | :terminus
          | :stranded
          | {:acted, :rail_remedy}
          | {:acted, :rail_escalate}
          | {:retry, :rail_escalate}
          | {:held, :adjudication_hold}
          | {:refused, String.t()}
  def evaluate(db, handlers, n, session_key, terminal_seq) do
    case drain(db, handlers, session_key) do
      {:pending, result} ->
        result

      {:cleared, _prior_result} ->
        evaluate_terminal(db, handlers, n, session_key, terminal_seq)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      db: Keyword.fetch!(opts, :db),
      handlers: Keyword.fetch!(opts, :handlers),
      n: Keyword.fetch!(opts, :prod_limit),
      delivery_opts: Keyword.take(opts, [:conn_registry, :lane_manager])
    }

    {:ok, state, {:continue, :recovery_sweep}}
  end

  @impl true
  def handle_continue(:recovery_sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:terminal, session_key, terminal_seq}, state) do
    safe_evaluate(state, session_key, fn ->
      evaluate(state.db, state.handlers, state.n, session_key, terminal_seq)
    end)

    {:noreply, state}
  end

  def handle_cast({:retired, session_key}, state) do
    safe_evaluate(state, session_key, fn ->
      :ok = Escalation.withdraw_for_retired(state.db, session_key)
      doorbells_for_holder(state.db, session_key)
      notify_stranded_ancestor(state, session_key)
    end)

    {:noreply, state}
  end

  def handle_cast(:sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  defp evaluate_terminal(db, handlers, n, session_key, terminal_seq) do
    case Assignments.oldest_open(db, session_key) do
      nil ->
        :idle

      assignment ->
        with :new <- dedupe(watermark(db, session_key), terminal_seq),
             0 <- Ledger.pending_count(db, session_key) do
          case holder_state(db, session_key) do
            :retired ->
              # Act-then-watermark (matches the remedy branch): doorbells are an
              # idempotent CAS, so a crash before the watermark re-rings them on
              # redelivery. Watermark-first would lose them permanently (a retired
              # session never re-terminals).
              doorbells_for_holder(db, session_key)
              write_watermark(db, session_key, terminal_seq)
              :stranded

            :live ->
              evaluate_live(db, handlers, n, session_key, terminal_seq, assignment)
          end
        else
          :duplicate ->
            :duplicate

          :coalesced ->
            :coalesced

          count when is_integer(count) and count > 0 ->
            :busy
        end
    end
  end

  # ── THE TURN-END SCHEDULE (supervision-impl r21) ──────────────────────────
  #
  # This list IS the end-of-turn shift: every governance that acts when a
  # turn ends holds exactly one named slot here, and the shift runs them in
  # this order, first halt wins. The order is SEMANTIC, not incidental:
  #
  #   :adjudication_hold — an open adjudication freezes everything downstream
  #                        (a held turn must not be enforced or prodded);
  #   :rail_enforcement  — the org's statutes get the turn before the
  #                        substrate's own ladder does (Rules.decide → remedy /
  #                        escalate / legibility rows; rails-mechanism-v1 owns
  #                        the semantics of this step, this module only hosts
  #                        its slot);
  #   :pending_wake_gate — an already-pending wake means the strand is not
  #                        stalled; nothing downstream should fire;
  #   :prod_ladder       — the sweep proper (prods, escalation ladder,
  #                        watermark). Always halts; the schedule never runs
  #                        off the end.
  #
  # ADDING A STEP (the lease — all four lines, or the shift rejects you):
  #   1. Add the atom HERE, in its semantically correct position.
  #   2. Add a `turn_end_step/2` clause returning `:cont` or `{:halt, result}`.
  #      Read state freely; any write must be idempotent (the terminal cast
  #      can be redelivered) and must NOT move the watermark — the watermark
  #      has ONE writer, the acting step that ends the shift.
  #   3. Extend the termination argument (spec §r21): your step must be
  #      bounded per shift and must not unconditionally re-trigger a turn —
  #      the enforcement loop is bounded ONLY because remedies are
  #      once-per-occurrence; say why yours is bounded too.
  #   4. Extend the order-pinning test in supervision_test.exs — it fails on
  #      any unannounced change to this list, by design.
  #
  # PRINCIPLES every step inherits (r20's invariants, kept verbatim): the
  # substrate never judges ("gave up" is not a state), never punishes (no
  # retire/cancel/re-staff — substrate acts are wakes, stamps, and
  # org-authored statute effects), never reads content (rows or nothing).
  #
  # This list is deliberately NOT a runtime registration seam: steps share
  # the turn context, the order carries meaning, and the termination proof is
  # over the closed composition. Orgs extend turn-end behavior through
  # STATUTES (data, hosted by :rail_enforcement) — never by code injection.
  @turn_end_schedule [:adjudication_hold, :rail_enforcement, :pending_wake_gate, :prod_ladder]

  @doc "The end-of-turn shift, in execution order. Pinned by test; amend both."
  def turn_end_schedule, do: @turn_end_schedule

  defp evaluate_live(db, handlers, n, session_key, terminal_seq, assignment) do
    ctx = %{
      db: db,
      handlers: handlers,
      n: n,
      session_key: session_key,
      terminal_seq: terminal_seq,
      assignment: assignment
    }

    run_schedule(@turn_end_schedule, ctx)
  end

  # First halt wins; :prod_ladder always halts, so the list never runs dry.
  defp run_schedule([step | rest], ctx) do
    case turn_end_step(step, ctx) do
      :cont -> run_schedule(rest, ctx)
      {:halt, result} -> result
    end
  end

  defp turn_end_step(:adjudication_hold, ctx) do
    case adjudication_hold(ctx.db, ctx.session_key, ctx.terminal_seq) do
      {:held, :adjudication_hold} = held -> {:halt, held}
      :fallthrough -> :cont
    end
  end

  defp turn_end_step(:rail_enforcement, ctx) do
    case rail_step(ctx.db, ctx.handlers, ctx.session_key, ctx.assignment, ctx.terminal_seq) do
      {:acted, _tag} = acted -> {:halt, acted}
      {:retry, _tag} = retry -> {:halt, retry}
      :fallthrough -> :cont
    end
  end

  defp turn_end_step(:pending_wake_gate, ctx) do
    if Wakes.pending_count(ctx.db, ctx.session_key) == 0,
      do: :cont,
      else: {:halt, :continuation}
  end

  defp turn_end_step(:prod_ladder, ctx) do
    if is_nil(ctx.terminal_seq) do
      {:halt, :idle}
    else
      {:halt,
       claim_and_act(
         ctx.db,
         ctx.handlers,
         ctx.n,
         ctx.session_key,
         ctx.terminal_seq,
         ctx.assignment
       )}
    end
  end

  defp adjudication_hold(_db, _session_key, nil), do: :fallthrough

  defp adjudication_hold(db, session_key, terminal_seq) do
    if Adjudication.open_for_session?(db, session_key) do
      write_watermark(db, session_key, terminal_seq)
      {:held, :adjudication_hold}
    else
      :fallthrough
    end
  end

  defp rail_step(_db, _handlers, _session_key, _assignment, nil), do: :fallthrough

  defp rail_step(db, handlers, session_key, assignment, terminal_seq) do
    if Wakes.self_pending_count(db, session_key) > 0 do
      :fallthrough
    else
      call = %{
        verb: "attest",
        origin: "remedy:sweep",
        principal: {:session, assignment.holderKey},
        session_key: nil,
        edge: :turn_end,
        params: %{assignment_id: assignment.id, kind: "completion"}
      }

      {decision, to_close, _to_consume} = Rules.decide(db, call)
      Enum.each(to_close, &close_episode(db, &1))

      case decision do
        {:remedy, statute, ref, _error} ->
          RailRemedy.fire(db, handlers, statute, ref, call)
          rail_sweep_lifecycle(db, session_key, ref, statute.name, "run-remedy")
          write_watermark(db, session_key, terminal_seq)
          {:acted, :rail_remedy}

        {:escalate, statute, ctx, dr_id} ->
          decision_request_id =
            case dr_id do
              nil ->
                {:decision_pending, id} =
                  Escalation.escalate(db, call, statute, Map.put(ctx, :dr_id, nil))

                id

              id ->
                id
            end

          case park_escalation(db, session_key, decision_request_id) do
            :parked ->
              rail_sweep_lifecycle(
                db,
                session_key,
                assignment.id,
                statute.name,
                "escalate-park"
              )

              write_watermark(db, session_key, terminal_seq)
              {:acted, :rail_escalate}

            :skipped ->
              {:retry, :rail_escalate}
          end

        # A sensor malfunction summons a mind, but its deny is the sweep's ordinary
        # re-obligate (§A3): the session is NOT parked, because parking is the escalate
        # effect's consequence and the ruling changed what a malfunction ALSO does, not
        # what it decides.
        {:deny_escalate, statute, ctx} ->
          rail_sweep_lifecycle(db, session_key, assignment.id, ctx.error.rule, "re-obligate")
          :ok = RailEpisodes.summon(db, call, statute, Map.put(ctx, :dr_id, nil))
          :fallthrough

        {:deny, error} ->
          rail_sweep_lifecycle(db, session_key, assignment.id, error.rule, "re-obligate")
          :fallthrough

        :allow ->
          rail_sweep_lifecycle(db, session_key, assignment.id, nil, "none")
          :fallthrough
      end
    end
  end

  # The sweep closes both kinds of episode the verb edge does (§C3.5, §A3).
  defp close_episode(db, {:episodes, statute, position}),
    do: RailEpisodes.recovered(db, statute, position)

  defp close_episode(db, {statute, subject}), do: RailRemedy.close(db, statute, subject)

  defp park_escalation(db, session_key, decision_request_id) do
    transaction!(db, fn txn ->
      case Txn.q(
             txn,
             "SELECT deadlineAt, parkWakeId, assignmentId FROM decision_requests WHERE id = ?1 AND status = 'open'",
             [decision_request_id]
           ) do
        [[deadline_at, nil, assignment_id]] ->
          wake =
            Wakes.schedule_in_txn(txn, %{
              session_key: session_key,
              target_role: nil,
              origin: "process:tightbeam",
              prompt:
                "Decision request #{decision_request_id} was ruled; re-adjudicate the obligation.",
              due_at: deadline_at,
              condition_kind: "escalation-ruled",
              condition_scope: decision_request_id,
              creator_session_key: nil,
              # A decision-DEADLINE wake resolves its assignment from the REQUEST
              # row, where it is durable (spec job-forensics-v2 §1).
              assignment_id: assignment_id
            })

          Txn.q(
            txn,
            "UPDATE decision_requests SET parkWakeId = ?2 WHERE id = ?1 AND parkWakeId IS NULL",
            [decision_request_id, wake.wake_id]
          )

          :parked

        [[_deadline_at, park_wake_id, _assignment_id]] when is_binary(park_wake_id) ->
          :parked

        [] ->
          :skipped
      end
    end)
  end

  defp rail_sweep_lifecycle(db, session_key, ref, statute, decision) do
    detail = JSON.encode!(%{ref: ref, statute: statute, decision: decision})
    best_effort_lifecycle(db, "rail_sweep", session_key, detail)
  end

  defp write_watermark(_db, _session_key, nil), do: :ok

  defp write_watermark(db, session_key, terminal_seq) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
        VALUES (?1, ?2, NULL, NULL, NULL, NULL)
        ON CONFLICT(sessionKey) DO UPDATE SET
          lastEvaluatedTerminal = excluded.lastEvaluatedTerminal,
          pendingBranch = NULL,
          pendingAssignment = NULL,
          pendingK = NULL,
          pendingN = NULL
        """,
        [session_key, terminal_seq]
      )

    :ok
  end

  defp dedupe(_watermark, nil), do: :new
  defp dedupe(nil, _terminal), do: :new
  defp dedupe(%{lastEvaluatedTerminal: terminal}, terminal), do: :duplicate
  defp dedupe(%{lastEvaluatedTerminal: prior}, terminal) when terminal < prior, do: :coalesced
  defp dedupe(_watermark, _terminal), do: :new

  defp holder_state(db, session_key) do
    case DB.query(db, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
      {:ok, [["retired"]]} -> :retired
      {:ok, [["active"]]} -> :live
    end
  end

  defp claim_and_act(db, handlers, n, session_key, terminal_seq, assignment) do
    prior = prod_state(db, assignment.id) || zero_state(assignment.id)
    attest_count = Assignments.attest_count(db, assignment.id)

    current =
      if attest_count > prior.attestCount do
        %{prior | attemptCount: 0, prodCount: 0, deniedStreak: 0, stalledAt: nil}
      else
        prior
      end

    attempt_count = current.attemptCount + 1

    {branch, k} =
      if current.prodCount < n do
        {"prod", current.prodCount + 1}
      else
        rung = current.prodCount - n + 1
        target = ladder_target(db, session_key, rung)
        {if(target == session_key, do: "terminus", else: "escalation"), rung}
      end

    stalled_at =
      if branch in ["escalation", "terminus"],
        do: current.stalledAt || now(),
        else: current.stalledAt

    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment, pendingK, pendingN)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(sessionKey) DO UPDATE SET
          lastEvaluatedTerminal = excluded.lastEvaluatedTerminal,
          pendingBranch = excluded.pendingBranch,
          pendingAssignment = excluded.pendingAssignment,
          pendingK = excluded.pendingK,
          pendingN = excluded.pendingN
        """,
        [session_key, terminal_seq, branch, assignment.id, k, n]
      )

      # prod_answered: attestCount is a bare COUNT, so which attest answered the
      # prods is unrecoverable from it. causal_events is its own watermark — every
      # attest not yet named by an event gets one, in attest-id order, so several
      # attests arriving between evaluations each keep their edge.
      if attest_count > prior.attestCount do
        job_ref = job_ref_in_txn(txn, assignment.id)

        for attest_id <- CausalEvents.unseen_attest_ids_in_txn(txn, assignment.id) do
          CausalEvents.append_in_txn(txn, %{
            kind: "prod_answered",
            assignment_id: assignment.id,
            job_ref: job_ref,
            session_key: session_key,
            detail: %{byAttestId: attest_id}
          })
        end
      end

      Txn.q(
        txn,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak, attestCount, lastProdAt, stalledAt, strandedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(assignmentId) DO UPDATE SET
          attemptCount = excluded.attemptCount,
          prodCount = excluded.prodCount,
          deniedStreak = excluded.deniedStreak,
          attestCount = excluded.attestCount,
          lastProdAt = excluded.lastProdAt,
          stalledAt = excluded.stalledAt
        """,
        [
          assignment.id,
          attempt_count,
          current.prodCount,
          current.deniedStreak,
          attest_count,
          current.lastProdAt,
          stalled_at,
          current.strandedAt
        ]
      )
    end)

    case drain(db, handlers, session_key) do
      {:pending, result} -> result
      {:cleared, result} -> result
    end
  end

  defp drain(db, handlers, session_key) do
    case watermark(db, session_key) do
      %{pendingBranch: branch} = pending when is_binary(branch) ->
        drain_pending(db, handlers, pending)

      _ ->
        {:cleared, nil}
    end
  end

  defp drain_pending(db, handlers, pending) do
    case open_assignment(db, pending.pendingAssignment) do
      nil ->
        clear_pending(db, pending)
        {:cleared, nil}

      assignment ->
        drain_open(db, handlers, pending, assignment)
    end
  end

  defp drain_open(db, handlers, %{pendingBranch: "prod"} = pending, assignment) do
    case holder_state(db, pending.sessionKey) do
      :retired ->
        clear_pending(db, pending)
        doorbell(db, assignment.id)
        {:cleared, nil}

      :live ->
        dispatch_wake(db, handlers, pending, assignment, pending.sessionKey)
    end
  end

  defp drain_open(db, handlers, %{pendingBranch: "escalation"} = pending, assignment) do
    target = ladder_target(db, pending.sessionKey, pending.pendingK)
    dispatch_wake(db, handlers, pending, assignment, target)
  end

  defp drain_open(db, _handlers, %{pendingBranch: "terminus"} = pending, _assignment) do
    attempt_count =
      (prod_state(db, pending.pendingAssignment) || zero_state(pending.pendingAssignment)).attemptCount

    EventLog.lifecycle(
      db,
      "supervision_terminus",
      pending.pendingAssignment,
      "holder=#{pending.sessionKey} attemptCount=#{attempt_count}"
    )

    clear_pending(db, pending)
    {:cleared, :terminus}
  end

  defp dispatch_wake(db, handlers, pending, assignment, target) do
    prompt =
      case pending.pendingBranch do
        "prod" ->
          prod_prompt(assignment.id, assignment.subject, pending.pendingK, pending.pendingN)

        "escalation" ->
          escalation_prompt(
            assignment.id,
            assignment.subject,
            pending.sessionKey,
            pending.pendingN,
            pending.pendingK
          )
      end

    # Supervision prods and escalations already hold their assignment when they
    # schedule; they stop dropping it. THIS is what unlocks prod-turn attribution.
    params = %{
      prompt: prompt,
      after_ms: 0,
      nudge: false,
      assignment_id: pending.pendingAssignment
    }

    params =
      if pending.pendingBranch == "escalation" do
        Map.merge(params, %{
          reresolve: "lineage",
          reresolve_seed: pending.sessionKey,
          reresolve_rung: pending.pendingK
        })
      else
        params
      end

    call = %{
      verb: "wake",
      origin: "process:tightbeam",
      principal: {:process, "tightbeam"},
      session_key: target,
      params: params
    }

    case Dispatch.dispatch(db, handlers, call) do
      {:ok, _} ->
        success_clear(db, pending)

        result =
          case pending.pendingBranch do
            "prod" -> {:prodded, pending.pendingK}
            "escalation" -> {:escalated, pending.pendingK, target}
          end

        {:cleared, result}

      {:error, %{code: code}} when code in ["rule_denied", "rule_error"] ->
        denied_streak = denied_clear(db, pending)
        detail = "code=#{code} deniedStreak=#{denied_streak}"
        best_effort_lifecycle(db, "supervision_prod_denied", assignment.id, detail)

        if denied_streak == max(pending.pendingN, 1) do
          best_effort_lifecycle(db, "supervision_blocked", assignment.id, detail)
        end

        {:cleared, {:refused, code}}

      {:error, %{code: code}} ->
        best_effort_lifecycle(db, "supervision_dispatch_failed", assignment.id, "code=#{code}")
        {:pending, {:refused, code}}
    end
  end

  defp clear_pending(db, pending) do
    transaction!(db, fn txn -> clear_pending_in_txn(txn, pending) end)
  end

  defp success_clear(db, pending) do
    transaction!(db, fn txn ->
      if clear_pending_in_txn(txn, pending) do
        Txn.q(
          txn,
          "UPDATE assignment_prods SET prodCount = prodCount + 1, lastProdAt = ?2, deniedStreak = 0 WHERE assignmentId = ?1",
          [pending.pendingAssignment, now()]
        )

        # prodCount is a mutable aggregate that RESETS on attest, and pendingK is
        # overwritten every evaluation: the tier that fired has no other home.
        if pending.pendingBranch == "prod" do
          CausalEvents.append_in_txn(txn, %{
            kind: "prod_fired",
            assignment_id: pending.pendingAssignment,
            job_ref: job_ref_in_txn(txn, pending.pendingAssignment),
            session_key: pending.sessionKey,
            detail: %{tier: pending.pendingK}
          })
        end
      end
    end)
  end

  defp denied_clear(db, pending) do
    transaction!(db, fn txn ->
      if clear_pending_in_txn(txn, pending) do
        Txn.q(
          txn,
          "UPDATE assignment_prods SET deniedStreak = deniedStreak + 1 WHERE assignmentId = ?1",
          [pending.pendingAssignment]
        )
      end

      [[streak]] =
        Txn.q(txn, "SELECT deniedStreak FROM assignment_prods WHERE assignmentId = ?1", [
          pending.pendingAssignment
        ])

      streak
    end)
  end

  defp job_ref_in_txn(txn, assignment_id) do
    case Txn.q(txn, "SELECT workItemId FROM assignments WHERE id = ?1", [assignment_id]) do
      [[job_ref]] -> job_ref
      [] -> nil
    end
  end

  defp clear_pending_in_txn(txn, pending) do
    Txn.q(
      txn,
      """
      UPDATE supervision_watermarks
      SET pendingBranch = NULL, pendingAssignment = NULL, pendingK = NULL, pendingN = NULL
      WHERE sessionKey = ?1 AND pendingBranch = ?2 AND pendingAssignment = ?3
      """,
      [pending.sessionKey, pending.pendingBranch, pending.pendingAssignment]
    )

    Txn.changes(txn) == 1
  end

  defp open_assignment(db, assignment_id) do
    {:ok, rows} =
      DB.query(db, "SELECT id, subject FROM assignments WHERE id = ?1 AND state = 'open'", [
        assignment_id
      ])

    case rows do
      [[id, subject]] -> %{id: id, subject: subject}
      [] -> nil
    end
  end

  defp doorbells_for_holder(db, session_key) do
    db
    |> Assignments.list(%{holder_key: session_key, state: "open"})
    |> Enum.each(&doorbell(db, &1.id))
  end

  defp doorbell(db, assignment_id) do
    stamped =
      transaction!(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO assignment_prods (assignmentId, strandedAt)
          VALUES (?1, ?2)
          ON CONFLICT(assignmentId) DO UPDATE SET strandedAt = excluded.strandedAt
          WHERE assignment_prods.strandedAt IS NULL
          """,
          [assignment_id, now()]
        )

        Txn.changes(txn) == 1
      end)

    if stamped, do: best_effort_lifecycle(db, "supervision_stranded", assignment_id, nil)
    :ok
  end

  defp notify_stranded_ancestor(state, session_key) do
    case Assignments.open_count(state.db, session_key) do
      0 ->
        :ok

      count ->
        target = ladder_target(state.db, session_key, 1)
        row_label = if count == 1, do: "row", else: "rows"

        prompt =
          "Session #{session_key} retired with #{count} open assignment #{row_label}. " <>
            "The work is stranded and requires your attention."

        Gateway.deliver_prompt(
          target,
          "process:tightbeam",
          prompt,
          [
            db: state.db,
            sender: "process:tightbeam",
            device_id: "process:tightbeam",
            client_message_id: "retired-strand:#{session_key}"
          ] ++ state.delivery_opts
        )
    end
  end

  defp sweep(state) do
    :ok =
      Adjudication.escalate_due(
        state.db,
        Application.get_env(:tightbeam, :adjudication_response_window_ms, 86_400_000)
      )

    open_holders =
      state.db
      |> Assignments.list(%{state: "open"})
      |> Enum.map(& &1.holderKey)

    {:ok, pending_rows} =
      DB.query(
        state.db,
        "SELECT sessionKey FROM supervision_watermarks WHERE pendingBranch IS NOT NULL"
      )

    pending_sessions = Enum.map(pending_rows, fn [session_key] -> session_key end)

    open_holders
    |> Kernel.++(pending_sessions)
    |> Enum.uniq()
    |> Enum.each(fn session_key ->
      safe_evaluate(state, session_key, fn ->
        evaluate(
          state.db,
          state.handlers,
          state.n,
          session_key,
          Ledger.last_terminal_seq(state.db, session_key)
        )
      end)
    end)
  rescue
    error ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        Exception.message(error)
      )
  catch
    kind, reason ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        "sweep",
        inspect({kind, reason})
      )
  end

  defp safe_evaluate(state, session_key, fun) do
    fun.()
  rescue
    error ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        session_key,
        Exception.message(error)
      )
  catch
    kind, reason ->
      best_effort_lifecycle(
        state.db,
        "supervision_evaluate_failed",
        session_key,
        inspect({kind, reason})
      )
  end

  defp best_effort_lifecycle(db, kind, subject, detail) do
    EventLog.lifecycle(db, kind, subject, detail)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp lineage(_db, nil, _visited, acc), do: Enum.reverse(acc)

  defp lineage(db, session_key, visited, acc) do
    if MapSet.member?(visited, session_key) do
      Enum.reverse(acc)
    else
      case query(db, "SELECT state, spawnedBy FROM sessions WHERE sessionKey = ?1", [session_key]) do
        [[state, spawned_by]] ->
          next_acc = if state == "active", do: [session_key | acc], else: acc
          lineage(db, spawned_by, MapSet.put(visited, session_key), next_acc)

        [] ->
          Enum.reverse(acc)
      end
    end
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp zero_state(assignment_id) do
    %{
      assignmentId: assignment_id,
      attemptCount: 0,
      prodCount: 0,
      deniedStreak: 0,
      attestCount: 0,
      lastProdAt: nil,
      stalledAt: nil,
      strandedAt: nil
    }
  end

  defp prod_prompt(id, subject, k, n) do
    "Your turn ended with no filing and no continuation scheduled for assignment #{id} — \"#{subject}\". " <>
      "File completion, schedule your continuation, or file surrender. This is prod #{k} of #{n}; " <>
      "a reply without a row escalates to your spawner."
  end

  defp escalation_prompt(id, subject, holder, n, rung) do
    "Assignment #{id} — \"#{subject}\" — held by #{holder} is stalled: #{n} prods produced no filing " <>
      "and no continuation. This is escalation #{rung} for this assignment. Why, and what happens next, " <>
      "is your judgment — the substrate only reports the rows."
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
