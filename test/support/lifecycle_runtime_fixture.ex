defmodule Tightbeam.LifecycleRuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.DB

  # Extract the shipped literal SQL, including the surrounding correlated
  # queries. A changed or removed query must update this explicit coverage map;
  # the test cannot pass against a faster handwritten substitute.
  def cases do
    [
      {"supervision.ex", "SELECT kind, detail FROM lifecycle_events", ["index-assignment"],
       [["supervision_entitlement_rearmed", "new"]]},
      {"supervision.ex", "SELECT 1 FROM supervision_liveness_sidecar", ["index-assignment"],
       [[1]]},
      {"supervision.ex", "SELECT 1 FROM lifecycle_events WHERE subject",
       ["index-assignment", "refusal"], [[1]]},
      {"supervision.ex", "SELECT w.wakeId,w.sessionKey FROM wakes w", [],
       [["index-unobserved", "index-session"]]},
      {"supervision.ex", "SELECT e.subject FROM lifecycle_events e", ["index-session", nil],
       [["index-observed-new"]]},
      {"gateway.ex", "SELECT seq, role, sender, content, attachments", ["index-session", 3, 100],
       [[1, "user", nil, "visible", "[]"]]},
      {"gateway.ex", "SELECT kind FROM lifecycle_events", ["index-session"],
       [["retired_workspace_cleanup_incomplete"]]},
      {"wakes.ex", "SELECT detail FROM lifecycle_events", ["index-observed"], [["wake-detail"]]},
      {"escalation.ex", "SELECT COUNT(*) FROM lifecycle_events WHERE kind", ["index-decision"],
       [[2]]}
    ]
    |> Enum.map(fn {file, prefix, params, expected} ->
      ast = File.read!(Path.join("lib/tightbeam", file)) |> Code.string_to_quoted!()

      {_, found} =
        Macro.prewalk(ast, [], fn
          sql, acc when is_binary(sql) ->
            if String.starts_with?(String.trim(sql), prefix) and
                 String.contains?(sql, "lifecycle_events"),
               do: {sql, [sql | acc]},
               else: {sql, acc}

          node, acc ->
            {node, acc}
        end)

      [sql] = Enum.uniq(found)
      %{file: file, sql: sql, params: params, expected: expected}
    end)
  end

  def assert_plans_and_results!(db) do
    for %{file: file, sql: sql, params: params, expected: expected} <- cases() do
      assert {:ok, plan} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, params)
      details = Enum.map(plan, &List.last/1)
      assert Enum.any?(details, &String.contains?(&1, "SEARCH")), inspect(plan)

      assert Enum.any?(details, &String.contains?(&1, "lifecycle_events_")),
             "#{file}: missing lifecycle index: #{inspect(plan)}"

      refute Enum.any?(details, &Regex.match?(~r/\bSCAN (?:lifecycle_events|e)\b/, &1)),
             "#{file}: lifecycle table scan: #{inspect(plan)}"

      assert DB.query(db, sql, params) == {:ok, expected}, file <> ": " <> sql
      IO.puts("lifecycle plan #{file}: #{inspect(details)}")
    end

    occurrence = Enum.find(cases(), &String.starts_with?(String.trim(&1.sql), "SELECT e.subject"))

    assert DB.query(db, occurrence.sql, ["index-session", "index-observed-new"]) ==
             {:ok, [["index-observed"]]}

    assert DB.query(db, occurrence.sql, ["absent-session", nil]) == {:ok, []}
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
    :ok
  end

  def seed!(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,createdAt,updatedAt)
      VALUES ('index-session','Synthetic','index-owner','process:synthetic','default','claude','anthropic','fable',0,0);
      INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt)
      VALUES ('index-unobserved','index-session','process:synthetic','fixture',0,0),
             ('index-observed','index-session','process:synthetic','fixture',0,0);
      INSERT INTO lifecycle_events(ts,kind,subject,detail) VALUES
        (0,'supervision_entitlement_old','index-assignment','old'),
        (0,'supervision_entitlement_recovery_refused','index-assignment','refusal'),
        (0,'supervision_entitlement_rearmed','index-assignment','new'),
        (0,'unrelated','index-assignment','later unrelated must not win'),
        (0,'idle_cleanup_pending_observed','index-observed','{"session":"index-session"}'),
        (0,'idle_cleanup_pending_observed','index-observed-new','{"session":"index-session"}'),
        (0,'idle_cleanup_pending_observed','other-wake','{"session":"other-session"}'),
        (0,'retired_workspace_cleanup_completed','index-session',NULL),
        (0,'retired_workspace_cleanup_incomplete','index-session',NULL),
        (0,'retired_workspace_cleanup_completed','other-session',NULL),
        (0,'wake_undeliverable','index-observed','wake-detail'),
        (0,'decision_request_ruled','index-decision',NULL),
        (0,'decision_request_ruled','index-decision',NULL),
        (0,'decision_request_ruled','another-decision',NULL),
        (0,'queued_message_suppressed','2','{"messageKind":"sender-replacement"}');
      INSERT INTO messages(seq,id,sessionKey,role,content,timestamp,llmVisibleMessageId)
      VALUES (1,'index-visible','index-session','user','visible',0,'index-visible'),
             (2,'index-hidden','index-session','user','hidden',0,'index-hidden'),
             (3,'index-foreign','other-session','user','foreign',0,'index-foreign');
      INSERT INTO turns(seq,sessionKey,messageId,origin,prompt,status,error,createdAt)
      VALUES (2,'index-session','index-hidden','process:synthetic','fixture','canceled',
              'queued-message-suppressed: sender_requested_replacement',0);
      """)
  end
end
