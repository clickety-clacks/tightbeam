defmodule Tightbeam.RecordNoticeTest do
  @moduledoc """
  Proofs for `EventLog.notice/5` (Flynn rulings 2026-08-03).

  The bias being corrected: `[adapter recovered]` reached the chat while
  `adapter_down` reached a table no client reads. A notice is ONE call that
  records and tells, so a caller cannot record without having decided who
  hears it — and what it tells rides the ordinary message path, so it both
  pushes live and replays on reconnect.
  """
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{ConnRegistry, DB, EventLog, Model, Org, Projection}
  alias Tightbeam.Wire.Payloads

  setup do
    db = :"notice_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    registry =
      start_supervised!({ConnRegistry, name: :"notice_reg_#{System.unique_integer([:positive])}"})

    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 0, 'admin_add', 1)"
      )

    create_session(db, Org.personal_session_key("flynn"), "Main")
    create_session(db, "work", "Work")

    %{db: db, registry: registry, main: Org.personal_session_key("flynn")}
  end

  defp create_session(db, session_key, display_name) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })
  end

  defp connect(registry, device_id) do
    {:ok, ref, _replaced} =
      ConnRegistry.register(registry, %{
        pid: self(),
        user_id: "flynn",
        device_id: device_id,
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    ref
  end

  defp lifecycle_kinds(db), do: db |> EventLog.lifecycle_events() |> Enum.map(& &1.kind)

  ## The record and the message are one act

  test "a session audience gets the row, the stored marker, and a live push", ctx do
    connect(ctx.registry, "d1")

    :ok =
      EventLog.notice(ctx.db, "adapter_down", "claude:shared@testhost", "{:acp_exit, 137}",
        audience: {:session, "work"},
        attention: :normal,
        message: "[adapter down]\n\nThe engine stopped.",
        conn_registry: ctx.registry
      )

    assert [
             %{
               kind: "adapter_down",
               subject: "claude:shared@testhost",
               detail: "{:acp_exit, 137}"
             }
           ] =
             EventLog.lifecycle_events(ctx.db)

    assert [marker] = Projection.list_after(ctx.db, "work", nil, 10)
    assert marker.content == "[adapter down]\n\nThe engine stopped."
    assert marker.sender == "process:tightbeam"
    assert marker.role == "assistant"
    assert marker.message_type == "substrate"
    assert marker.attention_tier == 0

    seq = marker.seq
    assert_receive {:push_message, "work", ^seq, %{"type" => "message"} = payload}
    assert payload["content"] == "[adapter down]\n\nThe engine stopped."
    assert payload["attentionTier"] == 0
  end

  test "the same notice replays to a client that reconnects after it", ctx do
    :ok =
      EventLog.notice(ctx.db, "adapter_down", "claude:shared@testhost", "died",
        audience: {:session, "work"},
        attention: :normal,
        message: "[adapter down]\n\nThe engine stopped.",
        conn_registry: ctx.registry
      )

    # Nobody was connected, so nothing was pushed. Replay is the other half of
    # the ruling: the same rows a reconnecting socket drains (Wire.Socket reads
    # list_after and frames each row with server_message/1).
    refute_received {:push_message, _, _, _}

    assert [replayed] = Projection.list_after(ctx.db, "work", nil, 501, 0)
    frame = Payloads.server_message(replayed)
    assert frame["content"] == "[adapter down]\n\nThe engine stopped."
    assert frame["sender"] == "process:tightbeam"
    assert frame["attentionTier"] == 0
  end

  ## Flynn ruling 2: no session is a log line, never a mailbox

  test "an audience with no session is logged and nothing is conjured for it", ctx do
    log =
      capture_log(fn ->
        :ok =
          EventLog.notice(ctx.db, "adapter_down", "claude:shared@ghosthost", "died",
            audience: {:session, "no-such-session"},
            attention: :normal,
            message: "[adapter down]\n\nThe engine stopped.",
            conn_registry: ctx.registry
          )
      end)

    assert log =~ "adapter_down"
    assert log =~ "no-such-session"
    assert log =~ "no active session"

    # The record still landed — the row is unconditional.
    assert lifecycle_kinds(ctx.db) == ["adapter_down"]

    # …and no session, no message, was created on demand.
    assert Org.get(ctx.db, "no-such-session") == nil
    assert Projection.list_after(ctx.db, "no-such-session", nil, 10) == []
  end

  test "a retired session is not an audience", ctx do
    Org.retire(ctx.db, "work", "user:flynn", 1_000)

    capture_log(fn ->
      :ok =
        EventLog.notice(ctx.db, "adapter_down", "claude:shared@testhost", "died",
          audience: {:session, "work"},
          attention: :normal,
          message: "[adapter down]\n\nThe engine stopped.",
          conn_registry: ctx.registry
        )
    end)

    assert lifecycle_kinds(ctx.db) == ["adapter_down"]
    assert Projection.list_after(ctx.db, "work", nil, 10) == []
  end

  ## Audiences

  test "an ambient audience lands in the named owner's main session", ctx do
    :ok =
      EventLog.notice(ctx.db, "endpoint_not_provisioned", "eurisko", "ssh refused",
        audience: {:ambient, "flynn"},
        attention: :low,
        message: "[host unreachable]\n\neurisko did not answer.",
        conn_registry: ctx.registry
      )

    assert [marker] = Projection.list_after(ctx.db, ctx.main, nil, 10)
    assert marker.content =~ "eurisko did not answer"
    assert Projection.list_after(ctx.db, "work", nil, 10) == []
  end

  test "several halted sessions share one record and each get their own marker", ctx do
    create_session(ctx.db, "second", "Second")

    :ok =
      EventLog.notice(ctx.db, "adapter_down", "claude:shared@testhost", "died",
        audience: {:sessions, ["work", "second"]},
        attention: :normal,
        message: "[adapter down]\n\nThe engine stopped.",
        conn_registry: ctx.registry
      )

    # ONE event, several affected readers — not one row per reader.
    assert lifecycle_kinds(ctx.db) == ["adapter_down"]
    assert [_] = Projection.list_after(ctx.db, "work", nil, 10)
    assert [_] = Projection.list_after(ctx.db, "second", nil, 10)
  end

  test "a caller-owned notice publishes only after commit and rolls back as one act", ctx do
    connect(ctx.registry, "txn-notice")

    assert {:error, %RuntimeError{message: "abort notice"}} =
             DB.transaction(ctx.db, fn txn ->
               EventLog.notice_in_txn(txn, "probe", "rolled-back", "detail",
                 audience: {:session, "work"},
                 attention: :high,
                 message: "[rolled back]\n\nThis must not survive."
               )

               raise "abort notice"
             end)

    assert EventLog.lifecycle_events(ctx.db) == []
    assert Projection.list_after(ctx.db, "work", nil, 10) == []
    refute_received {:push_message, _, _, _}

    assert {:ok, publication} =
             DB.transaction(ctx.db, fn txn ->
               EventLog.notice_in_txn(txn, "probe", "committed", "detail",
                 audience: {:session, "work"},
                 attention: :high,
                 message: "[committed]\n\nPublish after commit."
               )
             end)

    assert [_marker] = Projection.list_after(ctx.db, "work", nil, 10)
    refute_received {:push_message, _, _, _}

    assert :ok = EventLog.complete_notice(publication, conn_registry: ctx.registry)

    assert_receive {:push_message, "work", _seq,
                    %{"content" => "[committed]\n\nPublish after commit."}}
  end

  test "record_only writes the row and interrupts nobody", ctx do
    connect(ctx.registry, "d1")

    :ok =
      EventLog.notice(ctx.db, "condition_fact_filed", "17", "kind=quota-recovered",
        audience: :record_only,
        conn_registry: ctx.registry
      )

    assert lifecycle_kinds(ctx.db) == ["condition_fact_filed"]
    assert Projection.list_after(ctx.db, "work", nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main, nil, 10) == []
    refute_received {:push_message, _, _, _}
  end

  test "a fan-out that cannot run costs the delivery, never the caller or the record", ctx do
    absent = :"no_such_registry_#{System.unique_integer([:positive])}"
    assert Process.whereis(absent) == nil

    log =
      capture_log(fn ->
        # The caller here stands in for the AdapterCoordinator, which found
        # this: it was recording its OWN adapter's death when the publish exit
        # took it down, after the row had already committed.
        assert :ok =
                 EventLog.notice(ctx.db, "adapter_down", "claude:shared@testhost", "died",
                   audience: {:session, "work"},
                   attention: :normal,
                   message: "[adapter down]\n\nThe engine stopped.",
                   conn_registry: absent
                 )
      end)

    assert log =~ "replays on the next connect"
    assert lifecycle_kinds(ctx.db) == ["adapter_down"]
    assert [_marker] = Projection.list_after(ctx.db, "work", nil, 10)
  end

  ## Attention — one vocabulary, extended downward

  test "low, normal and high are the same vocabulary the agent elects over", ctx do
    connect(ctx.registry, "d1")

    for {attention, tier} <- [low: -1, normal: 0, high: 1] do
      :ok =
        EventLog.notice(ctx.db, "probe", to_string(attention), nil,
          audience: {:session, "work"},
          attention: attention,
          message: "[#{attention}]\n\nbody",
          conn_registry: ctx.registry
        )

      assert %{attention_tier: ^tier} =
               marker = ctx.db |> Projection.list_after("work", nil, 10) |> List.last()

      # The SAME payload key the agent's own reply election surfaces through.
      assert Payloads.server_message(marker)["attentionTier"] == tier
      assert Projection.attention_name(tier) == to_string(attention)
    end
  end

  test "a caller with an audience cannot record without electing attention or writing the line",
       ctx do
    assert_raise KeyError, fn ->
      EventLog.notice(ctx.db, "probe", "s", nil, audience: {:session, "work"}, attention: :low)
    end

    assert_raise KeyError, fn ->
      EventLog.notice(ctx.db, "probe", "s", nil, audience: {:session, "work"}, message: "x")
    end

    assert_raise KeyError, fn ->
      EventLog.notice(ctx.db, "probe", "s", nil, attention: :low, message: "x")
    end

    # None of the refusals left a half-written record behind.
    assert EventLog.lifecycle_events(ctx.db) == []
  end
end
