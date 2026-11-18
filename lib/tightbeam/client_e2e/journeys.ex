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

  alias Tightbeam.ClientE2E.{LegGateway, Scorecard, SimClient, Substrate}

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
          required(:gateway) => Tightbeam.ClientE2E.LegGateway.t() | nil,
          required(:leg) => map(),
          required(:turn_wait_ms) => pos_integer(),
          required(:settle_ms) => pos_integer(),
          optional(atom()) => term()
        }

  @ids ~w(J0 J1 J2 J3 J4 J5 J6 J7 J8)
  @terminal_turn_statuses ~w(delivered canceled failed failed_unknown)

  @no_gateway "this journey restarts the gateway, so it needs the runner's leg " <>
                "gateway handle (`:gateway` in the journey context); the in-process " <>
                "test harness has none"

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
        "echo message frame carrying our clientMessageId; typing active=true; assistant message replying to that clientMessageId; typing active=false and no further typing=true through the settle window. The indicator is the INVARIANT; its LABEL is not asserted here — the substrate relays only labels the harness reports and a plain turn legitimately has none (SMOKE step 3, measured 0e40b93). Step 4 asserts the label where an event backs it.",
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
        "three identified echoes arrive in post order before any assistant reply; ONE has its own correlated assistant reply. A later post accepted while an earlier direct turn or carrier is pending has no own turn or post-specific reply and is delivered through ordered batch membership; later posts may use separate carriers when readiness changes, or a direct turn once no earlier path is pending. If ONE ended before TWO was accepted and TWO has no staged membership, report INCOMPLETE because this setup did not exercise the batch path",
      substrate:
        "one identified user history row per post in source order, each retaining deviceId and clientMessageId; ONE has a delivered direct turn; each post staged while earlier work is pending has exactly one included membership and a delivered batch-carrier turn, with no own turn; never more than one `running` turn for the session (sampled DURING the run). Back-to-back posts do not guarantee ONE reached running; queued is busy"
    },
    %{
      journey: "J5",
      step: "10",
      label: "concurrency",
      action: "slow prompt in Main, immediate post in Smoke B, then a second post in Main",
      client:
        "every assistant bubble carries the store seq of its own reply row (delivery is a hint and may arrive out of commit order; the seq is what the client settles order with, so a missing or wrong seq fails), each before its own turn's terminal state and in the stream it was posted to (no cross-talk), each within a second of the store stamping it; and one of them ARRIVES, by the driver's clock, strictly inside another of these turns by the substrate's; Main's two turns complete in post order. A missing reply, cross-talk, a non-delivered turn row and Main's own two turns out of order fail the row whatever the lanes did. Past those, when the substrate never ran the lanes together the delivery legs are not asked at all: FAIL if Smoke B was enqueued while Main was still running yet never ran beside it (the lanes are not parallel), otherwise INCOMPLETE, because there was no overlap to observe",
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
      action: "POST /api/session-control set_model to a different catalog ref, then post again",
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
    },
    %{
      journey: "J7",
      step: "14",
      label: "restart resilience",
      action:
        "post a slow prompt, then SIGTERM the gateway's captured pid mid-turn, await process exit AND the health endpoint going unreachable, restart on the SAME port and base_dir, confirm a NEW pid, reconnect the same client",
      client:
        "the client reconnects onto a healed connection (auth_result, stream_snapshot, sync_complete) with its history replayed; the interrupted turn is never left as a silent spinning indicator; a fresh post afterwards completes",
      substrate:
        "a NEW gateway pid; no delivered message rows lost across the restart; the interrupted turn row reaches a TERMINAL status (delivered | failed | failed_unknown); the harness pointer is recorded"
    },
    %{
      journey: "J7",
      step: "15",
      label: "restart queue survival",
      action:
        "queue a second post behind a running one, restart before the first completes, re-send NOTHING",
      client:
        "the client reconnects with the second post's same identified history row replayed; no re-send is needed, and the staged post has no own turn or post-specific reply while its ready-time carrier is delivered after restart",
      substrate:
        "the second post's identified user history row and exactly one included batch membership survive; the linked carrier turn is created and delivered after the restarted gateway is up, and the first turn reaches a terminal status"
    },
    %{
      journey: "J8",
      step: "16",
      label: "wakes",
      action:
        ~s(wake Main with "reply with exactly: WAKE OK" through /agent/dispatch as the admin),
      client:
        "the wake's prompt lands in Main as a SENDER-TAGGED user message (provenance from the `sender` field, not text parsing); the assistant answers it",
      substrate: "the delivered message's turn row carries a wakeId and reaches `delivered`"
    },
    %{
      journey: "J8",
      step: "16b",
      label: "scheduled wake",
      action: "schedule the same wake with a delay",
      client: "the delayed prompt's reply arrives after the delay",
      substrate: "the wake row is `pending` and visible BEFORE it fires, then fires"
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
    {ctx, converse} =
      turn_completes(ctx, ctx.main_key, "hello, who are you?", "3", "converse", "J1")

    uname = String.trim(elem(System.cmd("uname", ["-s"]), 0))

    prompt =
      "Run the shell command `uname -s` and reply with exactly its output and nothing else."

    {ctx, result} = observe_turn(ctx, ctx.main_key, prompt)

    tool =
      cond do
        result.error ->
          Scorecard.fail("4", "tool use", result.error, journey: "J1")

        result.progress == [] ->
          Scorecard.fail("4", "tool use", "no progress label arrived during the turn",
            journey: "J1"
          )

        # DELIBERATE KEEP, do not generalize from it. This reads like the J8
        # content assertion Flynn removed, but it is a PLACEMENT proof — the same
        # shape as satellite S3's nonce file. Only a tool that really ran on THIS
        # host can produce this host's `uname -s`, so the text is evidence that
        # the turn executed where the substrate placed it, not evidence that the
        # agent followed an instruction well.
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
           ctx.turn_wait_ms
         ) do
      {:error, reason, client} ->
        {%{ctx | client: client},
         [
           Scorecard.fail("8", "cancel", "no typing indicator to cancel (#{inspect(reason)})",
             journey: "J3"
           )
         ]}

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
                 ctx.turn_wait_ms
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

        # SMOKE step 8 requires the indicator to CLEAR on cancel, not merely to
        # avoid coming back. Checking only for a later typing=true would pass a
        # cancel that leaves the indicator spinning forever — the exact stuck
        # indicator this journey exists to catch.
        cancel_frames = SimClient.frames_since(ctx.client, cancel_watermark)

        canceled_at =
          if canceled,
            do:
              Enum.find_index(
                cancel_frames,
                &(&1["type"] == "event" and &1["event"] == "prompt_turn_state" and
                    get_in(&1, ["payload", "messageId"]) == cmid and
                    get_in(&1, ["payload", "state"]) == "canceled")
              ),
            else: nil

        indicator_error =
          if canceled_at,
            do: indicator_settled_error(cancel_frames, ctx.main_key, canceled_at),
            else: nil

        turn = Substrate.turn_for_client_message(ctx.base_dir, cmid)

        {ctx, drained} =
          turn_completes(
            ctx,
            ctx.main_key,
            "say exactly: DRAINED",
            "8b",
            "post-cancel turn",
            "J3"
          )

        row =
          cond do
            status != 200 ->
              Scorecard.fail("8", "cancel", "session-control cancel → #{status}", journey: "J3")

            is_nil(canceled) ->
              Scorecard.fail("8", "cancel", "no canceled prompt_turn_state for the turn",
                journey: "J3"
              )

            get_in(canceled, ["payload", "terminalState"]) != true ->
              Scorecard.fail("8", "cancel", "canceled state was not terminal", journey: "J3")

            not is_nil(stray_reply) ->
              Scorecard.fail("8", "cancel", "an assistant bubble arrived for the canceled turn",
                journey: "J3"
              )

            indicator_error ->
              Scorecard.fail("8", "cancel", "after the cancel, #{indicator_error}", journey: "J3")

            is_nil(turn) or turn["status"] != "canceled" ->
              Scorecard.fail(
                "8",
                "cancel",
                "turn row is #{inspect(turn && turn["status"])}, not canceled",
                journey: "J3"
              )

            drained.status != :pass ->
              Scorecard.fail("8", "cancel", "the lane did not drain: #{drained.note}",
                journey: "J3"
              )

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

    {{observations, timed_out?}, samples} =
      Substrate.sample_while(ctx.base_dir, 200, fn ->
        await_post_paths(ctx.base_dir, ctx.main_key, ids, ctx.turn_wait_ms)
      end)

    # Batch carrier replies are not correlated to any one source post. Read
    # through the settled indicator sequence after every persisted delivery
    # path is terminal, rather than waiting for one reply per source id.
    client = drain_until_settled(ctx.client, watermark, ctx.main_key, 30_000)
    client = SimClient.settle(client, ctx.settle_ms)
    ctx = %{ctx | client: client}
    frames = SimClient.frames_since(ctx.client, watermark)

    last_assistant_at =
      frames
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {f, i}, acc ->
        if f["type"] == "message" and f["role"] == "assistant",
          do: i,
          else: acc
      end)

    indicator_error =
      cond do
        is_nil(last_assistant_at) -> nil
        is_nil(indicator_on_at(frames, ctx.main_key, 0)) -> "the typing indicator never turned on"
        true -> indicator_settled_error(frames, ctx.main_key, last_assistant_at)
      end

    echoes =
      for f <- frames,
          f["type"] == "message",
          f["role"] == "user",
          f["clientMessageId"] in ids,
          do: f["clientMessageId"]

    replies =
      for f <- frames,
          f["type"] == "message",
          f["role"] == "assistant",
          f["replyToClientMessageId"] in ids,
          do: f["replyToClientMessageId"]

    direct_ids = Enum.filter(ids, &(observations[&1].direct_turn != nil))
    staged_ids = Enum.filter(ids, &(observations[&1].staged_members != []))
    history_error = j4_history_error(ids, observations, ctx.client.device_id)
    path_error = j4_path_error(ids, observations)
    busy_error = j4_busy_path_error(ids, observations)
    batch_order_error = j4_batch_order_error(ids, observations)
    reply_error = j4_reply_error(ids, direct_ids, staged_ids, replies)
    setup_incomplete? = j4_too_fast_two?(ids, observations)

    first_reply_index =
      Enum.find_index(frames, &(&1["type"] == "message" and &1["role"] == "assistant"))

    echo_indexes =
      for {f, i} <- Enum.with_index(frames),
          f["type"] == "message",
          f["role"] == "user",
          f["clientMessageId"] in ids,
          do: i

    peak = Substrate.busiest_lane(samples, ctx.main_key)

    row =
      cond do
        timed_out? ->
          Scorecard.fail(
            "9",
            "queueing",
            "one or more direct or staged delivery paths did not reach a terminal state: " <>
              inspect(Enum.map(ids, &{&1, observations[&1]})),
            journey: "J4"
          )

        echoes != ids ->
          Scorecard.fail(
            "9",
            "queueing",
            "echoes were #{inspect(echoes)}, expected #{inspect(ids)}",
            journey: "J4"
          )

        history_error ->
          Scorecard.fail(
            "9",
            "queueing",
            history_error,
            journey: "J4"
          )

        path_error ->
          Scorecard.fail(
            "9",
            "queueing",
            path_error,
            journey: "J4"
          )

        busy_error ->
          Scorecard.fail("9", "queueing", busy_error, journey: "J4")

        batch_order_error ->
          Scorecard.fail("9", "queueing", batch_order_error, journey: "J4")

        reply_error ->
          Scorecard.fail("9", "queueing", reply_error, journey: "J4")

        peak > 1 ->
          Scorecard.fail("9", "queueing", "#{peak} turns were running at once in one lane",
            journey: "J4"
          )

        indicator_error ->
          Scorecard.fail("9", "queueing", "across the queued batch, #{indicator_error}",
            journey: "J4"
          )

        setup_incomplete? ->
          Scorecard.incomplete(
            "9",
            "queueing",
            "ONE reached a terminal state before TWO was accepted and TWO has no persisted " <>
              "batch membership; the back-to-back setup did not exercise batching",
            journey: "J4"
          )

        first_reply_index && Enum.any?(echo_indexes, &(&1 > first_reply_index)) ->
          Scorecard.fail(
            "9",
            "queueing",
            "an echo arrived after the first assistant reply — echoes are not immediate",
            journey: "J4"
          )

        true ->
          Scorecard.pass("9", "queueing", journey: "J4")
      end

    {ctx, [row]}
  end

  defp j4_history_error(ids, observations, device_id) do
    rows = Enum.flat_map(ids, &observations[&1].history_rows)
    ordered_ids = Enum.map(rows, & &1["clientMessageId"])
    history_sequences = Enum.map(rows, & &1["seq"])

    cond do
      ordered_ids != ids ->
        "identified user history rows were #{inspect(ordered_ids)}, expected #{inspect(ids)}"

      Enum.any?(history_sequences, &(not is_integer(&1))) or
          history_sequences != Enum.sort(history_sequences) ->
        "user history rows were not persisted in post order: #{inspect(history_sequences)}"

      Enum.any?(rows, &(&1["deviceId"] != device_id)) ->
        "a user history row did not retain the posting device identity"

      true ->
        nil
    end
  end

  defp j4_path_error(ids, observations) do
    Enum.find_value(ids, fn id ->
      %{direct_turn: direct, staged_members: members} = observations[id]

      cond do
        length(observations[id].history_rows) != 1 ->
          "#{id} has #{length(observations[id].history_rows)} user history rows, expected one"

        length(members) > 1 ->
          "#{id} has more than one persisted batch membership"

        direct && members != [] ->
          "#{id} has both a direct turn and staged batch membership"

        id == hd(ids) and (is_nil(direct) or members != []) ->
          "ONE did not use its own direct turn"

        is_map(direct) and direct["status"] != "delivered" ->
          "#{id} direct turn ended as #{direct["status"]}, not delivered"

        direct ->
          nil

        members == [] ->
          "#{id} has neither a direct turn nor persisted batch membership"

        true ->
          [member] = members

          cond do
            member["deviceId"] !=
                observations[id].history_rows |> List.first() |> Map.get("deviceId") ->
              "#{id} staged identity did not match its user history row"

            member["clientMessageId"] != id or member["historyClientMessageId"] != id ->
              "#{id} batch membership did not retain its clientMessageId"

            member["memberState"] != "included" or member["batchState"] != "delivered" ->
              "#{id} batch membership/batch ended as #{inspect({member["memberState"], member["batchState"]})}"

            member["carrierTurnSeq"] == nil or member["carrierStatus"] != "delivered" or
                member["carrierIsBatchCarrier"] != 1 ->
              "#{id} has no delivered batch-carrier turn"

            is_nil(member["historySeq"]) ->
              "#{id} staged user history row was not materialized"

            true ->
              nil
          end
      end
    end)
  end

  defp j4_busy_path_error(ids, observations) do
    ids
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.find_value(fn {id, index} ->
      accepted_at =
        observations[id].history_rows |> List.first() |> then(&(&1 && &1["timestamp"]))

      earlier_busy? =
        if is_integer(accepted_at) do
          Enum.take(ids, index)
          |> Enum.any?(fn earlier_id ->
            path_end = post_path_end_at(observations[earlier_id])
            is_nil(path_end) or path_end > accepted_at
          end)
        else
          false
        end

      if earlier_busy? and observations[id].staged_members == [] do
        "#{id} was accepted while an earlier turn/carrier was pending but got its own turn " <>
          "instead of joining a ready-time batch"
      end
    end)
  end

  defp j4_batch_order_error(ids, observations) do
    members = Enum.flat_map(ids, &observations[&1].staged_members)
    publication_sequences = Enum.map(members, & &1["publicationSeq"])
    carrier_sequences = Enum.map(members, & &1["carrierTurnSeq"])
    [one_id | later_ids] = ids
    one_ended_at = post_path_end_at(observations[one_id])

    same_ready_batch? =
      if is_integer(one_ended_at) do
        staged_while_one_busy =
          Enum.filter(later_ids, fn id ->
            accepted_at =
              observations[id].history_rows
              |> List.first()
              |> then(&(&1 && &1["timestamp"]))

            is_integer(accepted_at) and accepted_at < one_ended_at and
              observations[id].staged_members != []
          end)

        staged_batch_ids =
          Enum.flat_map(staged_while_one_busy, fn id ->
            Enum.map(observations[id].staged_members, & &1["batchId"])
          end)

        length(staged_while_one_busy) < 2 or length(Enum.uniq(staged_batch_ids)) == 1
      else
        true
      end

    cond do
      Enum.any?(publication_sequences, &(not is_integer(&1))) ->
        "a staged post has no persisted publication sequence"

      publication_sequences != Enum.sort(publication_sequences) ->
        "batch membership order differs from post order: #{inspect(publication_sequences)}"

      Enum.any?(carrier_sequences, &(not is_integer(&1))) ->
        "a staged post has no linked carrier turn sequence"

      carrier_sequences != Enum.sort(carrier_sequences) ->
        "ready-time carrier turns do not preserve staged post order: #{inspect(carrier_sequences)}"

      not same_ready_batch? ->
        "posts staged before ONE finished were split across ready-time batches"

      true ->
        nil
    end
  end

  defp j4_reply_error(ids, direct_ids, staged_ids, replies) do
    counts = Enum.frequencies(replies)

    cond do
      Enum.any?(staged_ids, &(Map.get(counts, &1, 0) != 0)) ->
        "a batch-staged post received a post-specific assistant reply: #{inspect(replies)}"

      Enum.any?(direct_ids, &(Map.get(counts, &1, 0) != 1)) ->
        "direct turns and source-correlated replies differ: turns=#{inspect(direct_ids)} replies=#{inspect(replies)}"

      Enum.filter(ids, &(Map.get(counts, &1, 0) == 1)) != direct_ids ->
        "direct assistant replies arrived out of post order: #{inspect(replies)}"

      true ->
        nil
    end
  end

  defp j4_too_fast_two?([one_id, two_id | _], observations) do
    one_ended_at = post_path_end_at(observations[one_id])
    two = observations[two_id]
    two_accepted_at = two.history_rows |> List.first() |> then(&(&1 && &1["timestamp"]))

    is_integer(one_ended_at) and is_integer(two_accepted_at) and
      one_ended_at <= two_accepted_at and two.staged_members == []
  end

  defp post_path_end_at(%{direct_turn: direct}) when is_map(direct), do: direct["endedAt"]

  defp post_path_end_at(%{staged_members: [member]}), do: member["carrierEndedAt"]
  defp post_path_end_at(_), do: nil

  defp await_post_paths(base_dir, session_key, ids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_post_paths(base_dir, session_key, ids, deadline)
  end

  defp poll_post_paths(base_dir, session_key, ids, deadline) do
    observations = Map.new(ids, &{&1, post_observation(base_dir, session_key, &1)})

    cond do
      Enum.all?(ids, &post_path_settled?(observations[&1])) ->
        {observations, false}

      System.monotonic_time(:millisecond) >= deadline ->
        {observations, true}

      true ->
        Process.sleep(200)
        poll_post_paths(base_dir, session_key, ids, deadline)
    end
  end

  defp post_observation(base_dir, session_key, client_message_id) do
    %{
      history_rows: Substrate.human_post_rows(base_dir, session_key, client_message_id),
      direct_turn: Substrate.turn_for_client_message(base_dir, client_message_id),
      staged_members: Substrate.staged_post_members(base_dir, session_key, client_message_id)
    }
  end

  defp post_path_settled?(%{direct_turn: %{"status" => status}}),
    do: status in @terminal_turn_statuses

  defp post_path_settled?(%{staged_members: members}) when members != [] do
    Enum.any?(members, fn member ->
      member["memberState"] == "canceled" or
        member["batchState"] in ~w(delivery_failed canceled delivered)
    end)
  end

  defp post_path_settled?(_), do: false

  defp await_post_admission(base_dir, session_key, client_message_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_post_admission(base_dir, session_key, client_message_id, deadline)
  end

  defp poll_post_admission(base_dir, session_key, client_message_id, deadline) do
    observation = post_observation(base_dir, session_key, client_message_id)

    cond do
      observation.history_rows != [] and
          (observation.direct_turn != nil or observation.staged_members != []) ->
        {:ok, observation}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, observation}

      true ->
        Process.sleep(200)
        poll_post_admission(base_dir, session_key, client_message_id, deadline)
    end
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
      {ctx,
       [
         Scorecard.fail(
           "10",
           "concurrency",
           "could not create Smoke B: #{status} #{inspect(created)}",
           journey: "J5"
         )
       ]}
    else
      watermark = SimClient.mark(ctx.client)

      {:ok, client, slow_id} =
        SimClient.post(
          ctx.client,
          ctx.main_key,
          # Long ON PURPOSE — a turn that lasts is what gives the other lane
          # something to run BESIDE. Which of the two finishes first is the
          # model's business and decides nothing here: the oracle asserts
          # committed order and live cross-lane delivery, both of which hold
          # either way.
          "Write a detailed haiku about each of the 10 planets and dwarf planets, " <>
            "one at a time, with a sentence of commentary after each."
        )

      {:ok, client, b_id} = SimClient.post(client, session_key, "what is 2+2?")
      {:ok, client, done_id} = SimClient.post(client, ctx.main_key, "now say exactly: DONE")
      ctx = %{ctx | client: client}

      {ctx, samples} =
        Substrate.sample_while(ctx.base_dir, 150, fn ->
          # The reply AND its turn's terminal state, for each post. `await/4`
          # stops reading the moment its predicate matches, so waiting only on
          # replies leaves the last turn's terminal frame sitting unread in the
          # socket — and an oracle that asks where a reply sits relative to that
          # frame would fail the healthy run for want of a frame nobody read.
          #
          # ONE deadline across all six, not six of them: six waits that each
          # restart the turn wait let a socket that has gone quiet hold J5
          # for six times the observer's one-turn wait.
          deadline = System.monotonic_time(:millisecond) + ctx.turn_wait_ms

          Enum.reduce([b_id, slow_id, done_id], ctx, fn id, ctx ->
            ctx
            |> await_frame_into(
              watermark,
              deadline,
              &(&1["type"] == "message" and &1["role"] == "assistant" and
                  &1["replyToClientMessageId"] == id)
            )
            |> await_frame_into(
              watermark,
              deadline,
              &(&1["type"] == "event" and &1["event"] == "prompt_turn_state" and
                  get_in(&1, ["payload", "messageId"]) == id and
                  get_in(&1, ["payload", "terminalState"]) == true)
            )
          end)
          |> settle()
        end)

      frames = SimClient.frames_since(ctx.client, watermark)

      reply_order =
        for f <- frames,
            f["type"] == "message",
            f["role"] == "assistant",
            do: f["replyToClientMessageId"]

      b_reply =
        Enum.find(
          frames,
          &(&1["type"] == "message" and &1["role"] == "assistant" and
              &1["replyToClientMessageId"] == b_id)
        )

      posts = [
        %{id: slow_id, session_key: ctx.main_key},
        %{id: b_id, session_key: session_key},
        %{id: done_id, session_key: ctx.main_key}
      ]

      # EVERY reply, not just Smoke B's, and BEFORE the concurrency gate: a
      # bubble in the wrong stream is a defect whatever the lanes did, and the
      # delivery oracle that also checks it is only reached once the substrate
      # has been shown to have run them together.
      cross_talk = wrong_stream_replies(frames, posts)

      turns =
        Enum.map([slow_id, b_id, done_id], &Substrate.turn_for_client_message(ctx.base_dir, &1))

      [slow_turn, b_turn, done_turn] = turns

      # SIMULTANEITY, two independent witnesses, both of which are about ONE
      # instant rather than a maximum merged across samples:
      #   - a single sample that caught both lanes running at once, and
      #   - the turn rows' own start/end intervals overlapping.
      # Either one proves the substrate ran them concurrently; the interval
      # join does not depend on the sampler being lucky.
      #
      # EITHER of Main's turns against B's, because either one overlapping B is
      # the lanes running beside each other — and the delivery oracle accepts a
      # reply landing inside any of these turns, so a gate that only knew about
      # `slow` could refuse a run the oracle was ready to pass.
      sampled_together? = Substrate.simultaneous?(samples, [ctx.main_key, session_key])

      intervals_overlapped? =
        Substrate.turns_overlapped?(slow_turn, b_turn) or
          Substrate.turns_overlapped?(done_turn, b_turn)

      substrate_concurrent? = sampled_together? or intervals_overlapped?

      # Did the substrate have the OPPORTUNITY to overlap them? The question is
      # when B was ENQUEUED, not when it started. A B turn serialized behind
      # Main necessarily STARTS after Main ends — using its start time put the
      # serialized case into INCOMPLETE and made the queued-behind FAIL branch
      # unreachable, which a probe confirmed.
      had_opportunity? = lanes_had_opportunity?(slow_turn, b_turn, done_turn)

      witness =
        "sampled_together=#{sampled_together?} intervals_overlapped=#{intervals_overlapped?} widest_sample=#{Substrate.widest_sample(samples)}"

      # The three posts, each with the stream it went to, the `messages.seq` the
      # store gave its reply — the per-store COMMIT order — and its turn's own
      # interval. Publication does NOT ride commit order and this row no longer
      # pretends it does: delivery is a hint, and what the row asserts is that
      # every frame carries the store seq that lets the client settle order.
      expected = expected_deliveries(ctx.base_dir, posts)

      row =
        cond do
          is_nil(b_reply) ->
            Scorecard.fail("10", "concurrency", "Smoke B never replied", journey: "J5")

          cross_talk != [] ->
            Scorecard.fail(
              "10",
              "concurrency",
              "cross-talk: #{inspect(cross_talk)} landed in a stream it was not posted to",
              journey: "J5"
            )

          Enum.any?(turns, &(is_nil(&1) or &1["status"] != "delivered")) ->
            Scorecard.fail(
              "10",
              "concurrency",
              "turn rows: #{inspect(Enum.map(turns, &(&1 && &1["status"])))}",
              journey: "J5"
            )

          Enum.filter(reply_order, &(&1 in [slow_id, done_id])) != [slow_id, done_id] ->
            Scorecard.fail(
              "10",
              "concurrency",
              "Main's turns completed out of order: #{inspect(reply_order)}",
              journey: "J5"
            )

          # The substrate PROVABLY ran both lanes at once, so what the client
          # showed is now the whole question, and a delayed or reordered frame
          # FAILS — calling it incomplete would launder exactly the defect this
          # journey should catch.
          substrate_concurrent? ->
            case concurrency_delivery_error(frames, expected) do
              nil ->
                Scorecard.pass("10", "concurrency", journey: "J5")

              error ->
                Scorecard.fail("10", "concurrency", "#{error} (#{witness})", journey: "J5")
            end

          # No simultaneity witness, and B only started after Main had already
          # finished: the substrate serialized the two lanes.
          had_opportunity? ->
            Scorecard.fail(
              "10",
              "concurrency",
              "Smoke B was ENQUEUED while Main was still running yet never ran beside it " <>
                "(#{witness}) — the lanes are not parallel",
              journey: "J5"
            )

          # Main's turn was over before B's could start: there was no overlap to
          # observe on either side, so the step has no verdict to give.
          true ->
            Scorecard.incomplete(
              "10",
              "concurrency",
              "no overlap was possible: Main's slow turn ended before Smoke B's turn started " <>
                "(#{witness}) — a faster-than-expected model left the premise unestablished",
              journey: "J5"
            )
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

  # --- J7: restart resilience (SMOKE 14, 15) -----------------------------------

  defp walk(ctx, "J7") do
    if is_nil(ctx[:gateway]) do
      {ctx,
       [
         Scorecard.incomplete("14", "restart resilience", @no_gateway, journey: "J7"),
         Scorecard.incomplete("15", "restart queue survival", @no_gateway, journey: "J7")
       ]}
    else
      {ctx, drain_row} = j7_drain(ctx)
      {ctx, queue_row} = j7_queue_survival(ctx)
      {ctx, [drain_row, queue_row]}
    end
  end

  # --- J8: wakes (SMOKE 16) ----------------------------------------------------

  defp walk(ctx, "J8") do
    {ctx, immediate} = j8_immediate_wake(ctx)
    {ctx, delayed} = j8_delayed_wake(ctx)
    {ctx, [immediate, delayed]}
  end

  # How long a reply may trail its own store stamp and still count as delivered
  # live. The path measures 0-1ms end to end (stamp -> commit -> publish ->
  # client frame, all on one host); a second is three orders of magnitude above
  # that and an order below what a person would notice as waiting, so what
  # crosses it is a frame that waited for something.
  @delivery_budget_ms 1_000

  @doc """
  J5's client-side oracle: what a client must show while two lanes run at once.

  `expected` is one entry per post this journey made — `%{id: clientMessageId,
  session_key: the stream it was posted to, committed_seq: and committed_at:
  its reply's `messages.seq` and store stamp (nil when the store holds no
  reply), started_at: and ended_at: its turn row's own interval}` — so every
  leg is scoped to THIS journey's three turns and a frame belonging to any
  other turn can neither satisfy a leg nor break one.

  No leg asks which model answered first. A trivial prompt in a fresh stream
  routinely outlives a deliberately slow one in a warm stream — it pays a new
  harness session and whatever preamble the agent elects — and a model's speed
  is not evidence about delivery. The legs, in order:

  1. the store holds a reply for every post. Its silence must not read as the
     client's success: the later legs would compare lists that agree on what
     they both omit;
  2. every one of those replies reached the client;
  3. every reply frame carries the store seq of its own row — seq fidelity.
     Arrival order is NOT asserted: delivery is a hint (ruled 2026-08-04),
     frames may legally arrive out of commit order, and the seq on each frame
     is what the client settles them with. A frame with a missing or wrong seq
     is unplaceable, and that is the defect. This replaced an arrival-order
     leg that the old registry filter enforced by deletion.

     WHAT THIS LEG DOES NOT REACH, since the row should not claim it: J5's
     three posts cannot produce two CONCURRENT writers to one stream. Main's
     two turns are serialized by its own lane and Smoke B is a second stream
     with its own cursor, so the drop this leg is shaped to catch — a publish
     out of commit order inside ONE session, which the cursor then suppresses
     forever — is not reachable from this journey. Reaching it needs two
     writers to one session at once (a client post's echo against a marker
     appended by something else), which is a different construction than three
     posts from one client;
  4. each reply carried the sessionKey of the stream it answers, and so did the
     terminal turn-state frame it is judged against. Correlating that frame by
     `messageId` alone would let one labelled with the wrong stream stand in for
     a frame the client was never shown;
  5. each reply arrived BEFORE its own turn's terminal `prompt_turn_state`.
     The substrate publishes those back to back at the end of the turn, so
     their order is the edge that catches a reply held behind the close of the
     very turn that produced it — the case the order leg cannot see when the
     held reply was committed last anyway. A turn whose terminal state never
     reached the client fails here too: an indicator left spinning is not a
     delivered turn;
  6. EVERY reply reached the client within `budget_ms` of its own store stamp
     (`committed_at`, `messages.timestamp`, taken as the row is inserted; a
     reply with no stamp fails here rather than skipping the check). The
     interval it measures is stamp -> commit -> publish -> frame, so a slow
     COMMIT counts against it as well as a slow publication; that is honest
     about what a client waited for, and the commit itself is microseconds of a
     one-second budget.

     Against the stamp and NOT against `turns.endedAt`, which is the timestamp
     this leg used to trust: the lane writes `endedAt` after the runner returns
     and the runner publishes before returning, so a stalled publication drags
     `endedAt` along with it and the bound measured the delay against itself.

     This is the one leg with a number in it. A frame that arrives eventually,
     in the right order, behind its own already-closed turn has no edge to be
     caught at — it is the last thing that happens in the run, so nothing else
     moves while it waits, and no successor event can bound it. Where no edge
     exists, the number: `@delivery_budget_ms`, three orders of magnitude above
     the 0-1ms this path measures and an order below anything a person would
     call waiting. What it names is a frame that WAITED for something, never a
     slow one. THE RESIDUAL, recorded rather than papered over: a delay shorter
     than the budget is invisible to this row, and no threshold can be chosen
     that both catches every delay and never fires on a healthy run;
  7. and some reply ARRIVED, by the driver's own clock, STRICTLY inside another
     of these turns (`started_at`..`ended_at` by the substrate's). This is the
     cross-lane liveness the journey exists to prove, and it holds whichever
     lane finishes first. It is deliberately a clock question rather than a
     frame-order one: a gateway that withheld every frame and flushed them in
     perfect order at the end satisfies every order leg and fails this. Strict
     bounds, because both clocks are millisecond truncations of one source: an
     arrival landing exactly on a turn's boundary is ambiguous, and an oracle
     must not accept ambiguity as proof. A flush timed to the millisecond of the
     last close would otherwise pass as live delivery.

  Returns nil when every leg holds, else the text of the first that did not.
  """
  @spec concurrency_delivery_error([map()], [map()], pos_integer()) :: String.t() | nil
  def concurrency_delivery_error(frames, expected, budget_ms \\ @delivery_budget_ms) do
    replies = reply_indexes(frames, expected)
    terminals = turn_state_indexes(frames, expected, &terminal_turn_state?/1)

    uncommitted = for %{id: id, committed_seq: nil} <- expected, do: id
    missing = for %{id: id} <- expected, not is_map_key(replies, id), do: id

    cond do
      uncommitted != [] ->
        "the store holds no reply row for #{inspect(uncommitted)} — the substrate never " <>
          "produced what the client is being asked to have shown"

      missing != [] ->
        "the store committed replies the client never received: #{inspect(missing)}"

      true ->
        # ARRIVAL order is deliberately not asserted. The wire contract (ruled
        # 2026-08-04, "delivery is a hint, the store is truth") permits frames
        # to arrive out of commit order; what it PROMISES is that every frame
        # carries the store seq that lets the client settle order. So the leg
        # asserts seq fidelity — frame seq present and equal to the store's —
        # which is exactly the capability the settled view stands on. A frame
        # with a missing or wrong seq is unplaceable, and THAT is the defect.
        # EVERY reply frame for a post, not only the first: a truthful first
        # frame must not launder a later duplicate whose seq is missing or
        # wrong — a client that placed the duplicate would corrupt its view.
        by_id = Map.new(expected, &{&1.id, &1.committed_seq})

        unplaceable =
          for frame <- frames,
              assistant_reply?(frame),
              committed = Map.get(by_id, frame["replyToClientMessageId"]),
              committed != nil,
              frame["seq"] != committed,
              do: {frame["replyToClientMessageId"], frame["seq"], committed}

        cross_talk = wrong_stream_replies(frames, expected)

        held =
          for %{id: id} <- expected,
              is_nil(terminals[id]) or replies[id].index > terminals[id],
              do: id

        undated = for %{id: id} <- expected, not is_integer(replies[id].received_at), do: id

        cond do
          unplaceable != [] ->
            "frames whose seq does not match the store row they carry — the client " <>
              "cannot settle these into commit order: " <>
              "#{inspect(Enum.map(unplaceable, fn {id, got, want} -> "#{id} seq=#{inspect(got)} store=#{want}" end))}"

          cross_talk != [] ->
            "cross-talk: #{inspect(cross_talk)} answered in a stream it was not posted to"

          held != [] ->
            "#{inspect(held)} did not reach the client before its own turn's terminal state — " <>
              "the reply was held behind the close of the very turn that produced it"

          undated != [] ->
            "the driver recorded no arrival time for #{inspect(undated)}, so live delivery " <>
              "cannot be judged for this run"

          (late = late_arrivals(expected, replies, budget_ms)) != [] ->
            "#{inspect(late)} reached the client more than #{budget_ms}ms after the store " <>
              "stamped it — delivered, but not delivered live"

          not cross_lane_live?(expected, replies) ->
            "no reply arrived while another of these streams' turns was still open — " <>
              "the frames were delivered, but not while the other lane was running"

          true ->
            nil
        end
    end
  end

  # Keep reading after the last awaited frame. Every wait here stops the moment
  # its predicate matches, so a frame the gateway sends AFTER the last one — a
  # second bubble for a post, in a stream it was never posted to — would never
  # be read, and an oracle can only judge frames the driver holds. This is J1's
  # settle window, for J1's reason: a negative proved by not-looking is not a
  # proof.
  defp settle(ctx), do: %{ctx | client: SimClient.settle(ctx.client, ctx.settle_ms)}

  # Read until `predicate` matches, keeping whatever arrived on the way. A frame
  # that never comes is left to the oracle to name — the wait decides only when
  # to stop reading.
  defp await_frame_into(ctx, watermark, deadline, predicate) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case SimClient.await(ctx.client, watermark, predicate, remaining) do
      {:ok, _frame, client} -> %{ctx | client: client}
      {:error, _reason, client} -> %{ctx | client: client}
    end
  end

  # Every reply whose arrival trails its own store stamp by more than the
  # budget. The stamp is taken as the row is written, so this measures how long
  # the FRAME waited, not how long the model thought.
  defp late_arrivals(expected, replies, budget_ms) do
    for %{id: id, committed_at: committed_at} <- expected,
        not is_integer(committed_at) or replies[id].received_at - committed_at > budget_ms,
        do: id
  end

  defp cross_lane_live?(expected, replies) do
    Enum.any?(expected, fn %{id: id, session_key: key} ->
      at = replies[id].received_at

      Enum.any?(expected, fn other ->
        other.session_key != key and is_integer(other.started_at) and
          is_integer(other.ended_at) and other.started_at < at and at < other.ended_at
      end)
    end)
  end

  @doc """
  Whether the substrate ever had the chance to run these lanes beside each
  other — the question that separates "the lanes are not parallel" (FAIL) from
  "there was nothing to observe" (INCOMPLETE).

  Asked of each ADJACENT pair in post order, and always of the LATER post's
  enqueue against the EARLIER turn's close: Smoke B was posted after Main's slow
  prompt, and Main's `done` after Smoke B. Comparing a turn's enqueue against
  the close of something posted after it proves nothing — B is created before
  `done` exists, so `b.createdAt < done.endedAt` is true in a perfectly
  sequential run and would report every such run as a parallelism failure.

  It is the ENQUEUE and not the start on the later side: a turn serialized
  behind another necessarily starts after it ends, so using its start makes the
  queued-behind case unreachable.
  """
  @spec lanes_had_opportunity?(map() | nil, map() | nil, map() | nil) :: boolean()
  def lanes_had_opportunity?(slow_turn, b_turn, done_turn) do
    queued_while_running?(b_turn, slow_turn) or queued_while_running?(done_turn, b_turn)
  end

  defp queued_while_running?(%{"createdAt" => created}, %{"endedAt" => ended})
       when is_integer(created) and is_integer(ended),
       do: created < ended

  defp queued_while_running?(_later, _earlier), do: false

  # Every post with ANY assistant frame answering it in a stream it was not
  # posted to. All of its frames and not just the first: a second bubble for the
  # same post, rendered in the wrong session, is the same defect and a check
  # that stopped at the first correctly-labelled one could not see it.
  defp wrong_stream_replies(frames, posts) do
    for %{id: id, session_key: key} <- posts,
        frame <- frames,
        assistant_reply?(frame),
        frame["replyToClientMessageId"] == id,
        frame["sessionKey"] != key,
        uniq: true,
        do: id
  end

  # %{clientMessageId => %{frame, index, received_at}} for the replies to THESE
  # posts, in the stream each was posted to. The FIRST frame answering a post is
  # the one it was answered by; a later duplicate cannot move its place in the
  # arrival order.
  defp reply_indexes(frames, expected) do
    ids = MapSet.new(expected, & &1.id)

    frames
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {frame, index}, acc ->
      id = frame["replyToClientMessageId"]

      if assistant_reply?(frame) and MapSet.member?(ids, id) and not is_map_key(acc, id),
        do: Map.put(acc, id, %{frame: frame, index: index, received_at: frame["receivedAt"]}),
        else: acc
    end)
  end

  # %{clientMessageId => index} of the FIRST matching turn-state frame for each
  # post — matched on the post's stream as well as its id, so a frame carrying
  # the wrong sessionKey cannot stand in for one the client never saw.
  defp turn_state_indexes(frames, expected, match?) do
    posts = Map.new(expected, &{&1.id, &1.session_key})

    frames
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {frame, index}, acc ->
      id = get_in(frame, ["payload", "messageId"])

      if match?.(frame) and Map.get(posts, id) == get_in(frame, ["payload", "sessionKey"]) and
           not is_map_key(acc, id),
         do: Map.put(acc, id, index),
         else: acc
    end)
  end

  defp assistant_reply?(frame),
    do: frame["type"] == "message" and frame["role"] == "assistant"

  defp terminal_turn_state?(frame) do
    frame["type"] == "event" and frame["event"] == "prompt_turn_state" and
      get_in(frame, ["payload", "terminalState"]) == true
  end

  # Each post paired with the stream it went to, the `messages.seq` of the reply
  # the store holds for it, and its turn row's own interval.
  defp expected_deliveries(base_dir, posts) do
    session_keys = posts |> Enum.map(& &1.session_key) |> Enum.uniq()

    committed =
      session_keys
      |> Enum.flat_map(&Substrate.messages(base_dir, &1))
      |> Enum.filter(&is_binary(&1["replyToClientMessageId"]))
      |> Map.new(&{&1["replyToClientMessageId"], {&1["seq"], &1["timestamp"]}})

    Enum.map(posts, fn post ->
      turn = Substrate.turn_for_client_message(base_dir, post.id) || %{}
      {seq, committed_at} = Map.get(committed, post.id, {nil, nil})

      Map.merge(post, %{
        committed_seq: seq,
        committed_at: committed_at,
        started_at: turn["startedAt"],
        ended_at: turn["endedAt"]
      })
    end)
  end

  defp j6_model_change(ctx) do
    {_status, before} = SimClient.get(ctx.client, "/api/session-status", sessionKey: ctx.main_key)
    current = get_in(before, ["display", "model"])

    candidates =
      before
      |> get_in(["modelCatalog", "models"])
      |> List.wrap()
      |> Enum.map(&(&1["ref"] || &1["id"]))
      |> Enum.reject(&(is_nil(&1) or &1 == current))
      |> Enum.uniq()

    if candidates == [] do
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
      try_model_change(ctx, current, candidates, [])
    end
  end

  # The gateway does not always ACCEPT a catalog model: on a resident session it
  # applies the change to the live harness session, and a model the grant is not
  # entitled to comes back `ok: false` with the session left alone. Reading that
  # field is the difference between an oracle and a guess — an earlier version
  # asserted the status had changed no matter what the response said, and failed
  # the substrate for correctly refusing.
  #
  # So: `ok: true` must change the model; `ok: false` must NOT change it (a
  # refusal that mutated the session anyway would be the worse bug, and is now
  # caught); and a catalog where nothing can be applied leaves the step without
  # a verdict rather than with a false one.
  defp try_model_change(ctx, current, [candidate | rest], refused) do
    {status, body} =
      SimClient.post_json(ctx.client, "/api/session-control", %{
        "sessionKey" => ctx.main_key,
        "action" => "set_model",
        "model" => candidate
      })

    {_status, after_change} =
      SimClient.get(ctx.client, "/api/session-status", sessionKey: ctx.main_key)

    reported = get_in(after_change, ["display", "model"])
    applied? = is_map(body) and body["ok"] == true

    cond do
      status != 200 ->
        {ctx, Scorecard.fail("13b", "model change", "set_model → HTTP #{status}", journey: "J6")}

      not is_map(body) or not is_boolean(body["ok"]) ->
        {ctx,
         Scorecard.fail(
           "13b",
           "model change",
           "set_model response carries no boolean `ok`: #{inspect(body)}",
           journey: "J6"
         )}

      applied? ->
        finish_model_change(ctx, candidate, reported, after_change)

      reported != current ->
        {ctx,
         Scorecard.fail(
           "13b",
           "model change",
           "set_model #{candidate} reported ok=false, yet the session's model changed from " <>
             "#{inspect(current)} to #{inspect(reported)} — a refusal must not mutate the session",
           journey: "J6"
         )}

      true ->
        try_model_change(ctx, current, rest, [candidate | refused])
    end
  end

  defp try_model_change(ctx, current, [], refused) do
    {ctx,
     Scorecard.incomplete(
       "13b",
       "model change",
       "every catalog model the driver offered was refused with ok=false while the session " <>
         "stayed on #{inspect(current)} (tried #{inspect(Enum.reverse(refused))}) — this grant " <>
         "is not entitled to a second applicable model, so the step has no verdict to give",
       journey: "J6"
     )}
  end

  defp finish_model_change(ctx, candidate, reported, after_change) do
    missing = decode_contract_gaps(after_change)
    row = Substrate.session(ctx.base_dir, ctx.main_key)

    {ctx, next_turn} =
      turn_completes(
        ctx,
        ctx.main_key,
        "say exactly: MODEL OK",
        "13b-turn",
        "post-change turn",
        "J6"
      )

    result =
      cond do
        reported != candidate ->
          Scorecard.fail(
            "13b",
            "model change",
            "set_model #{candidate} reported ok=true but session-status shows " <>
              "#{inspect(reported)}, expected #{inspect(candidate)}",
            journey: "J6"
          )

        missing != [] ->
          Scorecard.fail(
            "13b",
            "model change",
            "session-status omits fields the client's decoder requires: #{Enum.join(missing, ", ")}",
            journey: "J6"
          )

        stored_ref(row) != candidate ->
          Scorecard.fail(
            "13b",
            "model change",
            "sessions holds #{inspect(stored_ref(row))} (model/modelContext columns)",
            journey: "J6"
          )

        next_turn.status != :pass ->
          Scorecard.fail(
            "13b",
            "model change",
            "the turn after the change did not complete: #{next_turn.note}",
            journey: "J6"
          )

        true ->
          Scorecard.pass("13b", "model change",
            journey: "J6",
            note: "applied #{candidate}"
          )
      end

    {ctx, result}
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

    run_state =
      if is_map(status["run"]) and is_nil(status["run"]["state"]), do: ["run.state"], else: []

    top ++ run_state
  end

  def decode_contract_gaps(_), do: ["<no session-status payload>"]

  # --- J7 helpers -------------------------------------------------------------

  # Step 14: a turn in flight when the gateway is SIGTERMed either drains or is
  # published as failed — never a silent stuck indicator — and the client
  # reconnects onto healed state with its history intact.
  defp j7_drain(ctx) do
    # Row IDENTITY, captured BEFORE the interrupted post. A count taken here and
    # compared afterwards is satisfied by the interrupted turn's own new rows,
    # so losing an older message would be masked by the arithmetic.
    before_ids =
      ctx.base_dir |> Substrate.messages(ctx.main_key) |> MapSet.new(& &1["id"])

    watermark = SimClient.mark(ctx.client)

    {:ok, client, cmid} =
      SimClient.post(ctx.client, ctx.main_key, "Count to 300 slowly, one line per number.")

    {typing, client} =
      await_frame(
        client,
        watermark,
        &(&1["type"] == "typing" and &1["active"] == true and &1["sessionKey"] == ctx.main_key),
        ctx.turn_wait_ms
      )

    ctx = %{ctx | client: client}

    if is_nil(typing) do
      {ctx,
       Scorecard.fail("14", "restart resilience", "no turn was in flight to interrupt",
         journey: "J7"
       )}
    else
      old_pid = ctx.gateway.os_pid

      case LegGateway.restart(ctx.gateway) do
        {:error, reason} ->
          {ctx,
           Scorecard.fail("14", "restart resilience", "restart failed: #{inspect(reason)}",
             journey: "J7"
           )}

        {:ok, gateway} ->
          ctx = %{ctx | gateway: gateway}

          # The sim client's stand-in for "the app stays running and reconnects
          # by itself": the same client process, same device identity, same
          # token, a fresh socket.
          case reconnect(ctx) do
            {:error, reason} ->
              {ctx,
               Scorecard.fail(
                 "14",
                 "restart resilience",
                 "client could not reconnect after restart: #{inspect(reason)}",
                 journey: "J7"
               )}

            {:ok, ctx} ->
              j7_drain_verdict(ctx, cmid, old_pid, gateway.os_pid, before_ids)
          end
      end
    end
  end

  defp j7_drain_verdict(ctx, cmid, old_pid, new_pid, before_ids) do
    snapshot = SimClient.find(ctx.client, 0, &(&1["type"] == "stream_snapshot"))
    sync = SimClient.find(ctx.client, 0, &(&1["type"] == "sync_complete"))

    replayed_ids =
      SimClient.frames(ctx.client)
      |> Enum.filter(&(&1["type"] == "message"))
      |> MapSet.new(& &1["id"])

    kept_ids = ctx.base_dir |> Substrate.messages(ctx.main_key) |> MapSet.new(& &1["id"])
    lost = MapSet.difference(before_ids, kept_ids)
    unreplayed = MapSet.difference(before_ids, replayed_ids)

    turn =
      case Substrate.await_turn_terminal(ctx.base_dir, cmid, 120_000) do
        {:ok, row} -> row
        {:error, :timeout, row} -> row
      end

    {ctx, fresh} =
      turn_completes(
        ctx,
        ctx.main_key,
        "say exactly: AFTER RESTART",
        "14b",
        "post-restart turn",
        "J7"
      )

    pointer = Substrate.harness_pointer(ctx.base_dir, ctx.main_key)

    row =
      cond do
        new_pid == old_pid ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "the gateway pid did not change (#{old_pid})",
            journey: "J7"
          )

        is_nil(snapshot) or is_nil(sync) ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "reconnect did not heal: no stream_snapshot/sync_complete",
            journey: "J7"
          )

        MapSet.size(lost) > 0 ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "message rows present before the restart are GONE after it: " <>
              "#{inspect(Enum.take(lost, 5))}",
            journey: "J7"
          )

        MapSet.size(before_ids) > 0 and MapSet.size(unreplayed) > 0 ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "replay after reconnect did not carry the full history — missing " <>
              "#{inspect(Enum.take(unreplayed, 5))}",
            journey: "J7"
          )

        is_nil(pointer) or pointer["reason"] != "loaded" ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "the harness session was not re-adopted: pointer reason is " <>
              "#{inspect(pointer && pointer["reason"])}, expected \"loaded\" (a `fallback` " <>
              "means the model lost its context across the restart)",
            journey: "J7"
          )

        is_nil(turn) ->
          Scorecard.fail("14", "restart resilience", "the interrupted turn left no row",
            journey: "J7"
          )

        turn["status"] not in ~w(delivered failed failed_unknown) ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "the interrupted turn is #{turn["status"]} after the restart — a stuck indicator with " <>
              "no terminal state is the exact failure this step forbids",
            journey: "J7"
          )

        fresh.status != :pass ->
          Scorecard.fail(
            "14",
            "restart resilience",
            "a fresh post after the restart did not complete: #{fresh.note}",
            journey: "J7"
          )

        true ->
          Scorecard.pass("14", "restart resilience",
            journey: "J7",
            note:
              "pid #{old_pid} → #{new_pid}; interrupted turn #{turn["status"]}; " <>
                "harness pointer #{inspect(pointer && pointer["reason"])}"
          )
      end

    {ctx, row}
  end

  # Step 15: a staged human post survives restart and is included in the next
  # ready-time carrier without being re-sent.
  defp j7_queue_survival(ctx) do
    {:ok, client, first} =
      SimClient.post(ctx.client, ctx.main_key, "Count to 200 slowly, one line per number.")

    first_running = await_turn_running(ctx.base_dir, first, 60_000)

    if is_nil(first_running) or first_running["status"] != "running" do
      {ctx,
       Scorecard.incomplete(
         "15",
         "restart queue survival",
         "ONE did not reach `running` before the second post, so this setup cannot prove " <>
           "that a staged post survived behind active work",
         journey: "J7"
       )}
    else
      {:ok, client, second} = SimClient.post(client, ctx.main_key, "say exactly: SURVIVED")
      ctx = %{ctx | client: client}

      case await_post_admission(ctx.base_dir, ctx.main_key, second, 60_000) do
        {:error, observation} ->
          {ctx,
           Scorecard.fail(
             "15",
             "restart queue survival",
             "the second post had no persisted history row or direct/staged delivery path: " <>
               inspect(observation),
             journey: "J7"
           )}

        {:ok, admission} ->
          j7_restart_staged_post(ctx, first, second, admission)
      end
    end
  end

  defp j7_restart_staged_post(ctx, first, second, admission) do
    second_history = List.first(admission.history_rows)
    first_before_restart = Substrate.turn_for_client_message(ctx.base_dir, first)

    first_busy_at_acceptance? =
      is_map(first_before_restart) and
        (is_nil(first_before_restart["endedAt"]) or
           first_before_restart["endedAt"] > second_history["timestamp"])

    staged_member = List.first(admission.staged_members)

    stage_pending? =
      length(admission.staged_members) == 1 and is_nil(admission.direct_turn) and
        staged_member["memberState"] in ["active", "included"] and
        staged_member["batchState"] in ["open", "sealed", "delivery_pending"]

    cond do
      not first_busy_at_acceptance? ->
        {ctx,
         Scorecard.incomplete(
           "15",
           "restart queue survival",
           "ONE reached a terminal state before TWO was accepted, so the required " <>
             "running-behind setup did not occur",
           journey: "J7"
         )}

      admission.direct_turn != nil ->
        {ctx,
         Scorecard.fail(
           "15",
           "restart queue survival",
           "TWO received its own turn while ONE was still active instead of a staged " <>
             "batch membership",
           journey: "J7"
         )}

      not stage_pending? ->
        {ctx,
         Scorecard.fail(
           "15",
           "restart queue survival",
           "TWO did not have exactly one pending persisted batch membership before restart: " <>
             inspect(admission.staged_members),
           journey: "J7"
         )}

      true ->
        j7_restart_and_verify_staged_post(ctx, first, second, second_history, staged_member)
    end
  end

  defp j7_restart_and_verify_staged_post(ctx, first, second, original_history, original_member) do
    first_before_signal = Substrate.turn_for_client_message(ctx.base_dir, first)

    if is_nil(first_before_signal) or
         first_before_signal["status"] not in ["queued", "running"] or
         not is_nil(first_before_signal["endedAt"]) do
      {ctx,
       Scorecard.incomplete(
         "15",
         "restart queue survival",
         "ONE completed before restart began, so the action did not restart with work still active",
         journey: "J7"
       )}
    else
      # Recovery may create the carrier before the restarted HTTP listener answers.
      restart_started_at = System.system_time(:millisecond)

      case LegGateway.restart(ctx.gateway) do
        {:error, reason} ->
          {ctx,
           Scorecard.fail("15", "restart queue survival", "restart failed: #{inspect(reason)}",
             journey: "J7"
           )}

        {:ok, gateway} ->
          ctx = %{ctx | gateway: gateway}

          case reconnect(ctx) do
            {:error, reason} ->
              {ctx,
               Scorecard.fail(
                 "15",
                 "restart queue survival",
                 "client could not reconnect: #{inspect(reason)}",
                 journey: "J7"
               )}

            {:ok, ctx} ->
              {observations, timed_out?} =
                await_post_paths(ctx.base_dir, ctx.main_key, [second], ctx.turn_wait_ms)

              client = SimClient.settle(ctx.client, ctx.settle_ms)
              ctx = %{ctx | client: client}
              observation = observations[second]
              history = List.first(observation.history_rows)
              member = List.first(observation.staged_members)
              first_after_restart = Substrate.turn_for_client_message(ctx.base_dir, first)
              frames = SimClient.frames(ctx.client)

              replayed_history =
                Enum.filter(frames, fn frame ->
                  frame["type"] == "message" and frame["role"] == "user" and
                    frame["clientMessageId"] == second
                end)

              staged_replies =
                Enum.filter(frames, fn frame ->
                  frame["type"] == "message" and frame["role"] == "assistant" and
                    frame["replyToClientMessageId"] == second
                end)

              row =
                cond do
                  timed_out? ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO's staged carrier path did not reach a terminal state after restart",
                      journey: "J7"
                    )

                  length(observation.history_rows) != 1 ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO's identified user history row did not survive exactly once",
                      journey: "J7"
                    )

                  history["id"] != original_history["id"] or
                      history["seq"] != original_history["seq"] ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO's original history row identity or stream position changed across restart",
                      journey: "J7"
                    )

                  length(observation.staged_members) != 1 or observation.direct_turn != nil ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO no longer has exactly one staged membership and no own turn",
                      journey: "J7"
                    )

                  history["deviceId"] != ctx.client.device_id or
                    member["deviceId"] != history["deviceId"] or
                    member["clientMessageId"] != second or
                    member["historyClientMessageId"] != second or
                    member["historyMessageId"] != history["id"] or
                    member["memberId"] != original_member["memberId"] or
                      member["batchId"] != original_member["batchId"] ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO's identified history row did not survive with its original device " <>
                        "and clientMessageId",
                      journey: "J7"
                    )

                  member["memberState"] != "included" or member["batchState"] != "delivered" or
                    member["carrierTurnSeq"] == nil or member["carrierStatus"] != "delivered" or
                      member["carrierIsBatchCarrier"] != 1 ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO's membership did not reach one delivered batch-carrier turn",
                      journey: "J7"
                    )

                  not is_integer(member["carrierCreatedAt"]) or
                      member["carrierCreatedAt"] <= restart_started_at ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "the carrier turn was created before the restart began",
                      journey: "J7"
                    )

                  length(replayed_history) != 1 or
                      List.first(replayed_history)["id"] != history["id"] ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "reconnect did not replay TWO's same identified user history row",
                      journey: "J7"
                    )

                  staged_replies != [] ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "TWO received a post-specific assistant reply despite using a batch carrier",
                      journey: "J7"
                    )

                  is_nil(first_after_restart) or
                      first_after_restart["status"] not in @terminal_turn_statuses ->
                    Scorecard.fail(
                      "15",
                      "restart queue survival",
                      "ONE did not reach a terminal state after restart",
                      journey: "J7"
                    )

                  true ->
                    Scorecard.pass("15", "restart queue survival", journey: "J7")
                end

              {ctx, row}
          end
      end
    end
  end

  defp await_turn_running(base_dir, client_message_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_turn_running(base_dir, client_message_id, deadline, nil)
  end

  defp poll_turn_running(base_dir, client_message_id, deadline, last) do
    row = Substrate.turn_for_client_message(base_dir, client_message_id)

    cond do
      is_map(row) and row["status"] == "running" ->
        row

      is_map(row) and row["status"] in @terminal_turn_statuses ->
        row

      System.monotonic_time(:millisecond) >= deadline ->
        row || last

      true ->
        Process.sleep(200)
        poll_turn_running(base_dir, client_message_id, deadline, row || last)
    end
  end

  # --- J8 helpers -------------------------------------------------------------

  defp j8_immediate_wake(ctx) do
    watermark = SimClient.mark(ctx.client)

    case wake(ctx, %{"prompt" => "reply with exactly: WAKE OK"}) do
      {:error, reason} ->
        {ctx,
         Scorecard.fail("16", "wakes", "wake dispatch failed: #{inspect(reason)}", journey: "J8")}

      {:ok, result} ->
        j8_verdict(ctx, watermark, wake_id(result), "16", "wakes", ctx.turn_wait_ms)
    end
  end

  # One correlation chain, from the DISPATCHED wakeId to the reply, with no step
  # that accepts "some sender-tagged message" or "some wake-bearing row". Two
  # wakes in flight (J8 dispatches an immediate and a scheduled one) would
  # otherwise let the evidence for one vouch for the other. The waits below only
  # decide when to stop reading; `wake_oracle_error/1` decides what held.
  defp j8_verdict(ctx, watermark, wake_id, step, label, timeout_ms) do
    turn = wake_id && Substrate.await_wake_turn(ctx.base_dir, wake_id, timeout_ms)
    message_id = turn && turn["messageId"]

    {stamped, client} =
      if message_id do
        await_frame(
          ctx.client,
          watermark,
          &(&1["type"] == "message" and &1["role"] == "user" and &1["id"] == message_id and
              is_binary(&1["sender"])),
          60_000
        )
      else
        {nil, ctx.client}
      end

    {reply, client} =
      if stamped do
        await_frame(
          client,
          watermark,
          &(&1["type"] == "message" and &1["role"] == "assistant" and
              &1["replyToMessageId"] == message_id),
          timeout_ms
        )
      else
        {nil, client}
      end

    ctx = %{ctx | client: client}

    row =
      case wake_oracle_error(%{
             wake_id: wake_id,
             turn: turn,
             message_id: message_id,
             stamped: stamped,
             reply: reply
           }) do
        nil -> Scorecard.pass(step, label, journey: "J8")
        error -> Scorecard.fail(step, label, error, journey: "J8")
      end

    {ctx, row}
  end

  @doc """
  The J8 oracle: did the substrate carry the DISPATCHED wake all the way into a
  delivered turn?

  Every leg correlates on identity, never on "some wake-bearing row": the turn
  row carries the wakeId that was dispatched, that turn names the message it
  delivered, that message arrived sender-tagged (provenance from the `sender`
  field, not text parsing), a reply correlated to that message, and the turn
  reached `delivered`.

  WHAT IS NOT HERE: the reply's CONTENT. Whether the agent obeyed the prompt's
  instruction is agent EFFECTIVENESS, which evals own; e2e tests substrate
  FUNCTIONALITY (Flynn, 2026-07-26, after run a888f9b row 16 failed the claude
  leg on reply text while every substrate oracle held). A competent agent that
  answers the wake differently must still pass every leg above.

  `observed` keys: `:wake_id` (as dispatched), `:turn`, `:message_id`,
  `:stamped` (the sender-tagged frame), `:reply`.
  """
  @spec wake_oracle_error(map()) :: String.t() | nil
  def wake_oracle_error(observed) do
    turn = observed.turn

    cond do
      is_nil(observed.wake_id) ->
        "the wake dispatch returned no wakeId"

      is_nil(turn) ->
        "no turn row was ever created for wake #{observed.wake_id}"

      turn["wakeId"] != observed.wake_id ->
        "turn row carries wakeId #{inspect(turn["wakeId"])}, " <>
          "not the dispatched #{inspect(observed.wake_id)}"

      is_nil(observed.message_id) ->
        "the wake's turn row names no delivered message"

      is_nil(observed.stamped) ->
        "the wake's own message #{observed.message_id} never arrived as a " <>
          "sender-tagged message in Main"

      is_nil(observed.reply) ->
        "no assistant reply correlated to the wake's message"

      turn["status"] != "delivered" ->
        "the wake's turn row is #{turn["status"]}#{turn_error(turn)}"

      true ->
        nil
    end
  end

  defp wake_id(result) when is_map(result),
    do: result["wakeId"] || get_in(result, ["result", "wakeId"])

  defp wake_id(_), do: nil

  # The scheduled variant: the row is visible BEFORE it fires, then it fires.
  defp j8_delayed_wake(ctx) do
    delay_ms = 15_000
    watermark = SimClient.mark(ctx.client)

    case wake(ctx, %{"prompt" => "reply with exactly: LATER OK", "afterMs" => delay_ms}) do
      {:error, reason} ->
        {ctx,
         Scorecard.fail(
           "16b",
           "scheduled wake",
           "scheduled wake dispatch failed: #{inspect(reason)}",
           journey: "J8"
         )}

      {:ok, result} ->
        id = wake_id(result)
        # Read pending BEFORE waiting: the row must be visible while it is still
        # scheduled, which is the half of step 16 a fired-only check misses.
        pending? = id && Enum.any?(Substrate.pending_wakes(ctx.base_dir), &(&1["wakeId"] == id))

        if pending? do
          # Same single chain as the immediate variant, keyed on THIS wakeId, so
          # the immediate wake's delivery cannot stand in for the scheduled one.
          j8_verdict(
            ctx,
            watermark,
            id,
            "16b",
            "scheduled wake",
            delay_ms + ctx.turn_wait_ms
          )
        else
          {ctx,
           Scorecard.fail(
             "16b",
             "scheduled wake",
             "wake #{inspect(id)} was not listed as pending before firing (pending: " <>
               "#{inspect(Enum.map(Substrate.pending_wakes(ctx.base_dir), & &1["wakeId"]))})",
             journey: "J8"
           )}
        end
    end
  end

  # The ⌥ CLI path expressed over the gateway's own facade: /agent/dispatch with
  # the org cliToken, which is what `tb wake` posts.
  defp wake(ctx, params) do
    with {:ok, token} <- Substrate.cli_token(ctx.base_dir) do
      body = %{
        "verb" => "wake",
        "sessionKey" => ctx.main_key,
        "asUser" => ctx.client.user_id,
        "params" => params
      }

      case SimClient.post_json_as(ctx.client, token, "/agent/dispatch", body) do
        {200, response} -> {:ok, response["result"] || response}
        {status, response} -> {:error, {status, response}}
      end
    end
  end

  defp reconnect(ctx) do
    _ = SimClient.disconnect(ctx.client)
    device_id = ctx.client.device_id
    token = ctx.client.token

    case SimClient.connect(ctx.host, ctx.port, token, device_id: device_id, timeout: 30_000) do
      {:ok, client} -> {:ok, %{ctx | client: client}}
      {:error, reason} -> {:error, reason}
    end
  end

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
         Scorecard.fail(
           "5",
           "create stream",
           "no live stream_created frame (client had to reconnect to see it)",
           journey: "J2"
         )}

      result.error ->
        {ctx,
         Scorecard.fail("5", "create stream", "post in the new stream: #{result.error}",
           journey: "J2"
         )}

      is_nil(row) ->
        {ctx,
         Scorecard.fail("5", "create stream", "no sessions row for #{session_key}", journey: "J2")}

      row["origin"] != "user:#{ctx.client.user_id}" ->
        {ctx,
         Scorecard.fail("5", "create stream", "origin was #{inspect(row["origin"])}",
           journey: "J2"
         )}

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
         Scorecard.fail(
           "6",
           "rename stream",
           "frame carried #{inspect(get_in(frame, ["stream", "displayName"]))}",
           journey: "J2"
         )}

      row["displayName"] != renamed ->
        {ctx,
         Scorecard.fail(
           "6",
           "rename stream",
           "sessions.displayName is #{inspect(row["displayName"])}",
           journey: "J2"
         )}

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
        {ctx,
         Scorecard.fail("7", "retire stream", "sessions.state is #{inspect(row["state"])}",
           journey: "J2"
         )}

      kept < before or kept == 0 ->
        {ctx,
         Scorecard.fail(
           "7",
           "retire stream",
           "messages were not soft-retained (#{before} → #{kept})",
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

    # Wait for the frames that END the turn, then hand the whole SEQUENCE to
    # the oracle. Waiting per-frame from a shared watermark is what let a stale
    # clear vouch for a live indicator; the waits below only decide when to
    # stop reading, never what held.
    {_echo, client} =
      await_frame(
        client,
        watermark,
        &(&1["type"] == "message" and &1["clientMessageId"] == cmid),
        30_000
      )

    {_reply, client} = await_reply(client, watermark, cmid, ctx)

    {_typing_off, client} =
      await_frame(
        client,
        watermark,
        &(&1["type"] == "typing" and &1["active"] == false and &1["sessionKey"] == session_key),
        30_000
      )

    # The settle window is part of the evidence, not an afterthought: an
    # indicator that comes back after the turn ends only shows up here.
    client = SimClient.settle(client, ctx.settle_ms)
    ctx = %{ctx | client: client}
    frames = SimClient.frames_since(client, watermark)

    progress =
      Enum.filter(
        frames,
        &(&1["type"] == "agent_progress" and &1["sessionKey"] == session_key and
            (&1["progressText"] || "") != "")
      )

    turn =
      case Substrate.await_turn_terminal(ctx.base_dir, cmid, 30_000) do
        {:ok, row} -> row
        {:error, :timeout, row} -> row
      end

    reply =
      Enum.find(
        frames,
        &(&1["type"] == "message" and &1["role"] == "assistant" and
            &1["replyToClientMessageId"] == cmid)
      )

    error =
      turn_oracle_error(%{
        frames: frames,
        session_key: session_key,
        client_message_id: cmid,
        turn: turn,
        timeout_ms: ctx.turn_wait_ms
      })

    {ctx,
     %{
       client_message_id: cmid,
       frames: frames,
       watermark: watermark,
       reply_text: reply && reply["content"],
       progress: progress,
       turn: turn,
       error: error
     }}
  end

  defp await_reply(client, watermark, cmid, ctx) do
    predicate =
      &(&1["type"] == "message" and &1["role"] == "assistant" and
          &1["replyToClientMessageId"] == cmid)

    deadline = System.monotonic_time(:millisecond) + ctx.turn_wait_ms
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
          is_map(turn) and turn["status"] in ~w(failed failed_unknown canceled) ->
            {nil, client}

          # A closed socket returns instantly, so without this the loop would
          # spin on the database until the full turn timeout — burning minutes
          # per step to learn something the socket already said. No frame can
          # arrive on a closed socket; stop and let the oracle report it.
          client.closed ->
            {nil, client}

          System.monotonic_time(:millisecond) >= deadline ->
            {nil, client}

          true ->
            await_reply(client, watermark, cmid, ctx, predicate, deadline)
        end
    end
  end

  @doc """
  J1's turn-completion oracle as a pure decision over the turn's FRAME
  SEQUENCE; nil means every leg held.

  It takes frames rather than pre-resolved booleans, and that is the whole
  design. The first version asked "is there a typing=false somewhere after the
  post?", which a STALE clear from the previous turn answers happily: the
  broken sequence `typing=false → typing=true → reply` passed with the
  indicator left ON, because the clear check matched the old false while the
  lingering check started after the final true. An indicator invariant that
  cannot see order is not an invariant. Order is now the input.

  ORDER OF REPORTING: when the turn row already says what went wrong, that is
  reported ahead of the client-side symptom it caused. "no assistant reply
  within 180000ms" sends a reader looking at the client; "turn row is failed
  (Invalid value for config option model: …)" sends them to the fault.

  WHAT IS NOT HERE: the indicator's LABEL. ON and OFF are invariants and fail
  hard; the label is harness-reported and the substrate fabricates none, so a
  plain conversational turn legitimately runs unlabeled (SMOKE step 3 as
  amended, measured in run 0e40b93). Step 4 asserts the label where a
  `tool_call*` event backs it.

  `observed` keys: `:frames` (ordered, from the post watermark through the
  settle window), `:session_key`, `:client_message_id`, `:turn`, `:timeout_ms`.
  """
  @spec turn_oracle_error(map()) :: String.t() | nil
  def turn_oracle_error(observed) do
    turn = observed.turn
    frames = observed.frames
    cmid = observed.client_message_id
    key = observed.session_key

    echo_at = index_where(frames, &(&1["type"] == "message" and &1["clientMessageId"] == cmid))

    reply_at =
      index_where(
        frames,
        &(&1["type"] == "message" and &1["role"] == "assistant" and
            &1["replyToClientMessageId"] == cmid)
      )

    cond do
      is_nil(echo_at) ->
        "no echo bubble for the posted message"

      is_nil(turn) ->
        "no turn row for the posted message"

      turn["status"] in ~w(failed failed_unknown) ->
        "turn row is #{turn["status"]}#{turn_error(turn)}"

      is_nil(indicator_on_at(frames, key, echo_at)) ->
        "typing indicator never turned on"

      is_nil(reply_at) ->
        "no assistant reply within #{observed.timeout_ms}ms"

      error = indicator_settled_error(frames, key, reply_at) ->
        error

      turn["status"] != "delivered" ->
        "turn row is #{turn["status"]}#{turn_error(turn)}"

      true ->
        nil
    end
  end

  @doc """
  The indicator invariant: after `after_at`, the indicator must END cleared.

  Returns nil when the LAST typing frame for the session is a clear that came
  after `after_at`, and a reason otherwise. "Ends cleared" is the only form of
  this check that survives out-of-order frames — asking whether a clear exists
  anywhere lets a stale one vouch for a live indicator.
  """
  @spec indicator_settled_error([map()], String.t(), non_neg_integer()) :: String.t() | nil
  def indicator_settled_error(frames, session_key, after_at) do
    case last_indicator(frames, session_key) do
      nil ->
        "typing indicator never cleared (no typing frame at all)"

      {at, true} ->
        "typing indicator was left ON (last indicator frame at position #{at} is active)"

      {at, false} when at < after_at ->
        "typing indicator never cleared after the turn ended (its last clear at position " <>
          "#{at} predates position #{after_at})"

      {_at, false} ->
        nil
    end
  end

  @doc "Position of the first typing=true for the session after `after_at`, or nil."
  @spec indicator_on_at([map()], String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def indicator_on_at(frames, session_key, after_at) do
    frames
    |> Enum.with_index()
    |> Enum.find_value(fn {frame, at} ->
      if at > after_at and typing?(frame, session_key) and frame["active"] == true, do: at
    end)
  end

  defp last_indicator(frames, session_key) do
    frames
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {frame, at}, acc ->
      if typing?(frame, session_key), do: {at, frame["active"] == true}, else: acc
    end)
  end

  defp typing?(frame, session_key),
    do: frame["type"] == "typing" and frame["sessionKey"] == session_key

  defp index_where(frames, predicate) do
    frames |> Enum.with_index() |> Enum.find_value(fn {f, i} -> if predicate.(f), do: i end)
  end

  # Reads in short slices until the indicator sequence ENDS cleared, or the
  # deadline passes. Returning early when it is already settled keeps the happy
  # path fast; the deadline keeps a genuinely stuck indicator from hanging the
  # run instead of failing it.
  defp drain_until_settled(client, watermark, session_key, timeout_ms) do
    # Distinct NAME for the loop, not another 4-arity clause of this function:
    # two same-name/same-arity clauses with identical patterns mean the entry
    # clause always matches, and this recursed forever adding a fresh deadline
    # each time. It hung a live run for twenty minutes.
    drain_settled_loop(
      client,
      watermark,
      session_key,
      System.monotonic_time(:millisecond) + timeout_ms
    )
  end

  defp drain_settled_loop(client, watermark, session_key, deadline) do
    frames = SimClient.frames_since(client, watermark)

    cond do
      is_nil(indicator_settled_error(frames, session_key, 0)) -> client
      System.monotonic_time(:millisecond) >= deadline -> client
      true -> drain_settled_loop(SimClient.settle(client, 500), watermark, session_key, deadline)
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

  # The sessions row holds the identity in COLUMNS. This rebuilds the vendor
  # identifier the wire published, so the two can be compared without either
  # side parsing a packed string.
  defp stored_ref(%{"model" => family} = row) when is_binary(family) do
    Tightbeam.Model.to_ref(%Tightbeam.Model{
      family: family,
      context: blank_to_nil(row["modelContext"])
    })
  end

  defp stored_ref(_row), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
