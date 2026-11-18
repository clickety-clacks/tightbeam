# Opt-in end-to-end suite: model and harness switches through the REAL pinned
# Claude and Codex ACP adapters, driven through a running, isolated Tightbeam test
# instance whose harnesses are already signed in.
#
# Why it exists. A resident Claude session once could not be switched to another
# Claude model ("Session not found"). The unit fake answered session/fork with a
# session that was already live; the pinned claude-agent-acp writes the forked
# transcript and returns an id it has not registered. Nothing drove the real
# adapters through a switch, so nothing saw the difference. This suite does, for
# exactly three switches, each followed by a turn the new model must answer:
#
#   (a) a resident Claude session to another Claude model,
#   (b) a resident Codex session to another Codex model,
#   (c) a resident Claude session to Codex (a harness switch).
#
# "Resident" means the session has just finished a turn on its first model, so its
# adapter holds it loaded when the switch arrives. That is the path that failed;
# an evict-and-reload switch is a different path and is not what this covers.
#
# It calls real models, so it is excluded from every ordinary run (test_helper.exs
# excludes :real_adapter_switch). Run it explicitly through the canonical wrapper:
#
#   SWITCH_E2E_BASE_DIR=/abs/path/to/test-instance-base \
#   SWITCH_E2E_OWNED_BASE=/abs/path/to/test-instance-base \
#   SWITCH_E2E_USER=<admin user id on that instance> \
#   SWITCH_E2E_CLAUDE_FROM=<claude catalog model> SWITCH_E2E_CLAUDE_TO=<another claude model> \
#   SWITCH_E2E_CODEX_FROM=<codex catalog model>  SWITCH_E2E_CODEX_TO=<another codex model> \
#   scripts/verify_mix.sh --only real_adapter_switch test/real_adapter_switch_e2e_test.exs
#
# Optional: SWITCH_E2E_CLI (the instance's `tightbeam` CLI; default: `tightbeam` on
# PATH), SWITCH_E2E_EFFORT (one effort for every spawn and switch), SWITCH_E2E_ARCHETYPE,
# SWITCH_E2E_HOST, SWITCH_E2E_TURN_TIMEOUT_S (default 600).
#
# The variables are SWITCH_E2E_*, not TIGHTBEAM_*: the canonical wrapper removes every
# inherited TIGHTBEAM_* variable so a source run can never reach a live install. The
# suite hands the instance's base dir to the CLI child alone, from a fresh scratch
# working directory with no `.tightbeam-session` above it (a session marker wins over
# the base dir, so running beside one would address that session's organization).
#
# The instance is the system under test. Its gateway, adapters and sign-in are its
# own; this suite reads no credential and signs in nowhere. To compare unfixed and
# fixed code, run the suite unchanged against an instance running each build.
#
# With no SWITCH_E2E_* variables set every case is SKIPPED with the reason printed. A
# partial or unsafe configuration fails setup and names what is missing.

