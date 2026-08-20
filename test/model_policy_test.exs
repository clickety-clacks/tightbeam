defmodule Tightbeam.ModelPolicyTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ModelPolicy

  @f21_s_b64 "c2NoZW1hX3ZlcnNpb24gPSAxCgpbW2NhcHN1bGVzXV0KbW9kZWwgPSAiZ3B0LTUuNi1zb2wiCmRlc2NyaXB0aW9uID0gIkZpeHR1cmUgQS4iCgpbW2NhcHN1bGVzLmZvcm1zXV0KaGFybmVzcyA9ICJjb2RleCIKY29udGV4dCA9ICJkZWZhdWx0IgplZmZvcnRzID0gWyJoaWdoIl0KCltbY2Fwc3VsZXNdXQptb2RlbCA9ICJjbGF1ZGUtb3B1cy00LTgiCmRlc2NyaXB0aW9uID0gIkZpeHR1cmUgQi4iCgpbW2NhcHN1bGVzLmZvcm1zXV0KaGFybmVzcyA9ICJjbGF1ZGUiCmNvbnRleHQgPSAiZGVmYXVsdCIKZWZmb3J0cyA9IFsiaGlnaCJdCgpbW2NhcHN1bGVzXV0KbW9kZWwgPSAiY2xhdWRlLXNvbm5ldC01IgpkZXNjcmlwdGlvbiA9ICJGaXh0dXJlIFguIgoKW1tjYXBzdWxlcy5mb3Jtc11dCmhhcm5lc3MgPSAiY2xhdWRlIgpjb250ZXh0ID0gImRlZmF1bHQiCmVmZm9ydHMgPSBbIm1lZGl1bSJdCgpbW3VzZXNdXQppZCA9ICJmaXh0dXJlLXN1YnN0cmF0ZS1hbnkiCnRpdGxlID0gIkZpeHR1cmUgc3Vic3RyYXRlIGFueSIKd2FudHMgPSAiZXhhY3QgcHJvdmVuYW5jZSIKZmxvb3IgPSAiYW55IgoKW1t1c2VzLm1vZGVsc11dCmhhcm5lc3MgPSAiY29kZXgiCm1vZGVsID0gImdwdC01LjYtc29sIgplZmZvcnQgPSAiaGlnaCIKCltbdXNlcy5tb2RlbHNdXQpoYXJuZXNzID0gImNsYXVkZSIKbW9kZWwgPSAiY2xhdWRlLW9wdXMtNC04IgplZmZvcnQgPSAiaGlnaCIKCltbdXNlc11dCmlkID0gImZpeHR1cmUtc3Vic3RyYXRlLWNsb3NlZCIKdGl0bGUgPSAiRml4dHVyZSBzdWJzdHJhdGUgY2xvc2VkIgp3YW50cyA9ICJleGFjdCBwcm92ZW5hbmNlIgpmbG9vciA9ICJjbG9zZWQiCgpbW3VzZXMubW9kZWxzXV0KaGFybmVzcyA9ICJjb2RleCIKbW9kZWwgPSAiZ3B0LTUuNi1zb2wiCmVmZm9ydCA9ICJoaWdoIgo="
  @f21_k_lf_b64 "c2NoZW1hX3ZlcnNpb24gPSAxCgpbW3VzZXNdXQppZCA9ICJmaXh0dXJlLWt1bmdmdS13b3JraW5nIgp0aXRsZSA9ICJGaXh0dXJlIEt1bmcgRnUgd29ya2luZyIKd2FudHMgPSAiZXhhY3QgcHJvdmVuYW5jZSIKZmxvb3IgPSAid29ya2luZy1zZXQiCgpbW3VzZXMubW9kZWxzXV0KaGFybmVzcyA9ICJjb2RleCIKbW9kZWwgPSAiZ3B0LTUuNi1zb2wiCmVmZm9ydCA9ICJoaWdoIgoKW1t1c2VzXV0KaWQgPSAiZml4dHVyZS1rdW5nZnUtY2xvc2VkIgp0aXRsZSA9ICJGaXh0dXJlIEt1bmcgRnUgY2xvc2VkIgp3YW50cyA9ICJleGFjdCBwcm92ZW5hbmNlIgpmbG9vciA9ICJjbG9zZWQiCgpbW3VzZXMubW9kZWxzXV0KaGFybmVzcyA9ICJjb2RleCIKbW9kZWwgPSAiZ3B0LTUuNi1zb2wiCmVmZm9ydCA9ICJoaWdoIgo="
  @f21_k_crlf_b64 "c2NoZW1hX3ZlcnNpb24gPSAxDQoNCltbdXNlc11dDQppZCA9ICJmaXh0dXJlLWt1bmdmdS13b3JraW5nIg0KdGl0bGUgPSAiRml4dHVyZSBLdW5nIEZ1IHdvcmtpbmciDQp3YW50cyA9ICJleGFjdCBwcm92ZW5hbmNlIg0KZmxvb3IgPSAid29ya2luZy1zZXQiDQoNCltbdXNlcy5tb2RlbHNdXQ0KaGFybmVzcyA9ICJjb2RleCINCm1vZGVsID0gImdwdC01LjYtc29sIg0KZWZmb3J0ID0gImhpZ2giDQoNCltbdXNlc11dDQppZCA9ICJmaXh0dXJlLWt1bmdmdS1jbG9zZWQiDQp0aXRsZSA9ICJGaXh0dXJlIEt1bmcgRnUgY2xvc2VkIg0Kd2FudHMgPSAiZXhhY3QgcHJvdmVuYW5jZSINCmZsb29yID0gImNsb3NlZCINCg0KW1t1c2VzLm1vZGVsc11dDQpoYXJuZXNzID0gImNvZGV4Ig0KbW9kZWwgPSAiZ3B0LTUuNi1zb2wiDQplZmZvcnQgPSAiaGlnaCINCg=="

  @a %{harness: "codex", model: "gpt-5.6-sol", context: nil, effort: "high"}
  @b %{harness: "claude", model: "claude-opus-4-8", context: nil, effort: "high"}
  @x %{harness: "claude", model: "claude-sonnet-5", context: nil, effort: "medium"}
  @y %{harness: "codex", model: "fixture-external-model", context: nil, effort: "high"}

  test "decodes F21 sources byte-exactly and keeps raw provenance outside the semantic hash" do
    substrate = Base.decode64!(@f21_s_b64)
    kungfu_lf = Base.decode64!(@f21_k_lf_b64)
    kungfu_crlf = Base.decode64!(@f21_k_crlf_b64)

    assert byte_size(substrate) == 908
    assert byte_size(kungfu_lf) == 404
    assert byte_size(kungfu_crlf) == 427

    assert ModelPolicy.source_sha256(substrate) ==
             "28e40d7bc4432a57f35ac1bb4a24e14c3885f02518045c3205a4c2a5e25da960"

    assert ModelPolicy.source_sha256(kungfu_lf) ==
             "e899eeedb640a1e59b7a72cf0825f39d15530a58eba672293bc8b6beefab3003"

    assert ModelPolicy.source_sha256(kungfu_crlf) ==
             "d9d5690780d5cf1c8ba0051542fb2e08ec66ff9866a608e5a1d708149225e817"

    lf = compile_f21!(kungfu_lf)
    crlf = compile_f21!(kungfu_crlf)

    assert lf.projection == crlf.projection
    assert lf.canonical_json == crlf.canonical_json
    assert lf.policy_sha256 == crlf.policy_sha256

    lf_source = lf.uses["kungfu:agentic-engineering:fixture-kungfu-working"].source
    crlf_source = crlf.uses["kungfu:agentic-engineering:fixture-kungfu-working"].source

    assert lf.uses["substrate:fixture-substrate-closed"].source == %{
             kind: :substrate,
             name: "substrate",
             path: "guidance/preferred-models.toml",
             sha256: "28e40d7bc4432a57f35ac1bb4a24e14c3885f02518045c3205a4c2a5e25da960"
           }

    assert lf_source == %{
             kind: :kungfu,
             name: "agentic-engineering",
             path: "kungfu/agentic-engineering/preferred-models.toml",
             sha256: "e899eeedb640a1e59b7a72cf0825f39d15530a58eba672293bc8b6beefab3003"
           }

    assert lf_source.sha256 != crlf_source.sha256
  end

  test "semantic projection ignores TOML whitespace and key order while raw hashes remain byte-sensitive" do
    first = """
    schema_version = 1
    [[capsules]]
    model = "model-a"
    description = "A."
    [[capsules.forms]]
    harness = "codex"
    context = "default"
    efforts = ["high"]
    [[uses]]
    id = "use-a"
    title = "Use A"
    wants = "precision"
    floor = "closed"
    [[uses.models]]
    harness = "codex"
    model = "model-a"
    effort = "high"
    """

    second = """
    schema_version=1

    [[capsules]]
    description="A."
    model="model-a"
    [[capsules.forms]]
    efforts=[ "high" ]
    context="default"
    harness="codex"

    [[uses]]
    wants="precision"
    floor="closed"
    title="Use A"
    id="use-a"
    [[uses.models]]
    effort="high"
    model="model-a"
    harness="codex"
    """

    one = compile_source!(first)
    two = compile_source!(second)

    assert one.projection == two.projection
    assert one.policy_sha256 == two.policy_sha256
    refute ModelPolicy.source_sha256(first) == ModelPolicy.source_sha256(second)
  end

  test "policy ids admit numeric-leading canonical segments" do
    substrate = """
    schema_version = 1
    [[capsules]]
    model = "model-a"
    description = "A."
    [[capsules.forms]]
    harness = "codex"
    context = "default"
    efforts = ["high"]
    [[uses]]
    id = "1st-use"
    title = "First use"
    wants = "precision"
    floor = "closed"
    [[uses.models]]
    harness = "codex"
    model = "model-a"
    effort = "high"
    """

    assert {:ok, snapshot} =
             ModelPolicy.compile([
               %{
                 kind: :substrate,
                 name: "substrate",
                 path: "guidance/preferred-models.toml",
                 bytes: substrate
               },
               %{
                 kind: :kungfu,
                 name: "1st-bundle",
                 path: "kungfu/1st-bundle/preferred-models.toml",
                 bytes: "schema_version = 1\n"
               }
             ])

    assert Map.has_key?(snapshot.uses, "substrate:1st-use")
  end

  test "matches listed tuples and each floor exactly" do
    snapshot = compile_f21!(Base.decode64!(@f21_k_lf_b64))
    {:ok, closed} = ModelPolicy.resolve(snapshot, "fixture", "substrate:fixture-substrate-closed")

    {:ok, working} =
      ModelPolicy.resolve(
        snapshot,
        "fixture",
        "kungfu:agentic-engineering:fixture-kungfu-working"
      )

    {:ok, any} = ModelPolicy.resolve(snapshot, "fixture", "substrate:fixture-substrate-any")

    assert ModelPolicy.match(snapshot, closed, @a) ==
             {:ok, %{selection_kind: "listed", rung: 1}}

    assert ModelPolicy.match(snapshot, closed, @x) == {:error, :not_blessed}

    assert ModelPolicy.match(snapshot, closed, %{@a | effort: "medium"}) ==
             {:error, :not_blessed}

    assert ModelPolicy.match(snapshot, working, @a) ==
             {:ok, %{selection_kind: "listed", rung: 1}}

    assert ModelPolicy.match(snapshot, working, @x) ==
             {:ok, %{selection_kind: "working_set_unlisted", rung: nil}}

    assert ModelPolicy.match(snapshot, working, @y) == {:error, :not_blessed}

    assert ModelPolicy.match(snapshot, any, @b) ==
             {:ok, %{selection_kind: "listed", rung: 2}}

    assert ModelPolicy.match(snapshot, any, @y) ==
             {:ok, %{selection_kind: "any_unlisted", rung: 3}}
  end

  test "an override replaces its base rundown and explicit use outranks the default" do
    snapshot =
      compile_f21!(
        Base.decode64!(@f21_k_lf_b64),
        """
        name = "fixture"

        [model_policy]
        default_use = "substrate:fixture-substrate-closed"
        allowed_uses = [
          "substrate:fixture-substrate-closed",
          "substrate:fixture-substrate-any"
        ]

        [[model_policy.rundowns]]
        use = "substrate:fixture-substrate-closed"
        floor = "closed"

        [[model_policy.rundowns.models]]
        harness = "claude"
        model = "claude-opus-4-8"
        effort = "high"
        """
      )

    assert {:ok, default} = ModelPolicy.resolve(snapshot, "fixture")
    assert Enum.map(default.models, & &1.model) == ["claude-opus-4-8"]
    assert default.source.kind == :archetype

    assert {:ok, explicit} =
             ModelPolicy.resolve(snapshot, "fixture", "substrate:fixture-substrate-any")

    assert Enum.map(explicit.models, & &1.model) == ["gpt-5.6-sol", "claude-opus-4-8"]
    assert explicit.source.kind == :substrate

    assert ModelPolicy.resolve(snapshot, "fixture", "Fixture substrate any") ==
             {:error,
              %{
                code: "model_use_denied",
                archetype: "fixture",
                requested_use: "Fixture substrate any",
                allowed_uses: [
                  "substrate:fixture-substrate-any",
                  "substrate:fixture-substrate-closed"
                ]
              }}
  end

  test "A-01 validation refuses malformed schema and orders all errors deterministically" do
    invalid = """
    schema_version = 2
    surprise = true

    [[capsules]]
    model = "model-a"
    nickname = "bad|nick"
    description = "A."
    [[capsules.forms]]
    harness = "codex"
    context = "default"
    efforts = ["high", "high"]

    [[uses]]
    id = "use-a"
    title = "Use A"
    wants = "precision"
    floor = "open"
    [[uses.models]]
    harness = "codex"
    model = "model-a"
    effort = "medium"
    guidance_suffix = " first"
    [[uses.models]]
    harness = "codex"
    model = "model-a"
    effort = "medium"
    guidance_suffix = " second"

    [[uses]]
    id = "use-a"
    title = "Duplicate"
    wants = "precision"
    floor = "closed"
    [[uses.models]]
    harness = "codex"
    model = "missing-model"
    effort = "high"
    """

    assert {:error, errors} =
             ModelPolicy.compile([
               %{
                 kind: :kungfu,
                 name: "later-errors",
                 path: "kungfu/later-errors/preferred-models.toml",
                 bytes: "schema_version = 2\n"
               },
               %{
                 kind: :substrate,
                 name: "substrate",
                 path: "guidance/preferred-models.toml",
                 bytes: invalid
               }
             ])

    assert errors ==
             Enum.sort_by(errors, fn error ->
               {error.source_path, error.qualified_use || "", error.rung_rank || 0, error.field,
                error.message}
             end)

    fields = MapSet.new(errors, & &1.field)
    assert "schema_version" in fields
    assert "surprise" in fields
    assert "capsules.nickname" in fields
    assert "capsules.forms[1].efforts" in fields
    assert "uses.floor" in fields
    assert "models.effort" in fields
    assert "models" in fields
    assert "models.model" in fields
    assert "uses.id" in fields
  end

  test "A-01 refuses capsules in Kung Fu sources" do
    bytes = """
    schema_version = 1
    capsules = []
    """

    assert {:error, errors} =
             ModelPolicy.compile([
               %{
                 kind: :kungfu,
                 name: "agentic-engineering",
                 path: "kungfu/agentic-engineering/preferred-models.toml",
                 bytes: bytes
               }
             ])

    assert Enum.any?(errors, &(&1.field == "capsules" and &1.message =~ "cannot declare"))
  end

  test "A-02 refuses partial overrides and legacy model authorities" do
    manifest = """
    name = "fixture"

    [[model_preferences]]
    model = "gpt-5.6-sol"

    [defaults]
    harness = "codex"
    model = "gpt-5.6-sol"

    [model_policy]
    default_use = "substrate:fixture-substrate-closed"
    allowed_uses = ["substrate:fixture-substrate-closed"]

    [[model_policy.rundowns]]
    use = "substrate:fixture-substrate-closed"
    """

    assert {:error, errors} = compile_f21(Base.decode64!(@f21_k_lf_b64), manifest)
    fields = MapSet.new(errors, & &1.field)
    assert "model_preferences" in fields
    assert "defaults.model" in fields
    assert "model_policy.rundowns.floor" in fields
    assert "models" in fields
  end

  test "A-02 requires one resolvable default and at most one override per allowed use" do
    manifest = """
    name = "fixture"

    [model_policy]
    default_use = "substrate:not-present"
    allowed_uses = [
      "substrate:not-present",
      "substrate:not-present",
      "substrate:fixture-substrate-closed"
    ]

    [[model_policy.rundowns]]
    use = "substrate:fixture-substrate-closed"
    floor = "closed"
    [[model_policy.rundowns.models]]
    harness = "codex"
    model = "gpt-5.6-sol"
    effort = "high"

    [[model_policy.rundowns]]
    use = "substrate:fixture-substrate-closed"
    floor = "closed"
    [[model_policy.rundowns.models]]
    harness = "codex"
    model = "gpt-5.6-sol"
    effort = "high"
    """

    assert {:error, errors} = compile_f21(Base.decode64!(@f21_k_lf_b64), manifest)

    assert Enum.any?(
             errors,
             &(&1.field == "model_policy.default_use" and &1.message =~ "exactly once")
           )

    assert Enum.any?(
             errors,
             &(&1.field == "model_policy.allowed_uses" and
                 &1.qualified_use == "substrate:not-present")
           )

    assert Enum.any?(
             errors,
             &(&1.field == "model_policy.rundowns.use" and &1.message =~ "duplicate override")
           )
  end

  defp compile_f21!(kungfu, manifest \\ manifest()) do
    assert {:ok, snapshot} = compile_f21(kungfu, manifest)
    snapshot
  end

  defp compile_f21(kungfu, manifest) do
    ModelPolicy.compile(
      [
        %{
          kind: :substrate,
          name: "substrate",
          path: "guidance/preferred-models.toml",
          bytes: Base.decode64!(@f21_s_b64)
        },
        %{
          kind: :kungfu,
          name: "agentic-engineering",
          path: "kungfu/agentic-engineering/preferred-models.toml",
          bytes: kungfu
        }
      ],
      [%{name: "fixture", path: "archetypes/fixture.toml", bytes: manifest}]
    )
  end

  defp compile_source!(bytes) do
    assert {:ok, snapshot} =
             ModelPolicy.compile([
               %{
                 kind: :substrate,
                 name: "substrate",
                 path: "guidance/preferred-models.toml",
                 bytes: bytes
               }
             ])

    snapshot
  end

  defp manifest do
    """
    name = "fixture"

    [model_policy]
    default_use = "substrate:fixture-substrate-closed"
    allowed_uses = [
      "substrate:fixture-substrate-closed",
      "substrate:fixture-substrate-any",
      "kungfu:agentic-engineering:fixture-kungfu-working",
      "kungfu:agentic-engineering:fixture-kungfu-closed"
    ]
    """
  end
end
