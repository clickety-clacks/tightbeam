defmodule Tightbeam.AdjudicationTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{Adjudication, DB, Ledger, Org, Wakes}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})

    :ok = Tightbeam.Schema.ensure_all(name)

    owner =
      Org.create(name, %{
        session_key: "owner",
        display_name: "Owner",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "local",
        harness: "codex",
        provider: "openai",
        model: Model.new("owner-model")
      })

    holder =
      Org.create(name, %{
        session_key: "holder",
        display_name: "Holder",
        owner_user_id: "flynn",
        origin: "agent:owner",
        spawned_by: owner.session_key,
        archetype: "default",
        host: "local",
        harness: "codex",
        provider: "openai",
        model: Model.new("dead-model")
      })

    %{db: name, holder: holder, owner: owner}
  end

  test "claim and notify are guarded CAS transitions with a deterministic owner wake", ctx do
    {:ok, episode} =
      DB.transaction(ctx.db, fn txn ->
        episode =
          Adjudication.claim_in_txn(txn, ctx.holder.session_key, "other",
            claim_window_ms: 300_000
          )

        assert is_binary(episode.correlation_key)
        episode
      end)

    {:ok, {:ok, wake_id, "owner"}} =
      DB.transaction(ctx.db, fn txn ->
        Adjudication.notify_in_txn(txn, episode, "adjudicate", 86_400_000)
      end)

    assert Adjudication.get(ctx.db, "holder", "other").status == "notified"
    assert Wakes.get(ctx.db, wake_id).session_key == "owner"

    assert {:ok, nil} =
             DB.transaction(ctx.db, fn txn ->
               Adjudication.claim_in_txn(txn, "holder", "other", claim_window_ms: 300_000)
             end)
  end

  test "the unanswered-escalation re-notify names the precise cause, not just the condition",
       ctx do
    cause = "adapter_fault:claude:shared@testhost"

    {:ok, episode} =
      DB.transaction(ctx.db, fn txn ->
        episode =
          Adjudication.claim_in_txn(txn, ctx.holder.session_key, "other",
            claim_window_ms: 300_000,
            reresolve_seed: ctx.holder.session_key,
            reresolve_rung: 1,
            cause: cause
          )

        {:ok, _wake_id, _target} = Adjudication.notify_in_txn(txn, episode, "the brief", 0)
        Adjudication.get_in_txn(txn, ctx.holder.session_key, "other")
      end)

    # The original brief's wake is gone, so escalate_due falls back to composing
    # its own text — the path that used to say only "(other)".
    {:ok, _} = DB.query(ctx.db, "DELETE FROM wakes WHERE wakeId=?1", [episode.owner_wake_id])
    :ok = Adjudication.escalate_due(ctx.db, 86_400_000)

    escalated = Adjudication.get(ctx.db, ctx.holder.session_key, "other")
    assert escalated.owner_wake_id != episode.owner_wake_id
    prompt = Wakes.get(ctx.db, escalated.owner_wake_id).prompt

    # The cause the record already holds must reach the human who decides.
    assert prompt =~ "cause=#{cause}"
    assert prompt =~ "condition=other"

    # And it must not regress to a generic string that names the bucket alone.
    refute prompt =~ "(other)"
  end

  test "retirement drain cancels queued turns and uses the normal publication feed", ctx do
    for {id, wake_id} <- [{"m1", nil}, {"m2", "recovery"}] do
      assert {:ok, _} =
               Ledger.enqueue(ctx.db, %{
                 session_key: ctx.holder.session_key,
                 message_id: id,
                 wake_id: wake_id,
                 origin: "user:flynn",
                 prompt: id
               })
    end

    {:ok, seqs} =
      DB.transaction(ctx.db, fn txn ->
        Org.retire_in_txn(txn, ctx.holder.session_key)

        Ledger.drain_queued_for_retire_in_txn(
          txn,
          ctx.holder.session_key,
          "retired: test"
        )
      end)

    assert length(seqs) == 2
    assert :none = Ledger.claim_next(ctx.db, ctx.holder.session_key, "lane")

    assert Enum.map(Ledger.unpublished_terminals(ctx.db), & &1.status) == [
             "canceled",
             "canceled"
           ]
  end
end
