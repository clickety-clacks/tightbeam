defmodule Tightbeam.Retirements do
  @moduledoc "Durable, owner-held follow-through for stopped retirements."
  alias Tightbeam.{DB, Org, Wakes}
  alias Tightbeam.DB.Txn

  # The scheduler's existing no-deadline sentinel. Work blockers release this
  # wake from their mutation seams; no timer scans unfinished retirements.
  @no_deadline 253_402_300_799_000

  @objects [
    {"table", "unfinished_retirements",
     """
     CREATE TABLE unfinished_retirements (
       id TEXT PRIMARY KEY,
       targetSessionKey TEXT NOT NULL,
       ownerSessionKey TEXT NOT NULL,
       principalRef TEXT NOT NULL,
       keepOpenDescendants INTEGER NOT NULL CHECK(keepOpenDescendants IN (0,1)),
       blockerKind TEXT NOT NULL CHECK(blockerKind IN ('work','lease')),
       hardDeadline INTEGER,
       wakeId TEXT NOT NULL,
       state TEXT NOT NULL CHECK(state IN ('open','retired','withdrawn','superseded')),
       createdAt INTEGER NOT NULL,
       closedAt INTEGER,
       supersededBy TEXT,
       withdrawalReason TEXT,
       withdrawnBy TEXT
     )
     """},
    {"index", "unfinished_retirements_open_pair",
     "CREATE UNIQUE INDEX unfinished_retirements_open_pair ON unfinished_retirements(targetSessionKey,ownerSessionKey) WHERE state='open'"},
    {"index", "unfinished_retirements_owner",
     "CREATE INDEX unfinished_retirements_owner ON unfinished_retirements(ownerSessionKey) WHERE state='open'"},
    {"table", "retirement_blockers",
     """
     CREATE TABLE retirement_blockers (
       retirementId TEXT NOT NULL REFERENCES unfinished_retirements(id),
       kind TEXT NOT NULL CHECK(kind IN ('assignment','role')),
       reference TEXT NOT NULL,
       sessionKey TEXT NOT NULL,
       PRIMARY KEY(retirementId,kind,reference)
     )
     """},
    {"index", "retirement_blockers_reference",
     "CREATE INDEX retirement_blockers_reference ON retirement_blockers(kind,reference,retirementId)"},
    {"table", "retirement_owner_transfers",
     """
     CREATE TABLE retirement_owner_transfers (
       id INTEGER PRIMARY KEY,
       retirementId TEXT NOT NULL REFERENCES unfinished_retirements(id),
       formerOwnerSessionKey TEXT NOT NULL,
       newOwnerSessionKey TEXT NOT NULL,
       successorId TEXT NOT NULL REFERENCES unfinished_retirements(id),
       handoffWakeId TEXT,
       createdAt INTEGER NOT NULL
     )
     """}
  ]

  def ensure_schema(db) do
    case DB.transaction(db, fn txn ->
           Enum.each(@objects, fn {type, name, sql} ->
             case Txn.q(txn, "SELECT sql FROM sqlite_master WHERE type=?1 AND name=?2", [
                    type,
                    name
                  ]) do
               [] ->
                 Txn.exec(txn, sql)

               [[actual]] ->
                 unless normalize(actual) == normalize(sql),
                   do:
                     raise(Tightbeam.Schema.ShapeError,
                       message: "malformed retirement schema: #{name}"
                     )
             end
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> raise error
    end
  end

  defp normalize(sql), do: sql |> String.trim() |> String.replace(~r/\s+/, " ")

  def stopped_in_txn(txn, target, principal, keep, parent, blocker) do
    owner =
      case principal do
        {:session, key} -> key
        _ -> parent.session_key
      end

    id = "rti_" <> Tightbeam.Id.uuid4()
    Enum.each(open_pair(txn, target, owner), &close(txn, &1, "superseded", id))
    deadline = blocker[:hard_deadline]

    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key: owner,
        origin: "retirement:" <> id,
        prompt: prompt(target, keep),
        due_at: deadline || @no_deadline
      })

    Txn.q(
      txn,
      """
      INSERT INTO unfinished_retirements
        (id,targetSessionKey,ownerSessionKey,principalRef,keepOpenDescendants,
         blockerKind,hardDeadline,wakeId,state,createdAt)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'open',?9)
      """,
      [
        id,
        target,
        owner,
        principal_ref(principal),
        if(keep, do: 1, else: 0),
        if(deadline, do: "lease", else: "work"),
        deadline,
        wake.wake_id,
        now()
      ]
    )

    for descendant <- Map.get(blocker, :protected_descendants, []) do
      for assignment <- descendant.assignments do
        blocker_row(txn, id, "assignment", assignment.assignment_id, descendant.session_key)
      end

      for role <- descendant.roles, do: blocker_row(txn, id, "role", role, descendant.session_key)
    end

    Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)
    %{id: id, owner: session_details(txn, owner)}
  end

  defp blocker_row(txn, id, kind, reference, session) do
    Txn.q(txn, "INSERT INTO retirement_blockers VALUES(?1,?2,?3,?4)", [
      id,
      kind,
      reference,
      session
    ])
  end

  # Called only when the particular recorded assignment or role changes.
  def blocker_changed_in_txn(txn, kind, reference) do
    Txn.q(
      txn,
      """
      SELECT DISTINCT r.id,r.wakeId FROM retirement_blockers b
      JOIN unfinished_retirements r ON r.id=b.retirementId
      JOIN wakes w ON w.wakeId=r.wakeId
      WHERE b.kind=?1 AND b.reference=?2 AND r.state='open'
        AND w.state='pending' AND w.dueAt=?3
      """,
      [kind, reference, @no_deadline]
    )
    |> Enum.each(fn [id, wake] ->
      if blockers_clear?(txn, id) do
        at = now()
        Txn.q(txn, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1 AND state='pending'", [wake, at])
        Wakes.schedule_changed_in_txn(txn, {:schedule_changed, at})
      end
    end)

    :ok
  end

  defp blockers_clear?(txn, id) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM retirement_blockers b WHERE b.retirementId=?1 AND (
        (b.kind='assignment' AND EXISTS (
          SELECT 1 FROM assignments a WHERE a.id=b.reference AND a.state='open'
        )) OR (b.kind='role' AND EXISTS (
          SELECT 1 FROM roles r JOIN sessions s ON s.sessionKey=r.boundSessionKey
          WHERE r.name=b.reference AND r.boundSessionKey=b.sessionKey AND s.state='active'
        ))
      ) LIMIT 1
      """,
      [id]
    ) == []
  end

  def session_retired_in_txn(txn, key) do
    Txn.q(txn, "SELECT name FROM roles WHERE boundSessionKey=?1", [key])
    |> Enum.each(fn [role] -> blocker_changed_in_txn(txn, "role", role) end)
  end

  # The whole retiring set must be known before moving ownership: an ancestor
  # that is about to retire cannot accept a descendant's unfinished duty.
  def retiring_in_txn(txn, keys) do
    retiring = MapSet.new(keys)

    Enum.each(keys, fn key ->
      Txn.q(
        txn,
        "SELECT id FROM unfinished_retirements WHERE targetSessionKey=?1 AND state='open'",
        [key]
      )
      |> Enum.each(fn [id] -> close(txn, id, "retired", nil) end)
    end)

    Enum.each(keys, fn owner ->
      rows =
        Txn.q(
          txn,
          """
          SELECT id,targetSessionKey,keepOpenDescendants,wakeId FROM unfinished_retirements
          WHERE ownerSessionKey=?1 AND state='open' ORDER BY createdAt,id
          """,
          [owner]
        )

      if rows != [] do
        replacement = accountable_parent_in_txn(txn, owner, retiring)

        Enum.each(rows, fn [id, target, keep, wake_id] ->
          wake = Wakes.get_in_txn(txn, wake_id)
          delivered = wake.state == "fired" or is_integer(wake.delivered_turn_seq)
          existing = open_pair(txn, target, replacement)
          successor = List.first(existing) || id

          if existing == [] do
            Txn.q(txn, "UPDATE unfinished_retirements SET ownerSessionKey=?2 WHERE id=?1", [
              id,
              replacement
            ])

            if not delivered do
              {:ok, _} = Wakes.readdress_pending_in_txn(txn, wake_id, replacement)
            end
          else
            close(txn, id, "superseded", successor)
          end

          handoff =
            if delivered do
              former = session_details(txn, owner)

              Wakes.schedule_in_txn(txn, %{
                session_key: replacement,
                origin: "retirement:" <> successor,
                prompt:
                  prompt(target, keep == 1) <> " Former owner: #{former.display_name} (#{owner}).",
                due_at: now()
              }).wake_id
            end

          if handoff, do: Wakes.publish_change_in_txn(txn, "wake.scheduled", handoff)

          if handoff && existing == [] do
            Txn.q(txn, "UPDATE unfinished_retirements SET wakeId=?2 WHERE id=?1", [id, handoff])
          end

          Txn.q(
            txn,
            """
            INSERT INTO retirement_owner_transfers
              (retirementId,formerOwnerSessionKey,newOwnerSessionKey,successorId,handoffWakeId,createdAt)
            VALUES(?1,?2,?3,?4,?5,?6)
            """,
            [id, owner, replacement, successor, handoff, now()]
          )

          # Any still-queued handoffs from earlier transfers travel with the duty.
          Txn.q(
            txn,
            "SELECT handoffWakeId FROM retirement_owner_transfers WHERE successorId=?1 AND handoffWakeId IS NOT NULL",
            [id]
          )
          |> Enum.each(fn [previous] ->
            case Wakes.get_in_txn(txn, previous) do
              %{state: "pending", delivered_turn_seq: nil} ->
                if existing == [], do: Wakes.readdress_pending_in_txn(txn, previous, replacement)

              _ ->
                :ok
            end
          end)
        end)
      end
    end)

    :ok
  end

  def accountable_parent_in_txn(txn, key, excluded \\ MapSet.new()) do
    session = Org.get_in_txn(txn, key)

    nearest_parent(txn, current_parent(txn, key), excluded) ||
      Org.personal_session_key(session.owner_user_id)
  end

  defp current_parent(txn, key) do
    case Txn.q(
           txn,
           "SELECT #{Org.current_parent_sql("s")} FROM sessions s WHERE s.sessionKey=?1",
           [key]
         ) do
      [[parent]] -> parent
      [] -> nil
    end
  end

  defp nearest_parent(_txn, nil, _excluded), do: nil

  defp nearest_parent(txn, key, excluded) do
    case Org.get_in_txn(txn, key) do
      %{state: "active"} ->
        if MapSet.member?(excluded, key),
          do: nearest_parent(txn, current_parent(txn, key), excluded),
          else: key

      nil ->
        nil

      _ ->
        nearest_parent(txn, current_parent(txn, key), excluded)
    end
  end

  def withdraw_in_txn(txn, target, principal, reason) do
    if not is_binary(reason) or String.trim(reason) == "" do
      %{code: "invalid", message: "retire-withdraw requires a nonempty reason"}
    else
      owner =
        case principal do
          {:session, key} -> key
          _ -> accountable_parent_in_txn(txn, target)
        end

      case open_pair(txn, target, owner) do
        [id] ->
          close(txn, id, "withdrawn", nil)

          Txn.q(
            txn,
            "UPDATE unfinished_retirements SET withdrawalReason=?2,withdrawnBy=?3 WHERE id=?1",
            [id, reason, principal_ref(principal)]
          )

          %{
            unfinished_retirement: %{id: id, owner: session_details(txn, owner)},
            state: "withdrawn",
            reason: reason
          }

        [] ->
          %{code: "not_found", message: "no open retirement owned by caller for this target"}
      end
    end
  end

  defp open_pair(txn, target, owner) do
    Txn.q(
      txn,
      "SELECT id FROM unfinished_retirements WHERE targetSessionKey=?1 AND ownerSessionKey=?2 AND state='open'",
      [target, owner]
    )
    |> List.flatten()
  end

  defp close(txn, id, state, successor) do
    Txn.q(
      txn,
      "UPDATE unfinished_retirements SET state=?2,closedAt=?3,supersededBy=?4 WHERE id=?1 AND state='open'",
      [id, state, now(), successor]
    )

    Txn.q(
      txn,
      """
      SELECT wakeId FROM unfinished_retirements WHERE id=?1
      UNION SELECT handoffWakeId FROM retirement_owner_transfers WHERE successorId=?1 AND handoffWakeId IS NOT NULL
      """,
      [id]
    )
    |> Enum.each(fn [wake] ->
      if match?(%{state: "pending"}, Wakes.get_in_txn(txn, wake)) do
        true =
          Wakes.cancel_in_txn(txn, %{
            wake_id: wake,
            requester: %{kind: "process", id: "tightbeam:retirement"},
            reason_kind: "obligation_disposed",
            causal_source: %{kind: "retirement_transition", id: id},
            outcome: %{
              kind: "disposition",
              disposition_kind: "retirement_transition",
              disposition_id: id
            }
          })
      end
    end)
  end

  defp prompt(target, keep) do
    disposition = if keep, do: "--keep-open-descendants", else: "no keep disposition"

    "The recorded retirement blocker has cleared for #{target}. " <>
      "Originally requested: #{disposition}. Retry retirement against its current state, " <>
      "or withdraw with retire-withdraw --session #{target} --reason <reason>."
  end

  defp session_details(txn, key) do
    session = Org.get_in_txn(txn, key)
    %{session_key: key, display_name: session.display_name}
  end

  defp principal_ref({kind, id}), do: Atom.to_string(kind) <> ":" <> id
  defp now, do: System.system_time(:millisecond)
end
