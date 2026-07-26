defmodule Tightbeam.ClientE2E.Journeys do
  @moduledoc """
  The journeys — J0 through J6 of client-e2e-v1, each implementing its
  SMOKE.md steps BY NUMBER and inheriting the runbook's PASS conditions.
  SMOKE.md is normative; where this module and the runbook disagree, the
  runbook wins and this module is the bug.

  ## The two-column oracle contract

  `oracles/0` is the declarative half: for every SMOKE step this driver walks,
  one row naming the CLIENT assertion (what arrives on the socket / comes back
  from a route — the sim client's analog of the accessibility tree) and the
  SUBSTRATE assertion (the `state.db` row SMOKE.md names). Both columns must
  hold for the step to pass; "may" is not part of this contract.

  Where one side genuinely has no observable counterpart, the column says so
  as `{:none, reason}` — silence is illegal, and `Tightbeam.ClientE2ETest`
  fails the build if a column is simply missing. The executable half lives in
  `run/2`; the two are cross-checked by the same test, so an oracle that is
  described but not asserted (or asserted but not described) cannot ship.

  ## What "the client" means here

  The sim client is protocol-faithful, not pixel-faithful: it proves the
  gateway emits everything a client needs to render each journey, in the right
  order, with the right correlation. Two of the spec's surfaces are outside
  what any wire-level driver can witness and are named as such in the oracle
  table — the rendered typing INDICATOR (the driver asserts the typing frames
  it is rendered from) and the model FOOTER (the driver asserts the payload
  satisfies the client's decode contract; the rendered assertion is the app's
  own regression test, `ClawlineTests/SessionStatusDecodeResilienceTests.swift`).
  """

  alias Tightbeam.ClientE2E.{Scorecard, SimClient, Substrate}

  @typedoc """
  Journey context. `client` is the live sim client, `main_key` the admin's
  Main stream, `leg` the {harness, model} pass this run is walking.
  """
  @type ctx :: %{
          required(:base_dir) => String.t(),
          required(:host) => String.t(),
          required(:port) => :inet.port_number(),
          required(:client) => SimClient.t(),
          required(:main_key) => String.t() | nil,
          required(:leg) => map(),
          required(:turn_timeout_ms) => pos_integer(),
          required(:settle_ms) => pos_integer(),
          optional(atom()) => term()
        }

  @ids ~w(J0 J1 J2 J3 J4 J5 J6)

  # The oracle table. `client` and `substrate` are the two normative columns;
  # `{:none, reason}` is the only legal way for a column to be empty.
  @oracles [
    %{
      journey: "J0",
      step: "1",
      label: "boot",
      action: "GET /version against the freshly booted gateway",
      client: "protocolVersion == 1 in the response body",
      substrate: "state.db exists and carries the sessions schema"
    },
    %{
      journey: "J0",
      step: "2",
      label: "pair",
      action: "pair_request with a claimed name, then auth on a second socket",
      client:
        "pair_result success; auth_result success; stream_snapshot carries the built-in Main; sync_complete arrives (the app leaves its connecting state)",
      substrate: "one devices row `allowlisted`; one users row with isAdmin=1"
    },
    %{
      journey: "J1",
      step: "3",
      label: "converse",
      action: ~s(post "hello, who are you?" in Main),
      client:
        "echo message frame carrying our clientMessageId; typing active=true; at least one agent_progress with non-empty progressText; assistant message replying to that clientMessageId; typing active=false and no further typing=true through the settle window",
      substrate: "turn row for that clientMessageId reaches `delivered`"
    },
    %{
      journey: "J1",
      step: "4",
      label: "tool use",
      action: "post a prompt that provokes a tool call (uname)",
      client:
        "a progress label during the turn (tool-title vocabulary is [divergent] per harness); assistant bubble reports the command's real output; indicator clears",
      substrate: "turn row `delivered`"
    },
    %{
      journey: "J2",
      step: "5",
      label: "create stream",
      action: "POST /api/streams, then post in the new stream",
      client:
        "stream_created arrives on the EXISTING socket (no reconnect); the new stream is in the frame; posting in it completes a turn",
      substrate: "sessions row exists with origin = the creating user"
    },
    %{
      journey: "J2",
      step: "6",
      label: "rename stream",
      action: "PATCH /api/streams/:key with a new displayName",
      client: "stream_updated carries the new displayName live",
      substrate: "sessions.displayName is the new name"
    },
    %{
      journey: "J2",
      step: "7",
      label: "retire stream",
      action: "DELETE /api/streams/:key",
      client: "stream_deleted for that sessionKey arrives live",
      substrate: "sessions.state = 'retired' AND the stream's messages REMAIN (soft retention)"
    },
    %{
      journey: "J3",
      step: "8",
      label: "cancel",
      action: "post a long task, then POST /api/session-control cancel_current_run mid-turn",
      client:
        "prompt_turn_state state=canceled with terminalState=true; typing clears; NO assistant bubble for that turn through the settle window; a following post completes normally (lane drained)",
      substrate: "turn row `canceled`; the following turn row `delivered`"
    },
    %{
      journey: "J4",
      step: "9",
      label: "queueing",
      action: ~s(post "say ONE", "say TWO", "say THREE" back-to-back without waiting),
      client:
        "three echoes before any assistant reply; three assistant bubbles whose replyToClientMessageId order matches the post order",
      substrate:
        "never more than one `running` turn for the session (sampled DURING the run); all three turn rows `delivered`"
    },
    %{
      journey: "J5",
      step: "10",
      label: "concurrency",
      action: "slow prompt in Main, immediate post in Smoke B, then a second post in Main",
      client:
        "Smoke B's assistant bubble arrives BEFORE Main's first; every assistant bubble carries its own sessionKey (no cross-talk); Main's two turns complete in post order",
      substrate:
        "at peak, two `running` rows with DIFFERENT sessionKeys (sampled DURING the run); all turns `delivered`"
    },
    %{
      journey: "J6",
      step: "11",
      label: "/new",
      action: ~s(post "/new" as ordinary text),
      client: "J1's turn-completion oracle verbatim (bubble, indicator clears)",
      substrate: "turn row `delivered` — the substrate interprets no message content"
    },
    %{
      journey: "J6",
      step: "12",
      label: "/compact",
      action: ~s(post "/compact" as ordinary text),
      client: "J1's turn-completion oracle verbatim",
      substrate: "turn row `delivered`"
    },
    %{
      journey: "J6",
      step: "13a",
      label: "/model",
      action: ~s(post "/model" as ordinary text),
      client: "J1's turn-completion oracle verbatim",
      substrate: "turn row `delivered`"
    },
    %{
      journey: "J6",
      step: "13b",
      label: "model change",
      action:
        "POST /api/session-control set_model to a different catalog ref, then post again",
      client:
        "GET /api/session-status reports the new base ref; the payload satisfies the client's decode contract (every field the Swift SessionStatus decoder requires is present); the next turn completes",
      substrate: "sessions.model is the new ref; the following turn row `delivered`"
    },
    %{
      journey: "J6",
      step: "13c",
      label: "model footer",
      action: "render the changed model in the client's footer",
      client:
        {:none,
         "the sim client has no rendered footer; the rendered assertion is the app's own " <>
           "ClawlineTests/SessionStatusDecodeResilienceTests.swift plus the chat_footer_model_picker / " <>
           "chat_footer_label identifiers. The wire half of step 13 is row 13b. Note for a UI " <>
           "driver: the footer renders the catalog's DISPLAY NAME, not the ref that was posted, " <>
           "so asserting the ref verbatim fails against a correct client."},
      substrate:
        {:none, "a rendering assertion has no substrate row; 13b carries the substrate proof"}
    }
  ]

  @doc "Journey ids in run order."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "The declarative two-column oracle table (see the moduledoc)."
  @spec oracles() :: [map()]
  def oracles, do: @oracles

  @doc "The SMOKE steps this driver automates, in scorecard order."
  @spec automated_steps() :: [String.t()]
  def automated_steps, do: Enum.map(@oracles, & &1.step)

  @doc """
  Runs one journey, returning the updated context and its scorecard rows.

  A journey never raises past this boundary: an unexpected error becomes an
  `incomplete` row carrying the exception, because a driver that dies mid-run
  reports nothing at all about the steps it did walk.
  """
  @spec run(ctx(), String.t()) :: {ctx(), [Scorecard.Row.t()]}
  def run(ctx, id) do
    walk(ctx, id)
  rescue
    error ->
      {ctx,
       [
         Scorecard.incomplete(
           id,
           "journey #{id}",
           "driver error: " <> Exception.message(error),
           journey: id
         )
       ]}
  end

  # --- J0: boot + pair ---------------------------------------------------------

  defp walk(ctx, "J0") do
    {_status, version} = SimClient.get(ctx.client, "/version")

    boot =
      cond do
        is_map(version) and version["protocolVersion"] == 1 and schema_present?(ctx) ->
          Scorecard.pass("1", "boot", journey: "J0")

        is_map(version) and version["protocolVersion"] == 1 ->
          Scorecard.fail("1", "boot", "no sessions schema in state.db", journey: "J0")

        true ->
          Scorecard.fail("1", "boot", "GET /version returned #{inspect(version)}", journey: "J0")
      end

    client = ctx.client
    snapshot = SimClient.find(client, 0, &(&1["type"] == "stream_snapshot"))
    streams = (snapshot && snapshot["streams"]) || []
    main = Enum.find(streams, &(&1["kind"] == "main"))
    sync = SimClient.find(client, 0, &(&1["type"] == "sync_complete"))
    devices = Substrate.devices(ctx.base_dir)
    users = Substrate.users(ctx.base_dir)
    admin? = Enum.any?(users, &(&1["isAdmin"] == 1))
    allowlisted? = Enum.any?(devices, &(&1["status"] == "allowlisted"))

    pair =
      cond do
        is_nil(main) ->
          Scorecard.fail("2", "pair", "stream_snapshot carried no Main: #{inspect(streams)}",
            journey: "J0"
          )

        is_nil(sync) ->
          Scorecard.fail("2", "pair", "no sync_complete — the app never leaves connecting",
            journey: "J0"
          )

        not allowlisted? ->
          Scorecard.fail("2", "pair", "no allowlisted device row: #{inspect(devices)}",
            journey: "J0"
          )

        not admin? ->
          Scorecard.fail("2", "pair", "first user is not admin: #{inspect(users)}", journey: "J0")

        true ->
          Scorecard.pass("2", "pair", journey: "J0")
      end

    {%{ctx | main_key: main && main["sessionKey"]}, [boot, pair]}
  end

  # --- J1: converse ------------------------------------------------------------

  defp walk(ctx, "J1") do
    {ctx, converse} = turn_completes(ctx, ctx.main_key, "hello, who are you?", "3", "converse", "J1")

    uname = String.trim(elem(System.cmd("uname", ["-s"]), 0))
    prompt = "Run the shell command `uname -s` and reply with exactly its output and nothing else."
    {ctx, result} = observe_turn(ctx, ctx.main_key, prompt)

    tool =
      cond do
        result.error ->
          Scorecard.fail("4", "tool use", result.error, journey: "J1")

        result.progress == [] ->
          Scorecard.fail("4", "tool use", "no progress label arrived during the turn",
            journey: "J1"
          )

        not String.contains?(result.reply_text || "", uname) ->
          Scorecard.fail(
            "4",
            "tool use",
            "assistant did not report the command output (#{uname}): #{inspect(result.reply_text)}",
            journey: "J1"
          )

        true ->
          Scorecard.pass("4", "tool use", journey: "J1")
      end

    {ctx, [converse, tool]}
  end

  # --- J2: lifecycle -----------------------------------------------------------

  defp walk(ctx, "J2") do
    watermark = SimClient.mark(ctx.client)
    key_suffix = System.unique_integer([:positive])

    {status, created} =
      SimClient.post_json(ctx.client, "/api/streams", %{
        "displayName" => "Smoke",
        "idempotencyKey" => "client-e2e-smoke-#{key_suffix}"
      })

    session_key = get_in(created, ["stream", "sessionKey"]) || created["sessionKey"]

    if status not in [200, 201] or is_nil(session_key) do
      {ctx,
       [
         Scorecard.fail("5", "create stream", "POST /api/streams → #{status} #{inspect(created)}",
           journey: "J2"
         ),
         Scorecard.incomplete("6", "rename stream", "no stream to rename", journey: "J2"),
         Scorecard.incomplete("7", "retire stream", "no stream to retire", journey: "J2")
       ]}
    else
      {ctx, create} = j2_create(ctx, watermark, session_key)
      {ctx, rename} = j2_rename(ctx, session_key)
      {ctx, retire} = j2_retire(ctx, session_key)
      {ctx, [create, rename, retire]}
    end
  end

  # --- J3: cancel --------------------------------------------------------------

  defp walk(ctx, "J3") do
    watermark = SimClient.mark(ctx.client)

    {:ok, client, cmid} =
      SimClient.post(ctx.client, ctx.main_key, "Count to 200 slowly, one line per number.")

    case SimClient.await(
           client,
           watermark,
           &(&1["type"] == "typing" and &1["active"] == true and &1["sessionKey"] == ctx.main_key),
           ctx.turn_timeout_ms
         ) do
      {:error, reason, client} ->
        {%{ctx | client: client},
         [Scorecard.fail("8", "cancel", "no typing indicator to cancel (#{inspect(reason)})", journey: "J3")]}

      {:ok, _typing, client} ->
        cancel_watermark = SimClient.mark(client)
        ctx = %{ctx | client: client}

        {status, _body} =
          SimClient.post_json(ctx.client, "/api/session-control", %{
            "sessionKey" => ctx.main_key,
            "action" => "cancel_current_run"
          })

        {canceled, client} =
          case SimClient.await(
                 ctx.client,
                 cancel_watermark,
                 &(&1["type"] == "event" and &1["event"] == "prompt_turn_state" and
                     get_in(&1, ["payload", "messageId"]) == cmid and
                     get_in(&1, ["payload", "state"]) == "canceled"),
                 ctx.turn_timeout_ms
               ) do
            {:ok, frame, client} -> {frame, client}
            {:error, _reason, client} -> {nil, client}
          end

        client = SimClient.settle(client, ctx.settle_ms)
        ctx = %{ctx | client: client}

        stray_reply =
          SimClient.find(
            ctx.client,
            cancel_watermark,
            &(&1["type"] == "message" and &1["role"] == "assistant" and
                &1["replyToClientMessageId"] == cmid)
          )

        lingering =
          SimClient.find(
            ctx.client,
            cancel_watermark,
            &(&1["type"] == "typing" and &1["active"] == true and &1["sessionKey"] == ctx.main_key)
          )

        turn = Substrate.turn_for_client_message(ctx.base_dir, cmid)
        {ctx, drained} = turn_completes(ctx, ctx.main_key, "say exactly: DRAINED", "8b", "post-cancel turn", "J3")

        row =
          cond do
            status != 200 ->
              Scorecard.fail("8", "cancel", "session-control cancel → #{status}", journey: "J3")

            is_nil(canceled) ->
              Scorecard.fail("8", "cancel", "no canceled prompt_turn_state for the turn", journey: "J3")

            get_in(canceled, ["payload", "terminalState"]) != true ->
              Scorecard.fail("8", "cancel", "canceled state was not terminal", journey: "J3")

            not is_nil(stray_reply) ->
              Scorecard.fail("8", "cancel", "an assistant bubble arrived for the canceled turn", journey: "J3")

            not is_nil(lingering) ->
              Scorecard.fail("8", "cancel", "the typing indicator came back after the cancel", journey: "J3")

            is_nil(turn) or turn["status"] != "canceled" ->
              Scorecard.fail("8", "cancel", "turn row is #{inspect(turn && turn["status"])}, not canceled", journey: "J3")

            drained.status != :pass ->
              Scorecard.fail("8", "cancel", "the lane did not drain: #{drained.note}", journey: "J3")

            true ->
              Scorecard.pass("8", "cancel", journey: "J3")
          end

        {ctx, [row]}
    end
  end

  # --- J4: queueing ------------------------------------------------------------

  defp walk(ctx, "J4") do
    watermark = SimClient.mark(ctx.client)
    prompts = ["say ONE", "say TWO", "say THREE"]

    {client, ids} =
      Enum.reduce(prompts, {ctx.client, []}, fn prompt, {client, ids} ->
        {:ok, client, id} = SimClient.post(client, ctx.main_key, prompt)
        {client, ids ++ [id]}
      end)

    ctx = %{ctx | client: client}

    {ctx, peaks} =
      Substrate.sample_while(ctx.base_dir, 200, fn ->
        Enum.reduce(ids, ctx, fn id, ctx ->
          {_ok, _frame, client} =
            case SimClient.await(
                   ctx.client,
                   watermark,
                   &(&1["type"] == "message" and &1["role"] == "assistant" and
                       &1["replyToClientMessageId"] == id),
                   ctx.turn_timeout_ms
                 ) do
              {:ok, frame, client} -> {:ok, frame, client}
              {:error, reason, client} -> {:error, reason, client}
            end

          %{ctx | client: client}
        end)
      end)

    frames = SimClient.frames_since(ctx.client, watermark)
    echoes = for f <- frames, f["type"] == "message", f["role"] == "user", do: f["clientMessageId"]
    replies = for f <- frames, f["type"] == "message", f["role"] == "assistant", do: f["replyToClientMessageId"]
    first_reply_index = Enum.find_index(frames, &(&1["type"] == "message" and &1["role"] == "assistant"))
    echo_indexes = for {f, i} <- Enum.with_index(frames), f["type"] == "message", f["role"] == "user", do: i
    turns = Enum.map(ids, &Substrate.turn_for_client_message(ctx.base_dir, &1))
    peak = Map.get(peaks, ctx.main_key, 0)

    row =
      cond do
        Enum.take(echoes, 3) != ids ->
          Scorecard.fail("9", "queueing", "echoes were #{inspect(echoes)}, expected #{inspect(ids)}", journey: "J4")

        first_reply_index && Enum.any?(echo_indexes, &(&1 > first_reply_index)) ->
          Scorecard.fail("9", "queueing", "an echo arrived after the first assistant reply — echoes are not immediate", journey: "J4")

        Enum.filter(replies, &(&1 in ids)) != ids ->
          Scorecard.fail("9", "queueing", "assistant replies arrived out of order: #{inspect(replies)}", journey: "J4")

        peak > 1 ->
          Scorecard.fail("9", "queueing", "#{peak} turns were running at once in one lane", journey: "J4")

        Enum.any?(turns, &(is_nil(&1) or &1["status"] != "delivered")) ->
          Scorecard.fail("9", "queueing", "turn rows: #{inspect(Enum.map(turns, & &1 && &1["status"]))}", journey: "J4")

        true ->
          Scorecard.pass("9", "queueing", journey: "J4")
      end

    {ctx, [row]}
  end

  # --- J5: concurrency ---------------------------------------------------------

  defp walk(ctx, "J5") do
    {status, created} =
      SimClient.post_json(ctx.client, "/api/streams", %{
        "displayName" => "Smoke B",
        "idempotencyKey" => "client-e2e-smoke-b-#{System.unique_integer([:positive])}"
      })

    session_key = get_in(created, ["stream", "sessionKey"]) || created["sessionKey"]

    if status not in [200, 201] or is_nil(session_key) do
      {ctx, [Scorecard.fail("10", "concurrency", "could not create Smoke B: #{status} #{inspect(created)}", journey: "J5")]}
    else
      watermark = SimClient.mark(ctx.client)

      {:ok, client, slow_id} =
        SimClient.post(ctx.client, ctx.main_key, "Write a haiku about each of the 10 planets and dwarf planets, one at a time.")

      {:ok, client, b_id} = SimClient.post(client, session_key, "what is 2+2?")
      {:ok, client, done_id} = SimClient.post(client, ctx.main_key, "now say exactly: DONE")
      ctx = %{ctx | client: client}

      {ctx, peaks} =
        Substrate.sample_while(ctx.base_dir, 150, fn ->
          Enum.reduce([b_id, slow_id, done_id], ctx, fn id, ctx ->
            case SimClient.await(
                   ctx.client,
                   watermark,
                   &(&1["type"] == "message" and &1["role"] == "assistant" and
                       &1["replyToClientMessageId"] == id),
                   ctx.turn_timeout_ms
                 ) do
              {:ok, _frame, client} -> %{ctx | client: client}
              {:error, _reason, client} -> %{ctx | client: client}
            end
          end)
        end)

      frames = SimClient.frames_since(ctx.client, watermark)
      reply_order = for f <- frames, f["type"] == "message", f["role"] == "assistant", do: f["replyToClientMessageId"]
      b_reply = Enum.find(frames, &(&1["type"] == "message" and &1["role"] == "assistant" and &1["replyToClientMessageId"] == b_id))
      cross_talk = Enum.find(frames, &(&1["type"] == "message" and &1["role"] == "assistant" and &1["replyToClientMessageId"] == b_id and &1["sessionKey"] != session_key))
      parallel? = Map.get(peaks, ctx.main_key, 0) >= 1 and Map.get(peaks, session_key, 0) >= 1
      turns = Enum.map([slow_id, b_id, done_id], &Substrate.turn_for_client_message(ctx.base_dir, &1))

      row =
        cond do
          is_nil(b_reply) ->
            Scorecard.fail("10", "concurrency", "Smoke B never replied", journey: "J5")

          not is_nil(cross_talk) ->
            Scorecard.fail("10", "concurrency", "cross-talk: a reply landed in the wrong stream", journey: "J5")

          Enum.find_index(reply_order, &(&1 == b_id)) > Enum.find_index(reply_order, &(&1 == slow_id)) ->
            Scorecard.fail("10", "concurrency", "Smoke B's reply waited for Main's slow turn — the lanes are not parallel", journey: "J5")

          not parallel? ->
            Scorecard.fail("10", "concurrency", "never sampled running turns in both lanes: #{inspect(peaks)}", journey: "J5")

          Enum.filter(reply_order, &(&1 in [slow_id, done_id])) != [slow_id, done_id] ->
            Scorecard.fail("10", "concurrency", "Main's turns completed out of order: #{inspect(reply_order)}", journey: "J5")

          Enum.any?(turns, &(is_nil(&1) or &1["status"] != "delivered")) ->
            Scorecard.fail("10", "concurrency", "turn rows: #{inspect(Enum.map(turns, & &1 && &1["status"]))}", journey: "J5")

          true ->
            Scorecard.pass("10", "concurrency", journey: "J5")
        end

      {ctx, [row]}
    end
  end

  # --- J6: slash commands ------------------------------------------------------

  defp walk(ctx, "J6") do
    {ctx, new_row} = turn_completes(ctx, ctx.main_key, "/new", "11", "/new", "J6")
    {ctx, compact_row} = turn_completes(ctx, ctx.main_key, "/compact", "12", "/compact", "J6")
    {ctx, model_row} = turn_completes(ctx, ctx.main_key, "/model", "13a", "/model", "J6")
    {ctx, change_row} = j6_model_change(ctx)

    footer_row =
      Scorecard.manual(
        "13c",
        "model footer",
        "rendered-footer assertion is app-side: ClawlineTests/SessionStatusDecodeResilienceTests.swift " <>
          "plus the chat_footer_model_picker / chat_footer_label identifiers; the wire half is row 13b",
        journey: "J6"
      )

    {ctx, [new_row, compact_row, model_row, change_row, footer_row]}
  end

  defp j6_model_change(ctx) do
    {_status, before} = SimClient.get(ctx.client, "/api/session-status", sessionKey: ctx.main_key)
    current = get_in(before, ["display", "model"])

    candidate =
      before
      |> get_in(["modelCatalog", "models"])
      |> List.wrap()
      |> Enum.map(&(&1["ref"] || &1["id"]))
      |> Enum.reject(&(is_nil(&1) or base_ref(&1) == current))
      |> List.first()

    if is_nil(candidate) do
      {ctx,
       Scorecard.incomplete(
         "13b",
         "model change",
         "the session's model catalog offers no second model to switch to (current " <>
           "#{inspect(current)}). An EMPTY catalog usually means the org's credential " <>
           "metadata row is missing (gateway log: needs_onboarding) — SMOKE.md " <>
           "§Fresh-org provisioning, repaired with `tightbeam onboard <provider>`.",
         journey: "J6"
       )}
    else
      {status, _body} =
        SimClient.post_json(ctx.client, "/api/session-control", %{
          "sessionKey" => ctx.main_key,
          "action" => "set_model",
          "model" => candidate
        })

      {_status, after_change} = SimClient.get(ctx.client, "/api/session-status", sessionKey: ctx.main_key)
      reported = get_in(after_change, ["display", "model"])
      missing = decode_contract_gaps(after_change)
      row = Substrate.session(ctx.base_dir, ctx.main_key)
      {ctx, next_turn} = turn_completes(ctx, ctx.main_key, "say exactly: MODEL OK", "13b-turn", "post-change turn", "J6")

      result =
        cond do
          status != 200 ->
            Scorecard.fail("13b", "model change", "set_model → #{status}", journey: "J6")

          reported != base_ref(candidate) ->
            Scorecard.fail("13b", "model change", "session-status reports #{inspect(reported)}, expected #{inspect(base_ref(candidate))}", journey: "J6")

          missing != [] ->
            Scorecard.fail("13b", "model change", "session-status omits fields the client's decoder requires: #{Enum.join(missing, ", ")}", journey: "J6")

          base_ref(row["model"]) != base_ref(candidate) ->
            Scorecard.fail("13b", "model change", "sessions.model is #{inspect(row["model"])}", journey: "J6")

          next_turn.status != :pass ->
            Scorecard.fail("13b", "model change", "the turn after the change did not complete: #{next_turn.note}", journey: "J6")

          true ->
            Scorecard.pass("13b", "model change", journey: "J6")
        end

      {ctx, result}
    end
  end

  @doc """
  The fields the client's `SessionStatus` decoder requires, and whether the
  payload carries them.

  This is the wire-side half of the shipped failure the work item names: the
  Swift decode is all-or-nothing, so ONE missing key here empties the footer
  with a 200 response and nothing server-side to notice. Keep this list in
  step with `ios/Clawline/Clawline/Models/SessionStatus.swift`; the app-side
  regression tests assert the same contract from the other direction.
  """
  @spec decode_contract_gaps(term()) :: [String.t()]
  def decode_contract_gaps(status) when is_map(status) do
    required = [
      {"sessionKey", &is_binary/1},
      {"display", &is_map/1},
      {"run", &is_map/1},
      {"capabilities", &is_map/1}
    ]

    top = for {key, ok?} <- required, not ok?.(Map.get(status, key)), do: key
    run_state = if is_map(status["run"]) and is_nil(status["run"]["state"]), do: ["run.state"], else: []
    top ++ run_state
  end

  def decode_contract_gaps(_), do: ["<no session-status payload>"]

  # --- J2 helpers -------------------------------------------------------------

  defp j2_create(ctx, watermark, session_key) do
    {live, client} =
      case SimClient.await(
             ctx.client,
             watermark,
             &(&1["type"] == "stream_created" and
                 get_in(&1, ["stream", "sessionKey"]) == session_key),
             15_000
           ) do
        {:ok, frame, client} -> {frame, client}
        {:error, _reason, client} -> {nil, client}
      end

    ctx = %{ctx | client: client}
    {ctx, result} = observe_turn(ctx, session_key, "say exactly: SMOKE B READY")
    row = Substrate.session(ctx.base_dir, session_key)

    cond do
      is_nil(live) ->
        {ctx,
         Scorecard.fail("5", "create stream", "no live stream_created frame (client had to reconnect to see it)",
           journey: "J2"
         )}

      result.error ->
        {ctx, Scorecard.fail("5", "create stream", "post in the new stream: #{result.error}", journey: "J2")}

      is_nil(row) ->
        {ctx, Scorecard.fail("5", "create stream", "no sessions row for #{session_key}", journey: "J2")}

      row["origin"] != "user:#{ctx.client.user_id}" ->
        {ctx,
         Scorecard.fail("5", "create stream", "origin was #{inspect(row["origin"])}", journey: "J2")}

      true ->
        {ctx, Scorecard.pass("5", "create stream", journey: "J2")}
    end
  end

  defp j2_rename(ctx, session_key) do
    watermark = SimClient.mark(ctx.client)
    renamed = "Smoke Renamed"

    {status, _body} =
      SimClient.patch_json(ctx.client, "/api/streams/#{URI.encode_www_form(session_key)}", %{
        "displayName" => renamed
      })

    {frame, client} =
      case SimClient.await(
             ctx.client,
             watermark,
             &(&1["type"] == "stream_updated" and
                 get_in(&1, ["stream", "sessionKey"]) == session_key),
             15_000
           ) do
        {:ok, frame, client} -> {frame, client}
        {:error, _reason, client} -> {nil, client}
      end

    ctx = %{ctx | client: client}
    row = Substrate.session(ctx.base_dir, session_key)

    cond do
      status != 200 ->
        {ctx, Scorecard.fail("6", "rename stream", "PATCH → #{status}", journey: "J2")}

      is_nil(frame) ->
        {ctx, Scorecard.fail("6", "rename stream", "no live stream_updated frame", journey: "J2")}

      get_in(frame, ["stream", "displayName"]) != renamed ->
        {ctx,
         Scorecard.fail("6", "rename stream", "frame carried #{inspect(get_in(frame, ["stream", "displayName"]))}",
           journey: "J2"
         )}

      row["displayName"] != renamed ->
        {ctx, Scorecard.fail("6", "rename stream", "sessions.displayName is #{inspect(row["displayName"])}", journey: "J2")}

      true ->
        {ctx, Scorecard.pass("6", "rename stream", journey: "J2")}
    end
  end

  defp j2_retire(ctx, session_key) do
    watermark = SimClient.mark(ctx.client)
    before = length(Substrate.messages(ctx.base_dir, session_key))

    {status, _body} =
      SimClient.delete_json(ctx.client, "/api/streams/#{URI.encode_www_form(session_key)}", %{})

    {frame, client} =
      case SimClient.await(
             ctx.client,
             watermark,
             &(&1["type"] == "stream_deleted" and &1["sessionKey"] == session_key),
             15_000
           ) do
        {:ok, frame, client} -> {frame, client}
        {:error, _reason, client} -> {nil, client}
      end

    ctx = %{ctx | client: client}
    row = Substrate.session(ctx.base_dir, session_key)
    kept = length(Substrate.messages(ctx.base_dir, session_key))

    cond do
      status != 200 ->
        {ctx, Scorecard.fail("7", "retire stream", "DELETE → #{status}", journey: "J2")}

      is_nil(frame) ->
        {ctx, Scorecard.fail("7", "retire stream", "no live stream_deleted frame", journey: "J2")}

      row["state"] != "retired" ->
        {ctx, Scorecard.fail("7", "retire stream", "sessions.state is #{inspect(row["state"])}", journey: "J2")}

      kept < before or kept == 0 ->
        {ctx,
         Scorecard.fail("7", "retire stream", "messages were not soft-retained (#{before} → #{kept})",
           journey: "J2"
         )}

      true ->
        {ctx, Scorecard.pass("7", "retire stream", journey: "J2")}
    end
  end

  # --- shared turn oracle (J1's, reused verbatim by J2, J3 and J6) -------------

  @doc """
  J1's turn-completion oracle: echo, indicator on with progress, assistant
  reply, indicator clears, `delivered` row.

  J6 exists to catch a slash command dying pre-model and hanging the indicator
  forever, so it reuses this function rather than a paraphrase of it — a
  restatement is where the two drift and the regression class walks back in.
  """
  @spec turn_completes(ctx(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {ctx(), Scorecard.Row.t()}
  def turn_completes(ctx, session_key, content, step, label, journey) do
    {ctx, result} = observe_turn(ctx, session_key, content)

    row =
      case result.error do
        nil -> Scorecard.pass(step, label, journey: journey)
        error -> Scorecard.fail(step, label, error, journey: journey)
      end

    {ctx, row}
  end

  @doc """
  Posts one message and observes the whole turn, returning what the client saw
  and what the substrate recorded. `error` is nil when every leg of J1's
  oracle held.
  """
  @spec observe_turn(ctx(), String.t(), String.t()) :: {ctx(), map()}
  def observe_turn(ctx, session_key, content) do
    watermark = SimClient.mark(ctx.client)
    {:ok, client, cmid} = SimClient.post(ctx.client, session_key, content)

    {echo, client} = await_frame(client, watermark, &(&1["type"] == "message" and &1["clientMessageId"] == cmid), 30_000)

    {typing_on, client} =
      await_frame(client, watermark, &(&1["type"] == "typing" and &1["active"] == true and &1["sessionKey"] == session_key), 60_000)

    {reply, client} = await_reply(client, watermark, cmid, ctx)

    {typing_off, client} =
      await_frame(client, watermark, &(&1["type"] == "typing" and &1["active"] == false and &1["sessionKey"] == session_key), 30_000)

    settle_mark = SimClient.mark(client)
    client = SimClient.settle(client, ctx.settle_ms)
    ctx = %{ctx | client: client}

    lingering =
      SimClient.find(client, settle_mark, &(&1["type"] == "typing" and &1["active"] == true and &1["sessionKey"] == session_key))

    progress =
      client
      |> SimClient.frames_since(watermark)
      |> Enum.filter(&(&1["type"] == "agent_progress" and &1["sessionKey"] == session_key and (&1["progressText"] || "") != ""))

    turn =
      case Substrate.await_turn_terminal(ctx.base_dir, cmid, 30_000) do
        {:ok, row} -> row
        {:error, :timeout, row} -> row
      end

    # Order matters: when the turn row already says what went wrong, report
    # THAT rather than the client-side symptom it caused. "no assistant reply
    # within 180000ms" sends a reader looking at the client; "turn row is
    # failed (Invalid value for config option model: ...)" sends them to the
    # actual fault.
    error =
      cond do
        is_nil(echo) -> "no echo bubble for the posted message"
        is_nil(turn) -> "no turn row for the posted message"
        turn["status"] in ~w(failed failed_unknown) -> "turn row is #{turn["status"]}#{turn_error(turn)}"
        is_nil(typing_on) -> "typing indicator never turned on"
        progress == [] -> "no live progress text during the turn"
        is_nil(reply) -> "no assistant reply within #{ctx.turn_timeout_ms}ms"
        is_nil(typing_off) -> "typing indicator never cleared"
        not is_nil(lingering) -> "typing indicator came back after the turn ended"
        turn["status"] != "delivered" -> "turn row is #{turn["status"]}#{turn_error(turn)}"
        true -> nil
      end

    {ctx,
     %{
       client_message_id: cmid,
       reply_text: reply && reply["content"],
       progress: progress,
       turn: turn,
       error: error
     }}
  end

  # Waits for the assistant reply, but gives up the moment the SUBSTRATE says
  # no reply is coming.
  #
  # Without this, a turn that fails in the first second still costs the full
  # turn timeout on every step, and a red run takes an hour to say what the
  # turns table already knew. A driver nobody will sit through is a driver
  # nobody runs.
  defp await_reply(client, watermark, cmid, ctx) do
    predicate =
      &(&1["type"] == "message" and &1["role"] == "assistant" and
          &1["replyToClientMessageId"] == cmid)

    deadline = System.monotonic_time(:millisecond) + ctx.turn_timeout_ms
    await_reply(client, watermark, cmid, ctx, predicate, deadline)
  end

  defp await_reply(client, watermark, cmid, ctx, predicate, deadline) do
    slice = min(2_000, max(0, deadline - System.monotonic_time(:millisecond)))

    case SimClient.await(client, watermark, predicate, slice) do
      {:ok, frame, client} ->
        {frame, client}

      {:error, _reason, client} ->
        turn = Substrate.turn_for_client_message(ctx.base_dir, cmid)

        cond do
          is_map(turn) and turn["status"] in ~w(failed failed_unknown canceled) -> {nil, client}
          System.monotonic_time(:millisecond) >= deadline -> {nil, client}
          true -> await_reply(client, watermark, cmid, ctx, predicate, deadline)
        end
    end
  end

  defp await_frame(client, watermark, predicate, timeout_ms) do
    case SimClient.await(client, watermark, predicate, timeout_ms) do
      {:ok, frame, client} -> {frame, client}
      {:error, _reason, client} -> {nil, client}
    end
  end

  defp turn_error(%{"error" => error}) when is_binary(error) and error != "", do: " (#{error})"
  defp turn_error(_), do: ""

  defp schema_present?(ctx) do
    ctx.base_dir
    |> Substrate.query("SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'")
    |> Enum.any?()
  end

  defp base_ref(nil), do: nil
  defp base_ref(ref), do: ref |> String.split("[") |> List.first()
end
