defmodule Tightbeam.Visitor.KeyringTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Visitor.Keyring
  alias Tightbeam.Visitor.Keyring.UnavailableError

  @derivation :binary.copy(<<0x11>>, 32)
  @digest :binary.copy(<<0x22>>, 32)
  @derivation_id "vdk_test"
  @digest_id "vgk_test"

  setup do
    base = Path.join(System.tmp_dir!(), "tightbeam-keyring-#{System.unique_integer([:positive])}")
    secrets = Path.join(base, "secrets")
    File.mkdir_p!(secrets)
    File.chmod!(secrets, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)
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
             Keyring.load(ctx.base, expected_uid: uid, referenced_key_ids: ["vdk_retired"])

    assert Exception.message(error) ==
             "visitor_keyring_unavailable (missing key id: vdk_retired)"

    refute Exception.message(error) =~ Base.encode64(@derivation)
    refute inspect(error) =~ Base.encode64(@digest)
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

  defp assert_unavailable({:error, %UnavailableError{} = error}) do
    assert Exception.message(error) == "visitor_keyring_unavailable (validation)"
    refute Exception.message(error) =~ Base.encode64(@derivation)
    refute Exception.message(error) =~ Base.encode64(@digest)
  end

  defp write_keyring(path) do
    File.write!(path, keyring_json())
    File.chmod!(path, 0o600)
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
end
