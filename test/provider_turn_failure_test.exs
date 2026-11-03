defmodule Tightbeam.ProviderTurnFailureTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, ProviderTurnFailure, TurnLifecycle}

  test "capture retains only safe upstream identity and explicit absent credential truth" do
    snapshot =
      ProviderTurnFailure.capture(
        %{harness: :claude, host: "missing-credential-owner"},
        :prompt,
        %{
          "code" => -32_603,
          "message" => "API failed with bearer super-secret",
          "data" => %{
            "statusCode" => 500,
            "requestId" => "req_safe-123",
            "authorization" => "Bearer super-secret"
          }
        }
      )

    assert snapshot.upstream == %{
             http_status: 500,
             error_class: "http:500",
             request_id: "req_safe-123"
           }

    assert snapshot.credential.available == false
    assert snapshot.credential.terminal == nil
    assert snapshot.credential.last_health == nil
    refute JSON.encode!(snapshot) =~ "super-secret"
    refute JSON.encode!(snapshot) =~ "authorization"
  end

  test "failed turn retains exact correlation and redacted snapshots across restart" do
    unique = System.unique_integer([:positive])
    db = :"provider_failure_db_#{unique}"
    path = Path.join(System.tmp_dir!(), "provider-turn-failure-#{unique}.sqlite3")
    on_exit(fn -> File.rm(path) end)

    {:ok, first_owner} = DB.start_link(path: path, name: db)
    :ok = Tightbeam.Schema.ensure_all(db)
    seed_owner_and_session(db)

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: "failure-session",
        message_id: "failure-message",
        origin: "user:flynn",
        prompt: "provider prompt"
      })

    assert {:ok, %{owner_lease: lease}} =
             Ledger.claim_next(db, "failure-session", "lane:provider-failure")

    assert :ok = Ledger.stamp_adapter(db, seq, 7, lease)

    assert :ok =
             TurnLifecycle.append(db, seq, %{
               event_key: "prompt:dispatched",
               producer_event_id: "adapter:lease:request:41",
               kind: "prompt_dispatched",
               stage: "prompt",
               outcome: "dispatched",
               cause: "acp:port-write",
               principal: "process:tightbeam",
               owner_lease: lease,
               acp_request_id: 41,
               detail: %{v: 1}
             })

    seed_launch(db)

    snapshot = %{
      captured_at: 1_792_908_496_983,
      stage: "prompt",
      harness: "claude",
      host: "testhost",
      upstream: %{
        http_status: 500,
        error_class: "http:500",
        request_id: "req_provider_abc"
      },
      credential: %{
        captured_at: 1_792_908_496_983,
        provider: "anthropic",
        available: true,
        terminal: false,
        last_health: "onboarded",
        initial_auth_none_ignored: false
      }
    }

    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, seq, "failed", "provider failure",
                        owner_lease: lease
                      )

               :ok = ProviderTurnFailure.record_in_txn(txn, seq, snapshot)
               :recorded
             end)

    evidence = read(db, seq).failure_evidence

    assert evidence.correlation == %{
             turn_seq: seq,
             acp_request_id: 41,
             launch_id: "launch-1",
             launch_sequence: 9
           }

    assert evidence.upstream == %{
             http_status: 500,
             error_class: "http:500",
             request_id: "req_provider_abc"
           }

    assert evidence.credential_health.provenance == "credential-metadata"
    assert evidence.credential_health.terminal == false
    assert evidence.loaded_build.provenance == "launch-plan-filesystem"
    assert evidence.loaded_build.identity["adapter"]["version"] == "0.73.0"
    assert evidence.loaded_build.identity["sdk"]["version"] == "0.3.257"

    assert {:error, _} =
             DB.query(
               db,
               "UPDATE provider_turn_failures SET upstreamRequestId='changed' WHERE turnSeq=?1",
               [seq]
             )

    Process.unlink(first_owner)
    GenServer.stop(first_owner)
    {:ok, second_owner} = DB.start_link(path: path, name: db)
    on_exit(fn -> if Process.alive?(second_owner), do: GenServer.stop(second_owner) end)

    assert read(db, seq).failure_evidence == evidence
    encoded = JSON.encode!(evidence)
    refute encoded =~ "provider prompt"
    refute encoded =~ "provider failure"
  end

  defp seed_owner_and_session(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,creationKind,createdAt)
      VALUES ('flynn',0,'admin_add',1);
      INSERT INTO sessions
        (sessionKey,displayName,kind,isBuiltIn,ownerUserId,origin,operationalParent,
         archetype,identityName,harness,provider,model,thinkingLevel,modelContext,host,
         createdAt,updatedAt)
      VALUES
        ('failure-session','Failure session','main',1,'flynn','user:flynn','failure-session',
         'default','shared','claude','anthropic','claude-opus-4-8','high',NULL,'testhost',1,1);
      """)
  end

  defp seed_launch(db) do
    build = %{
      "provenance" => "launch-plan-filesystem",
      "adapter" => %{
        "package" => "@agentclientprotocol/claude-agent-acp",
        "version" => "0.73.0",
        "sourceSha256" => String.duplicate("a", 64)
      },
      "sdk" => %{
        "package" => "@anthropic-ai/claude-agent-sdk",
        "version" => "0.3.257",
        "sourceSha256" => nil
      },
      "executable" => %{
        "kind" => "adapter-bundle",
        "version" => "0.73.0",
        "sha256" => String.duplicate("a", 64)
      },
      "tightbeam" => %{"build" => 1, "sha" => String.duplicate("b", 40)}
    }

    :ok =
      DB.execute(db, """
      INSERT INTO harness_processes
        (launchId,adapterKey,harness,preset,host,helperPath,identityPath,launchSequence,
         state,createdAt)
      VALUES
        ('launch-1','claude:shared@testhost','claude','shared','testhost','/bin/true',
         '/tmp/identity',9,'running',1792908400000);
      """)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO harness_process_builds (launchId,capturedAt,provenance,buildJson)
        VALUES ('launch-1',1792908400000,'launch-plan-filesystem',?1)
        """,
        [JSON.encode!(build)]
      )
  end

  defp read(db, seq) do
    TurnLifecycle.read(db, %{
      params: %{session_key: "failure-session", turn_seq: seq},
      principal: {:user, "flynn"}
    })
  end
end
