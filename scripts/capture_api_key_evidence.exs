# ONE-SHOT API-KEY EVIDENCE CAPTURE.
#
# Flynn's constraint on the keys this reads is BINDING: one models-list call per
# key, total, for the whole lane. No retries. No other use -- not in CI, not in
# the suite, not in the smoke, not for a convenience check. This script is the
# ONLY thing that may spend that budget, and it enforces the budget itself
# rather than trusting whoever runs it:
#
#   * it REFUSES to call if the fixture it would write already exists, so a
#     second call requires visibly deleting a committed file;
#   * it has no retry path -- any error writes nothing and exits non-zero;
#   * it appends to a ledger BEFORE calling, so a crash mid-flight still leaves
#     an honest count. That ledger is what the handoff report quotes.
#
#     elixir scripts/capture_api_key_evidence.exs anthropic
#     elixir scripts/capture_api_key_evidence.exs openai
#
# The key is read from ~/tb-test-keys/<provider> and never touches argv, a child
# process, a log line, or an error message.
#
# Nothing in `mix test`, the conformance suite, CI or the smoke calls this. The
# suite consumes the RECORDED fixtures; the live gate is a capture step, not a
# test dependency. If a capture fails the recording does not exist, the test
# that would replay it stays skipped, and the cell stays honestly unverified.
# There is no fallback that invents one.

defmodule CaptureApiKeyEvidence do
  @out "priv/credential_live"
  @ledger Path.join(@out, "CAPTURE-LEDGER.md")

  def run(["anthropic"]), do: capture(:anthropic)
  def run(["openai"]), do: capture(:openai)

  def run(_argv) do
    IO.puts(:stderr, "usage: capture_api_key_evidence.exs anthropic|openai")
    System.halt(2)
  end

  defp fixture(:anthropic), do: Path.join(@out, "claude-live-api-key.json")
  defp fixture(:openai), do: Path.join(@out, "codex-live-api-key.json")

  defp url(:anthropic), do: ~c"https://api.anthropic.com/v1/models?limit=1"
  defp url(:openai), do: ~c"https://api.openai.com/v1/models"

  defp headers(:anthropic, key),
    do: [{~c"x-api-key", String.to_charlist(key)}, {~c"anthropic-version", ~c"2023-06-01"}]

  defp headers(:openai, key),
    do: [{~c"authorization", String.to_charlist("Bearer " <> key)}]

  defp header_name(:anthropic), do: "x-api-key"
  defp header_name(:openai), do: "authorization"

  defp capture(provider) do
    path = fixture(provider)

    # GUARD 1. The budget is one call. If the answer is already on disk this is
    # not a call worth spending -- and re-running this script must never be how a
    # second one happens.
    if File.exists?(path) do
      IO.puts("#{provider}: #{path} already exists — 0 calls made.")
      System.halt(0)
    end

    key = read_key!(provider)
    log!(provider, "ATTEMPT")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    # GUARD 2. One call. No loop, no rescue-and-retry: an error falls straight
    # through to `fail!`, which writes nothing.
    case :httpc.request(
           :get,
           {url(provider), headers(provider, key)},
           [ssl: ssl, timeout: 30_000],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        record!(provider, path, key, status, response_headers, body)

      {:error, reason} ->
        fail!(provider, "transport failure: #{inspect(reason)}")
    end
  end

  defp read_key!(provider) do
    path = Path.join([System.user_home!(), "tb-test-keys", to_string(provider)])

    case File.read(path) do
      {:ok, raw} ->
        case String.trim(raw) do
          "" -> fail!(provider, "#{path} is empty")
          key -> key
        end

      {:error, reason} ->
        fail!(provider, "cannot read #{path}: #{inspect(reason)}")
    end
  end

  defp record!(provider, path, key, status, response_headers, body) do
    # The fixture records the RESPONSE. Vendor error bodies DO echo a masked key
    # (`Incorrect API key provided: sk-proj-*ogus`, recorded 2026-07-28), so this
    # is checked rather than assumed: nothing containing the key, a prefix of it,
    # or the string "sk-" is written to a file that goes into git.
    leaked =
      String.contains?(body, key) or
        String.contains?(body, String.slice(key, 0, 12)) or
        String.contains?(body, "sk-")

    if leaked do
      log!(provider, "REFUSED_TO_RECORD (response echoed key material)")

      IO.puts(:stderr, """
      #{provider}: the response body contains key material, so NOTHING was written.
      The call was made and counts against the budget. Report this and stop — do
      not retry, and do not hand-edit the body into a fixture.
      """)

      System.halt(1)
    end

    content_type =
      Enum.find_value(response_headers, fn {name, value} ->
        if to_string(name) == "content-type", do: to_string(value)
      end)

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "recorded_at" => Date.to_iso8601(Date.utc_today()),
        "budget" => "one-shot capture under Flynn's API-key budget",
        "request" => %{
          "method" => "GET",
          "url" => to_string(url(provider)),
          "header" => header_name(provider),
          "sanitized" => true
        },
        "response" => %{
          "status" => status,
          "headers" => %{"content-type" => content_type},
          "body" => JSON.decode!(body)
        }
      })
    )

    log!(provider, "RECORDED status=#{status} bytes=#{byte_size(body)}")
    IO.puts("#{provider}: 1 call made, HTTP #{status}, recorded to #{path}")
  end

  defp fail!(provider, message) do
    log!(provider, "FAILED #{message}")
    IO.puts(:stderr, "#{provider}: #{message}. Nothing recorded. Do NOT retry — report it.")
    System.halt(1)
  end

  # GUARD 3. Appended BEFORE the call, so a crash mid-flight still leaves an
  # honest count. The file is created by the first invocation and is committed
  # once it has real rows in it; a row that failed before `ATTEMPT` (an
  # unreadable key file) never reached the vendor and is not a spent call, which
  # is why the reason is written out rather than reduced to a status.
  defp log!(provider, outcome) do
    File.mkdir_p!(@out)
    stamp = DateTime.to_iso8601(DateTime.utc_now())
    File.write!(@ledger, "- #{stamp} #{provider} #{outcome}\n", [:append])
  end
end

CaptureApiKeyEvidence.run(System.argv())
