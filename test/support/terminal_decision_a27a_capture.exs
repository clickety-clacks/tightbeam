defmodule Tightbeam.TerminalDecisionA27aCaptureTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Gateway, Model, Org, Roles, Rules}
  alias Tightbeam.Wire.Router

  @capture_output System.fetch_env!("TIGHTBEAM_A27A_CAPTURE_OUT")
  @source_commit System.fetch_env!("TIGHTBEAM_A27A_SOURCE_COMMIT")
  @repo_root System.get_env("TIGHTBEAM_A27A_REPO_ROOT", Path.expand("../..", __DIR__))
  @binary System.get_env(
            "TIGHTBEAM_A27A_BINARY",
            Path.join(@repo_root, "cli/target/release/tightbeam")
          )
  @spec_sha256 "7a0affca1a550eb23bd6be0b331e8107bb6e85825d2496f207ba40042684187c"
  @unknown_id "dr_ffffffff-ffff-4fff-bfff-ffffffffffff"
  @unknown_id_2 "dr_eeeeeeee-eeee-4eee-aeee-eeeeeeeeeeee"
  @nonvisible_id "dr_00000000-0000-4000-8000-000000000001"

  defmodule NudgeSink do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, :ok}
    def handle_call({:fire_matching, _fact_id}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    unless File.exists?(@binary) do
      raise "capture CLI missing: #{@binary}; build cli/target/release/tightbeam first"
    end

    db = :"terminal_a27a_capture_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    scheduler = :"terminal_a27a_capture_wakes_#{System.unique_integer([:positive])}"
    start_supervised!({NudgeSink, scheduler})
    {:ok, calls} = start_supervised({Agent, fn -> [] end})

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-terminal-a27a-#{System.unique_integer([:positive])}"
      )

    workdir = Path.join(base_dir, "work/session/nested")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    Tightbeam.TestCase.register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: base_dir, cli_bin: nil}
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('capture-owner', 1, 1)"
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('capture-foreign', 0, 1)"
      )

    raiser = create_session(db, "capture-raiser", "capture-owner")
    foreign = create_session(db, "capture-foreign-raiser", "capture-foreign")

    Roles.create!(db, "capture-raiser", "capture-owner", raiser.session_key)
    Roles.create!(db, "capture-foreign-raiser", "capture-foreign", foreign.session_key)

    gateway_config = %{
      db: db,
      base_dir: base_dir,
      cwd: base_dir,
      wake_tick_ms: 1_000,
      wake_scheduler: scheduler
    }

    Archetypes.load!(base_dir)
    real_handlers = Gateway.handlers(gateway_config)
    Rules.load!(base_dir, Map.keys(real_handlers))

    handlers =
      Map.new(real_handlers, fn {verb, handler} ->
        {verb,
         fn call ->
           Agent.update(calls, &[call | &1])
           handler.(call)
         end}
      end)

    router_opts =
      Router.init(
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_terminal_a27a",
        session_status: fn _ -> nil end
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    session_dir = Path.join(base_dir, "work/session")

    File.write!(
      Path.join(session_dir, ".tightbeam-session"),
      JSON.encode!(%{
        url: "http://127.0.0.1:#{port}",
        token: raiser.cli_token,
        sessionKey: raiser.session_key
      })
    )

    %{
      base_dir: base_dir,
      binary: @binary,
      calls: calls,
      db: db,
      foreign: foreign,
      raiser: raiser,
      router_opts: router_opts,
      workdir: workdir
    }
  end

  test "capture exact REST-absent A-27a evidence", ctx do
    ids = create_fixture_state(ctx)
    _discard_setup_calls = drain_calls(ctx.calls)

    gateway = %{
      "openDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.open}),
      "withdrawnDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.withdrawn}),
      "supersededDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.superseded}),
      "ruledList" => wire_capture(ctx, "capture-owner", "decision-requests", %{status: "ruled"}),
      "ruledDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.ruled}),
      "hiddenDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.hidden}),
      "unknownDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: @unknown_id}),
      "nonvisibleDetail" =>
        wire_capture(ctx, "capture-owner", "decision-request", %{request: @nonvisible_id})
    }

    cli = %{
      "ruledDetail" => cli_capture(ctx, ["decision-request", "--request", ids.ruled], "ruled"),
      "unknownDetail" =>
        cli_capture(ctx, ["decision-request", "--request", @unknown_id], "unknown"),
      "nonvisibleDetail" =>
        cli_capture(ctx, ["decision-request", "--request", @nonvisible_id], "nonvisible"),
      "parser" => %{
        "missing" => cli_capture(ctx, ["decision-request"], "parser-missing"),
        "blank" => cli_capture(ctx, ["decision-request", "--request", ""], "parser-blank"),
        "prefix" =>
          cli_capture(ctx, ["decision-request", "--request", "dr_12345678"], "parser-prefix"),
        "positional" => cli_capture(ctx, ["decision-request", @unknown_id], "parser-positional"),
        "duplicate" =>
          cli_capture(
            ctx,
            [
              "decision-request",
              "--request",
              @unknown_id,
              "--request",
              @unknown_id_2
            ],
            "parser-duplicate"
          ),
        "target" =>
          cli_capture(
            ctx,
            ["decision-request", "--request", @unknown_id, "--target", "main"],
            "parser-target"
          )
      }
    }

    corrupt_impossible!(ctx.db, ids.impossible)

    gateway =
      Map.merge(gateway, %{
        "impossibleList" =>
          wire_capture(ctx, "capture-owner", "decision-requests", %{status: "ruled"}),
        "impossibleDetail" =>
          wire_capture(ctx, "capture-owner", "decision-request", %{request: ids.impossible})
      })

    cli =
      Map.put(
        cli,
        "impossibleDetail",
        cli_capture(ctx, ["decision-request", "--request", ids.impossible], "impossible")
      )

    capture = %{
      "proofArm" => "rest-absent",
      "sourceCommit" => @source_commit,
      "specFileSha256" => @spec_sha256,
      "routeInventory" => route_inventory(),
      "builtCli" => cli_identity(ctx.binary),
      "gatewayInvocation" => %{
        "route" => "/agent/dispatch",
        "transport" => "real Tightbeam.Wire.Router with real Gateway handlers"
      },
      "fixtureSetupPath" => "test/support/terminal_decision_a27a_capture.exs",
      "fixtureIds" => Map.new(ids),
      "gateway" => gateway,
      "cli" => cli,
      "integrityEvidence" => evidence_counts(ctx.db, ids)
    }

    File.mkdir_p!(Path.dirname(@capture_output))
    File.write!(@capture_output, JSON.encode!(capture) <> "\n")
  end

  defp create_fixture_state(ctx) do
    open = ask(ctx, ctx.raiser.cli_token, "capture open?")

    legacy = ask(ctx, ctx.raiser.cli_token, "capture legacy?")
    legacy_row = rule(ctx, "capture-owner", legacy)
    make_legacy_if_supported(ctx.db, legacy, legacy_row["rulingFactId"])

    ruled = ask(ctx, ctx.raiser.cli_token, "capture ruled?")
    rule(ctx, "capture-owner", ruled)

    withdrawn = ask(ctx, ctx.raiser.cli_token, "capture withdrawn?")

    wire!(ctx, ctx.raiser.cli_token, "operator-withdraw", %{
      request: withdrawn,
      reason: "captured withdrawal"
    })

    superseded = ask(ctx, ctx.raiser.cli_token, "capture superseded?")

    _replacement =
      wire!(ctx, ctx.raiser.cli_token, "operator-ask", %{
        question: "capture replacement?",
        options: [%{label: "accept"}, %{label: "decline"}],
        supersedes: superseded
      })

    hidden = ask(ctx, ctx.foreign.cli_token, "capture hidden?")
    rule(ctx, "capture-foreign", hidden)

    impossible = ask(ctx, ctx.raiser.cli_token, "capture impossible?")
    rule(ctx, "capture-owner", impossible)

    insert_nonvisible_statute!(ctx.db)

    %{
      open: open,
      ruled: ruled,
      withdrawn: withdrawn,
      superseded: superseded,
      legacy: legacy,
      hidden: hidden,
      impossible: impossible,
      nonvisible: @nonvisible_id,
      unknown: @unknown_id
    }
  end

  defp corrupt_impossible!(db, request_id) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO lifecycle_events (ts, kind, subject, detail) VALUES (?1, 'decision_request_ruled', ?2, NULL)",
        [System.system_time(:millisecond), request_id]
      )
  end

  defp ask(ctx, token, question) do
    wire!(ctx, token, "operator-ask", %{
      question: question,
      options: [%{label: "accept"}, %{label: "decline"}]
    })["id"]
  end

  defp rule(ctx, owner, id) do
    wire!(ctx, "tbc_terminal_a27a", "operator-rule", %{request: id, decision: "accept"},
      as_user: owner
    )
  end

  defp wire!(ctx, token, verb, params, opts \\ []) do
    response = wire_conn(ctx, token, verb, params, opts)

    unless response.status == 200 do
      raise "fixture setup #{verb} failed: #{response.status} #{response.resp_body}"
    end

    JSON.decode!(response.resp_body)["result"]
  end

  defp wire_capture(ctx, as_user, verb, params) do
    response = wire_conn(ctx, "tbc_terminal_a27a", verb, params, as_user: as_user)
    %{"status" => response.status, "body" => response.resp_body}
  end

  defp wire_conn(ctx, token, verb, params, opts) do
    body = %{"verb" => verb, "params" => params}
    body = if opts[:as_user], do: Map.put(body, "asUser", opts[:as_user]), else: body

    conn(:post, "/agent/dispatch", JSON.encode!(body))
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(ctx.router_opts)
  end

  defp cli_capture(ctx, args, label) do
    _discard_prior_calls = drain_calls(ctx.calls)
    stdout_path = Path.join(ctx.base_dir, "#{label}.stdout")
    stderr_path = Path.join(ctx.base_dir, "#{label}.stderr")
    wrapper = Path.expand("capture_cli.sh", __DIR__)

    {status_text, 0} =
      System.cmd(
        "/bin/sh",
        [wrapper, stdout_path, stderr_path, ctx.binary | args],
        cd: ctx.workdir
      )

    %{
      "exitStatus" => status_text |> String.trim() |> String.to_integer(),
      "stdout" => File.read!(stdout_path),
      "stderr" => File.read!(stderr_path),
      "wireRequests" => drain_calls(ctx.calls) |> Enum.map(&wire_request/1)
    }
  end

  defp wire_request(call) do
    %{
      "verb" => call.verb,
      "params" =>
        Map.new(call.params, fn {key, value} ->
          key =
            key
            |> Atom.to_string()
            |> Macro.camelize()
            |> then(&(String.downcase(String.first(&1)) <> String.slice(&1, 1..-1//1)))

          {key, value}
        end)
    }
  end

  defp drain_calls(agent), do: Agent.get_and_update(agent, &{Enum.reverse(&1), []})

  defp route_inventory do
    router_path = Path.join(@repo_root, "lib/tightbeam/wire/router.ex")
    pattern = ~s(^[[:space:]]*get "/api/decision-requests)
    {stdout, exit_status} = System.cmd("rg", ["-n", pattern, router_path])

    %{
      "command" => ~s(rg -n '#{pattern}' lib/tightbeam/wire/router.ex),
      "exitStatus" => exit_status,
      "stdout" => stdout,
      "routes" =>
        stdout
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [_, route] = Regex.run(~r/get "([^"]+)"/, line)
          %{"verb" => "GET", "path" => route}
        end)
    }
  end

  defp cli_identity(binary) do
    {version, 0} = System.cmd(binary, ["version"])
    {sha256, 0} = System.cmd("sha256sum", [binary])

    %{
      "path" => "cli/target/release/tightbeam",
      "version" => String.trim(version),
      "sha256" => sha256 |> String.split() |> hd()
    }
  end

  defp make_legacy_if_supported(db, request_id, fact_id) do
    {:ok, columns} = DB.query(db, "PRAGMA table_info(decision_requests)")

    if Enum.any?(columns, fn [_cid, name | _] -> name == "ruledViaPrincipal" end) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_request_terminal_epoch SET legacyRulingFactMaxId=?1 WHERE id=0",
          [fact_id]
        )

      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET ruledViaPrincipal=NULL, ruledViaSessionState=NULL WHERE id=?1",
          [request_id]
        )
    end
  end

  defp insert_nonvisible_statute!(db) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, raiserSessionKey, ownerUserId, raisedAt, deadlineAt,
           statuteName, actionKey, question, options, context, status)
        VALUES (?1, 'statute', 'session:capture-foreign-raiser', 'capture-foreign-raiser',
                'capture-foreign', 1, 2, 'capture', 'nonvisible', 'hidden statute?',
                ?2, ?3, 'open')
        """,
        [@nonvisible_id, JSON.encode!([%{"label" => "allow"}]), JSON.encode!(%{})]
      )
  end

  defp evidence_counts(db, ids) do
    {:ok, tables} =
      DB.query(
        db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='decision_request_integrity_evidence'"
      )

    if tables == [] do
      %{"supported" => false}
    else
      %{
        "supported" => true,
        "hidden" => evidence_count(db, ids.hidden),
        "impossible" => evidence_count(db, ids.impossible)
      }
    end
  end

  defp evidence_count(db, request_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM decision_request_integrity_evidence WHERE requestId=?1",
        [request_id]
      )

    count
  end

  defp create_session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      is_built_in: true
    })
  end
end
