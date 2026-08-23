defmodule Tightbeam.ClientFleetProofTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ClientFleetProof

  @fixture Path.join(__DIR__, "fixtures/client-fleet-proof-v1.json")

  test "shared literal vectors match and validate" do
    fixture = fixture()
    assert fixture["schema"] == "tightbeam-client-fleet-proof-fixture/v1"

    for vector <- fixture["vectors"] do
      hosts = hosts(vector)
      assert {:ok, host} = ClientFleetProof.host_set(hosts)
      assert host.bytes == decode_hex(vector["hostSetHex"])
      assert host.sha256 == vector["hostSetSha256"]
      assert :ok = ClientFleetProof.validate_host_set(host.bytes)

      assert {:ok, fleet} = ClientFleetProof.fleet_proof(hosts, fleet_input(vector))
      assert fleet.bytes == decode_hex(vector["fleetProofHex"])
      assert fleet.sha256 == vector["fleetProofSha256"]
      assert fleet.host_set_sha256 == vector["hostSetSha256"]
      assert :ok = ClientFleetProof.validate_fleet_proof(fleet.bytes, hosts)
    end
  end

  test "structured inputs refuse noncanonical rows, fields, and protocols" do
    vector = fixture()["vectors"] |> List.last()
    hosts = hosts(vector)
    input = fleet_input(vector)

    assert {:error, :noncanonical_order} = ClientFleetProof.host_set(Enum.reverse(hosts))
    assert {:error, :duplicate_name} = ClientFleetProof.host_set([hd(hosts), hd(hosts)])

    for field <- [:name, :ssh, :base_dir, :cli_bin, :adapter_bin_dir] do
      assert {:error, :missing_field} =
               ClientFleetProof.host_set([Map.delete(hd(hosts), field)])
    end

    assert {:error, :noncanonical_order} =
             ClientFleetProof.fleet_proof(hosts, %{input | results: Enum.reverse(input.results)})

    assert {:error, :host_result_mismatch} =
             ClientFleetProof.fleet_proof(hosts, %{input | results: tl(input.results)})

    assert {:error, :duplicate_name} =
             ClientFleetProof.fleet_proof(hosts, %{
               input
               | results: input.results ++ [List.last(input.results)]
             })

    assert {:error, :noncanonical_protocol_order} =
             ClientFleetProof.fleet_proof(hosts, %{input | terminal_protocols: [1, 0]})

    assert {:error, :duplicate_protocol} =
             ClientFleetProof.fleet_proof(hosts, %{input | terminal_protocols: [1, 1]})

    assert {:error, :invalid_sha256} =
             ClientFleetProof.fleet_proof(hosts, %{
               input
               | manifest_sha256: String.upcase(input.manifest_sha256)
             })

    invalid_results = [
      Map.put(hd(input.results), :target, "unknown-target"),
      Map.put(hd(input.results), :release, "01.2.3"),
      Map.put(hd(input.results), :release, "1.2.3-!"),
      Map.put(hd(input.results), :build_commit, String.duplicate("A", 40)),
      Map.put(hd(input.results), :member_sha256, String.duplicate("A", 64)),
      Map.put(hd(input.results), :terminal_protocols, [1, 1])
    ]

    for result <- invalid_results do
      assert {:error, _reason} =
               ClientFleetProof.fleet_proof(hosts, %{
                 input
                 | results: [result | tl(input.results)]
               })
    end

    {:ok, original} = ClientFleetProof.host_set(hosts)

    for field <- [:ssh, :base_dir, :cli_bin, :adapter_bin_dir] do
      changed =
        List.update_at(hosts, 0, &Map.update!(&1, field, fn value -> (value || "") <> "x" end))

      assert {:ok, receipt} = ClientFleetProof.host_set(changed)
      refute receipt.sha256 == original.sha256
    end
  end

  test "byte validators refuse structural mutations and distinguish a canonical one-bit change" do
    vector = fixture()["vectors"] |> List.last()
    hosts = hosts(vector)
    {:ok, host} = ClientFleetProof.host_set(hosts)
    {:ok, fleet} = ClientFleetProof.fleet_proof(hosts, fleet_input(vector))

    host_prefix_size = byte_size("tightbeam-host-set-v1\0")
    fleet_prefix_size = byte_size("tightbeam-fleet-proof-v1\0")

    for index <- [0, host_prefix_size + 7, host_prefix_size + 8, host_prefix_size + 16] do
      assert {:error, _reason} = ClientFleetProof.validate_host_set(flip(host.bytes, index))
    end

    for index <- [0, fleet_prefix_size, fleet_prefix_size + 8] do
      assert {:error, _reason} =
               ClientFleetProof.validate_fleet_proof(flip(fleet.bytes, index), hosts)
    end

    uppercase_manifest =
      replace_first(
        fleet.bytes,
        vector["manifestSha256"],
        String.upcase(String.first(vector["manifestSha256"])) <>
          String.slice(vector["manifestSha256"], 1..-1//1)
      )

    assert {:error, :invalid_sha256} =
             ClientFleetProof.validate_fleet_proof(uppercase_manifest, hosts)

    assert {:error, :trailing_bytes} =
             ClientFleetProof.validate_fleet_proof(fleet.bytes <> <<0>>, hosts)

    for length <- 0..(byte_size(fleet.bytes) - 1) do
      assert {:error, _reason} =
               ClientFleetProof.validate_fleet_proof(binary_part(fleet.bytes, 0, length), hosts)
    end

    canonical_mutation = flip(fleet.bytes, byte_size(fleet.bytes) - 1)
    refute digest(canonical_mutation) == fleet.sha256
    assert :ok = ClientFleetProof.validate_fleet_proof(canonical_mutation, hosts)
  end

  defp fixture do
    @fixture |> File.read!() |> JSON.decode!()
  end

  defp hosts(vector) do
    Enum.map(vector["hosts"], fn row ->
      %{
        name: row["name"],
        ssh: row["ssh"],
        base_dir: row["baseDir"],
        cli_bin: row["cliBin"],
        adapter_bin_dir: row["adapterBinDir"]
      }
    end)
  end

  defp fleet_input(vector) do
    %{
      manifest_sha256: vector["manifestSha256"],
      terminal_protocols: vector["terminalProtocols"],
      release_transition_protocols: vector["releaseTransitionProtocols"],
      results:
        Enum.map(vector["results"], fn row ->
          %{
            name: row["name"],
            target: row["target"],
            release: row["release"],
            build_commit: row["buildCommit"],
            member_sha256: row["memberSha256"],
            terminal_protocols: row["terminalProtocols"]
          }
        end)
    }
  end

  defp decode_hex(value), do: Base.decode16!(value, case: :lower)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp flip(bytes, index) do
    <<before::binary-size(index), byte, after_bytes::binary>> = bytes
    before <> <<Bitwise.bxor(byte, 1)>> <> after_bytes
  end

  defp replace_first(bytes, from, to) do
    {index, length} = :binary.match(bytes, from)
    <<before::binary-size(index), _::binary-size(length), after_bytes::binary>> = bytes
    before <> to <> after_bytes
  end
end
