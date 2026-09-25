defmodule Tightbeam.ErrorDiagnosticTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ErrorDiagnostic

  # Synthetic fixtures only. None of these is, or was copied from, a real secret.
  @token "sk-fixture-SENTINEL-0123456789abcdef"
  @github "ghp_fixtureSENTINEL0123456789"
  @bearer "fixtureSENTINELbearer0123456789"
  @password "fixture-SENTINEL-password"

  defp leaks?(value), do: value |> JSON.encode!() |> String.contains?("SENTINEL")

  describe "redact_text/1" do
    test "masks every secret form in place and keeps the surrounding text" do
      text =
        "call failed key #{@token} for #{@github}; Authorization: Bearer #{@bearer}; " <>
          "url https://user:#{@password}@example.test/v1 password=#{@password} " <>
          ~s({"client_secret":"#{@password}"}) <>
          "\n-----BEGIN RSA PRIVATE KEY-----\nfixtureSENTINELkeybody\n-----END RSA PRIVATE KEY-----\nafter"

      redacted = ErrorDiagnostic.redact_text(text)

      refute redacted =~ "SENTINEL"
      assert redacted =~ "call failed key [REDACTED:token] for [REDACTED:token];"
      assert redacted =~ "Authorization: Bearer [REDACTED:secret_field]"
      assert redacted =~ "https://[REDACTED:userinfo]@example.test/v1"
      assert redacted =~ "password=[REDACTED:secret_field]"
      assert redacted =~ ~s("client_secret":"[REDACTED:secret_field]")
      assert redacted =~ "[REDACTED:private_key]\nafter"
    end

    test "leaves ordinary text alone" do
      text = "turn failed: rate limited (retry after 30s) at https://example.test/v1"
      assert ErrorDiagnostic.redact_text(text) == text
    end

    test "an unterminated private key block is masked to the end" do
      assert ErrorDiagnostic.redact_text("x -----BEGIN PRIVATE KEY-----\nfixtureSENTINEL") ==
               "x [REDACTED:private_key]"
    end
  end

  describe "encode_term/1" do
    test "secret-named fields keep their keys and lose their values" do
      encoded =
        ErrorDiagnostic.encode_term(%{
          "apiKey" => @token,
          "x-api-key" => @token,
          access_token: @token,
          password: @password,
          status: 401,
          headers: [{"authorization", "Bearer " <> @bearer}, ["Cookie", "s=" <> @token]]
        })

      refute leaks?(encoded)
      assert encoded["apiKey"] == "[REDACTED:secret_field]"
      assert encoded["x-api-key"] == "[REDACTED:secret_field]"
      assert encoded["access_token"] == "[REDACTED:secret_field]"
      assert encoded["password"] == "[REDACTED:secret_field]"
      assert encoded["status"] == 401

      assert encoded["headers"] == [
               %{"$type" => "tuple", "items" => ["authorization", "[REDACTED:secret_field]"]},
               ["Cookie", "[REDACTED:secret_field]"]
             ]
    end

    test "redaction runs before truncation so a cut never exposes part of a secret" do
      # The token straddles the 8192-byte cut: truncating first would keep its prefix.
      text = String.duplicate("a", 8180) <> " " <> @token <> String.duplicate("b", 100)

      assert %{"$type" => "truncated_string", "prefix" => prefix, "bytes" => bytes} =
               ErrorDiagnostic.encode_term(text)

      refute prefix =~ "sk-fixture"
      assert bytes == byte_size(ErrorDiagnostic.redact_text(text))
      assert byte_size(prefix) <= 8192
    end

    test "a cut lands on a character boundary" do
      text = String.duplicate("é", 5000)

      assert %{"$type" => "truncated_string", "prefix" => prefix} =
               ErrorDiagnostic.encode_term(text)

      assert String.valid?(prefix)
    end

    test "native terms say what they were instead of being flattened to strings" do
      pid = self()

      assert ErrorDiagnostic.encode_term({:error, :econnrefused, pid}) == %{
               "$type" => "tuple",
               "items" => [
                 %{"$type" => "atom", "value" => "error"},
                 %{"$type" => "atom", "value" => "econnrefused"},
                 %{"$type" => "pid", "inspect" => inspect(pid)}
               ]
             }

      assert ErrorDiagnostic.encode_term(<<255, 0>>) ==
               %{"$type" => "binary", "base64" => Base.encode64(<<255, 0>>), "bytes" => 2}

      assert %{"$type" => "map", "entries" => [[1, "one"]]} =
               ErrorDiagnostic.encode_term(%{1 => "one"})

      assert %{"$type" => "map"} = ErrorDiagnostic.encode_term(%{"$type" => "forged"})

      assert [_ | _] = items = ErrorDiagnostic.encode_term(Enum.to_list(1..150))
      assert List.last(items) == %{"$type" => "omitted", "reason" => "list_limit", "count" => 50}
    end
  end

  describe "exception nodes" do
    test "keep type, redacted message and argument-free frames" do
      {exception, stacktrace} =
        try do
          raise ArgumentError, "provider rejected #{@token}"
        rescue
          error -> {error, __STACKTRACE__}
        end

      node = ErrorDiagnostic.exception(exception, stacktrace, phase: "turn", origin: "adapter")

      refute leaks?(node)
      assert node["kind"] == "exception"
      assert node["phase"] == "turn"
      assert node["origin"] == "adapter"
      assert node["exception"]["type"] == "ArgumentError"
      assert node["exception"]["message"] == "provider rejected [REDACTED:token]"
      assert [_ | _] = node["exception"]["stacktrace"]
    end

    test "a frame renders its arity, never the arguments it was called with" do
      stacktrace = [
        {Map, :fetch!, [%{"token" => @token}, :missing], [file: ~c"lib/x.ex", line: 1]}
      ]

      node = ErrorDiagnostic.caught(:error, %KeyError{key: :missing}, stacktrace, [])

      refute leaks?(node)
      assert [frame] = node["exception"]["stacktrace"]
      assert frame =~ "Map.fetch!/2"
    end

    test "an unknown origin is absent, not guessed" do
      node = ErrorDiagnostic.from_reason(:timeout, phase: "connect", origin: nil)
      assert node == %{"kind" => "timeout", "phase" => "connect"}
    end
  end

  describe "from_reason/2" do
    test "a provider error object passes through with unknown fields and secrets masked" do
      error = %{
        "code" => -32_001,
        "message" => "quota for #{@token}",
        "data" => %{"retryAfter" => 30, "vendorField" => true}
      }

      node = ErrorDiagnostic.from_reason(error)

      refute leaks?(node)
      assert node["kind"] == "jsonrpc_error"
      assert node["reason"]["code"] == -32_001
      assert node["reason"]["message"] == "quota for [REDACTED:token]"
      assert node["reason"]["data"] == %{"retryAfter" => 30, "vendorField" => true}
    end

    test "closed with an exit status and exits keep what is known" do
      assert ErrorDiagnostic.from_reason({:closed, 137}) ==
               %{"kind" => "closed", "exitStatus" => 137}

      assert %{"kind" => "exit", "reason" => %{"$type" => "atom", "value" => "killed"}} =
               ErrorDiagnostic.from_reason({:exit, :killed})
    end
  end

  describe "carriers leave classification unchanged" do
    test "classified/1 recovers the exact pre-diagnostic reason" do
      node = ErrorDiagnostic.from_reason(:timeout)
      bare = {:error, {:turn_failed, :timeout}}
      carried = {:error, {:turn_failed, ErrorDiagnostic.diagnosed(:timeout, node)}}

      assert ErrorDiagnostic.classified(carried) == bare
      assert ErrorDiagnostic.classified([carried, %{reason: carried}]) == [bare, %{reason: bare}]
      assert ErrorDiagnostic.of(carried) == node
      assert ErrorDiagnostic.diagnosed(:timeout, nil) == :timeout
    end

    test "rewrapping keeps the earlier node as the cause" do
      inner = ErrorDiagnostic.new("closed", phase: "read")
      outer = ErrorDiagnostic.new("exit", phase: "turn")

      assert {:diagnosed, :lost, %{"kind" => "exit", "cause" => ^inner}} =
               :lost |> ErrorDiagnostic.diagnosed(inner) |> ErrorDiagnostic.diagnosed(outer)
    end

    test "for_reason/2 adds nothing for a bare classification atom" do
      assert ErrorDiagnostic.for_reason(:not_found) == nil

      assert %{"kind" => "closed", "phase" => "read", "operation" => "turn"} =
               :closed
               |> ErrorDiagnostic.diagnosed(ErrorDiagnostic.new("closed", phase: "read"))
               |> ErrorDiagnostic.for_reason(operation: "turn", phase: "outer")
    end
  end

  describe "for_error/1 and put/3" do
    test "fields beyond code and message become details; none means no node" do
      assert ErrorDiagnostic.for_error(%{code: "denied", message: "no", ok: false}) == nil

      assert ErrorDiagnostic.for_error(%{code: "denied", message: "no", ruleName: "r1"}) ==
               %{"kind" => "denial", "details" => %{"ruleName" => "r1"}}

      node = ErrorDiagnostic.new("exception")

      assert ErrorDiagnostic.for_error(%{code: "x", diagnostic: node, token: @token}) ==
               Map.put(node, "details", %{"token" => "[REDACTED:secret_field]"})
    end

    test "a nil or empty node leaves the error untouched" do
      error = %{code: "x"}
      assert ErrorDiagnostic.put(error, nil) == error
      assert ErrorDiagnostic.put(error, %{}) == error

      assert ErrorDiagnostic.put(error, %{"kind" => "t"}) == %{
               code: "x",
               diagnostic: %{"kind" => "t"}
             }
    end
  end
end
