defmodule Tightbeam.CronWake do
  @moduledoc "Five-field cron schedules in the gateway's local time zone."
  alias Tightbeam.{DB, Wakes}
  alias Tightbeam.DB.Txn
  require Logger

  def ensure_schema(db) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.exec(txn, """
        CREATE TABLE IF NOT EXISTS cron_wake_migration (
          id INTEGER PRIMARY KEY CHECK(id=0),
          appliedAt INTEGER NOT NULL
        );
        """)

        if Txn.q(txn, "SELECT id FROM cron_wake_migration WHERE id=0") == [] do
          Txn.exec(txn, """
          CREATE TABLE cron_wake_schedules (
            wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
            schedule TEXT NOT NULL
          );
          """)

          Txn.q(txn, "INSERT INTO cron_wake_migration VALUES(0,?1)", [
            System.system_time(:millisecond)
          ])
        end

        :ok
      end)

    :ok
  end

  def valid?(schedule) do
    next_at(schedule, System.system_time(:millisecond))
    true
  rescue
    ArgumentError -> false
  end

  def next_at(schedule, after_ms) do
    [minute, hour, day, month, weekday] = parse!(schedule)
    {date, _time} = :calendar.system_time_to_local_time(div(after_ms, 1000), :second)
    start_day = :calendar.date_to_gregorian_days(date)

    # Eight years covers the longest gap between leap days in the Gregorian calendar.
    Enum.find_value(0..(8 * 366), fn offset ->
      {year, mon, dom} = date = :calendar.gregorian_days_to_date(start_day + offset)
      dow = rem(:calendar.day_of_the_week(date), 7)

      day_match =
        if day.wild or weekday.wild,
          do: dom in day.values and dow in weekday.values,
          else: dom in day.values or dow in weekday.values

      if mon in month.values and day_match do
        for h <- hour.values,
            m <- minute.values,
            utc <- :calendar.local_time_to_universal_time_dst({{year, mon, dom}, {h, m, 0}}),
            at = (:calendar.datetime_to_gregorian_seconds(utc) - 62_167_219_200) * 1000,
            at > after_ms do
          at
        end
        |> Enum.min(fn -> nil end)
      end
    end) || raise ArgumentError, "cron schedule has no future occurrence"
  end

  defp parse!(schedule) when is_binary(schedule) do
    fields = String.split(schedule)
    if length(fields) != 5, do: raise(ArgumentError, "cron requires five numeric fields")

    Enum.zip(fields, [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}])
    |> Enum.map(fn {field, {lo, hi}} ->
      values =
        field
        |> String.split(",")
        |> Enum.flat_map(fn part ->
          {range, step} =
            case String.split(part, "/") do
              [range] -> {range, 1}
              [range, step] -> {range, number!(step, 1, hi)}
              _ -> raise ArgumentError, "invalid cron step"
            end

          {first, last} =
            case String.split(range, "-") do
              ["*"] ->
                {lo, hi}

              [value] ->
                n = number!(value, lo, hi)
                {n, n}

              [first, last] ->
                {number!(first, lo, hi), number!(last, lo, hi)}

              _ ->
                raise ArgumentError, "invalid cron range"
            end

          if first > last, do: raise(ArgumentError, "invalid cron range")
          Enum.take_every(Enum.to_list(first..last), step)
        end)

      values = if hi == 7, do: Enum.map(values, &rem(&1, 7)), else: values
      %{wild: String.starts_with?(field, "*"), values: Enum.sort(Enum.uniq(values))}
    end)
  end

  defp parse!(_), do: raise(ArgumentError, "cron must be a string")

  defp number!(text, lo, hi) do
    case Integer.parse(text) do
      {n, ""} when n >= lo and n <= hi -> n
      _ -> raise ArgumentError, "invalid cron value"
    end
  end

  def fire_due(db, at) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM wakes INDEXED BY wakes_due
        WHERE state='pending' AND consumer='cron' AND dueAt<=?1 ORDER BY dueAt
        """,
        [at]
      )

    Enum.each(rows, fn [id] ->
      try do
        {:ok, :ok} =
          DB.transaction(db, fn txn ->
            case Wakes.get_in_txn(txn, id) do
              %{state: "pending", due_at: due} = wake when due <= at ->
                [[schedule]] =
                  Txn.q(txn, "SELECT schedule FROM cron_wake_schedules WHERE wakeId=?1", [id])

                next = next_at(schedule, at)

                input = if wake.class_election == "classifier", do: Map.delete(wake, :class), else: wake

                input
                |> Map.delete(:wake_id)
                |> Map.merge(%{consumer: "prompt", due_at: at})
                |> then(&Wakes.schedule_in_txn(txn, &1))

                Txn.q(txn, "UPDATE wakes SET dueAt=?2, firedAt=?3 WHERE wakeId=?1", [id, next, at])

                Wakes.schedule_changed_in_txn(txn, {:schedule_changed, next})

              _ ->
                :ok
            end

            :ok
          end)
      rescue
        error in DB.Overloaded -> reraise error, __STACKTRACE__
        error in MatchError ->
          if match?({:error, %DB.Overloaded{}}, error.term),
            do: reraise(error, __STACKTRACE__),
            else: Logger.warning("cron wake #{id} deferred: #{Exception.message(error)}")
        error -> Logger.warning("cron wake #{id} deferred: #{Exception.message(error)}")
      end
    end)
  end
end
