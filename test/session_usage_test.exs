defmodule Tightbeam.SessionUsageTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, Schema, SessionUsage}

  setup do
    db = :"session_usage_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    session = ensure_main_session(db, "flynn")
    %{db: db, session: session}
  end

  test "normalizes Claude and Codex prompt-usage variants without deriving fields" do
    assert SessionUsage.normalize(%{
             "totalTokens" => 160,
             "inputTokens" => 100,
             "outputTokens" => 20,
             "cachedReadTokens" => 30,
             "cachedWriteTokens" => 10
           }) == %{
             totalTokens: 160,
             inputTokens: 100,
             outputTokens: 20,
             cachedReadTokens: 30,
             cachedWriteTokens: 10
           }

    assert SessionUsage.normalize(%{
             "totalTokens" => 240,
             "inputTokens" => 120,
             "outputTokens" => 40,
             "thoughtTokens" => 50,
             "cachedReadTokens" => 30
           }) == %{
             totalTokens: 240,
             inputTokens: 120,
             outputTokens: 40,
             thoughtTokens: 50,
             cachedReadTokens: 30
           }

    assert SessionUsage.normalize(%{
             "totalTokens" => 9,
             "inputTokens" => 7,
             "outputTokens" => nil,
             "thoughtTokens" => "2",
             "cachedReadTokens" => -1,
             "providerAccount" => "private-sentinel"
           }) == %{totalTokens: 9, inputTokens: 7}

    refute Map.has_key?(SessionUsage.normalize(%{"inputTokens" => 7}), :totalTokens)
    assert SessionUsage.normalize(nil) == %{}
  end

  test "aggregates only counters with complete turn coverage", %{db: db, session: session} do
    first = turn!(db, session.session_key, 1)
    second = turn!(db, session.session_key, 2)

    assert :ok =
             SessionUsage.record(db, first, session.session_key, %{
               totalTokens: 100,
               inputTokens: 60,
               outputTokens: 20,
               thoughtTokens: 5,
               cachedReadTokens: 20
             })

    assert :ok =
             SessionUsage.record(db, second, session.session_key, %{
               totalTokens: 90,
               inputTokens: 50,
               outputTokens: 15,
               cachedReadTokens: 25,
               cachedWriteTokens: 5
             })

    assert SessionUsage.project(db, session.session_key) == %{
             observedTurns: 2,
             totalTokens: 190,
             inputTokens: 110,
             outputTokens: 35,
             cachedReadTokens: 45
           }
  end

  test "same-turn replay is idempotent and a conflicting replay refuses", %{
    db: db,
    session: session
  } do
    turn = turn!(db, session.session_key, 1)
    usage = %{totalTokens: 8, inputTokens: 5, outputTokens: 3}

    assert :ok = SessionUsage.record(db, turn, session.session_key, usage)
    assert :ok = SessionUsage.record(db, turn, session.session_key, usage)

    assert SessionUsage.project(db, session.session_key) == %{
             observedTurns: 1,
             totalTokens: 8,
             inputTokens: 5,
             outputTokens: 3
           }

    assert {:error, %RuntimeError{message: message}} =
             SessionUsage.record(db, turn, session.session_key, %{totalTokens: 9})

    assert message =~ "session usage replay conflict"
  end

  test "absent and invalid usage create no observation", %{db: db, session: session} do
    turn = turn!(db, session.session_key, 1)

    assert :ok = SessionUsage.record(db, turn, session.session_key, nil)
    assert :ok = SessionUsage.record(db, turn, session.session_key, %{"totalTokens" => "8"})
    assert SessionUsage.project(db, session.session_key) == nil
  end

  test "durable and wire projections contain counters only", %{db: db, session: session} do
    turn = turn!(db, session.session_key, 1)

    raw = %{
      "totalTokens" => 15,
      "inputTokens" => 10,
      "outputTokens" => 5,
      "accountId" => "private-account-sentinel",
      "token" => "private-token-sentinel",
      "_meta" => %{"providerPayload" => "private-meta-sentinel"}
    }

    assert :ok = SessionUsage.record(db, turn, session.session_key, raw)

    encoded = SessionUsage.project(db, session.session_key) |> JSON.encode!()
    refute encoded =~ "private-account-sentinel"
    refute encoded =~ "private-token-sentinel"
    refute encoded =~ "private-meta-sentinel"

    assert {:ok, [[15, 10, 5]]} =
             DB.query(
               db,
               "SELECT totalTokens,inputTokens,outputTokens FROM session_usage_observations"
             )
  end

  defp turn!(db, session_key, n) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "usage-message-#{n}",
        origin: "user:flynn",
        prompt: "measure #{n}"
      })

    seq
  end
end
