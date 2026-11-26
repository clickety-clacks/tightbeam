defmodule Tightbeam.PeopleMessages do
  @moduledoc "Durable conversations with people and their independent delivery relay."

  alias Tightbeam.{DB, Escalation, Id, Org, Wakes}
  alias Tightbeam.DB.Txn

  @mutations ~w(send update reply withdraw)
  @relay_commands ~w(collect report event)
  @availability_refusals ~w(no_recipients decider_unreachable)
  @event_kinds ~w(chat answer seen reminder_not_seen reminder_not_acted joined left unreachable closed)

  def ensure_schema(db) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.exec(txn, """
        CREATE TABLE IF NOT EXISTS people_conversations (
          id TEXT PRIMARY KEY,
          sender TEXT NOT NULL,
          holder TEXT,
          revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          message TEXT NOT NULL,
          relay TEXT,
          server TEXT,
          remote TEXT,
          answered INTEGER NOT NULL DEFAULT 0,
          UNIQUE (relay, server, remote)
        );
        CREATE INDEX IF NOT EXISTS people_conversations_holder ON people_conversations(holder);
        CREATE TABLE IF NOT EXISTS people_operations (
          seq INTEGER PRIMARY KEY,
          id TEXT NOT NULL UNIQUE,
          conversation TEXT NOT NULL REFERENCES people_conversations(id),
          actor TEXT NOT NULL,
          retryKey TEXT,
          request TEXT NOT NULL,
          record TEXT NOT NULL,
          report TEXT,
          wakeId TEXT,
          UNIQUE (actor, retryKey)
        );
        CREATE INDEX IF NOT EXISTS people_operations_waiting ON people_operations(conversation, seq)
          WHERE report IS NULL;
        CREATE INDEX IF NOT EXISTS people_operations_wake ON people_operations(wakeId) WHERE wakeId IS NOT NULL;
        CREATE TABLE IF NOT EXISTS people_events (
          conversation TEXT NOT NULL REFERENCES people_conversations(id),
          kind TEXT NOT NULL,
          event TEXT NOT NULL,
          payload TEXT NOT NULL,
          wakeId TEXT,
          PRIMARY KEY (conversation, kind, event)
        );
        CREATE INDEX IF NOT EXISTS people_events_wake ON people_events(wakeId) WHERE wakeId IS NOT NULL;
        """)
      end)

    :ok
  end

  def dispatch(
        db,
        %{
          verb: "people-" <> command,
          principal: {:session, session},
          transport_session_key: session,
          params: params
        },
        relay
      )
      when is_map(params) do
    cond do
      command in @relay_commands and session != relay ->
        error("forbidden", "people-message relay permission required")

      true ->
        {:ok, result} =
          DB.transaction(db, fn txn ->
            case command do
              "collect" ->
                collect(txn, params)

              "report" ->
                report(txn, session, params)

              "event" ->
                receive_event(txn, session, params)

              "status" ->
                status(txn, session, params)

              mutation when mutation in @mutations ->
                mutate(txn, mutation, session, params, relay)
            end
          end)

        result
    end
  end

  def dispatch(_db, _call, _relay), do: error("forbidden", "authenticated session required")

  defp mutate(txn, kind, session, params, relay) do
    key = params["key"]
    request = %{"kind" => kind, "params" => params}

    case if(is_binary(key),
           do:
             Txn.q(
               txn,
               "SELECT request, record FROM people_operations WHERE actor=?1 AND retryKey=?2",
               [session, key]
             ),
           else: []
         ) do
      [[saved, record]] ->
        if JSON.decode!(saved) == request,
          do: %{"record" => JSON.decode!(record), "relay_configured" => present?(relay)},
          else: error("conflict", "retry key already used")

      [] ->
        with :ok <- check(is_nil(key) or present?(key), "key must be nonblank"),
             {:ok, message} <- prepare(txn, kind, session, params) do
          %{
            "record" => append(txn, kind, session, key, request, message),
            "relay_configured" => present?(relay)
          }
        end
    end
  end

  defp prepare(txn, "send", sender, params) do
    work = params["work_item_id"]
    rule = params["answer_rule"]
    choices = params["choices"] || []
    decision = params["decision_request_id"]

    with :ok <- check(present?(work), "work_item_id required"),
         [[owner]] <- Txn.q(txn, "SELECT ownerUserId FROM work_items WHERE id=?1", [work]),
         addresses <- default_addresses(params["addresses"], owner),
         :ok <-
           check(
             is_list(addresses) and addresses != [] and Enum.all?(addresses, &present?/1) and
               Enum.uniq(addresses) == addresses,
             "addresses must be distinct nonblank strings"
           ),
         :ok <- validate_content(params["title"], params["body"], choices),
         :ok <-
           check(
             is_nil(params["organization"]) or present?(params["organization"]),
             "organization must be nonblank"
           ),
         :ok <- validate_rule(txn, sender, work, decision, rule, choices) do
      id = Id.uuid4()

      message = %{
        "conversation_id" => id,
        "sender_session" => sender,
        "addresses" => addresses,
        "title" => params["title"],
        "body" => params["body"],
        "choices" => choices,
        "answer_rule" => rule,
        "revision" => 1,
        "work_item_id" => work,
        "address" => nil,
        "organization" => params["organization"],
        "decision_request_id" => decision
      }

      Txn.q(
        txn,
        """
        INSERT INTO people_conversations(id,sender,holder,revision,state,message)
        VALUES(?1,?2,?2,1,'open',?3)
        """,
        [id, sender, JSON.encode!(message)]
      )

      {:ok, message}
    else
      [] -> error("not_found", "work item not found")
      failure -> failure
    end
  end

  defp prepare(txn, kind, session, params) do
    with {:ok, conversation} <- conversation(txn, params["conversation_id"]),
         :ok <- check(conversation.state == "open", "conversation is closed"),
         :ok <-
           check(
             session == if(kind == "reply", do: conversation.holder, else: conversation.sender),
             "conversation authority required"
           ) do
      change(txn, kind, conversation, params)
    end
  end

  defp change(txn, "update", %{message: message} = conversation, params) do
    choices = Map.get(params, "choices", message["choices"])

    with :ok <- check(params["revision"] == message["revision"], "current revision required"),
         :ok <- validate_content(params["title"], params["body"], choices),
         :ok <-
           validate_rule(
             txn,
             conversation.sender,
             message["work_item_id"],
             message["decision_request_id"],
             message["answer_rule"],
             choices
           ) do
      updated =
        Map.merge(message, %{
          "title" => params["title"],
          "body" => params["body"],
          "choices" => choices,
          "revision" => message["revision"] + 1
        })

      Txn.q(txn, "UPDATE people_conversations SET revision=?2, message=?3 WHERE id=?1", [
        conversation.id,
        updated["revision"],
        JSON.encode!(updated)
      ])

      {:ok, updated}
    end
  end

  defp change(_txn, "reply", %{message: message}, params) do
    with :ok <- check(present?(params["body"]), "reply body required"),
         :ok <-
           check(
             is_nil(params["address"]) or present?(params["address"]),
             "mention must be nonblank"
           ) do
      {:ok, Map.merge(message, Map.take(params, ["body", "address"]))}
    end
  end

  defp change(txn, "withdraw", conversation, _params) do
    Txn.q(txn, "UPDATE people_conversations SET state='withdrawn' WHERE id=?1", [conversation.id])
    {:ok, conversation.message}
  end

  defp default_addresses(addresses, owner) when addresses in [nil, []], do: ["user:" <> owner]
  defp default_addresses(addresses, _owner), do: addresses

  defp validate_content(title, body, choices) do
    with :ok <- check(present?(title) and present?(body), "title and body required"),
         :ok <-
           check(
             is_list(choices) and
               Enum.all?(choices, fn
                 %{"id" => id, "label" => label} -> present?(id) and present?(label)
                 _ -> false
               end),
             "choices need an id and label"
           ) do
      ids = Enum.map(choices, & &1["id"])
      check(Enum.uniq(ids) == ids, "choice ids must be distinct")
    end
  end

  defp validate_rule(_txn, _sender, _work, nil, nil, []), do: :ok
  defp validate_rule(_txn, _sender, _work, nil, %{"kind" => "first"}, _choices), do: :ok

  defp validate_rule(
         txn,
         sender,
         work,
         decision,
         %{"kind" => "named", "address" => address},
         choices
       )
       when is_binary(decision) do
    Escalation.validate_people_decision_in_txn(txn, decision, sender, work, address, choices)
  end

  defp validate_rule(_txn, _sender, _work, _decision, _rule, _choices),
    do: error("invalid", "invalid answer rule")

  defp append(txn, kind, actor, key, request, message) do
    id = if kind == "send", do: message["conversation_id"], else: Id.uuid4()

    record =
      Map.merge(message, %{"id" => id, "kind" => kind, "delivery_state" => "waiting_undelivered"})

    Txn.q(
      txn,
      """
      INSERT INTO people_operations(id,conversation,actor,retryKey,request,record)
      VALUES(?1,?2,?3,?4,?5,?6)
      """,
      [id, message["conversation_id"], actor, key, JSON.encode!(request), JSON.encode!(record)]
    )

    record
  end

  defp collect(txn, params) do
    limit = Map.get(params, "limit", 50)

    if is_integer(limit) and limit in 1..100 do
      records =
        Txn.q(
          txn,
          """
          SELECT o.record,c.server,c.remote
          FROM people_operations o JOIN people_conversations c ON c.id=o.conversation
          WHERE o.report IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM people_operations before
              WHERE before.conversation=o.conversation AND before.report IS NULL AND before.seq<o.seq
            )
          ORDER BY o.seq LIMIT ?1
          """,
          [limit]
        )

      %{
        records:
          Enum.map(records, fn
            [record, nil, nil] ->
              JSON.decode!(record)

            [record, server, remote] ->
              Map.merge(JSON.decode!(record), %{
                "server_id" => server,
                "remote_conversation_id" => remote
              })
          end)
      }
    else
      error("invalid", "limit must be between 1 and 100")
    end
  end

  defp status(txn, session, params) do
    with {:ok, conversation} <- conversation(txn, params["conversation_id"]),
         :ok <-
           check(
             session in [conversation.sender, conversation.holder],
             "conversation authority required"
           ) do
      operations =
        Txn.q(
          txn,
          "SELECT record, report FROM people_operations WHERE conversation=?1 ORDER BY seq",
          [conversation.id]
        )
        |> Enum.map(fn [record, report] ->
          if report do
            Map.merge(JSON.decode!(record), %{
              "delivery_state" => "reported",
              "report" => JSON.decode!(report)
            })
          else
            JSON.decode!(record)
          end
        end)

      %{
        "conversation_id" => conversation.id,
        "state" => conversation.state,
        "operations" => operations
      }
    end
  end

  defp report(txn, relay, params) do
    id = params["id"]

    case if(is_binary(id),
           do:
             Txn.q(
               txn,
               "SELECT seq, conversation, record, report FROM people_operations WHERE id=?1",
               [id]
             ),
           else: []
         ) do
      [[_, _, _, saved]] when is_binary(saved) ->
        if JSON.decode!(saved) == params,
          do: %{accepted: true, duplicate: true},
          else: error("conflict", "operation already reported")

      [[seq, conversation_id, record, nil]] ->
        with {:ok, conversation} <- conversation(txn, conversation_id),
             [] <-
               Txn.q(
                 txn,
                 "SELECT 1 FROM people_operations WHERE conversation=?1 AND seq<?2 AND report IS NULL LIMIT 1",
                 [conversation_id, seq]
               ),
             :ok <- validate_report(JSON.decode!(record), params),
             :ok <- bind_remote(txn, relay, conversation, JSON.decode!(record), params) do
          wake = notify(txn, conversation, "People message delivery", params)

          Txn.q(txn, "UPDATE people_operations SET report=?2, wakeId=?3 WHERE id=?1", [
            id,
            JSON.encode!(params),
            wake
          ])

          %{accepted: true, duplicate: false}
        else
          [_ | _] -> error("conflict", "earlier operation awaits its report")
          failure -> failure
        end

      [] ->
        error("not_found", "operation not found")
    end
  end

  defp validate_report(record, %{"outcomes" => outcomes} = params) when is_list(outcomes) do
    addresses = record["addresses"]

    valid =
      Enum.all?(outcomes, fn
        %{"address" => address, "status" => state} ->
          address in addresses and state in ~w(reached not_reachable refused)

        _ ->
          false
      end)

    with :ok <-
           check(
             valid and Enum.uniq_by(outcomes, & &1["address"]) == outcomes,
             "invalid address outcomes"
           ) do
      case params["refusal"] do
        nil ->
          :ok

        %{"code" => code, "message" => message} ->
          availability_failure = record["kind"] == "send" and code in @availability_refusals
          no_delivery = Enum.all?(outcomes, &(&1["status"] != "reached"))

          check(
            present?(code) and present?(message) and
              (outcomes == [] or (availability_failure and no_delivery)),
            "invalid whole-operation refusal"
          )

        _ ->
          error("invalid", "invalid whole-operation refusal")
      end
    end
  end

  defp validate_report(_record, _params), do: error("invalid", "outcomes array required")

  defp bind_remote(txn, relay, conversation, %{"kind" => "send"}, params) do
    server = params["server_id"]
    remote = params["remote_conversation_id"]
    reached = Enum.any?(params["outcomes"], &(&1["status"] == "reached"))

    cond do
      present?(server) and present?(remote) and is_nil(params["refusal"]) ->
        case Txn.q(
               txn,
               "SELECT id FROM people_conversations WHERE relay=?1 AND server=?2 AND remote=?3",
               [relay, server, remote]
             ) do
          [] ->
            Txn.q(
              txn,
              "UPDATE people_conversations SET relay=?2,server=?3,remote=?4 WHERE id=?1",
              [conversation.id, relay, server, remote]
            )

            :ok

          _ ->
            error("conflict", "remote conversation already bound")
        end

      is_nil(server) and is_nil(remote) and not reached ->
        Txn.q(txn, "UPDATE people_conversations SET state='undelivered' WHERE id=?1", [
          conversation.id
        ])

        rows =
          Txn.q(
            txn,
            """
            SELECT id FROM people_operations
            WHERE conversation=?1 AND id<>?1 AND report IS NULL ORDER BY seq
            """,
            [conversation.id]
          )

        Enum.each(rows, fn [id] ->
          report = %{
            "id" => id,
            "outcomes" => [],
            "refusal" => %{
              "code" => "initial_send_undelivered",
              "message" => "The initial send established no conversation"
            }
          }

          Txn.q(txn, "UPDATE people_operations SET report=?2 WHERE id=?1", [
            id,
            JSON.encode!(report)
          ])
        end)

        :ok

      true ->
        error("invalid", "successful send needs both remote identifiers")
    end
  end

  defp bind_remote(_txn, _relay, _conversation, _record, _params), do: :ok

  defp receive_event(txn, relay, params) do
    kind = params["kind"]
    event = params["event_id"]

    with :ok <-
           check(
             kind in @event_kinds and present?(event) and present?(params["server_id"]) and
               present?(params["remote_conversation_id"]),
             "invalid event identity"
           ),
         [[id]] <-
           Txn.q(
             txn,
             "SELECT id FROM people_conversations WHERE relay=?1 AND server=?2 AND remote=?3",
             [relay, params["server_id"], params["remote_conversation_id"]]
           ),
         {:ok, conversation} <- conversation(txn, id) do
      case Txn.q(
             txn,
             "SELECT 1 FROM people_events WHERE conversation=?1 AND kind=?2 AND event=?3",
             [id, kind, event]
           ) do
        [[1]] -> %{accepted: true, duplicate: true}
        [] -> accept_new_event(txn, conversation, kind, event, params)
      end
    else
      [] -> error("not_found", "remote conversation not yet bound")
      failure -> failure
    end
  end

  defp accept_new_event(txn, conversation, kind, event, params) do
    revision = params["revision"]
    speaker = params["speaker"]
    content = params["content"]

    with :ok <-
           check(
             is_integer(revision) and revision > 0 and
               revision <= conversation.message["revision"],
             "invalid event revision"
           ),
         :ok <-
           check(
             valid_speaker?(speaker, params["server_id"]) and (kind != "chat" or is_map(speaker)),
             "invalid speaker"
           ),
         :ok <-
           check(
             is_map(content) and (kind != "answer" or present?(content["answer"])) and
               (kind != "chat" or present?(content["body"])),
             "invalid event content"
           ) do
      disposition = answer_disposition(txn, conversation, kind, params)
      payload = Map.put(params, "answer_disposition", disposition)
      name = if speaker, do: speaker["display_name"], else: "Delivery service"
      wake = notify(txn, conversation, "People message #{kind} from #{name}", payload)

      Txn.q(
        txn,
        """
        INSERT INTO people_events(conversation,kind,event,payload,wakeId) VALUES(?1,?2,?3,?4,?5)
        """,
        [conversation.id, kind, event, JSON.encode!(payload), wake]
      )

      if kind == "closed" do
        Txn.q(
          txn,
          "UPDATE people_conversations SET state='closed' WHERE id=?1 AND state='open'",
          [conversation.id]
        )
      end

      %{accepted: true, duplicate: false}
    end
  end

  defp answer_disposition(_txn, _conversation, kind, _params) when kind != "answer", do: nil

  defp answer_disposition(txn, conversation, "answer", params) do
    message = conversation.message

    if conversation.state == "open" and not conversation.answered and
         message["revision"] == params["revision"] do
      case message["answer_rule"] do
        %{"kind" => "first"} ->
          mark_answered(txn, conversation.id)
          "settled"

        %{"kind" => "named", "address" => address} ->
          with %{"address" => ^address} <- params["speaker"],
               :ok <-
                 Escalation.rule_people_decision_in_txn(txn, message, params["content"]["answer"]) do
            mark_answered(txn, conversation.id)
            "ruled"
          else
            _ -> "advice"
          end

        _ ->
          "advice"
      end
    else
      "advice"
    end
  end

  defp mark_answered(txn, id),
    do: Txn.q(txn, "UPDATE people_conversations SET answered=1 WHERE id=?1", [id])

  defp valid_speaker?(nil, _server), do: true

  defp valid_speaker?(%{"address" => address, "display_name" => name}, _server),
    do: present?(address) and present?(name)

  defp valid_speaker?(
         %{"server_id" => server, "person_id" => person, "display_name" => name},
         server
       ),
       do: present?(person) and present?(name)

  defp valid_speaker?(_, _server), do: false

  defp notify(_txn, %{holder: nil}, _title, _payload), do: nil

  defp notify(txn, conversation, title, payload) do
    notice =
      Map.merge(payload, %{
        "conversation_id" => conversation.id,
        "work_item_id" => conversation.message["work_item_id"]
      })

    Wakes.schedule_in_txn(txn, %{
      session_key: conversation.holder,
      origin: "process:tightbeam",
      class: "fyi",
      due_at: System.system_time(:millisecond),
      prompt: title <> "\n\n" <> JSON.encode!(notice)
    }).wake_id
  end

  def retire_in_txn(txn, session) do
    rows = Txn.q(txn, "SELECT id FROM people_conversations WHERE holder=?1", [session])

    if rows != [] do
      successor = successor(txn, session, MapSet.new())

      Enum.each(rows, fn [id] ->
        {:ok, conversation} = conversation(txn, id)
        move_pending_wakes(txn, id, session, successor)

        if successor do
          Txn.q(txn, "UPDATE people_conversations SET holder=?2 WHERE id=?1", [id, successor])
        else
          Txn.q(txn, "UPDATE people_conversations SET holder=NULL,state='closed' WHERE id=?1", [
            id
          ])

          if conversation.state == "open" do
            message =
              Map.put(
                conversation.message,
                "body",
                "This conversation is closing because no agent inherited it."
              )

            append(txn, "close", session, nil, %{}, message)
          end
        end
      end)
    end

    :ok
  end

  defp successor(txn, session, visited) do
    if not MapSet.member?(visited, session) do
      role =
        Txn.q(
          txn,
          """
          SELECT r.boundSessionKey FROM retirement_blockers b
          JOIN unfinished_retirements u ON u.id=b.retirementId
          JOIN roles r ON r.name=b.reference
          WHERE b.kind='role' AND b.sessionKey=?1 AND r.createdAt<u.createdAt
            AND r.boundSessionKey IS NOT NULL AND r.boundSessionKey<>?1
          ORDER BY r.name
          """,
          [session]
        )

      handovers =
        Txn.q(
          txn,
          """
          SELECT newOwnerSessionKey FROM retirement_owner_transfers
          WHERE formerOwnerSessionKey=?1 ORDER BY id
          """,
          [session]
        )

      (List.flatten(role ++ handovers) ++
         Enum.map(
           Txn.q(
             txn,
             "SELECT #{Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1",
             [session]
           ),
           &hd/1
         ))
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(fn candidate ->
        case Org.get_in_txn(txn, candidate) do
          %{state: "active"} -> candidate
          %{state: "retired"} -> successor(txn, candidate, MapSet.put(visited, session))
          _ -> nil
        end
      end)
    end
  end

  defp move_pending_wakes(txn, id, retiring, successor) do
    Txn.q(
      txn,
      """
      SELECT w.wakeId FROM wakes w
      WHERE w.state='pending' AND w.wakeId IN (
        SELECT wakeId FROM people_events WHERE conversation=?1 UNION
        SELECT wakeId FROM people_operations WHERE conversation=?1
      )
      """,
      [id]
    )
    |> Enum.each(fn [wake_id] ->
      if successor do
        {:ok, _} = Wakes.readdress_pending_in_txn(txn, wake_id, successor)
      else
        true =
          Wakes.cancel_in_txn(txn, %{
            wake_id: wake_id,
            requester: %{kind: "process", id: "tightbeam:retirement"},
            reason_kind: "target_retired",
            causal_source: %{kind: "session_transition", id: retiring},
            outcome: %{kind: "no_replacement"}
          })
      end
    end)
  end

  defp conversation(txn, id) when is_binary(id) do
    case Txn.q(
           txn,
           "SELECT sender, holder, state, message, answered FROM people_conversations WHERE id=?1",
           [id]
         ) do
      [[sender, holder, state, message, answered]] ->
        {:ok,
         %{
           id: id,
           sender: sender,
           holder: holder,
           state: state,
           message: JSON.decode!(message),
           answered: answered == 1
         }}

      [] ->
        error("not_found", "conversation not found")
    end
  end

  defp conversation(_txn, _id), do: error("invalid", "conversation_id required")

  defp check(true, _message), do: :ok
  defp check(false, message), do: error("invalid", message)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp error(code, message), do: %{code: code, message: message}
end
