defmodule Tightbeam.ProviderAccountsUpgradeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Credentials, DB, ProviderAccounts, Schema, StateResources}

  @host "test-host"
  # The second fixture is the same synthetic 0.1.16 DB opened by Schema.ensure_all/1
  # at 3123c3cb (pre-account 0.1.17 source), then dumped from SQLite.
  @fixtures [
    {"published_0_1_16_4283.sql.gz.b64", "artifact-process-attribution-v1-015"},
    {"pre_account_3123c3cb.sql.gz.b64", "holder-role-provenance-v1-0118"}
  ]

  for {fixture, stamp} <- @fixtures do
    test "upgrades #{fixture} and records the existing login without changing its files" do
      db = start_supervised!({DB, path: ":memory:", name: :provider_accounts_upgrade})
      load_predecessor(db, unquote(fixture))
      assert DB.query(db, "SELECT shape FROM schema_stamp") == {:ok, [[unquote(stamp)]]}
      refute "accountId" in turn_columns(db)
      {:ok, [_ | _] = original_turns} = DB.query(db, "SELECT seq, status FROM turns ORDER BY seq")

      base_dir = Path.join(System.tmp_dir!(), "account-upgrade-#{Tightbeam.Id.uuid4()}")
      on_exit(fn -> File.rm_rf!(base_dir) end)

      codex = store_fixture(base_dir, :openai, %{"kind" => "api_key"})

      claude =
        store_fixture(base_dir, :anthropic, %{"kind" => "subscription", "onboarded_at_ms" => 42})

      snapshot = credential_files([codex, claude])

      assert :ok = Schema.ensure_all(db)
      assert ProviderAccounts.list(db) == []
      assert DB.query(db, "SELECT seq,status FROM turns ORDER BY seq") == {:ok, original_turns}
      assert DB.query(db, "SELECT seq FROM turns WHERE accountId IS NOT NULL") == {:ok, []}

      start_owner(db, base_dir)

      assert [claude_account, codex_account] = ProviderAccounts.list(db)
      assert claude_account["harness"] == "claude"
      assert claude_account["kind"] == "subscription"
      assert claude_account["signedInAt"] == 42
      assert codex_account["harness"] == "codex"
      assert codex_account["kind"] == "api_key"
      assert codex_account["signedInAt"] == nil

      for account <- [claude_account, codex_account] do
        assert %{
                 "id" => "acct_" <> _,
                 "host" => @host,
                 "slot" => "shared",
                 "label" => "default",
                 "loginState" => "signed_in",
                 "loginReason" => nil,
                 "identityKey" => nil,
                 "identityReason" => "legacy_identity_unread",
                 "enabled" => true
               } = account

        id = account["id"]
        assert ProviderAccounts.get(db, id) == account

        assert StateResources.provider_account(
                 Map.put(account, "email", "fixture@example.invalid")
               ) ==
                 account

        assert %{"accountId" => ^id, "revision" => 1, "reason" => "initial"} =
                 serving = ProviderAccounts.serving(db, account["harness"], @host)

        assert StateResources.account_serving(serving) == serving
        assert ProviderAccounts.limits(db, id) == []
      end

      assert credential_files([codex, claude]) == snapshot
      assert :ok = stop_supervised(Credentials)
      assert :ok = Schema.ensure_all(db)
      start_owner(db, base_dir)
      assert ProviderAccounts.list(db) == [claude_account, codex_account]
      assert credential_files([codex, claude]) == snapshot
      assert DB.query(db, "PRAGMA foreign_key_check") == {:ok, []}
    end
  end

  defp load_predecessor(db, filename) do
    bytes =
      Path.join([__DIR__, "fixtures", filename])
      |> File.read!()
      |> String.trim()
      |> Base.decode64!()
      |> :zlib.gunzip()

    assert :ok = DB.execute(db, "DROP TABLE pending_recognition_waits")
    assert :ok = DB.execute(db, "DROP TABLE pending_recognition")
    assert :ok = DB.execute(db, bytes)
    assert :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
  end

  defp turn_columns(db) do
    {:ok, columns} = DB.query(db, "PRAGMA table_info(turns)")
    Enum.map(columns, &Enum.at(&1, 1))
  end

  defp store_fixture(base_dir, provider, metadata) do
    path = Credentials.credential_path(base_dir, @host, provider)
    marker = Path.join([Path.dirname(path), ".tightbeam", "credential.json"])
    File.mkdir_p!(Path.dirname(marker))
    File.write!(path, ~s({"fixture":"synthetic-test-value"}))
    File.chmod!(path, 0o600)
    File.write!(marker, JSON.encode!(metadata))
    [path, marker]
  end

  defp credential_files(paths) do
    for path <- List.flatten(paths) do
      %{inode: inode, mode: mode, mtime: mtime, type: :regular} = File.lstat!(path)
      {path, File.read!(path), inode, mode, mtime}
    end
  end

  defp start_owner(db, base_dir) do
    worker =
      start_supervised!(
        {Credentials,
         name: :provider_account_fixture,
         machine: @host,
         base_dir: base_dir,
         provider_accounts_db: db,
         onboarders: %{},
         stop: fn _ -> flunk("upgrade must not stop a harness") end,
         start: fn _, _ -> flunk("upgrade must not start a harness") end,
         sh: fn _ -> flunk("upgrade must not open a subprocess to inspect local credentials") end}
      )

    # The credential owner serializes the backfill before serving calls.
    assert Credentials.kind(:openai, worker) == :api_key
  end
end
