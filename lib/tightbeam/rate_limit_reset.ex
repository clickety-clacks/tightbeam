defmodule Tightbeam.RateLimitReset do
  @moduledoc false

  alias Tightbeam.{DB, EventLog, Harness, HarnessProcess, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Harness.Claude

  @consumer "rate_limit_reset"

  def schedule_in_txn(%Txn{} = txn, session, result, reason, observed_at) do
    with true <- to_string(session.harness) == Claude.wire_name(),
         reset_at when is_integer(reset_at) <- from_error(reason, observed_at),
         {_, %{observationId: observation_id}} <- result do
      wake_id = "rate-limit-reset:" <> observation_id

      if Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [wake_id]) == [] do
        Wakes.schedule_in_txn(txn, %{
          wake_id: wake_id,
          session_key: session.session_key,
          origin: "process:tightbeam",
          consumer: @consumer,
          prompt: observation_id,
          due_at: reset_at
        })

        # A retry can encounter another limit before a normal success has
        # resolved the incident. Reinstate admission's hold for that reset.
        if open_incident(txn, observation_id) != [] do
          HarnessProcess.begin_park_in_txn(txn, adapter_key(Claude.wire_name(), session.host))
        end
      end
    end

    :ok
  end

  def release(db, %{wake_id: wake_id}) do
    DB.transaction(db, fn txn ->
      at = System.system_time(:millisecond)

      case Txn.q(
             txn,
             "SELECT prompt,dueAt FROM wakes WHERE wakeId=?1 AND consumer=?2 AND state='pending'",
             [wake_id, @consumer]
           ) do
        [[observation_id, due_at]] when due_at <= at ->
          Wakes.consume_internal_in_txn(txn, wake_id)
          release_incident_in_txn(txn, observation_id, due_at, at)

        [[_, _]] ->
          {:deferred, :before_reset}

        [] ->
          :already_consumed
      end
    end)
  end

  defp release_incident_in_txn(txn, observation_id, due_at, at) do
    case open_incident(txn, observation_id) do
      [[incident_id, harness, host]] ->
        later_resets =
          Txn.q(
            txn,
            """
            SELECT 1 FROM wakes w
            JOIN harness_health_observations o ON o.id=w.prompt
            WHERE w.consumer=?1 AND w.state='pending' AND w.dueAt>?2
              AND o.incidentId=?3 LIMIT 1
            """,
            [@consumer, at, incident_id]
          )

        key = adapter_key(harness, host)

        if later_resets == [] and HarnessProcess.parked_in_txn?(txn, key) do
          HarnessProcess.complete_park_in_txn(txn, key)

          # Reset permits another attempt; it is not a successful provider
          # response and must not resolve health or authorize success redelivery.
          EventLog.lifecycle_in_txn(
            txn,
            "rate_limit_hold_released",
            incident_id,
            JSON.encode!(%{observationId: observation_id, resetAt: due_at, releasedAt: at})
          )

          Txn.q(
            txn,
            """
            SELECT DISTINCT s.sessionKey FROM sessions s
            JOIN turns t ON t.sessionKey=s.sessionKey
            WHERE s.harness=?1 AND s.host=?2 AND s.state='active' AND t.status='queued'
            """,
            [harness, host]
          )
          |> Enum.each(fn [session_key] ->
            Txn.handoff(txn, Tightbeam.LaneManager, {:ensure_lane, session_key})
          end)
        end

        :ok

      [] ->
        :ok
    end
  end

  defp open_incident(txn, observation_id) do
    Txn.q(
      txn,
      """
      SELECT i.id,i.harness,i.host FROM harness_health_observations o
      JOIN harness_health_incidents i ON i.id=o.incidentId
      WHERE o.id=?1 AND i.state='open' AND i.failureClass='rate-limit-dead'
      """,
      [observation_id]
    )
  end

  defp adapter_key(harness, host), do: {Harness.parse!(harness).id(), "shared", host}

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @reset ~r/\bresets\s+(?:(?<month>[A-Za-z]{3})\s+(?<day>\d{1,2})(?:,\s*|\s+at\s+))?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<period>am|pm)\s*(?<zone>\([A-Za-z0-9_+\/-]+\)|UTC)(?![A-Za-z])/i

  # The reset text belongs to a typed terminal provider error. Assistant
  # output that happens to quote a limit message is not recovery evidence.
  def from_error(%{"data" => %{"errorKind" => "rate_limit"}, "message" => message}, at)
      when is_binary(message) and is_integer(at) do
    case Regex.named_captures(@reset, message) do
      nil -> nil
      fields -> reset_at(fields, DateTime.from_unix!(at, :millisecond))
    end
  end

  def from_error(_error, _at), do: nil

  defp reset_at(fields, observed) do
    hour = String.to_integer(fields["hour"])
    minute = if fields["minute"] == "", do: 0, else: String.to_integer(fields["minute"])
    zone = fields["zone"] |> String.trim_leading("(") |> String.trim_trailing(")")
    zone = if String.upcase(zone) == "UTC", do: "Etc/UTC", else: zone

    with true <- hour in 1..12 and minute in 0..59,
         {:ok, local_observed} <- DateTime.shift_zone(observed, zone, Tz.TimeZoneDatabase) do
      hour = rem(hour, 12) + if(String.downcase(fields["period"]) == "pm", do: 12, else: 0)
      time = Time.new!(hour, minute, 0)
      # Provider text has minute precision. An error received during that
      # minute must not turn an already-due reset into another day's hold.
      observed_minute = div(DateTime.to_unix(observed), 60) * 60

      fields
      |> dates(DateTime.to_date(local_observed))
      |> Enum.reduce_while(nil, fn date, nil ->
        case DateTime.new(date, time, zone, Tz.TimeZoneDatabase) do
          {:ok, reset} ->
            next_reset([reset], observed_minute)

          {:ambiguous, first, second} ->
            # During a repeated hour, use the next occurrence of the stated
            # clock time, including the second occurrence if the first passed.
            next_reset([first, second], observed_minute)

          {:gap, _before_gap, after_gap} ->
            # A future nonexistent local time does not identify a deadline.
            # Keep the hold rather than inventing a reset after the clock jump.
            if DateTime.to_unix(after_gap) >= observed_minute,
              do: {:halt, nil},
              else: {:cont, nil}

          {:error, _} ->
            {:halt, nil}
        end
      end)
    else
      _ -> nil
    end
  end

  defp next_reset(resets, observed_minute) do
    case Enum.find(resets, &(DateTime.to_unix(&1) >= observed_minute)) do
      nil -> {:cont, nil}
      reset -> {:halt, DateTime.to_unix(reset, :millisecond)}
    end
  end

  defp dates(%{"month" => ""}, date), do: [date, Date.add(date, 1)]

  defp dates(%{"month" => month, "day" => day}, date) do
    case Enum.find_index(@months, &(&1 == String.downcase(month))) do
      nil ->
        []

      index ->
        for year <- [date.year, date.year + 1],
            {:ok, reset} <- [Date.new(year, index + 1, String.to_integer(day))],
            do: reset
    end
  end
end
