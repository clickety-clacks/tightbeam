defmodule Tightbeam.MergeGateIsolationTest do
  use Tightbeam.TestCase, async: false

  @production_port 11_373

  test "the authoritative wrapper refuses before tests when Cargo is unavailable" do
    capture = capture_preflight_refusal!(omit: "cargo")

    assert capture =~
             ~s(tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"cargo-unavailable"})

    refute capture =~ "TESTS_STARTED"
    refute capture =~ "Authoritative Mix gate:"
  end

  test "the authoritative wrapper refuses before tests when the locale is not UTF-8" do
    capture = capture_preflight_refusal!(charmap: "ANSI_X3.4-1968")

    assert capture =~
             ~s(tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"utf8-locale-unavailable"})

    refute capture =~ "TESTS_STARTED"
    refute capture =~ "Authoritative Mix gate:"
  end

  test "the authoritative wrapper refuses before tests when neither direct tools nor Mise provide the pinned BEAM" do
    capture = capture_preflight_refusal!(erlang: "28.4", mise: :failing)

    assert capture =~
             ~s(tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"pinned-beam-unavailable"})

    refute capture =~ "TESTS_STARTED"
    refute capture =~ "Authoritative Mix gate:"
  end

  test "the authoritative wrapper accepts a binary patch release of the pinned OTP line" do
    # erlef/setup-beam installs OTP's binary patch releases: OTP_VERSION reads
    # 28.5.0.5 for pin 28.5. That is the pinned release and must run directly,
    # with no Mise fallback (CI runners have none).
    fake_bin = fake_toolchain_bin!(erlang: "28.5.0.5", mise: :failing)
    wrapper = Path.expand("../scripts/verify_mix.sh", __DIR__)

    assert {capture, 0} =
             System.cmd(wrapper, [],
               env: [{"PATH", fake_bin <> ":/usr/bin:/bin"}, {"LANG", "C.UTF-8"}],
               stderr_to_stdout: true
             )

    assert capture =~ "TESTS_STARTED\n"
    assert capture =~ "Authoritative Mix gate:"
  end

  test "a different OTP line sharing the pin's digits is still refused" do
    capture = capture_preflight_refusal!(erlang: "28.50", mise: :failing)

    assert capture =~
             ~s(tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"pinned-beam-unavailable"})

    refute capture =~ "TESTS_STARTED"
  end

  test "a malformed suffix on the pinned line is refused, not accepted" do
    # The boundary is dot-separated numeric components only: empty, trailing-dot,
    # nonnumeric, repeated-dot, and mixed suffix components are all refusals.
    for malformed <- ["28.5.", "28.5.foo", "28.5..1", "28.5.1a", "28.5.0.5a", "28.5.0..5"] do
      capture = capture_preflight_refusal!(erlang: malformed, mise: :failing)

      assert capture =~
               ~s(tightbeam-gate-preflight: {"schema":"tightbeam-gate-preflight-refusal/v1","cause":"pinned-beam-unavailable"}),
             "#{malformed} must refuse"

      refute capture =~ "TESTS_STARTED", "#{malformed} must not start the gate"
    end
  end

  test "the authoritative wrapper uses Mise when only Mise provides the pinned BEAM" do
    fake_bin = fake_toolchain_bin!(erlang: "28.4", mise: :pinned)
    wrapper = Path.expand("../scripts/verify_mix.sh", __DIR__)

    assert {capture, 0} =
             System.cmd(wrapper, ["--trace"],
               env: [{"PATH", fake_bin <> ":/usr/bin:/bin"}, {"LANG", "C.UTF-8"}],
               stderr_to_stdout: true
             )

    assert capture =~ "MISE_TESTS_STARTED\n"
    assert capture =~ "Authoritative Mix gate:"
    assert capture =~ "ARG=--trace\n"
  end

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
      assert capture =~ "Elixir 1.19.5 (compiled with Erlang/OTP 28)\n"
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
    fake_bin = fake_toolchain_bin!()

    poisoned_env = [
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"LANG", "C.UTF-8"},
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

  defp capture_preflight_refusal!(options) do
    fake_bin = fake_toolchain_bin!(options)
    wrapper = Path.expand("../scripts/verify_mix.sh", __DIR__)

    assert {capture, 78} =
             System.cmd(wrapper, [],
               env: [
                 {"PATH", fake_bin <> ":/usr/bin:/bin"},
                 {"LANG", "C.UTF-8"},
                 {"LC_ALL", nil},
                 {"LC_CTYPE", nil}
               ],
               stderr_to_stdout: true
             )

    capture
  end

  defp fake_toolchain_bin!(options \\ []) do
    fake_bin =
      Path.join(System.tmp_dir!(), "merge-gate-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_bin)
    on_exit(fn -> File.rm_rf!(fake_bin) end)

    unless options[:omit] == "cargo", do: write_tool!(fake_bin, "cargo", "exit 0")

    write_tool!(fake_bin, "locale", "printf '#{options[:charmap] || "UTF-8"}\\n'")
    write_tool!(fake_bin, "erl", "printf '#{options[:erlang] || "28.5"}\\n'")
    write_tool!(fake_bin, "mix", "exit 0")

    write_tool!(fake_bin, "elixir", """
    if [ "${1:-}" = "--version" ]; then
      printf 'Elixir 1.19.5 (compiled with Erlang/OTP 28)\\n'
      exit 0
    fi
    printf 'TESTS_STARTED\\n'
    env | sort
    for arg in "$@"; do
      printf 'ARG=%s\\n' "$arg"
    done
    """)

    if options[:mise] == :failing, do: write_tool!(fake_bin, "mise", "exit 1")

    if options[:mise] == :pinned do
      write_tool!(fake_bin, "mise", """
      shift 2
      case "$1" in
        erl) printf '28.5\\n' ;;
        mix) exit 0 ;;
        elixir)
          shift
          if [ "${1:-}" = "--version" ]; then
            printf 'Elixir 1.19.5 (compiled with Erlang/OTP 28)\\n'
            exit 0
          fi
          printf 'MISE_TESTS_STARTED\\n'
          for arg in "$@"; do printf 'ARG=%s\\n' "$arg"; done
          ;;
      esac
      """)
    end

    fake_bin
  end

  defp write_tool!(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  defp captured_node(capture) do
    [node] = Regex.run(~r/^TIGHTBEAM_GATE_NODE=(.+)$/m, capture, capture: :all_but_first)
    node
  end
end
