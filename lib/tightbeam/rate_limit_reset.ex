defmodule Tightbeam.RateLimitReset do
  @moduledoc false

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @reset ~r/\bresets\s+(?:(?<month>[A-Za-z]{3})\s+(?<day>\d{1,2}),\s*)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<period>am|pm)\s*(?:\(UTC\)|UTC)(?![A-Za-z])/i

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

    if hour in 1..12 and minute in 0..59 do
      hour = rem(hour, 12) + if(String.downcase(fields["period"]) == "pm", do: 12, else: 0)
      time = Time.new!(hour, minute, 0)

      fields
      |> dates(DateTime.to_date(observed))
      |> Enum.map(&DateTime.new!(&1, time, "Etc/UTC"))
      |> Enum.find(&(DateTime.compare(&1, observed) != :lt))
      |> case do
        nil -> nil
        reset -> DateTime.to_unix(reset, :millisecond)
      end
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
