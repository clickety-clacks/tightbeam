defmodule Tightbeam.RowReactions do
  @moduledoc false
  alias Tightbeam.RowReactions.{
    Store,
    Notice,
    Snapshot,
    AttestNoticeCutover,
    TerminalNoticeCutover
  }

  alias Tightbeam.{DB, Rules}
  alias Tightbeam.DB.Txn

  # Schema readiness is connection-local and re-established on every boot.
  # It is runtime lifecycle state, never a policy election or fallback.
  def activate(db) do
    case DB.transaction(db, fn txn ->
           Process.put({__MODULE__, txn.conn}, true)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def recover(db) do
    if GenServer.whereis(db), do: recover_running(db), else: :ok
  end

  defp recover_running(db) do
    case DB.transaction(db, &recover_if_ready_in_txn/1) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  def recover_if_ready_in_txn(txn) do
    if Process.get({__MODULE__, txn.conn}, false), do: recover_in_txn(txn)
    :ok
  end

  def adopt_if_ready_in_txn(txn) do
    if Process.get({__MODULE__, txn.conn}, false) do
      at = System.system_time(:millisecond)
      AttestNoticeCutover.adopt_in_txn(txn, at)
      TerminalNoticeCutover.adopt_in_txn(txn, at)
    end

    :ok
  end

  def notice_owned_in_txn?(txn, wake_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1 LIMIT 1",
      [wake_id]
    ) != []
  end

  def recover_in_txn(txn) do
    at = System.system_time(:millisecond)
    AttestNoticeCutover.adopt_in_txn(txn, at)
    TerminalNoticeCutover.adopt_in_txn(txn, at)

    for [org, event_id, event_json, facts_json] <-
          Txn.q(txn, """
          SELECT e.org,e.eventId,e.event,e.facts FROM
            (SELECT DISTINCT org,eventId FROM row_reaction_actions WHERE status='pending') p
          JOIN row_reaction_events e ON e.org=p.org AND e.eventId=p.eventId
          ORDER BY e.admittedAt,e.eventId
          """) do
      :ok = Txn.exec(txn, "SAVEPOINT reaction_pending_recovery")

      try do
        event = JSON.decode!(event_json)
        facts = Snapshot.current(txn, event, JSON.decode!(facts_json))
        reconcile_in_txn(txn, org, event_id, facts, Rules.reactions(), at)
        :ok = Txn.exec(txn, "RELEASE reaction_pending_recovery")
      rescue
        error ->
          :ok = Txn.exec(txn, "ROLLBACK TO reaction_pending_recovery")
          :ok = Txn.exec(txn, "RELEASE reaction_pending_recovery")

          for action <- Store.actions_in_txn(txn, org, event_id), action["status"] == "pending" do
            Store.failure_in_txn(txn, action["id"], Exception.message(error), at)
          end
      end
    end

    :ok
  end

  def observe_in_txn(txn, event) do
    facts = Snapshot.current(txn, event, %{})
    admit_in_txn(txn, event, facts, Rules.reactions(), event["at"])
  end

  def observe_turn_in_txn(txn, transition, opts) do
    if Process.get({__MODULE__, txn.conn}, false) do
      before = Map.fetch!(transition, :reaction_before)
      after_row = Snapshot.turn(txn, transition.row_id)
      at = Keyword.get(opts, :at, Map.fetch!(after_row, "endedAt"))
      principal = Keyword.get(opts, :principal, "process:tightbeam")
      [kind, id] = String.split(principal, ":", parts: 2)

      observe_in_txn(txn, %{
        "id" => "turn:#{transition.row_id}:status:#{after_row["status"]}",
        "org" => transition.owner_user_id,
        "kind" => "turn",
        "at" => at,
        "principal" => %{"kind" => kind, "id" => id},
        "before" => before,
        "after" => after_row
      })
    end

    :ok
  end

  # Source owners call these only after their actual successful write, with the
  # before row captured in the same transaction. Reading an old row is not an
  # observation and must instead use the explicit historical adoption seam.
  def observe_assignment_in_txn(txn, before, source, principal, at) do
    if Process.get({__MODULE__, txn.conn}, false) do
      TerminalNoticeCutover.adopt_in_txn(txn, at)

      case Tightbeam.Wakes.terminal_source_in_txn(txn, before["id"], source) do
        {:ok, _} ->
          :ok

        {:error, refusal} ->
          raise Tightbeam.Assignments.TerminalNotificationRefused,
            code: refusal.code,
            message: refusal.message
      end

      row = Snapshot.assignment_row(txn, before["id"])

      [[owner]] =
        Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [row["holderKey"]])

      [kind, id] = String.split(principal, ":", parts: 2)

      observe_in_txn(txn, %{
        "id" => "assignment:#{row["id"]}:closed:#{source["kind"]}:#{source["id"]}",
        "org" => owner,
        "kind" => "assignment",
        "at" => at,
        "principal" => %{"kind" => kind, "id" => id},
        "before" => before,
        "after" => row,
        "source" => source
      })

      recover_in_txn(txn)
    end

    :ok
  end

  def observe_wake_delivery_in_txn(txn, before, delivery, principal, at) do
    if Process.get({__MODULE__, txn.conn}, false) do
      row = Snapshot.wake(txn, before["wakeId"])
      [kind, id] = String.split(principal, ":", parts: 2)
      # Historical sources may predate wake ownership. The delivery's actual
      # recipient establishes this event's organization; source rows stay raw.
      [[owner]] =
        Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [
          delivery["sessionKey"]
        ])

      observe_in_txn(txn, %{
        "id" => "wake_delivery:#{row["wakeId"]}:turn:#{delivery["turnSeq"]}",
        "org" => owner,
        "kind" => "wake_delivery",
        "at" => at,
        "principal" => %{"kind" => kind, "id" => id},
        "before" => before,
        "after" => row,
        "delivery" => delivery
      })
    end

    :ok
  end

  def observe_request_in_txn(txn, before, after_row, principal, verb, at, outputs \\ []) do
    if Process.get({__MODULE__, txn.conn}, false) do
      [kind, id] = String.split(principal, ":", parts: 2)
      row = Snapshot.request_row(after_row)

      # Outputs are the command's actual returned wake identities, recorded in
      # the same transaction. Eligibility and same-recipient suppression belong
      # to the elected rail, never to this source adapter.
      observe_in_txn(txn, %{
        "id" => "decision_request:#{row["id"]}:status:#{row["status"]}",
        "org" => row["ownerUserId"],
        "kind" => "decision_request",
        "at" => at,
        "verb" => verb,
        "principal" => %{"kind" => kind, "id" => id},
        "before" => Snapshot.request_row(before),
        "after" => row,
        "outputs" => Enum.map(outputs, &%{"wakeId" => &1.wake_id, "operation" => verb})
      })
    end

    :ok
  end

  def observe_attest_result_in_txn(_txn, %{replayed: true}), do: :ok

  def observe_attest_result_in_txn(txn, %{attest: attest}) do
    if Process.get({__MODULE__, txn.conn}, false) do
      AttestNoticeCutover.adopt_in_txn(txn, attest.ts)
      observe_in_txn(txn, Snapshot.attest_event(txn, attest.id))
      recover_in_txn(txn)
    end

    :ok
  end

  def observe_attest_result_in_txn(_txn, _result), do: :ok

  # Reconcile only the event that owns this output. A failure rolls back this
  # output's preparation, without blocking unrelated notices in the due batch.
  def prepare_notice_in_txn(txn, wake_id) when is_binary(wake_id) do
    owners =
      Txn.q(
        txn,
        """
        SELECT DISTINCT e.org,e.eventId,e.event,e.facts
        FROM row_reaction_actions a JOIN row_reaction_events e
          ON e.org=a.org AND e.eventId=a.eventId
        WHERE json_extract(a.result,'$.wake_id')=?1
        """,
        [wake_id]
      )

    if owners == [] do
      :ordinary
    else
      at = System.system_time(:millisecond)

      Enum.each(owners, fn [org, id, bytes, facts] ->
        event = JSON.decode!(bytes)

        reconcile_in_txn(
          txn,
          org,
          id,
          Snapshot.current(txn, event, JSON.decode!(facts)),
          Rules.reactions(),
          at
        )
      end)

      case Tightbeam.Wakes.get_in_txn(txn, wake_id) do
        %{state: "pending"} = wake ->
          if delivery_ready_in_txn?(txn, wake_id) and
               (wake.due_at <= at or not is_nil(wake.fired_at) or not is_nil(wake.recognition_at)),
             do: {:notice, wake},
             else: :skipped

        %{state: "canceled"} ->
          case Tightbeam.Wakes.notice_undeliverable_evidence_in_txn(txn, wake_id) do
            nil -> :skipped
            evidence -> {:undelivered, evidence}
          end

        _ ->
          :skipped
      end
    end
  end

  def prepare_notice_in_txn(_txn, _wake_id), do: :ordinary

  def delivery_ready_in_txn?(txn, wake_id) do
    Txn.q(
      txn,
      "SELECT 1 FROM row_reaction_actions WHERE status='held' AND json_extract(result,'$.wake_id')=?1 LIMIT 1",
      [wake_id]
    ) == []
  end

  def admit_in_txn(txn, event, facts, rails, at) do
    Store.admit_in_txn(txn, event, Map.put(facts, "reaction_actions", []), rails, at)
    |> Enum.each(&execute_in_txn(txn, &1, at))

    Store.actions_in_txn(txn, event["org"], event["id"])
  end

  def reconcile_in_txn(txn, org, event_id, facts, rails, at) do
    Store.actions_in_txn(txn, org, event_id)
    |> Enum.each(&Notice.synchronize_in_txn(txn, &1, at))

    facts = Map.put(facts, "reaction_actions", action_facts(txn, org, event_id))

    Store.reconcile_in_txn(txn, org, event_id, rails, at, facts)
    |> Enum.each(&execute_in_txn(txn, &1, at))

    Store.actions_in_txn(txn, org, event_id)
  end

  defp action_facts(txn, org, event_id) do
    Store.actions_in_txn(txn, org, event_id)
    |> Enum.map(fn action ->
      [_org, family, _event, slot] = action["plan"]["identity"]
      Map.take(action, ~w(id status result)) |> Map.merge(%{"family" => family, "slot" => slot})
    end)
  end

  defp execute_in_txn(txn, %{"plan" => %{"kind" => "notice"}} = action, at),
    do: Notice.execute_in_txn(txn, action, at)

  defp execute_in_txn(_txn, action, _at),
    do:
      raise(ArgumentError, "reaction executor unavailable for #{inspect(action["plan"]["kind"])}")
end
