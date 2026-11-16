defmodule Tightbeam.UnresponsiveBounceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Model, Org}

  setup do
    db = :"unresponsive_bounce_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    sender = ensure_main_session(db, "flynn")

    Org.create(db, %{
      session_key: "agent:unresponsive:recipient",
      display_name: "Recipient",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    %{db: db, sender: sender.session_key, target: "agent:unresponsive:recipient"}
  end

  test "a parked recipient leaves the source queued and bounces to its sender once", ctx do
    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO harness_park_fences(adapterKey,requestedAt) VALUES('claude:shared@testhost',1)"
             )

    deliver = fn ->
      DB.transaction(ctx.db, fn txn ->
        Gateway.deliver_prompt_in_txn(
          txn,
          ctx.target,
          "user:flynn",
          "Please read this",
          wake_id: "w_unresponsive_source"
        )
      end)
    end

    assert {:ok, first} = deliver.()
    assert match?({:staged, _}, first) or match?({:appended, _, _, _}, first)
    assert {:ok, _duplicate} = deliver.()

    assert {:ok, [[notice, sender, "pending"]]} =
             DB.query(
               ctx.db,
               "SELECT prompt,sessionKey,state FROM wakes WHERE wakeId LIKE 'w_unresponsive_%' AND wakeId!='w_unresponsive_source'"
             )

    assert sender == ctx.sender
    assert notice =~ "has not been read yet"
    assert notice =~ "harness is parked"
    assert notice =~ "original message remains queued"

    case first do
      {:staged, source} -> assert source.state == "pending"
      {:appended, _, _, _} ->
        assert {:ok, [["queued"]]} =
                 DB.query(ctx.db, "SELECT status FROM turns WHERE wakeId='w_unresponsive_source'")
    end
  end
end
