defmodule Tightbeam.FirehoseDirectApplyMatrix do
  @moduledoc false

  alias Tightbeam.{Artifacts, Assignments, Ledger, Org, Wakes, WorkItems}
  alias Tightbeam.Firehose.Hub

  def execute(base, %{"op" => "seed"}) do
    fixture = base |> Path.join("reopen-fixture.json") |> File.read!() |> JSON.decode!()
    user_id = fixture["userId"]
    session_key = fixture["holder"]
    File.write!(Path.join([base, "work", "sample.md"]), "restart convergence fixture")

    work_item =
      WorkItems.__handle__(Tightbeam.DB, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:#{user_id}",
        principal: {:user, user_id},
        session_key: nil,
        params: %{title: "Cold restart work item"}
      })

    assignment = create_assignment(user_id, session_key, work_item.id, "Lifecycle assignment")
    attest_assignment = create_assignment(user_id, session_key, work_item.id, "Attest assignment")
    attest = create_attest(session_key, attest_assignment.id, "Seed attest")

    artifact = create_artifact(base, session_key, work_item.id, "Seed artifact")

    {:ok, turn_seq} =
      enqueue_turn(session_key, work_item.id, attest_assignment.id, "Seed turn")

    wake = schedule_wake(session_key, work_item.id, attest_assignment.id, "Seed wake")

    %{
      "workItemId" => work_item.id,
      "assignmentId" => assignment.id,
      "attestAssignmentId" => attest_assignment.id,
      "attestId" => attest.id,
      "artifactId" => artifact.artifact_id,
      "turnSeq" => turn_seq,
      "wakeId" => wake.wake_id,
      "sessionKey" => session_key
    }
  end

  def execute(base, %{"op" => "mutate", "resource" => resource, "phase" => phase} = action)
      when phase in ["before", "after"] do
    fixture = base |> Path.join("reopen-fixture.json") |> File.read!() |> JSON.decode!()
    user_id = fixture["userId"]
    session_key = fixture["holder"]

    case {resource, phase} do
      {"work-items", phase} ->
        work_item_id = action["workItemId"]

        _row =
          WorkItems.__handle__(Tightbeam.DB, "work-item-update", %{
            verb: "work-item-update",
            origin: "user:#{user_id}",
            principal: {:user, user_id},
            session_key: nil,
            firehose_in_txn: true,
            firehose_hub: Hub,
            supervision_interval_ms: 1_000,
            params: %{work_item_id: work_item_id, title: "#{phase} restart update"}
          })

        result(resource, "work_item.updated", "id", work_item_id)

      {"assignments", "before"} ->
        assignment_id = action["assignmentId"]

        Assignments.__handle__(Tightbeam.DB, "revoke-assignment", %{
          verb: "revoke-assignment",
          origin: "user:#{user_id}",
          principal: {:user, user_id},
          session_key: nil,
          firehose_in_txn: true,
          firehose_hub: Hub,
          params: %{assignment_id: assignment_id, reason: "Close before cold restart"}
        })

        result(resource, "assignment.closed", "id", assignment_id)

      {"assignments", "after"} ->
        assignment_id = action["assignmentId"]

        Assignments.__handle__(Tightbeam.DB, "reopen-assignment", %{
          verb: "reopen-assignment",
          origin: "user:#{user_id}",
          principal: {:user, user_id},
          session_key: nil,
          firehose_in_txn: true,
          firehose_hub: Hub,
          supervision_interval_ms: 60_000,
          params: %{assignment_id: assignment_id, reason: "Reopen after cold restart"}
        })

        result(resource, "assignment.reopened", "id", assignment_id)

      {"attests", phase} ->
        attest = create_attest(session_key, action["attestAssignmentId"], "Attest #{phase}")
        result(resource, "attest.filed", "id", attest.id)

      {"artifacts", phase} ->
        artifact = create_artifact(base, session_key, action["workItemId"], "Artifact #{phase}")
        result(resource, "artifact.recorded", "artifactId", artifact.artifact_id)

      {"turns", phase} ->
        {:ok, seq} =
          enqueue_turn(
            session_key,
            action["workItemId"],
            nil,
            "Turn #{phase}"
          )

        result(resource, "turn.queued", "seq", seq)

      {"wakes", phase} ->
        wake_id = action["wakeId"]
        update_pending_wake(wake_id, phase)
        result(resource, "wake.scheduled", "wakeId", wake_id)

      {"sessions", phase} ->
        _session = Org.rename(Tightbeam.DB, session_key, "#{phase} restart session")
        result(resource, "session.updated", "sessionKey", session_key)
    end
  end

  defp create_assignment(user_id, session_key, work_item_id, subject) do
    Assignments.__handle__(Tightbeam.DB, "assign", %{
      verb: "assign",
      origin: "user:#{user_id}",
      principal: {:user, user_id},
      session_key: session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 60_000,
      params: %{subject: subject, work_item_id: work_item_id}
    })
  end

  defp create_attest(session_key, assignment_id, note) do
    result =
      Assignments.__handle__(Tightbeam.DB, "attest", %{
        verb: "attest",
        origin: "agent:test-session",
        principal: {:session, session_key},
        session_key: nil,
        firehose_in_txn: true,
        firehose_hub: Hub,
        params: %{assignment_id: assignment_id, kind: "progress", note: note}
      })

    result.attest
  end

  defp create_artifact(base, session_key, work_item_id, title) do
    Artifacts.record(Tightbeam.DB, %{
      principal: {:session, session_key},
      session_key: session_key,
      artifact_base_dir: Path.join(base, "work"),
      params: %{
        kind: "report",
        title: title,
        origin_path: "sample.md",
        work_item_id: work_item_id
      }
    })
  end

  defp enqueue_turn(session_key, work_item_id, assignment_id, prompt) do
    Ledger.enqueue(Tightbeam.DB, %{
      session_key: session_key,
      message_id: "direct-apply-#{System.unique_integer([:positive])}",
      origin: "user:direct-apply",
      prompt: prompt,
      assignment_id: assignment_id,
      job_ref: work_item_id
    })
  end

  defp schedule_wake(session_key, work_item_id, assignment_id, prompt) do
    Wakes.schedule(Tightbeam.DB, %{
      session_key: session_key,
      origin: "user:direct-apply",
      prompt: prompt,
      due_at: System.system_time(:millisecond) + 60_000,
      work_item_id: work_item_id,
      assignment_id: assignment_id
    })
  end

  defp update_pending_wake(wake_id, phase) do
    due_at = System.system_time(:millisecond) + if(phase == "before", do: 60_000, else: 120_000)

    case Tightbeam.DB.transaction(Tightbeam.DB, fn txn ->
           Tightbeam.DB.Txn.q(
             txn,
             "UPDATE wakes SET dueAt=?2,prompt=?3 WHERE wakeId=?1 AND state='pending'",
             [wake_id, due_at, "Wake updated #{phase}"]
           )

           :ok = Wakes.publish_change_in_txn(txn, "wake.scheduled", wake_id)
           wake_id
         end) do
      {:ok, ^wake_id} -> :ok
      {:error, error} -> raise error
    end
  end

  defp result(resource, class, key_field, key) do
    %{"resource" => resource, "class" => class, "keyField" => key_field, "key" => key}
  end
end
