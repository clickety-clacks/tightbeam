defmodule Tightbeam.RowReactions.Cutover do
  @moduledoc false
  alias Tightbeam.{RowReactions, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.RowReactions.{Snapshot, Store}
  @source "terminal-notices/v1"
  @attest_source "assignment-attest-notices/v1"
  @root "terminal-child-owner-notification:"
  @reminder "terminal-child-owner-action-reminder:"

  def adopt(txn) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [@source]) do
      [[1]] ->
        :ok

      [] ->
        [[watermark]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid),0) FROM wakes")
        # One finite source population. Never replay old closes that had no
        # output, and never grow this population on later rule publication.
        ids =
          Txn.q(
            txn,
            """
            SELECT wakeId FROM wakes WHERE rowid<=?1 AND
              (obligationRef LIKE ?2 OR obligationRef LIKE ?3)
            ORDER BY CASE WHEN obligationRef LIKE ?2 THEN 0 ELSE 1 END,rowid
            """,
            [watermark, @root <> "%", @reminder <> "%"]
          )

        at = System.system_time(:millisecond)

        held =
          Enum.count(ids, fn [id] ->
            adopt_output(txn, Wakes.get_in_txn(txn, id), at) == "held"
          end)

        # Missing historical output is not evidence that a destination existed
        # at delivery. Mark consumed deliveries without manufacturing reminders.
        for [id] <- ids,
            event = RowReactions.delivery_event(txn, id),
            not is_nil(event),
            is_nil(Store.event(txn, event["org"], event["id"])) do
          Store.remember(txn, event, Snapshot.current(txn, event, %{}))
        end

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,?4)",
          [@source, JSON.encode!(%{"wakeRowid" => watermark}), at, held]
        )

        :ok
    end

    adopt_attest_notices(txn)
  end

  defp adopt_attest_notices(txn) do
    case Txn.q(txn, "SELECT 1 FROM row_reaction_cutovers WHERE source=?1", [@attest_source]) do
      [[1]] ->
        :ok

      [] ->
        [[watermark]] = Txn.q(txn, "SELECT COALESCE(MAX(rowid),0) FROM wakes")

        ids =
          Txn.q(
            txn,
            """
            SELECT wakeId FROM wakes WHERE rowid<=?1 AND consumer='prompt'
              AND assignmentId IS NOT NULL
              AND prompt LIKE 'Attest % was filed on assignment %.'
            ORDER BY rowid
            """,
            [watermark]
          )

        at = System.system_time(:millisecond)

        held =
          Enum.count(ids, fn [id] ->
            adopt_attest_notice(txn, Wakes.get_in_txn(txn, id), at) == "held"
          end)

        Txn.q(
          txn,
          "INSERT INTO row_reaction_cutovers(source,watermark,adoptedAt,heldCount) VALUES(?1,?2,?3,?4)",
          [@attest_source, JSON.encode!(%{"wakeRowid" => watermark}), at, held]
        )

        :ok
    end
  end

  defp adopt_attest_notice(_txn, nil, _at), do: "held"

  defp adopt_attest_notice(txn, wake, at) do
    case legacy_attest_source(txn, wake) do
      {:ok, event, facts} ->
        status = legacy_notice_status(txn, wake)
        plan = legacy_attest_plan(event, wake)

        result = %{
          "wake_id" => wake.wake_id,
          "intent_wake_id" => wake.wake_id,
          "adopted" => true,
          "requested_due_at" => wake.due_at,
          "delivery" => legacy_notice_delivery(txn, wake)
        }

        Store.adopt(txn, event, facts, plan, status, result, at)

        if status == "held" do
          Store.record(
            txn,
            %{"id" => Store.id(plan.identity)},
            "held",
            result,
            at,
            "historical attest notice source or delivery outcome is unproven"
          )
        end

        status

      {:unresolved, reason} ->
        adopt_unresolved_attest_notice(txn, wake, at, reason)
    end
  end

  defp legacy_attest_source(txn, wake) do
    with [attest_id, kind, assignment_id] <- legacy_attest_prompt(wake.prompt),
         true <- wake.assignment_id == assignment_id,
         attest when is_map(attest) <- Snapshot.attest(txn, attest_id),
         true <- attest["assignmentId"] == assignment_id,
         true <- attest["kind"] == kind,
         assignment when is_map(assignment) <- Snapshot.assignment(txn, assignment_id),
         true <- assignment["workItemId"] == wake.work_item_id,
         context <- Snapshot.assignment_context(txn, assignment_id),
         true <- context.owner_user_id == wake.owner_user_id,
         true <- wake.creator_session_key == attest["bySession"],
         {:ok, principal} <- legacy_attest_principal(attest, wake.origin) do
      event = RowReactions.attest_event(txn, attest, principal, wake.owner_user_id)
      {:ok, event, Snapshot.current(txn, event, %{})}
    else
      false -> {:unresolved, "historical attest notice does not match its source rows"}
      nil -> {:unresolved, "historical attest notice source row is missing"}
      _ -> {:unresolved, "historical attest notice prompt or principal is ambiguous"}
    end
  end

  defp legacy_attest_prompt(prompt) when is_binary(prompt) do
    case Regex.run(
           ~r/\AAttest ([^\s]+) \(([^()\r\n]+)\) was filed on assignment ([^\s]+)\.\z/u,
           prompt,
           capture: :all_but_first
         ) do
      [attest_id, kind, assignment_id] -> [attest_id, kind, assignment_id]
      _ -> nil
    end
  end

  defp legacy_attest_prompt(_prompt), do: nil

  defp legacy_attest_principal(%{"bySession" => session}, "agent:" <> session),
    do: {:ok, {:session, session}}

  defp legacy_attest_principal(%{"byUser" => user}, "user:" <> user),
    do: {:ok, {:user, user}}

  defp legacy_attest_principal(%{"bySession" => nil, "byUser" => nil}, "process:" <> name),
    do: {:ok, {:process, name}}

  defp legacy_attest_principal(_attest, _origin), do: {:error, :ambiguous_principal}

  defp legacy_attest_plan(event, wake) do
    %{
      identity: [event["org"], "r01-attest-notice", event["id"], "notice"],
      family: "r01-attest-notice",
      slot: "notice",
      source_event_id: event["id"],
      rule: "r01-attest-notice",
      provenance: %{"source" => @attest_source, "historical" => true},
      kind: "notice",
      selected: true,
      value: %{
        "wake_id" => wake.wake_id,
        "session_key" => wake.session_key,
        "owner_user_id" => wake.owner_user_id,
        "origin" => wake.origin,
        "creator_session_key" => wake.creator_session_key,
        "assignment_id" => wake.assignment_id,
        "work_item_id" => wake.work_item_id,
        "prompt" => wake.prompt,
        "due_at" => wake.due_at,
        "on_unavailable" => "schedule"
      }
    }
  end

  defp legacy_notice_status(txn, wake) do
    cond do
      is_integer(wake.delivered_turn_seq) -> "accepted"
      Wakes.undelivered_notice_in_txn?(txn, wake.wake_id) -> "pending"
      wake.state == "pending" -> "pending"
      wake.state == "canceled" -> "canceled"
      true -> "held"
    end
  end

  defp legacy_notice_delivery(txn, wake) do
    cond do
      is_integer(wake.delivered_turn_seq) -> "delivered"
      Wakes.undelivered_notice_in_txn?(txn, wake.wake_id) -> "undelivered"
      true -> wake.state
    end
  end

  defp adopt_unresolved_attest_notice(txn, wake, at, reason) do
    event = %{
      "id" => "legacy-attest-unresolved:" <> wake.wake_id,
      "org" => wake.owner_user_id,
      "kind" => "legacy_unresolved",
      "at" => wake.created_at,
      "historical" => true,
      "source" => %{"kind" => "wake", "id" => wake.wake_id}
    }

    plan =
      legacy_attest_plan(event, wake)
      |> Map.merge(%{
        identity: [event["org"], "r01-attest-notice", event["id"], "notice"],
        source_event_id: event["id"]
      })

    result = %{
      "wake_id" => wake.wake_id,
      "intent_wake_id" => wake.wake_id,
      "adopted" => true,
      "requested_due_at" => wake.due_at,
      "delivery" => legacy_notice_delivery(txn, wake)
    }

    Store.adopt(txn, event, %{}, plan, "held", result, at)
    Store.record(txn, %{"id" => Store.id(plan.identity)}, "held", result, at, reason)
    "held"
  end

  defp adopt_output(txn, wake, at) do
    {event, family, slot} =
      case wake.obligation_ref do
        @root <> _ -> {terminal_event(txn, wake), "terminal-handoff", "handoff"}
        @reminder <> root -> {reminder_event(txn, wake, root), "terminal-action", "reminder"}
      end

    unresolved = is_nil(event)

    event =
      event ||
        %{
          "id" => "legacy-unresolved:" <> wake.wake_id,
          "org" => wake.owner_user_id,
          "kind" => "legacy_unresolved",
          "at" => wake.created_at,
          "historical" => true,
          "source" => %{"kind" => "wake", "id" => wake.wake_id}
        }

    incomplete = not unresolved and Wakes.undelivered_notice_in_txn?(txn, wake.wake_id)

    status =
      cond do
        incomplete -> "pending"
        wake.state == "canceled" -> "canceled"
        is_integer(wake.delivered_turn_seq) -> "accepted"
        unresolved -> "held"
        wake.state == "pending" -> "pending"
        true -> "held"
      end

    facts = if unresolved, do: %{}, else: Snapshot.current(txn, event, %{})

    value =
      Map.new(
        ~w(wake_id session_key origin owner_user_id creator_session_key assignment_id work_item_id prompt due_at obligation_ref)a,
        fn key -> {Atom.to_string(key), Map.get(wake, key)} end
      )

    plan = %{
      identity: [event["org"], family, event["id"], slot],
      family: family,
      slot: slot,
      source_event_id: event["id"],
      kind: "notice",
      value: value,
      provenance: %{"source" => @source, "historical" => true}
    }

    result = %{
      "wake_id" => wake.wake_id,
      "adopted" => true,
      "requested_due_at" => wake.due_at,
      "delivery" =>
        cond do
          incomplete -> "undelivered"
          is_integer(wake.delivered_turn_seq) -> "delivered"
          true -> wake.state
        end
    }

    Store.adopt(txn, event, facts, plan, status, result, at)

    if status == "held" do
      Store.record(
        txn,
        %{"id" => Store.id(plan.identity)},
        "held",
        result,
        at,
        "historical source or actual delivery outcome is unproven"
      )
    end

    status
  end

  defp terminal_event(txn, wake) do
    case Wakes.terminal_source_in_txn(txn, wake.wake_id) do
      {:ok, terminal} ->
        after_row =
          Snapshot.assignment(txn, terminal.assignment_id)
          |> Map.merge(%{
            "state" => "closed",
            "outcome" => terminal.outcome,
            "closedAt" => terminal.terminal_at
          })

        %{
          "id" => "legacy-notice:" <> wake.wake_id,
          "org" => terminal.owner_user_id,
          "kind" => "assignment",
          "at" => terminal.terminal_at,
          "historical" => true,
          "source" => %{"kind" => terminal.source_kind, "id" => terminal.source_token},
          "generation" => terminal.source_token,
          "terminal" => stringify(terminal),
          "before" => nil,
          "after" => after_row,
          "principal" => %{"kind" => "process", "id" => "tightbeam"}
        }

      _ ->
        nil
    end
  end

  defp reminder_event(txn, wake, root) do
    predecessors = [
      root
      | Txn.q(txn, "SELECT wakeId FROM wakes WHERE obligationRef=?1", [@reminder <> root])
        |> List.flatten()
    ]

    Enum.find_value(predecessors, fn id ->
      predecessor = if id == root, do: "initial", else: id

      digest =
        :crypto.hash(
          :sha256,
          JSON.encode!(["terminal-child-owner-action-reminder", root, predecessor])
        )
        |> Base.encode16(case: :lower)

      if wake.wake_id == "w_terminal_action_" <> digest, do: RowReactions.delivery_event(txn, id)
    end)
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
