defmodule Tightbeam.MergeGateIsolationTest do
  use Tightbeam.TestCase, async: false

  @production_port 11_373

  test "the authoritative wrapper isolates two runs while production port 11373 stays occupied" do
    occupant = occupy_or_observe_production_port!()

    on_exit(fn ->
      case occupant do
        {:owned, socket} -> :gen_tcp.close(socket)
        :external -> :ok
      end
    end)

    first = capture_wrapper_invocation!()
    second = capture_wrapper_invocation!()

    first_node = captured_node(first)
    second_node = captured_node(second)

    assert first_node =~ ~r/^tightbeam_mix_gate_[A-Za-z0-9]+$/
    assert second_node =~ ~r/^tightbeam_mix_gate_[A-Za-z0-9]+$/
    refute first_node == second_node

    for capture <- [first, second] do
      assert capture =~ "TIGHTBEAM_PORT=0\n"
      assert capture =~ "TIGHTBEAM_AUTHORITATIVE_GATE=1\n"
      assert capture =~ "TIGHTBEAM_GATE_NODE=#{captured_node(capture)}\n"
      assert capture =~ "Authoritative Mix gate: node=#{captured_node(capture)} port=0\n"
      assert capture =~ "ARG=--sname\nARG=#{captured_node(capture)}\nARG=-S\nARG=mix\nARG=test\n"
      assert capture =~ "ARG=--trace\n"

      refute capture =~ "TIGHTBEAM_BASE_DIR="
      refute capture =~ "TIGHTBEAM_ADVERTISED_URL="
      refute capture =~ "TIGHTBEAM_FUTURE_PRODUCTION_INPUT="
      refute capture =~ "RELEASE_NODE="
      refute capture =~ "RELEASE_ROOT="
      refute capture =~ "RELEASE_FUTURE_PRODUCTION_INPUT="
      refute capture =~ "ROOTDIR="
      refute capture =~ "BINDIR="
    end

    assert {:error, :eaddrinuse} =
             :gen_tcp.listen(@production_port, [
               :binary,
               ip: {127, 0, 0, 1},
               active: false,
               reuseaddr: false
             ])
  end

  defp occupy_or_observe_production_port! do
    case :gen_tcp.listen(@production_port, [
           :binary,
           ip: {127, 0, 0, 1},
           active: false,
           reuseaddr: false
         ]) do
      {:ok, socket} ->
        {:owned, socket}

      {:error, :eaddrinuse} ->
        :external

      {:error, reason} ->
        flunk("cannot establish the port-11373 precondition: #{inspect(reason)}")
    end
  end

  defp capture_wrapper_invocation! do
    fake_bin =
      Path.join(System.tmp_dir!(), "merge-gate-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_bin)
    on_exit(fn -> File.rm_rf!(fake_bin) end)

    fake_elixir = Path.join(fake_bin, "elixir")

    File.write!(fake_elixir, """
    #!/bin/sh
    env | sort
    for arg in "$@"; do
      printf 'ARG=%s\\n' "$arg"
    done
    """)

    File.chmod!(fake_elixir, 0o755)

    poisoned_env = [
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"TIGHTBEAM_BASE_DIR", "/production/org"},
      {"TIGHTBEAM_ADVERTISED_URL", "http://127.0.0.1:11373"},
      {"TIGHTBEAM_FUTURE_PRODUCTION_INPUT", "must-be-scrubbed"},
      {"TIGHTBEAM_PORT", "11373"},
      {"RELEASE_NODE", "tightbeam_gateway_11373"},
      {"RELEASE_ROOT", "/production/release"},
      {"RELEASE_FUTURE_PRODUCTION_INPUT", "must-be-scrubbed"},
      {"ROOTDIR", "/production/erts"},
      {"BINDIR", "/production/erts/bin"}
    ]

    wrapper = Path.expand("../scripts/verify_mix.sh", __DIR__)

    assert {capture, 0} =
             System.cmd(wrapper, ["--trace"], env: poisoned_env, stderr_to_stdout: true)

    capture
  end

  defp captured_node(capture) do
    [node] = Regex.run(~r/^TIGHTBEAM_GATE_NODE=(.+)$/m, capture, capture: :all_but_first)
    node
  end
end
