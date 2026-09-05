defmodule Tightbeam.OperatorWithdrawTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Escalation, EventLog, Model, Org}

  setup do
    db = :"operator_withdraw_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    owner_main = ensure_main_session(db, "flynn")
    raiser = session(db, "raiser", "flynn")
    opener = session(db, "opener", "flynn")
    holder = session(db, "holder", "flynn")
    outsider = session(db, "outsider", "flynn")

    %{
      db: db,
      owner_main: owner_main,
      raiser: raiser,
      opener: opener,
      holder: holder,
      outsider: outsider
    }
  end

  test "a same-owner subject-card opener retracts another session's operator request", ctx do
    assignment_id = assignment(ctx, "session-opener", opened_by_session: ctx.opener.session_key)
    request = operator_request(ctx, assignment_id)

    assert %{status: "withdrawn", withdrawn_by: "agent:opener", withdrawn_reason: "resolved"} =
             Escalation.operator_withdraw(
               ctx.db,
               withdraw_call(ctx.opener, "agent:opener", request.id, "resolved")
             )

    assert {:ok, [["withdrawn", "agent:opener", "resolved", nil, nil, nil, nil]]} =
             terminal_row(ctx.db, request.id)

    assert Enum.count(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "decision_request_withdrawn" and event.subject == request.id and
               event.detail == "by=agent:opener reason=resolved"
           end) == 1
  end

  test "a same-owner session that is neither raiser nor opener stays refused", ctx do
    assignment_id = assignment(ctx, "outsider-refused", opened_by_session: ctx.opener.session_key)
    request = operator_request(ctx, assignment_id)
    before = terminal_row(ctx.db, request.id)

    assert %{code: "not_owner"} =
             Escalation.operator_withdraw(
               ctx.db,
               withdraw_call(ctx.outsider, "agent:outsider", request.id, "silence it")
             )

    assert terminal_row(ctx.db, request.id) == before
  end

  test "a request without a subject card gains no new session withdrawer", ctx do
    request = operator_request(ctx, nil)
    before = terminal_row(ctx.db, request.id)

    assert %{code: "not_owner"} =
             Escalation.operator_withdraw(
               ctx.db,
               withdraw_call(ctx.opener, "agent:opener", request.id, "no card")
             )

    assert terminal_row(ctx.db, request.id) == before
  end

  test "the owner's personal session is the opener for a user-opened subject card", ctx do
    assignment_id = assignment(ctx, "user-opener", opened_by_user: "flynn")
    request = operator_request(ctx, assignment_id)

    assert %{status: "withdrawn", withdrawn_by: "agent:main"} =
             Escalation.operator_withdraw(
               ctx.db,
               withdraw_call(ctx.owner_main, "agent:main", request.id, "owner-opened card")
             )
  end

  test "a newly authorized opener still needs a withdrawal reason", ctx do
    assignment_id = assignment(ctx, "reason-required", opened_by_session: ctx.opener.session_key)
    request = operator_request(ctx, assignment_id)
    before = terminal_row(ctx.db, request.id)

    call = withdraw_call(ctx.opener, "agent:opener", request.id, "unused")

    assert %{code: "invalid"} =
             Escalation.operator_withdraw(ctx.db, put_in(call, [:params, :reason], nil))

    assert terminal_row(ctx.db, request.id) == before
  end

  test "raiser retirement withdraws operator and non-operator requests", ctx do
    operator = operator_request(ctx, nil)

    {:decision_pending, statute_id} =
      Escalation.escalate(
        ctx.db,
        %{
          verb: "attest",
          origin: "agent:raiser",
          principal: {:session, ctx.raiser.session_key},
          params: %{assignment_id: "asg-retirement", kind: "completion"}
        },
        %{name: "review", text: "owner denied review"},
        %{question: "Allow this action?", options: nil}
      )

    assert :ok = Escalation.withdraw_for_retired(ctx.db, ctx.raiser.session_key)

    assert {:ok, [["withdrawn", "process:tightbeam", "raiser-retired", nil, nil, nil, nil]]} =
             terminal_row(ctx.db, operator.id)

    assert {:ok, [["withdrawn", "process:tightbeam", "raiser-retired"]]} =
             DB.query(
               ctx.db,
               "SELECT status,withdrawnBy,withdrawnReason FROM decision_requests WHERE id=?1",
               [statute_id]
             )
  end

  test "boot recovery withdraws an operator request from an already retired raiser once", ctx do
    request = operator_request(ctx, nil)
    Org.retire(ctx.db, ctx.raiser.session_key, "user:flynn", 60_000)

    assert :ok = Escalation.recover_retired(ctx.db)

    after_first = terminal_row(ctx.db, request.id)

    assert {:ok, [["withdrawn", "process:tightbeam", "raiser-retired", nil, nil, nil, nil]]} =
             after_first

    event_count = withdrawn_event_count(ctx.db, request.id)
    assert event_count == 1

    assert :ok = Escalation.recover_retired(ctx.db)
    assert terminal_row(ctx.db, request.id) == after_first
    assert withdrawn_event_count(ctx.db, request.id) == event_count
  end

  defp session(db, name, owner) do
    Org.create(db, %{
      session_key: "agent:#{name}:app",
      display_name: name,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp assignment(ctx, suffix, opener) do
    id = "asg_#{suffix}"
    opened_by_session = Keyword.get(opener, :opened_by_session)
    opened_by_user = Keyword.get(opener, :opened_by_user)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedBySession,openedAt) VALUES (?1,?2,?3,?4,?5,?6)",
               [
                 id,
                 suffix,
                 ctx.holder.session_key,
                 opened_by_user,
                 opened_by_session,
                 System.system_time(:millisecond)
               ]
             )

    id
  end

  defp operator_request(ctx, assignment_id) do
    params = %{question: "Clear this request?"}
    params = if assignment_id, do: Map.put(params, :assignment, assignment_id), else: params
    Escalation.operator_ask(ctx.db, ask_call(ctx.raiser, params))
  end

  defp ask_call(session, params) do
    %{
      verb: "operator-ask",
      origin: "agent:raiser",
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: params
    }
  end

  defp withdraw_call(session, origin, request_id, reason) do
    %{
      verb: "operator-withdraw",
      origin: origin,
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: %{request: request_id, reason: reason}
    }
  end

  defp terminal_row(db, request_id) do
    DB.query(
      db,
      "SELECT status,withdrawnBy,withdrawnReason,decision,ruledBy,ruledAt,rulingFactId FROM decision_requests WHERE id=?1",
      [request_id]
    )
  end

  defp withdrawn_event_count(db, request_id) do
    Enum.count(EventLog.lifecycle_events(db), fn event ->
      event.kind == "decision_request_withdrawn" and event.subject == request_id
    end)
  end
end