defmodule Tightbeam.RealAdapterSwitchE2E do
  @moduledoc false

  @required ~w(SWITCH_E2E_BASE_DIR SWITCH_E2E_OWNED_BASE SWITCH_E2E_USER SWITCH_E2E_CLAUDE_FROM
               SWITCH_E2E_CLAUDE_TO SWITCH_E2E_CODEX_FROM SWITCH_E2E_CODEX_TO)

  @skip_reason """
  real-adapter switch E2E skipped: no test instance configured. \
  Set SWITCH_E2E_BASE_DIR (and SWITCH_E2E_OWNED_BASE to the same path) to a running, \
  isolated Tightbeam test instance whose claude and codex harnesses are signed in, \
  plus SWITCH_E2E_USER and SWITCH_E2E_{CLAUDE,CODEX}_{FROM,TO}. \
  See the header of test/real_adapter_switch_e2e_test.exs.\
  """

  def skip_reason, do: @skip_reason

  @doc "nil when any suite configuration is supplied; otherwise the skip reason."
  def unconfigured do
    configured? =
      Enum.any?(System.get_env(), fn {name, _} -> String.starts_with?(name, "SWITCH_E2E_") end)

    if configured?, do: nil, else: @skip_reason
  end

  @doc "True when this run explicitly selected the suite's tag."
  def selected? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(fn
      :real_adapter_switch -> true
      {:real_adapter_switch, _} -> true
      _ -> false
    end)
  end

  @doc """
  The validated configuration, or `{:error, problems}`. Every refusal names the
  variable to fix; none of them reads a file's contents.
  """
  def config do
    base = System.get_env("SWITCH_E2E_BASE_DIR")
    missing = Enum.filter(@required, &blank?(System.get_env(&1)))

    problems =
      []
      |> add_if(missing != [], "unset: #{Enum.join(missing, ", ")}")
      |> add_if(
        not is_binary(base) or Path.type(base) != :absolute,
        "SWITCH_E2E_BASE_DIR must be an absolute path"
      )
      |> add_if(
        System.get_env("SWITCH_E2E_OWNED_BASE") != base,
        "SWITCH_E2E_OWNED_BASE must equal SWITCH_E2E_BASE_DIR: name the disposable base twice"
      )
      |> add_if(
        not (is_binary(base) and File.dir?(base)),
        "SWITCH_E2E_BASE_DIR is not a directory: #{base}"
      )
      |> add_if(
        is_binary(base) and File.dir?(base) and not File.exists?(Path.join(base, "gateway.json")),
        "no running gateway: #{base} has no gateway.json"
      )
      |> add_if(
        System.get_env("SWITCH_E2E_CLAUDE_FROM") == System.get_env("SWITCH_E2E_CLAUDE_TO") and
          not blank?(System.get_env("SWITCH_E2E_CLAUDE_TO")),
        "SWITCH_E2E_CLAUDE_FROM and SWITCH_E2E_CLAUDE_TO must differ"
      )
      |> add_if(
        System.get_env("SWITCH_E2E_CODEX_FROM") == System.get_env("SWITCH_E2E_CODEX_TO") and
          not blank?(System.get_env("SWITCH_E2E_CODEX_TO")),
        "SWITCH_E2E_CODEX_FROM and SWITCH_E2E_CODEX_TO must differ"
      )

    cli = System.get_env("SWITCH_E2E_CLI") || System.find_executable("tightbeam")
    problems = add_if(problems, is_nil(cli), "no tightbeam CLI: set SWITCH_E2E_CLI")

    if problems == [] do
      {:ok,
       %{
         base: base,
         user: System.fetch_env!("SWITCH_E2E_USER"),
         cli: cli,
         effort: present(System.get_env("SWITCH_E2E_EFFORT")),
         archetype: present(System.get_env("SWITCH_E2E_ARCHETYPE")),
         host: present(System.get_env("SWITCH_E2E_HOST")),
         turn_timeout_ms:
           String.to_integer(System.get_env("SWITCH_E2E_TURN_TIMEOUT_S") || "600") * 1_000,
         claude:
           {System.fetch_env!("SWITCH_E2E_CLAUDE_FROM"),
            System.fetch_env!("SWITCH_E2E_CLAUDE_TO")},
         codex:
           {System.fetch_env!("SWITCH_E2E_CODEX_FROM"), System.fetch_env!("SWITCH_E2E_CODEX_TO")}
       }}
    else
      {:error, Enum.reverse(problems)}
    end
  end

  @doc """
  A scratch working directory for every CLI call. Refuses one with a
  `.tightbeam-session` marker in any ancestor, because the CLI would then act in
  that session's organization instead of the named test instance.
  """
  def scratch_cwd! do
    dir = Path.join(System.tmp_dir!(), "switch-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    marker =
      dir
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.map(&Path.join(&1, ".tightbeam-session"))
      |> Enum.find(&File.exists?/1)

    if marker do
      raise "refusing to run the CLI under #{marker}: it would address that session's " <>
              "organization, not the test instance"
    end

    dir
  end

  @doc "Runs one CLI verb against the instance and decodes its JSON reply."
  def cli!(ctx, args) do
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(
        &(String.starts_with?(&1, "TIGHTBEAM_") or String.starts_with?(&1, "RELEASE_"))
      )
      |> Enum.map(&{&1, nil})
      |> Kernel.++([{"TIGHTBEAM_BASE_DIR", ctx.config.base}])

    argv = args ++ ["--as-user", ctx.config.user]

    {out, status} =
      System.cmd(ctx.config.cli, argv, cd: ctx.cwd, env: env, stderr_to_stdout: true)

    if status != 0 do
      raise "tightbeam #{Enum.join(redact(argv), " ")} exited #{status}: #{String.trim(out)}"
    end

    case JSON.decode(out) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        raise "tightbeam #{hd(args)} printed non-JSON output: #{String.trim(out)}"
    end
  end

  # Prompt text is the only free text in argv; keep logs short.
  defp redact(argv) do
    Enum.map(argv, fn arg ->
      if String.length(arg) > 80, do: String.slice(arg, 0, 77) <> "...", else: arg
    end)
  end

  @doc "Spawns a throwaway session on the instance and returns its key."
  def spawn!(ctx, label, harness, model) do
    args =
      [
        "spawn",
        "--display",
        "E2E switch #{label} #{ctx.run_id}",
        "--harness",
        harness,
        "--model",
        model,
        "--key",
        "switch-e2e-#{label}-#{ctx.run_id}"
      ]
      |> opt("--effort", ctx.config.effort)
      |> opt("--archetype", ctx.config.archetype)
      |> opt("--host", ctx.config.host)

    reply = cli!(ctx, args)
    key = find_key(reply, ["sessionKey", "session_key"])
    key || raise "spawn reply carried no session key: #{inspect(reply)}"
  end

  @doc """
  Changes the model (and optionally the harness) of a session. The turn that just
  answered may still be closing on the gateway, so a `turn_in_progress` refusal is
  retried for up to a minute; every other refusal fails the case.
  """
  def tune!(ctx, session, opts, attempts \\ 30) do
    args =
      ["tune", "--session", session]
      |> opt("--harness", opts[:harness])
      |> opt("--model", opts[:model])
      |> opt("--effort", ctx.config.effort)

    reply =
      try do
        cli!(ctx, args)
      rescue
        error in RuntimeError ->
          if attempts > 1 and String.contains?(error.message, "turn_in_progress") do
            :retry
          else
            reraise error, __STACKTRACE__
          end
      end

    cond do
      reply == :retry ->
        Process.sleep(2_000)
        tune!(ctx, session, opts, attempts - 1)

      is_map(reply) and reply["ok"] == false ->
        raise "tune refused: #{inspect(reply)}"

      true ->
        reply
    end
  end

  def retire(ctx, session) do
    cli!(ctx, ["retire", "--session", session, "--key", "switch-e2e-retire-#{session}"])
  rescue
    error -> log(ctx, "retire #{session} failed: #{Exception.message(error)}")
  end

  @doc """
  Sends one prompt carrying `nonce` and waits for the turn's reply. Returns the
  user entry, the concatenated reply text and the model/harness the substrate
  recorded for that turn.
  """
  def turn!(ctx, session, prompt, nonce) do
    cli!(ctx, ["wake", "--session", session, "--prompt", prompt])
    deadline = System.monotonic_time(:millisecond) + ctx.config.turn_timeout_ms
    await_reply(ctx, session, nonce, deadline)
  end

  defp await_reply(ctx, session, nonce, deadline) do
    entries = transcript(ctx, session)

    user =
      Enum.find(
        entries,
        &(&1["role"] == "user" and String.contains?(to_string(&1["content"]), nonce))
      )

    replies =
      if user,
        do:
          Enum.filter(
            entries,
            &(&1["role"] == "assistant" and &1["replyToMessageId"] == user["id"])
          ),
        else: []

    text = Enum.map_join(replies, "\n", &to_string(&1["content"]))

    cond do
      replies != [] and String.contains?(text, nonce) ->
        last = List.last(replies)

        %{
          user_id: user["id"],
          reply_ids: Enum.map(replies, & &1["id"]),
          text: text,
          model: last["model"],
          harness: last["harness"],
          turn_seq: last["turnSeq"]
        }

      System.monotonic_time(:millisecond) > deadline ->
        raise "no reply carrying #{nonce} from #{session} before the turn deadline; " <>
                "user entry #{inspect(user && user["id"])}, replies so far: #{inspect(text)}"

      true ->
        Process.sleep(2_000)
        await_reply(ctx, session, nonce, deadline)
    end
  end

  defp transcript(ctx, session) do
    case cli!(ctx, ["transcript", "--session", session, "--limit", "200"]) do
      %{"messages" => messages} when is_list(messages) -> messages
      other -> raise "unexpected transcript reply: #{inspect(other)}"
    end
  end

  @doc """
  Versions of the adapters the instance installed, read from their package.json
  under the instance base (absent when the harness host is remote).
  """
  def installed_adapter_versions(base) do
    for package <- ["claude-agent-acp", "codex-acp"], into: %{} do
      path =
        Path.join([
          base,
          "adapters",
          "node_modules",
          "@agentclientprotocol",
          package,
          "package.json"
        ])

      version =
        with {:ok, body} <- File.read(path),
             {:ok, %{"version" => v}} <- JSON.decode(body),
             do: v,
             else: (_ -> "not found at #{path}")

      {package, version}
    end
  end

  def log(ctx, line) do
    IO.puts(
      "[switch-e2e #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()} " <>
        "run=#{ctx.run_id}] #{line}"
    )
  end

  def nonce(tag), do: "#{tag}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

  @doc "The recorded model names the requested one (the record may add a context suffix)."
  def model_matches?(recorded, requested) when is_binary(recorded),
    do: recorded == requested or String.starts_with?(recorded, requested <> "[")

  def model_matches?(_recorded, _requested), do: false

  defp find_key(map, names) when is_map(map) do
    Enum.find_value(names, &(is_binary(map[&1]) && map[&1])) ||
      Enum.find_value(Map.values(map), &find_key(&1, names))
  end

  defp find_key(list, names) when is_list(list), do: Enum.find_value(list, &find_key(&1, names))
  defp find_key(_other, _names), do: nil

  defp opt(args, _flag, nil), do: args
  defp opt(args, flag, value), do: args ++ [flag, value]

  defp add_if(problems, true, problem), do: [problem | problems]
  defp add_if(problems, _false, _problem), do: problems

  defp blank?(value), do: value in [nil, ""]
  defp present(value), do: if(blank?(value), do: nil, else: value)
end

defmodule Tightbeam.RealAdapterSwitchE2ETest do
  use ExUnit.Case, async: false

  alias Tightbeam.RealAdapterSwitchE2E, as: E2E

  @moduletag :real_adapter_switch
  @moduletag timeout: :timer.minutes(45)

  # Decided when this file is loaded, so an unconfigured run reports every case as
  # skipped instead of failing it. The reason is printed only when the run asked for
  # this suite, so ordinary runs (which exclude it) stay quiet.
  @unconfigured E2E.unconfigured()
  if @unconfigured do
    @moduletag skip: @unconfigured
    if E2E.selected?(), do: IO.puts(:stderr, "\n" <> @unconfigured <> "\n")
  end

  setup_all do
    if @unconfigured do
      :ok
    else
      case E2E.config() do
        {:ok, config} ->
          run_id = "#{System.system_time(:second)}-#{:rand.uniform(9_999)}"

          IO.puts("""
          [switch-e2e] run=#{run_id} base=#{config.base} cli=#{config.cli}
          [switch-e2e] checkout adapter pins: claude-agent-acp #{Tightbeam.Harness.Claude.adapter_version()}, codex-acp #{Tightbeam.Harness.Codex.adapter_version()}
          [switch-e2e] instance installed adapters: #{inspect(E2E.installed_adapter_versions(config.base))}
          [switch-e2e] models: claude #{inspect(config.claude)}, codex #{inspect(config.codex)}, effort #{inspect(config.effort)}
          """)

          {:ok, config: config, run_id: run_id}

        {:error, problems} ->
          flunk(
            "real-adapter switch E2E is misconfigured:\n  - " <> Enum.join(problems, "\n  - ")
          )
      end
    end
  end

  setup context do
    {:ok, ctx: %{config: context.config, run_id: context.run_id, cwd: E2E.scratch_cwd!()}}
  end

  # One session per case, retired afterwards whatever happened.
  defp spawn_tracked(ctx, label, harness, model) do
    session = E2E.spawn!(ctx, label, harness, model)
    E2E.log(ctx, "#{label}: spawned #{session} on #{harness}/#{model}")
    on_exit(fn -> E2E.retire(ctx, session) end)
    session
  end

  defp first_turn!(ctx, label, session, harness, model, codeword) do
    nonce = E2E.nonce("ready")

    turn =
      E2E.turn!(
        ctx,
        session,
        "Switch test, first turn. Remember this codeword for later in this conversation: " <>
          "#{codeword}. Do not use any tools. Reply with exactly: #{nonce}",
        nonce
      )

    E2E.log(
      ctx,
      "#{label}: turn 1 user=#{turn.user_id} reply=#{inspect(turn.reply_ids)} " <>
        "recorded=#{turn.harness}/#{turn.model}"
    )

    assert turn.harness == harness
    assert E2E.model_matches?(turn.model, model)
    turn
  end

  defp assert_answers_after_switch!(ctx, label, session, harness, model, prompt_tail, expect) do
    nonce = E2E.nonce("after")

    turn =
      E2E.turn!(
        ctx,
        session,
        "Switch test, turn after the switch. Do not use any tools. " <>
          prompt_tail <>
          " End your reply with: #{nonce}",
        nonce
      )

    E2E.log(
      ctx,
      "#{label}: turn 2 user=#{turn.user_id} reply=#{inspect(turn.reply_ids)} " <>
        "recorded=#{turn.harness}/#{turn.model} text=#{inspect(String.slice(turn.text, 0, 200))}"
    )

    # The turn ran under the switched configuration and the engine answered it.
    assert turn.harness == harness, "turn 2 ran on #{turn.harness}, expected #{harness}"

    assert E2E.model_matches?(turn.model, model),
           "turn 2 recorded #{turn.model}, expected #{model}"

    for token <- expect, do: assert(String.contains?(turn.text, token), "reply lacks #{token}")
    turn
  end

  test "(a) a resident Claude session switches to another Claude model and keeps its conversation",
       %{ctx: ctx} do
    {from, to} = ctx.config.claude
    session = spawn_tracked(ctx, "claude-model", "claude", from)
    codeword = E2E.nonce("amber")
    first_turn!(ctx, "claude-model", session, "claude", from, codeword)

    # Immediately after a completed turn: the adapter still holds the session.
    reply = E2E.tune!(ctx, session, model: to)
    E2E.log(ctx, "claude-model: tune --model #{to} -> #{inspect(reply)}")

    assert_answers_after_switch!(
      ctx,
      "claude-model",
      session,
      "claude",
      to,
      "State the codeword I asked you to remember in my first message.",
      [codeword]
    )
  end

  test "(b) a resident Codex session switches to another Codex model and keeps its conversation",
       %{ctx: ctx} do
    {from, to} = ctx.config.codex
    session = spawn_tracked(ctx, "codex-model", "codex", from)
    codeword = E2E.nonce("cobalt")
    first_turn!(ctx, "codex-model", session, "codex", from, codeword)

    reply = E2E.tune!(ctx, session, model: to)
    E2E.log(ctx, "codex-model: tune --model #{to} -> #{inspect(reply)}")

    assert_answers_after_switch!(
      ctx,
      "codex-model",
      session,
      "codex",
      to,
      "State the codeword I asked you to remember in my first message.",
      [codeword]
    )
  end

  test "(c) a resident Claude session switches harness to Codex and the Codex model answers",
       %{ctx: ctx} do
    {claude_from, _} = ctx.config.claude
    {codex_model, _} = ctx.config.codex
    session = spawn_tracked(ctx, "harness", "claude", claude_from)
    first_turn!(ctx, "harness", session, "claude", claude_from, E2E.nonce("umber"))

    reply = E2E.tune!(ctx, session, harness: "codex", model: codex_model)
    E2E.log(ctx, "harness: tune --harness codex --model #{codex_model} -> #{inspect(reply)}")

    # A harness switch starts a fresh engine context by design, so this turn proves
    # the new engine answers, not that the old conversation carried over.
    assert_answers_after_switch!(
      ctx,
      "harness",
      session,
      "codex",
      codex_model,
      "Reply with one short sentence confirming you received this message.",
      []
    )
  end
end
