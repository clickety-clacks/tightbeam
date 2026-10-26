defmodule Tightbeam.Acp.IdentityEvidenceTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Acp.IdentityEvidence

  @hash String.duplicate("a", 64)

  test "the persisted shape excludes unallowlisted and secret-bearing fields" do
    record =
      IdentityEvidence.sanitize(%{
        correlation: %{request_id: "req_fixture", prompt: "private prompt"},
        requested: %{family: "claude-opus-5-5", context: nil, effort: "high"},
        resident: %{
          effort_config: "effort",
          config_options: [
            %{
              "id" => "model",
              "currentValue" => "opus[1m]",
              "account" => "private-account",
              "options" => [
                %{
                  "value" => "opus[1m]",
                  "name" => "Opus 5.5 with 1M context",
                  "description" => "password=fixture-secret",
                  "credential" => "fixture-secret"
                }
              ]
            }
          ]
        },
        environment: %{"TOKEN" => "fixture-secret"}
      })

    encoded = JSON.encode!(record)
    refute encoded =~ "private prompt"
    refute encoded =~ "private-account"
    refute encoded =~ "fixture-secret"
    refute encoded =~ "environment"

    assert get_in(record, ["resident", "modelOption", "options", Access.at(0), "description"]) ==
             nil
  end

  test "truthful nulls distinguish later disk hashes from loader attestations" do
    disk =
      IdentityEvidence.sanitize(%{
        loaded_identity: %{source: "disk", acp: %{sha256: @hash}}
      })

    assert get_in(disk, ["loadedIdentity", "acp"]) == %{
             "sha256" => nil,
             "reason" => "process_loader_attestation_unavailable"
           }

    loaded =
      IdentityEvidence.sanitize(%{
        correlation: %{harness_launch_id: "launch-fixture", adapter_connection_generation: 3},
        loaded_identity: %{
          source: "process_loader",
          acp: %{sha256: @hash},
          sdk: %{sha256: @hash},
          native: %{sha256: @hash}
        }
      })

    assert get_in(loaded, ["loadedIdentity", "binding"]) == %{
             "harnessLaunchId" => "launch-fixture",
             "adapterConnectionGeneration" => 3
           }

    assert get_in(loaded, ["loadedIdentity", "acp"]) == %{
             "sha256" => @hash,
             "reason" => nil
           }
  end
end
