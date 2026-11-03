defmodule Tightbeam.NeutralTriggerSourceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, Schema, StateResources}
  alias Tightbeam.DB.Txn

  @legacy_source "legacy-human-source"
  @turns_name_regex ~r/^\s*CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:"turns"|`turns`|\[turns\]|turns)(?=\s|\()/i
  @trigger_source_constraint_regex ~r/triggerSource\s+TEXT\s+CHECK\s*\(\s*triggerSource\s+IS\s+NULL\s+OR\s+triggerSource\s+IN\s*\(([^)]*)\)\s*\)/i

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)

    :ok =
      DB.execute(name, """
      INSERT INTO sessions
        (sessionKey, displayName, ownerUserId, origin, archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('k1', 'K1', 'fixture-owner', 'user:fixture-owner', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1),
        ('k2', 'K2', 'fixture-owner', 'user:fixture-owner', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1);
      """)

    %{db: name}
  end

  test "stores and serves the neutral human value while preserving explicit batch", %{db: db} do
    human_seq = enqueue!(db, "k1", "human turn")
    batch_seq = enqueue!(db, "k2", "batch turn", trigger_source: "batch")

    assert {:ok, [["human"]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [human_seq])

    assert StateResources.turn(StateResources.query_turn_by_seq(db, human_seq))["triggerSource"] ==
             "human"

    assert {:ok, [["batch"]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [batch_seq])

    assert StateResources.turn(StateResources.query_turn_by_seq(db, batch_seq))["triggerSource"] ==
             "batch"
  end

  test "normalizes a historical constrained source and keeps old turns human-readable", %{
    db: db
  } do
    seq = enqueue!(db, "k1", "historical human turn")
    install_legacy_turns_table!(db, :constrained)

    assert {:ok, [[@legacy_source]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [seq])

    assert :ok = Schema.ensure_neutral_turn_trigger_source(db)

    assert {:ok, [["human"]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [seq])

    assert StateResources.turn(StateResources.query_turn_by_seq(db, seq))["triggerSource"] ==
             "human"

    next_seq = enqueue!(db, "k2", "new human turn")

    assert {:ok, [["human"]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [next_seq])

    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  test "normalizes historical values on older tables without a source constraint", %{db: db} do
    seq = enqueue!(db, "k1", "unconstrained historical human turn")
    install_legacy_turns_table!(db, :unconstrained)

    assert {:ok, [[@legacy_source]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [seq])

    assert :ok = Schema.ensure_neutral_turn_trigger_source(db)

    assert {:ok, [["human"]]} =
             DB.query(db, "SELECT triggerSource FROM turns WHERE seq=?1", [seq])

    assert StateResources.turn(StateResources.query_turn_by_seq(db, seq))["triggerSource"] ==
             "human"

    assert {:ok, []} =
             DB.query(db, "UPDATE turns SET triggerSource=NULL WHERE seq=?1", [seq])

    assert StateResources.turn(StateResources.query_turn_by_seq(db, seq))["triggerSource"] ==
             "human"
  end

  defp enqueue!(db, session_key, prompt, opts \\ []) do
    attrs = %{
      session_key: session_key,
      message_id: "message-#{System.unique_integer([:positive])}",
      origin: "user:fixture-owner",
      prompt: prompt
    }

    attrs =
      case Keyword.fetch(opts, :trigger_source) do
        {:ok, source} -> Map.put(attrs, :trigger_source, source)
        :error -> attrs
      end

    {:ok, seq} = Ledger.enqueue(db, attrs)

    seq
  end

  defp install_legacy_turns_table!(db, constraint_mode) do
    {:ok, :ok} =
      DB.migration_transaction(
        db,
        :test_legacy_turn_source,
        ["PRAGMA foreign_keys=OFF", "PRAGMA legacy_alter_table=ON"],
        ["PRAGMA legacy_alter_table=OFF", "PRAGMA foreign_keys=ON"],
        fn txn ->
          [[current_sql]] =
            Txn.q(
              txn,
              "SELECT sql FROM sqlite_master WHERE type='table' AND name='turns'"
            )

          index_and_trigger_sql =
            Txn.q(
              txn,
              """
              SELECT sql FROM sqlite_master
              WHERE tbl_name='turns' AND sql IS NOT NULL AND type IN ('index','trigger')
              ORDER BY type,name
              """
            )
            |> Enum.map(&hd/1)

          legacy_sql =
            case constraint_mode do
              :constrained ->
                Regex.replace(
                  @trigger_source_constraint_regex,
                  current_sql,
                  "triggerSource TEXT CHECK (triggerSource IS NULL OR triggerSource IN ('batch','#{@legacy_source}','agent','process','other'))",
                  global: false
                )

              :unconstrained ->
                Regex.replace(
                  @trigger_source_constraint_regex,
                  current_sql,
                  "triggerSource TEXT",
                  global: false
                )
            end
            |> Regex.replace(
              @turns_name_regex,
              "CREATE TABLE turns_legacy_test",
              global: false
            )

          :ok = Txn.exec(txn, legacy_sql)

          columns =
            Txn.q(txn, "PRAGMA table_info(turns)")
            |> Enum.map(fn [_cid, name | _rest] -> name end)

          quoted_columns = Enum.map(columns, &quote_identifier/1)
          column_list = Enum.join(quoted_columns, ",")

          selected_columns =
            Enum.map(columns, fn
              "triggerSource" ->
                "CASE WHEN triggerSource='human' AND origin LIKE 'user:%' THEN '#{@legacy_source}' ELSE triggerSource END"

              column ->
                quote_identifier(column)
            end)
            |> Enum.join(",")

          Txn.q(
            txn,
            "INSERT INTO turns_legacy_test (#{column_list}) SELECT #{selected_columns} FROM turns"
          )

          :ok = Txn.exec(txn, "DROP TABLE turns")
          :ok = Txn.exec(txn, "ALTER TABLE turns_legacy_test RENAME TO turns")
          Enum.each(index_and_trigger_sql, &Txn.exec(txn, &1))
          :ok
        end
      )
  end

  defp quote_identifier(identifier),
    do: "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""
end
