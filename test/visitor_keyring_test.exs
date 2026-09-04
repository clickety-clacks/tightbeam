defmodule Tightbeam.Visitor.KeyringTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Boot, DB}
  alias Tightbeam.Visitor.Keyring
  alias Tightbeam.Visitor.Keyring.UnavailableError

  @derivation :binary.copy(<<0x11>>, 32)
  @digest :binary.copy(<<0x22>>, 32)
  @derivation_id "vdk_test"
  @digest_id "vgk_test"
  @retained_derivation :binary.copy(<<0x33>>, 32)
  @retained_digest :binary.copy(<<0x44>>, 32)
  @retained_derivation_id "vdk_retained"
  @retained_digest_id "vgk_retained"
  @current_previsitor_schema "coordination-fabric-v1-phase1-v17"
  @composable_previsitor_schema "coordination-fabric-v1-phase1-v16"
  @migratable_previsitor_schema "coordination-fabric-v1-phase1-v15"

  setup do
    base = Path.join(System.tmp_dir!(), "tightbeam-keyring-#{System.unique_integer([:positive])}")
    secrets = Path.join(base, "secrets")
    File.mkdir_p!(secrets)
    File.chmod!(secrets, 0o700)

    on_exit(fn ->
      :persistent_term.erase({Keyring, :loaded})
      File.rm_rf!(base)
      File.rm_rf!(base <> "-restore")
      File.rm_rf!(base <> "-missing-keyring")
    end)

    %{base: base, secrets: secrets, path: Path.join(secrets, "visitor-keyring-v1.json")}
  end

  test "A18 restart reloads exact keys and preserves deterministic derivation and digest separation",
       ctx do
    write_keyring(ctx.path)
    uid = File.stat!(ctx.secrets).uid
    first = Keyring.load!(ctx.base, expected_uid: uid)
    second = Keyring.load!(ctx.base, expected_uid: uid)

    invitation = Keyring.derive_invitation_credential(first, "vi_exact", 1)
    access = Keyring.derive_access_credential(first, "vas_exact", 1)

    persisted = %{
      derivation_key_id: @derivation_id,
      digest_key_id: @digest_id,
      invitation_digest: Keyring.credential_digest(first, invitation),
      access_digest: Keyring.credential_digest(first, access)
    }

    assert invitation == Keyring.derive_invitation_credential(second, "vi_exact", 1)
    assert access == Keyring.derive_access_credential(second, "vas_exact", 1)
    assert persisted.invitation_digest == Keyring.credential_digest(second, invitation)
    assert persisted.access_digest == Keyring.credential_digest(second, access)
    assert String.starts_with?(invitation, "tbi_")
    assert String.starts_with?(access, "tbv_")

    expected_invitation =
      "tbi_" <>
        Base.url_encode64(
          :crypto.mac(
            :hmac,
            :sha256,
            @derivation,
            "tightbeam/visitor-invitation-credential/v1\0vi_exact\01"
          ),
          padding: false
        )

    assert invitation == expected_invitation

    assert Keyring.credential_digest(first, invitation) ==
             :crypto.mac(:hmac, :sha256, @digest, invitation)

    refute Keyring.credential_digest(first, invitation) ==
             :crypto.mac(:hmac, :sha256, @derivation, invitation)
  end

  test "A18 a database and keyring backup pair restores byte-identical retry results", ctx do
    write_keyring(ctx.path)
    uid = File.stat!(ctx.secrets).uid
    original = Keyring.load!(ctx.base, expected_uid: uid)
    original_credential = Keyring.derive_access_credential(original, "vas_backup", "v1")
    original_digest = Keyring.credential_digest(original, original_credential)

    restore_base = ctx.base <> "-restore"
    restore_secrets = Path.join(restore_base, "secrets")
    File.mkdir_p!(restore_secrets)
    File.chmod!(restore_secrets, 0o700)
    File.cp!(ctx.path, Path.join(restore_secrets, "visitor-keyring-v1.json"))
    File.chmod!(Path.join(restore_secrets, "visitor-keyring-v1.json"), 0o600)
    on_exit(fn -> File.rm_rf!(restore_base) end)

    restored = Keyring.load!(restore_base, expected_uid: File.stat!(restore_secrets).uid)
    assert Keyring.derive_access_credential(restored, "vas_backup", "v1") == original_credential
    assert Keyring.credential_digest(restored, original_credential) == original_digest
  end

  test "A18 absent referenced keys expose only the missing id and never key material", ctx do
    write_keyring(ctx.path)
    uid = File.stat!(ctx.secrets).uid

    assert {:error, %UnavailableError{} = error} =
             Keyring.load(ctx.base,
               expected_uid: uid,
               referenced_derivation_key_ids: ["vdk_retired"]
             )

    assert Exception.message(error) ==
             "visitor_keyring_unavailable (missing key id: vdk_retired)"

    refute Exception.message(error) =~ Base.encode64(@derivation)
    refute inspect(error) =~ Base.encode64(@digest)
  end

  test "A18 referenced ids must retain the database-declared key purpose", ctx do
    keys =
      complete_keys()
      |> Map.put(@retained_derivation_id, key(@retained_derivation, "credential-digest"))

    write_keyring(ctx.path, keyring_json(keys: keys))
    uid = File.stat!(ctx.secrets).uid

    assert {:error, %UnavailableError{} = error} =
             Keyring.load(ctx.base,
               expected_uid: uid,
               referenced_derivation_key_ids: [@retained_derivation_id],
               referenced_digest_key_ids: [@retained_digest_id]
             )

    assert Exception.message(error) ==
             "visitor_keyring_unavailable (missing key id: #{@retained_derivation_id})"
  end

  test "A18 Boot reloads and restores a database/keyring pair with typed referenced keys", ctx do
    write_keyring(ctx.path, keyring_json(keys: complete_keys()))
    uid = File.stat!(ctx.secrets).uid
    seed = Keyring.load!(ctx.base, expected_uid: uid)

    invitation =
      Keyring.derive_invitation_credential(
        seed,
        "vi_boot",
        "v1",
        @retained_derivation_id
      )

    access =
      Keyring.derive_access_credential(seed, "vas_boot", "v1", @retained_derivation_id)

    db_path = Path.join(ctx.base, "state.db")
    db = start_reference_db(db_path, "original")
    insert_reference_rows(db, seed, invitation, access)

    assert :ok = Boot.load_visitor_keyring!(ctx.base, db, phase: :after_schema)
    first = Keyring.current!()
    assert_authenticates(db, first, invitation, access)

    GenServer.stop(db)
    backup_base = ctx.base <> "-restore"
    backup_secrets = Path.join(backup_base, "secrets")
    File.mkdir_p!(backup_secrets)
    File.chmod!(backup_secrets, 0o700)
    File.cp!(db_path, Path.join(backup_base, "state.db"))
    File.cp!(ctx.path, Path.join(backup_secrets, "visitor-keyring-v1.json"))
    File.chmod!(Path.join(backup_secrets, "visitor-keyring-v1.json"), 0o600)

    restarted = start_reference_db(db_path, "restart")
    assert :ok = Boot.load_visitor_keyring!(ctx.base, restarted, phase: :after_schema)
    second = Keyring.current!()
    assert_authenticates(restarted, second, invitation, access)

    assert Keyring.derive_invitation_credential(second, "vi_boot", "v1", @retained_derivation_id) ==
             invitation

    assert Keyring.derive_access_credential(second, "vas_boot", "v1", @retained_derivation_id) ==
             access

    restored = start_reference_db(Path.join(backup_base, "state.db"), "restore")
    assert :ok = Boot.load_visitor_keyring!(backup_base, restored, phase: :after_schema)
    restored_keyring = Keyring.current!()
    assert_authenticates(restored, restored_keyring, invitation, access)

    missing_base = ctx.base <> "-missing-keyring"
    File.mkdir_p!(missing_base)
    missing_db_path = Path.join(missing_base, "state.db")
    GenServer.stop(restored)
    File.cp!(Path.join(backup_base, "state.db"), missing_db_path)
    missing_db = start_reference_db(missing_db_path, "missing")

    assert_raise UnavailableError, ~r/visitor_keyring_unavailable/, fn ->
      Boot.load_visitor_keyring!(missing_base, missing_db, phase: :after_schema)
    end

    GenServer.stop(missing_db)

    wrong_purpose_keys =
      complete_keys()
      |> Map.put(@retained_derivation_id, key(@retained_derivation, "credential-digest"))

    write_keyring(ctx.path, keyring_json(keys: wrong_purpose_keys))

    assert_raise UnavailableError, ~r/#{@retained_derivation_id}/, fn ->
      Boot.load_visitor_keyring!(ctx.base, restarted, phase: :after_schema)
    end

    write_keyring(
      ctx.path,
      keyring_json(keys: Map.delete(complete_keys(), @retained_digest_id))
    )

    assert_raise UnavailableError, ~r/#{@retained_digest_id}/, fn ->
      Boot.load_visitor_keyring!(ctx.base, restarted, phase: :after_schema)
    end

    GenServer.stop(restarted)
  end

  test "A18 Boot refuses an unknown schema stamp before it can load a keyring", ctx do
    write_keyring(ctx.path)
    name = :"visitor_keyring_unknown_#{System.unique_integer([:positive])}"
    {:ok, db} = DB.start_link(path: Path.join(ctx.base, "unknown.db"), name: name)
    :ok = DB.execute(db, "CREATE TABLE schema_stamp (shape TEXT PRIMARY KEY, stampedAt INTEGER)")

    {:ok, []} =
      DB.query(db, "INSERT INTO schema_stamp (shape, stampedAt) VALUES (?1, 0)", [
        "unknown-schema-v1"
      ])

    assert_raise UnavailableError, ~r/database_references/, fn ->
      Boot.load_visitor_keyring!(ctx.base, db, phase: :before_schema)
    end

    GenServer.stop(db)
  end

  test "A18 Boot refuses the captured v5 database when current schema has no predecessor migration",
       ctx do
    write_keyring(ctx.path)
    source = Path.join([__DIR__, "fixtures", "cold_start", "v5-healthy", "state.db"])
    target = Path.join(ctx.base, "captured-v5.db")
    File.cp!(source, target)
    db = start_db(target, "captured_v5")

    assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    assert_raise UnavailableError, ~r/database_references/, fn ->
      Boot.load_visitor_keyring!(ctx.base, db, phase: :before_schema)
    end

    assert_raise Tightbeam.Schema.ShapeError, ~r/There is no migration/, fn ->
      Boot.ensure_schema!(db)
    end

    assert {:ok, [["coordination-fabric-v1-phase1-v5"]]} =
             DB.query(db, "SELECT shape FROM schema_stamp")

    GenServer.stop(db)
  end

  test "A18 Boot admits only the exact current previsitor schema", ctx do
    write_keyring(ctx.path)

    Enum.each(
      ["coordination-fabric-v1-phase1-v14", "coordination-fabric-v1-phase1-v8"],
      fn shape ->
        db = start_stamped_db(ctx.base, shape)

        assert_raise UnavailableError, ~r/database_references/, fn ->
          Boot.load_visitor_keyring!(ctx.base, db, phase: :before_schema)
        end

        GenServer.stop(db)
      end
    )

    current = start_stamped_db(ctx.base, @current_previsitor_schema)
    assert :ok = Boot.load_visitor_keyring!(ctx.base, current, phase: :before_schema)
    assert :ok = Boot.load_visitor_keyring!(ctx.base, current, phase: :after_schema)
    GenServer.stop(current)

    composable = start_stamped_db(ctx.base, @composable_previsitor_schema)
    assert :ok = Boot.load_visitor_keyring!(ctx.base, composable, phase: :before_schema)

    assert_raise UnavailableError, ~r/database_references/, fn ->
      Boot.load_visitor_keyring!(ctx.base, composable, phase: :after_schema)
    end

    GenServer.stop(composable)

    migratable = start_stamped_db(ctx.base, @migratable_previsitor_schema)
    assert :ok = Boot.load_visitor_keyring!(ctx.base, migratable, phase: :before_schema)

    assert_raise UnavailableError, ~r/database_references/, fn ->
      Boot.load_visitor_keyring!(ctx.base, migratable, phase: :after_schema)
    end

    GenServer.stop(migratable)
  end

  test "A18 missing pair half, symlink, wrong owner, and unsafe modes all refuse one redacted class",
       ctx do
    uid = File.stat!(ctx.secrets).uid
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))

    outside = Path.join(ctx.base, "outside.json")
    write_keyring(outside)
    File.ln_s!(outside, ctx.path)
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))
    File.rm!(ctx.path)

    outside_directory = Path.join(ctx.base, "outside-secrets")
    File.mkdir_p!(outside_directory)
    File.chmod!(outside_directory, 0o700)
    write_keyring(Path.join(outside_directory, "visitor-keyring-v1.json"))
    File.rmdir!(ctx.secrets)
    File.ln_s!(outside_directory, ctx.secrets)
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))
    File.rm!(ctx.secrets)
    File.mkdir_p!(ctx.secrets)
    File.chmod!(ctx.secrets, 0o700)

    write_keyring(ctx.path)
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid + 1))

    File.chmod!(ctx.path, 0o640)
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))
    File.chmod!(ctx.path, 0o600)

    File.chmod!(ctx.secrets, 0o750)
    assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))
  end

  test "A18 malformed, duplicate, removed, wrong-purpose, wrong-length, and equal active keys refuse",
       ctx do
    uid = File.stat!(ctx.secrets).uid

    invalid_documents = [
      "not-json",
      duplicate_id_json(),
      keyring_json(keys: %{@digest_id => key(@digest, "credential-digest")}),
      keyring_json(keys: %{@derivation_id => key(@derivation, "credential-derivation")}),
      keyring_json(
        keys: %{
          @derivation_id => key(@derivation, "credential-digest"),
          @digest_id => key(@digest, "credential-digest")
        }
      ),
      keyring_json(
        keys: %{
          @derivation_id => key(@derivation, "credential-digest"),
          @digest_id => key(@digest, "credential-derivation")
        }
      ),
      keyring_json(
        keys: %{
          @derivation_id => key(<<1, 2, 3>>, "credential-derivation"),
          @digest_id => key(@digest, "credential-digest")
        }
      ),
      keyring_json(
        keys: %{
          @derivation_id => key(@derivation, "credential-derivation"),
          @digest_id => key(@derivation, "credential-digest")
        }
      )
    ]

    Enum.each(invalid_documents, fn document ->
      File.write!(ctx.path, document)
      File.chmod!(ctx.path, 0o600)
      assert_unavailable(Keyring.load(ctx.base, expected_uid: uid))
    end)
  end

  test "A18 loaded key material is redacted from inspect and key ids remain available", ctx do
    write_keyring(ctx.path)
    keyring = Keyring.load!(ctx.base)
    rendered = inspect(keyring)

    assert Keyring.key_ids(keyring) == [@derivation_id, @digest_id]
    assert rendered =~ "keys=[redacted]"
    refute rendered =~ Base.encode64(@derivation)
    refute rendered =~ Base.encode64(@digest)
  end

  test "A18 accepts a schema-valid retained-key file larger than one MiB", ctx do
    retained =
      for index <- 1..14_000, into: %{} do
        id = "vdk_archive_#{String.pad_leading(Integer.to_string(index), 5, "0")}"
        {id, key(<<index::unsigned-size(256)>>, "credential-derivation")}
      end

    keys = Map.merge(complete_keys(), retained)
    write_keyring(ctx.path, keyring_json(keys: keys))
    assert File.stat!(ctx.path).size > 1_048_576
    assert %Keyring{} = Keyring.load!(ctx.base)
  end

  defp assert_unavailable({:error, %UnavailableError{} = error}) do
    assert Exception.message(error) == "visitor_keyring_unavailable (validation)"
    refute Exception.message(error) =~ Base.encode64(@derivation)
    refute Exception.message(error) =~ Base.encode64(@digest)
  end

  defp write_keyring(path, contents \\ nil) do
    File.write!(path, contents || keyring_json())
    File.chmod!(path, 0o600)
  end

  defp complete_keys do
    %{
      @derivation_id => key(@derivation, "credential-derivation"),
      @digest_id => key(@digest, "credential-digest"),
      @retained_derivation_id => key(@retained_derivation, "credential-derivation"),
      @retained_digest_id => key(@retained_digest, "credential-digest")
    }
  end

  defp keyring_json(overrides \\ []) do
    keys =
      Keyword.get(overrides, :keys, %{
        @derivation_id => key(@derivation, "credential-derivation"),
        @digest_id => key(@digest, "credential-digest")
      })

    JSON.encode!(%{
      "schema" => "visitor-keyring-v1",
      "activeDerivationKeyId" => @derivation_id,
      "activeDigestKeyId" => @digest_id,
      "keys" => keys
    })
  end

  defp key(bytes, purpose), do: %{"purpose" => purpose, "bytesBase64" => Base.encode64(bytes)}

  defp duplicate_id_json do
    encoded_derivation = Base.encode64(@derivation)
    encoded_digest = Base.encode64(@digest)

    ~s({"schema":"visitor-keyring-v1","activeDerivationKeyId":"#{@derivation_id}","activeDigestKeyId":"#{@digest_id}","keys":{"#{@derivation_id}":{"purpose":"credential-derivation","bytesBase64":"#{encoded_derivation}"},"#{@derivation_id}":{"purpose":"credential-derivation","bytesBase64":"#{encoded_derivation}"},"#{@digest_id}":{"purpose":"credential-digest","bytesBase64":"#{encoded_digest}"}}})
  end

  defp start_reference_db(path, suffix) do
    db = start_db(path, suffix)

    if suffix == "original" do
      :ok =
        DB.execute(db, "CREATE TABLE schema_stamp (shape TEXT PRIMARY KEY, stampedAt INTEGER)")

      {:ok, []} =
        DB.query(db, "INSERT INTO schema_stamp (shape, stampedAt) VALUES (?1, 0)", [
          "visitor-principal-v3-v1"
        ])

      :ok =
        DB.execute(
          db,
          "CREATE TABLE visitor_invitations (invitationId TEXT PRIMARY KEY, derivationKeyId TEXT NOT NULL, digestKeyId TEXT NOT NULL, credentialDigest BLOB NOT NULL)"
        )

      :ok =
        DB.execute(
          db,
          "CREATE TABLE visitor_access_sessions (accessSessionId TEXT PRIMARY KEY, derivationKeyId TEXT NOT NULL, digestKeyId TEXT NOT NULL, credentialDigest BLOB NOT NULL)"
        )
    end

    db
  end

  defp start_stamped_db(base, shape) do
    path = Path.join(base, "#{shape}-#{System.unique_integer([:positive])}.db")
    db = start_db(path, "stamped")
    :ok = DB.execute(db, "CREATE TABLE schema_stamp (shape TEXT PRIMARY KEY, stampedAt INTEGER)")

    {:ok, []} =
      DB.query(db, "INSERT INTO schema_stamp (shape, stampedAt) VALUES (?1, 0)", [shape])

    db
  end

  defp start_db(path, suffix) do
    name = :"visitor_keyring_#{suffix}_#{System.unique_integer([:positive])}"
    {:ok, db} = DB.start_link(path: path, name: name)
    db
  end

  defp insert_reference_rows(db, keyring, invitation, access) do
    {:ok, []} =
      DB.query(
        db,
        "INSERT INTO visitor_invitations (invitationId, derivationKeyId, digestKeyId, credentialDigest) VALUES (?1, ?2, ?3, ?4)",
        [
          "vi_boot",
          @retained_derivation_id,
          @retained_digest_id,
          Keyring.credential_digest(keyring, invitation, @retained_digest_id)
        ]
      )

    {:ok, []} =
      DB.query(
        db,
        "INSERT INTO visitor_access_sessions (accessSessionId, derivationKeyId, digestKeyId, credentialDigest) VALUES (?1, ?2, ?3, ?4)",
        [
          "vas_boot",
          @retained_derivation_id,
          @retained_digest_id,
          Keyring.credential_digest(keyring, access, @retained_digest_id)
        ]
      )
  end

  defp assert_authenticates(db, keyring, invitation, access) do
    {:ok, [[invitation_digest]]} =
      DB.query(
        db,
        "SELECT credentialDigest FROM visitor_invitations WHERE invitationId='vi_boot'"
      )

    {:ok, [[access_digest]]} =
      DB.query(
        db,
        "SELECT credentialDigest FROM visitor_access_sessions WHERE accessSessionId='vas_boot'"
      )

    assert Keyring.credential_digest(keyring, invitation, @retained_digest_id) ==
             invitation_digest

    assert Keyring.credential_digest(keyring, access, @retained_digest_id) == access_digest
  end
end
