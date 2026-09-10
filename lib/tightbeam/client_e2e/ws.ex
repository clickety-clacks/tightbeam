defmodule Tightbeam.ClientE2E.WS do
  @moduledoc """
  A minimal RFC 6455 client over `:gen_tcp` — the byte-level half of the
  sim client (`Tightbeam.ClientE2E.SimClient`).

  It exists because the driver must speak the gateway's REAL wire: the same
  HTTP upgrade, the same masked text frames, the same control-frame
  obligations a shipping client has. The repo carries no WebSocket client
  dependency and this needs no more than the spec's own frame rules, so the
  codec lives here rather than arriving as a package.

  Scope is deliberately the client half only:
  - client→server frames are always masked (RFC 6455 §5.3) and never
    fragmented; the gateway's `max_frame_size` is 2 MiB.
  - server→client frames are never masked. Continuation frames ARE
    reassembled: nothing in the contract forbids Bandit fragmenting a large
    replay frame, and a driver that dropped the tail would fail as a client
    bug.
  - server PINGs are answered with a PONG carrying the same payload. This is
    not optional politeness: the gateway arms a pong deadline (90s default)
    and closes a silent socket, which would surface as a spurious journey
    failure on any leg that idles longer than that (J3's long task, J5's
    parallel streams).

  Sockets are passive (`active: false`): the driver reads on its own schedule
  with real deadlines, so a journey that hangs fails at its own timeout rather
  than filling a mailbox.
  """

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), buffer: binary(), fragment: binary() | nil}
  @type frame :: {:text, binary()} | :closed
  @type event :: {:text, binary()} | {:closed, non_neg_integer() | nil}

  defstruct [:socket, buffer: <<>>, fragment: nil]

  @connect_timeout_ms 5_000

  @doc """
  Opens a TCP connection and completes the WebSocket upgrade handshake.

  `path` is either "/" or "/ws" — the router upgrades on both, and the path is
  not part of the WS contract (see `Tightbeam.Wire.Router`).
  """
  @spec connect(String.t(), :inet.port_number(), String.t()) :: {:ok, t()} | {:error, term()}
  def connect(host, port, path \\ "/ws") do
    opts = [:binary, active: false, packet: :raw, nodelay: true]

    case :gen_tcp.connect(to_charlist(host), port, opts, @connect_timeout_ms) do
      {:ok, socket} ->
        # Once the socket exists, EVERY failure path closes it. A driver that
        # leaks a socket per failed attempt exhausts descriptors across a
        # matrix run and starts failing for reasons that have nothing to do
        # with the gateway.
        with :ok <- :gen_tcp.send(socket, upgrade_request(host, port, path)),
             {:ok, rest} <- read_handshake(socket, <<>>) do
          {:ok, %__MODULE__{socket: socket, buffer: rest}}
        else
          {:error, reason} ->
            _ = :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sends one masked text frame."
  @spec send_text(t(), binary()) :: :ok | {:error, term()}
  def send_text(%__MODULE__{socket: socket}, payload) do
    :gen_tcp.send(socket, encode(0x1, payload))
  end

  @doc """
  Reads the next TEXT frame, or `:closed` when the peer closes.

  Control frames are handled here and never surface to the caller: PING is
  answered, PONG and CLOSE-acknowledgement bookkeeping is done inline. The
  timeout is a deadline for the *frame*, not for a single `recv`.
  """
  @spec recv(t(), timeout()) :: {:ok, frame(), t()} | {:error, :timeout | term(), t()}
  def recv(ws, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case recv_until(ws, deadline) do
      {:ok, {:closed, _code}, ws} -> {:ok, :closed, ws}
      other -> other
    end
  end

  @doc "Reads the next text or close event, retaining the peer's close code."
  @spec recv_event(t(), timeout()) :: {:ok, event(), t()} | {:error, :timeout | term(), t()}
  def recv_event(ws, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_until(ws, deadline)
  end

  @doc "Sends a CLOSE frame and shuts the socket down; always returns :ok."
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}) do
    _ = :gen_tcp.send(socket, encode(0x8, <<1000::16>>))
    _ = :gen_tcp.close(socket)
    :ok
  end

  # --- handshake --------------------------------------------------------------

  defp upgrade_request(host, port, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    [
      "GET #{path} HTTP/1.1\r\n",
      "Host: #{host}:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n\r\n"
    ]
  end

  defp read_handshake(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {position, 4} ->
        <<head::binary-size(position), _::binary-size(4), rest::binary>> = acc
        if head =~ ~r{^HTTP/1\.1 101}, do: {:ok, rest}, else: {:error, {:upgrade_refused, head}}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, @connect_timeout_ms) do
          {:ok, data} -> read_handshake(socket, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # --- frame loop -------------------------------------------------------------

  defp recv_until(ws, deadline) do
    case decode(ws.buffer) do
      {:ok, fin, opcode, payload, rest} ->
        ws |> Map.put(:buffer, rest) |> dispatch_frame(fin, opcode, payload, deadline)

      :incomplete ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :timeout, ws}
        else
          case :gen_tcp.recv(ws.socket, 0, remaining) do
            {:ok, data} -> recv_until(%{ws | buffer: ws.buffer <> data}, deadline)
            {:error, :closed} -> {:ok, :closed, ws}
            {:error, reason} -> {:error, reason, ws}
          end
        end
    end
  end

  # TEXT (0x1) starts a message; CONTINUATION (0x0) may only extend one.
  #
  # Strictness is the point, not pedantry: the wire contract is text JSON, and
  # a gateway that regressed to BINARY JSON would still be understood by a
  # permissive driver while breaking the shipping client. A driver that is
  # more tolerant than the client it stands in for cannot fail on the client's
  # behalf, so anything that is not a text-or-continuation data frame is an
  # error here.
  defp dispatch_frame(ws, fin, 0x1, payload, deadline) do
    if is_nil(ws.fragment) do
      finish_or_fragment(ws, fin, payload, deadline)
    else
      {:error, {:protocol_error, :text_inside_fragmented_message}, ws}
    end
  end

  defp dispatch_frame(ws, fin, 0x0, payload, deadline) do
    if is_nil(ws.fragment) do
      {:error, {:protocol_error, :continuation_without_message}, ws}
    else
      finish_or_fragment(ws, fin, ws.fragment <> payload, deadline)
    end
  end

  defp dispatch_frame(ws, _fin, 0x8, payload, _deadline),
    do: {:ok, {:closed, close_code(payload)}, ws}

  defp dispatch_frame(ws, _fin, 0x9, payload, deadline) do
    case :gen_tcp.send(ws.socket, encode(0xA, payload)) do
      :ok -> recv_until(ws, deadline)
      {:error, reason} -> {:error, reason, ws}
    end
  end

  defp dispatch_frame(ws, _fin, 0xA, _payload, deadline), do: recv_until(ws, deadline)

  defp dispatch_frame(ws, _fin, opcode, _payload, _deadline) do
    {:error, {:protocol_error, {:unexpected_opcode, opcode}}, ws}
  end

  defp finish_or_fragment(ws, true, assembled, _deadline),
    do: {:ok, {:text, assembled}, %{ws | fragment: nil}}

  defp finish_or_fragment(ws, false, assembled, deadline),
    do: recv_until(%{ws | fragment: assembled}, deadline)

  # --- codec ------------------------------------------------------------------

  defp encode(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    masked = apply_mask(payload, mask)

    length =
      case byte_size(payload) do
        n when n < 126 -> <<1::1, n::7>>
        n when n < 65_536 -> <<1::1, 126::7, n::16>>
        n -> <<1::1, 127::7, n::64>>
      end

    <<1::1, 0::3, opcode::4>> <> length <> mask <> masked
  end

  # The header's first two bytes are read together: splitting after the MASK
  # bit leaves the tail unaligned, and `rest::binary` never matches a
  # bit-offset remainder — a decoder that looks right and returns :incomplete
  # forever.
  defp decode(<<fin::1, _rsv::3, opcode::4, masked::1, length::7, rest::binary>>) do
    with {:ok, length, rest} <- decode_length(length, rest),
         {:ok, mask, rest} <- decode_mask(masked, rest),
         <<payload::binary-size(length), tail::binary>> <- rest do
      {:ok, fin == 1, opcode, apply_mask(payload, mask), tail}
    else
      _ -> :incomplete
    end
  end

  defp decode(_), do: :incomplete

  defp decode_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp decode_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp decode_length(length, rest) when length < 126, do: {:ok, length, rest}
  defp decode_length(_, _), do: :incomplete

  defp decode_mask(0, rest), do: {:ok, nil, rest}
  defp decode_mask(1, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp decode_mask(_, _), do: :incomplete

  defp close_code(<<code::16, _reason::binary>>), do: code
  defp close_code(_payload), do: nil

  defp apply_mask(payload, nil), do: payload

  defp apply_mask(payload, mask) do
    key = :binary.copy(mask, div(byte_size(payload), 4) + 1)
    :crypto.exor(payload, binary_part(key, 0, byte_size(payload)))
  end
end
