defmodule Tightbeam.ExecutionSafetyIsolationTest do
  use Tightbeam.TestCase, async: false

  # These are execution safeguards for concurrent source-test runs, not
  # Timeout/Fidelity product acceptance tests.
  @production_port 11_373

  test "concurrent source-test runs isolate node, port, and production identity" do
    occupant = occupy_or_observe_production_port!()

    on_exit(fn ->
      case occupant do
        {:owned, socket} -> :gen_tcp.close(socket)
        :external -> :ok
      end
    end)

    fixture_dir =
      Path.join(System.tmp_dir!(), "execution-safety-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_dir)
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    fake_bin = Path.join(fixture_dir, "bin")
    File.mkdir_p!(fake_bin)
    started_file = Path.join(fixture_dir, "started-nodes")
    File.write!(started_file, "")

    write_tool!(fake_bin, "cargo", "exit 0")
    write_tool!(fake_bin, "erl", "printf '28.5\\n'")
    write_tool!(fake_bin, "mix", "exit 0")
    write_tool!(fake_bin, "elixir", concurrent_elixir_fixture())

    wrapper = Path.expand("../scripts/verify_mix.sh", __DIR__)

    env = [
      {"PATH", fake_bin <> ":/usr/bin:/bin"},
      {"LANG", "C.UTF-8"},
      {"LC_ALL", nil},
      {"LC_CTYPE", nil},
      {"GATE_STARTED_FILE", started_file},
      {"TIGHTBEAM_BASE_DIR", "/sentinel/prod/base"},
      {"TIGHTBEAM_ADVERTISED_URL", "https://prod.invalid"},
      {"TIGHTBEAM_FUTURE_PRODUCTION_INPUT", "must-be-scrubbed"},
      {"TIGHTBEAM_PORT", Integer.to_string(@production_port)},
      {"RELEASE_NODE", "tightbeam_prod@fixture"},
      {"RELEASE_ROOT", "/sentinel/release"},
      {"RELEASE_FUTURE_PRODUCTION_INPUT", "must-be-scrubbed"},
      {"ROOTDIR", "/sentinel/erts"},
      {"BINDIR", "/sentinel/erts/bin"}
    ]

    captures =
      1..2
      |> Task.async_stream(
        fn _ ->
          System.cmd(wrapper, ["--execution-safety-fixture"],
            env: env,
            stderr_to_stdout: true
          )
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn
        {:ok, {capture, 0}} -> capture
        {:ok, {capture, status}} -> flunk("execution-safety fixture exited #{status}: #{capture}")
        {:exit, reason} -> flunk("execution-safety fixture process failed: #{inspect(reason)}")
      end)

    nodes = Enum.map(captures, &captured_node/1)
    assert length(Enum.uniq(nodes)) == 2

    started_nodes = started_file |> File.read!() |> String.split()
    assert Enum.sort(started_nodes) == Enum.sort(nodes)

    for {capture, node} <- Enum.zip(captures, nodes) do
      assert capture =~ "RUNS_OVERLAPPED=2\n"
      assert capture =~ "CHILD_RUN_NODE=#{node}\n"
      assert capture =~ "TIGHTBEAM_GATE_NODE=#{node}\n"
      assert capture =~ "TIGHTBEAM_PORT=0\n"
      assert capture =~ "Authoritative Mix gate: node=#{node} port=0\n"

      assert capture =~
               "ARG=--sname\nARG=#{node}\nARG=-S\nARG=mix\nARG=test\nARG=--execution-safety-fixture\n"

      for production_name <- [
            "TIGHTBEAM_BASE_DIR=",
            "TIGHTBEAM_ADVERTISED_URL=",
            "TIGHTBEAM_FUTURE_PRODUCTION_INPUT=",
            "TIGHTBEAM_PORT=#{@production_port}",
            "RELEASE_NODE=",
            "RELEASE_ROOT=",
            "RELEASE_FUTURE_PRODUCTION_INPUT=",
            "ROOTDIR=",
            "BINDIR="
          ] do
        refute capture =~ production_name
      end
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
        flunk("cannot establish the production-port safety precondition: #{inspect(reason)}")
    end
  end

  defp captured_node(capture) do
    [node] =
      Regex.run(~r/^Authoritative Mix gate: node=(\S+) port=0$/m, capture,
        capture: :all_but_first
      )

    node
  end

  defp write_tool!(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  defp concurrent_elixir_fixture do
    """
    if [ "${1:-}" = "--version" ]; then
      printf 'Elixir 1.19.5 (compiled with Erlang/OTP 28)\\n'
      exit 0
    fi

    printf '%s\\n' "$TIGHTBEAM_GATE_NODE" >> "$GATE_STARTED_FILE"
    waits=0
    started=0
    while [ "$waits" -lt 500 ]; do
      started=$(wc -l < "$GATE_STARTED_FILE")
      [ "$started" -ge 2 ] && break
      waits=$((waits + 1))
      sleep 0.01
    done
    [ "$started" -ge 2 ] || exit 80

    printf 'RUNS_OVERLAPPED=2\\n'
    printf 'CHILD_RUN_NODE=%s\\n' "$TIGHTBEAM_GATE_NODE"
    env | sort
    for arg do printf 'ARG=%s\\n' "$arg"; done
    """
  end
end
