defmodule Tightbeam.RecoveryFixture do
  @moduledoc false

  @marker "tightbeam recovery acceptance arena v1\n"

  # Test fixture placement only. Never invoke npm, onboard a provider, or read
  # another base directory. The caller must have created this exact marked arena.
  def place_adapter!(arena, opts \\ []) do
    arena = Path.expand(arena)
    ^arena = Path.absname(arena)
    @marker = File.read!(Path.join(arena, ".soak-arena"))

    # Ordinary startup checks every registered harness before credentials.
    # Preplace accepted package shapes; non-fixture executables fail closed.
    placeholders =
      for module <- Tightbeam.Harness.all(), module != Tightbeam.Harness.Fixture do
        %{input: %{profile: profile}} =
          Enum.find(module.conformance_vectors()["ensure_adapter"], &(&1.case == "local_present"))

        package =
          Path.join(
            arena,
            "adapters/node_modules/@agentclientprotocol/#{profile.adapter_package}"
          )

        bundle = Path.join([package, "dist", profile.adapter_bundle])
        binary = Path.join(arena, "adapters/node_modules/.bin/#{profile.adapter_bin}")
        File.mkdir_p!(Path.dirname(bundle))
        File.mkdir_p!(Path.dirname(binary))

        File.write!(
          Path.join(package, "package.json"),
          JSON.encode!(%{"version" => profile.adapter_version})
        )

        File.write!(bundle, profile.patched)

        File.write!(
          binary,
          "#!/bin/sh\necho 'recovery arena: non-fixture adapter invocation forbidden' >&2\nexit 64\n"
        )

        File.chmod!(binary, 0o755)
        %{module: module, binary: binary, bundle: bundle}
      end

    package = Path.join(arena, "adapters/node_modules/@agentclientprotocol/fixture-acp")
    bundle = Path.join(package, "dist/fixture.js")
    binary = Path.join(arena, "adapters/node_modules/.bin/fixture-acp")
    auth = Path.join(arena, "auth/fixture")

    for dir <- [Path.dirname(bundle), Path.dirname(binary), auth], do: File.mkdir_p!(dir)

    File.write!(
      Path.join(package, "package.json"),
      JSON.encode!(%{
        name: "@agentclientprotocol/fixture-acp",
        version: "1.0.0",
        bin: %{"fixture-acp" => "dist/fixture.js"}
      })
    )

    File.cp!(Path.join(__DIR__, "recovery_acp_fixture.js"), bundle)
    File.chmod!(bundle, 0o755)
    File.ln_s!(bundle, binary)

    if Keyword.get(opts, :seed_credential, true) do
      File.write!(Path.join(auth, "fixture.json"), "fixture-provider-credential")

      File.write!(
        Path.join(auth, "credential.json"),
        JSON.encode!(%{
          onboarded: true,
          kind: "subscription"
        })
      )
    end

    %{
      placeholders: placeholders,
      binary: binary,
      bundle: bundle,
      package: package,
      env: [{"RECOVERY_FIXTURE_ARENA", arena}],
      transcript: Path.join(arena, "recovery-acp.jsonl")
    }
  end
end
