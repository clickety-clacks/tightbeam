defmodule Tightbeam.RateLimitResetTest do
  use ExUnit.Case, async: true

  alias Tightbeam.RateLimitReset

  test "session reset uses the next UTC clock time, including midnight rollover" do
    assert reset("1:30am UTC", ~U[2026-10-22 21:19:00Z]) ==
             millis(~U[2026-10-23 01:30:00Z])

    assert reset("1:40am (UTC)", ~U[2026-10-22 00:16:00Z]) ==
             millis(~U[2026-10-22 01:40:00Z])

    assert reset("12am (UTC)", ~U[2026-10-22 23:00:00Z]) ==
             millis(~U[2026-10-23 00:00:00Z])

    assert reset("12pm UTC", ~U[2026-10-22 11:00:00Z]) ==
             millis(~U[2026-10-22 12:00:00Z])
  end

  test "dated weekly reset retains the provider date and handles year rollover" do
    assert reset("Aug 15, 12am (UTC)", ~U[2026-08-09 10:00:00Z]) ==
             millis(~U[2026-08-15 00:00:00Z])

    assert reset("Jan 1, 1am (UTC)", ~U[2026-12-31 23:00:00Z]) ==
             millis(~U[2027-01-01 01:00:00Z])
  end

  test "a reset at the observation time is due immediately" do
    at = ~U[2026-10-23 01:30:00Z]
    assert reset("1:30am UTC", at) == millis(at)
    assert reset("1:30am UTC", ~U[2026-10-23 01:30:45Z]) == millis(at)
  end

  test "only typed limits with an understood reset supply a deadline" do
    at = millis(~U[2026-10-22 21:19:00Z])
    message = "You've hit your session limit · resets 1:30am UTC"
    assert RateLimitReset.from_error(message, at) == nil
    assert RateLimitReset.from_error(%{"message" => message}, at) == nil

    for text <- ["", "1:30am", "1:30am (PDT)", "25:30am UTC", "1:99am UTC", "Feb 30, 1am UTC"] do
      assert reset(text, ~U[2026-10-22 21:19:00Z]) == nil
    end
  end

  defp reset(text, observed) do
    RateLimitReset.from_error(
      %{
        "data" => %{"errorKind" => "rate_limit"},
        "message" => "Internal error: You've hit your session limit · resets " <> text
      },
      millis(observed)
    )
  end

  defp millis(datetime), do: DateTime.to_unix(datetime, :millisecond)
end
