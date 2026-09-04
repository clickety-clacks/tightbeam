defmodule Tightbeam.Dispatch do
  @moduledoc """
  THE verb chokepoint (T3: one chokepoint, closed sets; TS reference:
  src/core/dispatch.ts). Every state-changing call — wire, HTTP facade, agent
  CLI, wake delivery — is a verb dispatched here. Nothing mutates registry/
  store/devices except through a verb handler. Reads may query stores
  directly; writes may not.

  Elixir shape (deliberate divergence from the TS mutable registry): the
  handler table is an IMMUTABLE map built once by the composition root
  (`Tightbeam.Gateway.handlers/1`) and passed in the call. There is no
  register/2 at runtime — the verb set is closed at build time, which is the
  point. Dispatch itself is a plain function, not a process: handlers run in
  the CALLER's process (a socket, an HTTP request task, the scheduler), and
  anything long-running goes through the Ledger/lane pipeline, never inline.

  Before a known handler runs, the deny-only `Tightbeam.Rules` tier evaluates
  the raw call. A statute denial or fact error appends kind "denied" and
  returns immediately; that audit append is best-effort so an unavailable
  sink cannot fail open. All calls that pass statutes retain the existing
  behavior: kind "verb" on acceptance, kind "denied" when the verb is unknown
  or the handler returns a denial (`%{code: _}`). Handler outcome rows are
  appended AFTER the handler so they can carry the result; a handler crash
  still appends a "verb" row with the error.
  """

  alias Tightbeam.{
    Assignments,
    Escalation,
    EventLog,
    Firehose.Publisher,
    Placement,
    RailEpisodes,
    RailRemedy,
    Rules
  }

  @typedoc """
  A verb call. `origin` is WHO (\"user:flynn\" | \"agent:<handle>\") — never
  trusted from params, always set by the transport from its authenticated
  identity. `session_key` is the TARGET (nil for verbs without one).
  """
  @type call :: %{
          required(:verb) => String.t(),
          required(:origin) => String.t(),
          required(:session_key) => String.t() | nil,
          required(:params) => map(),
          optional(:principal) =>
            {:session, String.t()}
            | {:user, String.t()}
            | {:process, String.t()}
            | {:remedy, map()}
            | nil
        }

  @typedoc "An accepted result whose event was committed by the handler transaction."
  @type accepted_in_txn ::
          {:accepted_in_txn, pos_integer(), %{canceled: true} | %{assignment: map()}}

  @typedoc "A handler: pure-ish fun; returns a result map, or %{code: _} to deny."
  @type handler :: (call() -> map() | accepted_in_txn())

  @type handlers :: %{optional(String.t()) => handler()}

  @doc """
  Dispatch a call through the handler table. Unknown verb → `{:error,
  %{code: "unknown_verb"}}` + a "denied" event. Handler returning `%{code: _}`
  → `{:error, that_map}` + a "denied" event. Otherwise `{:ok, result}` + a
  "verb" event. A raising handler is caught: "verb" event with the error,
  `{:error, %{code: "server_error", message: _}}` to the caller.
  """
  @spec dispatch(GenServer.server(), handlers(), call()) ::
          {:ok, map()} | {:error, map()} | {:decision_pending, String.t()}
  def dispatch(db \\ Tightbeam.DB, handlers, call) do
    verb = Map.fetch!(call, :verb)
    origin = Map.fetch!(call, :origin)
    principal = Map.get(call, :principal)
    session_key = Map.get(call, :session_key)

    case bracket_precheck(db, call, verb) do
      :proceed ->
        dispatch_through_rail(db, handlers, call, verb, origin, principal, session_key)

      {:replay, assignment} ->
        # A keyed replay bypasses the rail entirely (statute inertness): the
        # original assignment is returned, no rumination, no terminal guard.
        :ok =
          EventLog.append_event_with_handoff(
            db,
            "verb",
            verb,
            origin,
            session_key,
            assignment,
            principal,
            &Publisher.observed_accepted_in_txn(&1, call)
          )

        {:ok, assignment}

      {:refuse, error} ->
        # Terminal guard fires BEFORE Rules.decide: no statute or remedy episode
        # touches a non-open item (work-item-brackets §Mechanism, Proof 12).
        best_effort_denial(db, verb, origin, principal, session_key, error)
        {:error, error}
    end
  end

  # The replay/terminal hoist is the one structural change: for an assign or
  # dispatch, the idempotency replay lookup and the terminal guard are resolved
  # before the rail so both the guard and Rules.decide see the replay outcome.
  defp bracket_precheck(db, call, verb) when verb in ["assign", "dispatch"] do
    Assignments.dispatch_precheck(db, call)
  end

  defp bracket_precheck(_db, _call, _verb), do: :proceed

  defp dispatch_through_rail(db, handlers, call, verb, origin, principal, session_key) do
    {decision, to_close, to_consume} = Rules.decide(db, call)
    Enum.each(to_close, &close(db, handlers, &1))

    case decision do
      {:deny, error} ->
        best_effort_denial(db, verb, origin, principal, session_key, error)
        {:error, error}

      {:remedy, statute, ref, error} ->
        outcome = RailRemedy.fire(db, handlers, statute, ref, call)
        error = remedy_error(error, outcome)
        best_effort_denial(db, verb, origin, principal, session_key, error)
        {:error, error}

      {:escalate, statute, ctx, dr_id} ->
        outcome =
          case dr_id do
            nil -> Escalation.escalate(db, call, statute, Map.put(ctx, :dr_id, nil))
            id -> {:decision_pending, id}
          end

        best_effort_denial(db, verb, origin, principal, session_key, ctx.error)
        outcome

      # A sensor malfunction denies AND summons (§A3). The caller gets the denial it
      # already got — never `{:decision_pending, _}` — while the escalation engine opens
      # the request that puts a mind on the sensor. The episode key in `ctx` is what
      # makes the one-open-request index dedupe on the CONDITION, so a retry loop cannot
      # storm the engine. The deny is settled FIRST and the summons is `summon/4`, which
      # cannot raise: the summons is subordinate to the deny (§B3), so an unreachable
      # mind is a recorded gap and never a crashed call.
      {:deny_escalate, statute, ctx} ->
        best_effort_denial(db, verb, origin, principal, session_key, ctx.error)
        :ok = RailEpisodes.summon(db, call, statute, Map.put(ctx, :dr_id, nil))
        {:error, ctx.error}

      :allow ->
        consumed = Enum.map(to_consume, &{&1, Escalation.consume(db, &1)})

        case Enum.find(consumed, fn {_id, won?} -> not won? end) do
          nil ->
            dispatch_to_handler(db, handlers, call, verb, origin, principal, session_key)

          {lost_id, false} ->
            error = %{
              code: "rule_denied",
              rule: ruling_statute(db, lost_id),
              edge: if(Map.get(call, :edge, :verb) == :turn_end, do: "turn-end", else: "verb"),
              reason: "rule_denied",
              script_exit_class: nil,
              ref: gated_ref(call),
              producer: nil,
              identity_manifest_sha: Rules.active_identity_manifest_sha(),
              message: "ruling authorization was no longer available"
            }

            best_effort_denial(db, verb, origin, principal, session_key, error)
            {:error, error}
        end
    end
  end

  # Two closures ride the same actor-owned list. A remedy episode closes for a subject
  # whose statute passed; a malfunction episode closes because the statute's check
  # answered at all, whatever it answered. The atom tag is unambiguous — a statute name
  # is a lowercase string, never an atom.
  defp close(db, _handlers, {:episodes, statute, position}),
    do: RailEpisodes.recovered(db, statute, position)

  defp close(db, _handlers, {statute, subject, occurrence}),
    do: RailRemedy.close(db, statute, subject, occurrence)

  defp close(db, handlers, {:notice, statute, subject, call}),
    do: RailRemedy.notice(db, handlers, statute, subject, call)

  defp dispatch_to_handler(db, handlers, call, verb, origin, principal, session_key) do
    call =
      if verb in ["identity-edit", "identity-relearn", "learn", "unlearn", "kungfu-scaffold"] do
        Map.put_new(call, :invocation_id, "identity-" <> Tightbeam.Id.uuid4())
      else
        call
      end

    publisher_call = Publisher.capture_before(db, call)

    case Map.fetch(handlers, verb) do
      :error ->
        error = %{code: "unknown_verb"}

        :ok =
          EventLog.append_event_with_handoff(
            db,
            "denied",
            verb,
            origin,
            session_key,
            error,
            principal,
            &Publisher.denied_in_txn(&1, publisher_call, error)
          )

        {:error, error}

      {:ok, handler} ->
        publisher_call =
          if Publisher.transactional_verb?(verb),
            do: Map.put(publisher_call, :firehose_in_txn, true),
            else: publisher_call

        handler_call =
          case verb do
            verb when verb in ["assign", "dispatch"] ->
              Map.put(publisher_call, :accepted_event_in_txn, true)

            "condition" ->
              Map.put(publisher_call, :firehose_effect_requested, true)

            _ ->
              publisher_call
          end

        case invoke(handler, handler_call) do
          {:returned, %{code: _} = error} ->
            payload =
              if verb == "settle-turn",
                do: outcome_payload(verb, call, {:returned, error}),
                else: error

            :ok =
              EventLog.append_event_with_handoff(
                db,
                "denied",
                verb,
                origin,
                session_key,
                payload,
                principal,
                &Publisher.denied_in_txn(&1, publisher_call, error)
              )

            {:error, error}

          {:returned, {:accepted_in_txn, event_id, %{canceled: true} = result}}
          when is_integer(event_id) and event_id > 0 and map_size(result) == 1 ->
            :ok = Publisher.accepted_after_handler(db, publisher_call, result)
            {:ok, result}

          {:returned, {:accepted_in_txn, event_id, %{assignment: assignment} = envelope}}
          when is_integer(event_id) and event_id > 0 and map_size(envelope) == 1 and
                 is_map(assignment) ->
            :ok = Publisher.accepted_after_handler(db, publisher_call, assignment)
            {:ok, assignment}

          {:returned, {:firehose_effect, result, changed?}} when is_boolean(changed?) ->
            payload = outcome_payload(verb, call, {:returned, result})
            :ok = EventLog.append_event(db, "verb", verb, origin, session_key, payload, principal)

            :ok =
              Publisher.accepted_after_handler(
                db,
                Map.put(publisher_call, :firehose_changed, changed?),
                result
              )

            {:ok, result}

          {:returned, result} ->
            payload = outcome_payload(verb, call, {:returned, result})

            if Publisher.transactional_verb?(verb) do
              :ok =
                EventLog.append_event(
                  db,
                  "verb",
                  verb,
                  origin,
                  session_key,
                  payload,
                  principal
                )
            else
              :ok =
                EventLog.append_event_with_handoff(
                  db,
                  "verb",
                  verb,
                  origin,
                  session_key,
                  payload,
                  principal,
                  &Publisher.accepted_in_txn(&1, publisher_call, result)
                )
            end

            {:ok, result}

          {:raised, exception} ->
            error = %{code: "server_error", message: Exception.message(exception)}
            payload = outcome_payload(verb, call, {:raised, exception})

            :ok =
              EventLog.append_event_with_handoff(
                db,
                "verb",
                verb,
                origin,
                session_key,
                payload,
                principal,
                &Publisher.denied_in_txn(&1, publisher_call, error)
              )

            {:error, error}
        end
    end
  end

  # Verbs whose RESULT must not be duplicated into observability. A closed set,
  # like the handler table. `events.payload` is write-only observability at the
  # application seam and an agent on the gateway host can read the database
  # directly, so this is not secret-keeping: it prevents UNBOUNDED STORAGE GROWTH
  # (a second copy of every transcript on every read, plus content in crash rows)
  # and keeps the trail to WHAT was read rather than WHAT was returned.
  #
  # ADDING THE SECOND VERB: `elided_count/1` defines N as the summed length of the
  # result's top-level lists. That is exactly the entry/candidate count for a verb
  # whose result carries ONE page list. A verb returning two lists would have them
  # summed, and one returning none would report 0 — so a second member either
  # accepts that meaning of N or brings its own counter.
  @result_elided ~w(transcript)
  @activation_write_verbs ~w(activation-declare activation-authority activation-attempt activation-observe activation-reconcile activation-withdraw activation-renotify activation-ack)

  # The CALL is audited with its params — that IS the access trail — and the
  # RESULT is replaced by a count. Denials are NOT elided: an error map is useful
  # audit and carries no transcript.
  #
  # A crash is elided too, and its PAYLOAD never carries `Exception.message/1`: an
  # exception message is an uncontrolled channel for whatever the handler was
  # holding (a MatchError renders `inspect(term)`), so a raise mid-read would
  # otherwise write message content verbatim into durable storage. That is why
  # elision keys on the classified handler OUTCOME, not on the event kind.
  #
  # SCOPE, stated exactly: the caller's returned error above IS built with
  # `Exception.message/1`, so it can carry the term the handler held. That is
  # deliberate and unchanged — the caller just passed authorization for those very
  # rows, so it is content they were entitled to read, and narrowing it is a
  # behavior change no spec here authorizes. Elision governs the audit row only.
  defp outcome_payload("onboard", _call, {:returned, result}) when is_map(result),
    do: Map.delete(result, :lease_id)

  defp outcome_payload(verb, _call, {:returned, %{event: event, state: state}})
       when verb in @activation_write_verbs do
    %{
      activation_id: event.activation_id,
      event_kind: event.kind,
      event_id: event.event_id,
      state: state
    }
  end

  defp outcome_payload("activation-status", _call, {:returned, result}) do
    %{
      activation_id: result.activation_id,
      state: result.state,
      event_count: length(result.events)
    }
  end

  defp outcome_payload("activations", _call, {:returned, result}), do: %{count: result.count}

  defp outcome_payload("settle-turn", call, outcome) do
    params = Map.get(call, :params, %{})

    base = %{
      session_key: params[:session_key],
      turn_seq: params[:turn_seq],
      outcome: params[:outcome],
      principal: Map.get(call, :origin),
      idempotency_key_digest: digest(params[:idempotency_key]),
      reason_digest: digest(params[:reason])
    }

    case outcome do
      {:returned, %{code: code}} -> Map.put(base, :code, code)
      {:returned, result} -> Map.merge(base, %{code: "settled", result: result})
      {:raised, _exception} -> Map.merge(base, %{code: "server_error", crash: true})
    end
  end

  defp outcome_payload(verb, _call, {:raised, _exception})
       when verb in @activation_write_verbs or verb in ["activation-status", "activations"],
       do: %{code: "server_error", crash: true}

  defp outcome_payload(verb, call, outcome) do
    if verb in @result_elided do
      elided = %{elided: true, params: Map.get(call, :params, %{})}

      case outcome do
        {:returned, result} -> Map.put(elided, :count, elided_count(result))
        {:raised, _exception} -> Map.merge(elided, %{crash: true, code: "server_error"})
      end
    else
      case outcome do
        {:returned, result} -> result
        {:raised, exception} -> %{code: "server_error", message: Exception.message(exception)}
      end
    end
  end

  # An elided read returns a page, and the page is the only top-level list it
  # carries — so the count needs no per-verb knowledge of which key holds it. See
  # the note on `@result_elided` before adding a second member.
  defp elided_count(result) when is_map(result) do
    result |> Map.values() |> Enum.filter(&is_list/1) |> Enum.map(&length/1) |> Enum.sum()
  end

  defp elided_count(_result), do: 0

  defp digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp digest(_value), do: nil

  defp best_effort_denial(db, verb, origin, principal, session_key, error) do
    try do
      :ok =
        EventLog.append_event_with_handoff(
          db,
          "denied",
          verb,
          origin,
          session_key,
          JSON.encode!(error),
          principal,
          fn txn ->
            Publisher.denied_in_txn(
              txn,
              %{
                verb: verb,
                origin: origin,
                principal: principal,
                session_key: session_key,
                params: %{}
              },
              error
            )
          end
        )
    catch
      _kind, _reason -> :ok
    end
  end

  defp invoke(handler, call) do
    {:returned, handler.(call)}
  rescue
    exception in Placement.Refusal ->
      {:returned, %{code: exception.code, message: exception.message}}

    exception ->
      {:raised, exception}
  end

  defp gated_ref(call) do
    params = Map.fetch!(call, :params)

    params[:assignment_id] || params["assignment_id"] || params[:reviews_assignment_id] ||
      params["reviews_assignment_id"] || params[:work_item_id] || params["work_item_id"]
  end

  defp remedy_error(error, %{denial: denial}) do
    error
    |> Map.merge(Map.take(denial, [:rule, :ref, :message]))
    |> Map.put(:reason, "remedy_blocked")
    |> Map.put(:producer, nil)
  end

  defp remedy_error(error, outcome),
    do: %{error | reason: "remedy_fired", producer: outcome.producer_id}

  defp ruling_statute(db, ruling_id) do
    case Escalation.statute_name_for_ruling(db, ruling_id) do
      {:ok, statute} -> statute
      :not_found -> "ruling-authorization"
    end
  end
end
