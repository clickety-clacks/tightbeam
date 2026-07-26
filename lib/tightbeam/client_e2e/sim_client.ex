defmodule Tightbeam.ClientE2E.SimClient do
  @moduledoc """
  The SIM CLIENT — a scripted Clawline client that speaks the gateway's real
  wire: `Tightbeam.Wire.Socket`'s frames over a real WebSocket and
  `Tightbeam.Wire.Router`'s routes over real HTTP.

  It is a client, not a fixture. Nothing here reaches into the gateway's
  processes or database; every observation is a frame that arrived on the
  socket or a JSON body that came back from a route. That constraint is what
  makes the journeys' CLIENT column meaningful — the frame log this module
  accumulates is the driver's analog of the app's accessibility tree, and an
  assertion over it is an assertion about what a client could show.

  ## The frame log and watermarks

  Every frame the client receives is appended to `frames`, in arrival order,
  and never consumed: oracles re-read history, and a turn's proof usually
  spans several frames (echo → typing on → progress → reply → typing off).
  `mark/1` returns a watermark into that log and `await/4` scans forward from
  one, so an assertion about THIS turn cannot be satisfied by a frame from the
  previous one — the failure mode that makes a green journey worthless.

  ## Auth shape

  Pairing and authed traffic are two different socket lifecycles (the gateway
  closes the pairing socket after `pair_result`), so `pair/3` opens and closes
  its own connection and `connect/4` opens the long-lived one. The device
  token doubles as the HTTP bearer, exactly as the app uses it.
  """

  alias Tightbeam.ClientE2E.WS

  @type t :: %__MODULE__{
          host: String.t(),
          port: :inet.port_number(),
          ws: WS.t() | nil,
          token: String.t() | nil,
          user_id: String.t() | nil,
          device_id: String.t() | nil,
          is_admin: boolean(),
          frames: [map()],
          closed: boolean(),
          counter: non_neg_integer()
        }

  defstruct [
    :host,
    :port,
    :ws,
    :token,
    :user_id,
    :device_id,
    is_admin: false,
    frames: [],
    closed: false,
    counter: 0
  ]

  @http_timeout_ms 30_000

  @doc """
  Pairs a device: opens a pairing socket, sends `pair_request`, reads
  `pair_result`, closes.

  Returns the device token and user id on success, or the gateway's own
  refusal reason (`pair_pending` | `pair_denied` | a wire error code).
  """
  @spec pair(String.t(), :inet.port_number(), keyword()) ::
          {:ok, %{token: String.t(), user_id: String.t()}} | {:error, term()}
  def pair(host, port, opts) do
    device_id = Keyword.fetch!(opts, :device_id)

    request = %{
      "type" => "pair_request",
      "protocolVersion" => 1,
      "deviceId" => device_id,
      "claimedName" => Keyword.get(opts, :claimed_name, "sim-client"),
      "deviceInfo" => %{"platform" => "sim", "model" => "client-e2e"}
    }

    with {:ok, ws} <- WS.connect(host, port, "/ws"),
         :ok <- WS.send_text(ws, JSON.encode!(request)),
         {:ok, {:text, body}, ws} <- WS.recv(ws, 10_000) do
      WS.close(ws)

      case JSON.decode(body) do
        {:ok, %{"type" => "pair_result", "success" => true} = frame} ->
          {:ok, %{token: frame["token"], user_id: frame["userId"]}}

        {:ok, %{"type" => "pair_result", "reason" => reason}} ->
          {:error, reason}

        {:ok, %{"type" => "error", "code" => code}} ->
          {:error, code}

        other ->
          {:error, {:unexpected_pair_frame, other}}
      end
    else
      {:ok, :closed, _ws} -> {:error, :closed_before_pair_result}
      {:error, reason, _ws} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Authenticates a socket and drains the connect sequence.

  Returns once `sync_complete` has arrived — the frame the app waits for to
  leave its connecting state — with `auth_result`, the stream snapshot, and
  any replayed messages already in the frame log.
  """
  @spec connect(String.t(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def connect(host, port, token, opts \\ []) do
    device_id = Keyword.fetch!(opts, :device_id)

    auth =
      %{"type" => "auth", "token" => token, "deviceId" => device_id}
      |> maybe_put("replayCursorsBySessionKey", Keyword.get(opts, :replay_cursors))

    with {:ok, ws} <- WS.connect(host, port, "/ws"),
         :ok <- WS.send_text(ws, JSON.encode!(auth)) do
      client = %__MODULE__{host: host, port: port, ws: ws, token: token, device_id: device_id}

      case await(client, 0, &(&1["type"] == "sync_complete"), Keyword.get(opts, :timeout, 15_000)) do
        {:ok, _frame, client} ->
          case find(client, 0, &(&1["type"] == "auth_result")) do
            %{"success" => true} = result ->
              {:ok, %{client | user_id: result["userId"], is_admin: result["isAdmin"] == true}}

            %{"reason" => reason} ->
              {:error, reason}

            nil ->
              {:error, :no_auth_result}
          end

        {:error, reason, client} ->
          case find(client, 0, &(&1["type"] == "auth_result" and &1["success"] == false)) do
            %{"reason" => refusal} -> {:error, refusal}
            _ -> {:error, reason}
          end
      end
    end
  end

  @doc "Closes the socket. Safe to call on an already-closed client."
  @spec disconnect(t()) :: t()
  def disconnect(%__MODULE__{ws: nil} = client), do: client

  def disconnect(%__MODULE__{ws: ws} = client) do
    WS.close(ws)
    %{client | ws: nil, closed: true}
  end

  @doc """
  Posts a message and returns the generated clientMessageId.

  The id shape is the wire contract (`c_` prefix or `invalid_message`), and it
  is the correlation key for every turn oracle: the echo carries it as
  `clientMessageId`, `prompt_turn_state` as `messageId`/`correlationId`, and
  the assistant reply as `replyToClientMessageId`.
  """
  @spec post(t(), String.t(), String.t()) :: {:ok, t(), String.t()} | {:error, term()}
  def post(client, session_key, content) do
    client = %{client | counter: client.counter + 1}
    id = "c_sim_#{System.unique_integer([:positive, :monotonic])}_#{client.counter}"

    frame = %{
      "type" => "message",
      "id" => id,
      "sessionKey" => session_key,
      "content" => content
    }

    case WS.send_text(client.ws, JSON.encode!(frame)) do
      :ok -> {:ok, client, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A watermark into the frame log; pass it to `await/4` to scope a wait to what follows."
  @spec mark(t()) :: non_neg_integer()
  def mark(%__MODULE__{frames: frames}), do: length(frames)

  @doc "All frames received so far, in arrival order."
  @spec frames(t()) :: [map()]
  def frames(%__MODULE__{frames: frames}), do: frames

  @doc "Frames received at or after `watermark`, in arrival order."
  @spec frames_since(t(), non_neg_integer()) :: [map()]
  def frames_since(%__MODULE__{frames: frames}, watermark), do: Enum.drop(frames, watermark)

  @doc "The first frame at or after `watermark` matching `predicate`, or nil. Reads nothing."
  @spec find(t(), non_neg_integer(), (map() -> boolean())) :: map() | nil
  def find(client, watermark, predicate) do
    client |> frames_since(watermark) |> Enum.find(predicate)
  end

  @doc """
  Waits for a frame at or after `watermark` matching `predicate`, reading from
  the socket as needed. Frames read along the way stay in the log.
  """
  @spec await(t(), non_neg_integer(), (map() -> boolean()), timeout()) ::
          {:ok, map(), t()} | {:error, :timeout | :closed | term(), t()}
  def await(client, watermark, predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_until(client, watermark, predicate, deadline)
  end

  @doc """
  Reads frames for `duration_ms` without waiting for anything in particular.

  This is the shape of a negative assertion: "the indicator clears and does
  NOT come back", "no assistant bubble arrives for the canceled turn". A
  negative proved by not-looking is not a proof, so the driver looks.
  """
  @spec settle(t(), non_neg_integer()) :: t()
  def settle(client, duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    drain(client, deadline)
  end

  # --- HTTP control plane -----------------------------------------------------

  @doc "GET a JSON route with the device bearer; returns {status, decoded_body}."
  @spec get(t(), String.t(), keyword()) :: {integer(), term()}
  def get(client, path, query \\ []) do
    request(client, :get, path <> query_string(query), nil)
  end

  @doc "POST a JSON body with the device bearer; returns {status, decoded_body}."
  @spec post_json(t(), String.t(), map()) :: {integer(), term()}
  def post_json(client, path, body), do: request(client, :post, path, body)

  @doc "PATCH a JSON body with the device bearer; returns {status, decoded_body}."
  @spec patch_json(t(), String.t(), map()) :: {integer(), term()}
  def patch_json(client, path, body), do: request(client, :patch, path, body)

  @doc "DELETE with a JSON body with the device bearer; returns {status, decoded_body}."
  @spec delete_json(t(), String.t(), map()) :: {integer(), term()}
  def delete_json(client, path, body), do: request(client, :delete, path, body)

  defp request(client, method, path, body) do
    _ = Application.ensure_all_started(:inets)
    url = ~c"http://#{client.host}:#{client.port}#{path}"
    headers = [{~c"authorization", ~c"Bearer #{client.token}"}]

    request =
      if is_nil(body),
        do: {url, headers},
        else: {url, headers, ~c"application/json", JSON.encode!(body)}

    case :httpc.request(method, request, [{:timeout, @http_timeout_ms}], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response}} ->
        {status, decode_body(response)}

      {:error, reason} ->
        {0, %{"error" => %{"code" => "transport", "message" => inspect(reason)}}}
    end
  end

  defp decode_body(""), do: nil

  defp decode_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp query_string([]), do: ""

  defp query_string(query) do
    "?" <>
      Enum.map_join(query, "&", fn {key, value} ->
        "#{key}=#{URI.encode_www_form(to_string(value))}"
      end)
  end

  # --- frame pump -------------------------------------------------------------

  defp await_until(client, watermark, predicate, deadline) do
    case find(client, watermark, predicate) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)

        cond do
          client.closed -> {:error, :closed, client}
          remaining <= 0 -> {:error, :timeout, client}
          true -> pump(client, watermark, predicate, deadline, remaining)
        end

      frame ->
        {:ok, frame, client}
    end
  end

  defp pump(client, watermark, predicate, deadline, remaining) do
    case WS.recv(client.ws, remaining) do
      {:ok, {:text, body}, ws} ->
        client = %{client | ws: ws} |> record(body)
        await_until(client, watermark, predicate, deadline)

      {:ok, :closed, ws} ->
        {:error, :closed, %{client | ws: ws, closed: true}}

      {:error, :timeout, ws} ->
        {:error, :timeout, %{client | ws: ws}}

      {:error, reason, ws} ->
        {:error, reason, %{client | ws: ws, closed: true}}
    end
  end

  defp drain(client, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if client.closed or remaining <= 0 do
      client
    else
      case WS.recv(client.ws, remaining) do
        {:ok, {:text, body}, ws} -> %{client | ws: ws} |> record(body) |> drain(deadline)
        {:ok, :closed, ws} -> %{client | ws: ws, closed: true}
        {:error, :timeout, ws} -> %{client | ws: ws}
        {:error, _reason, ws} -> %{client | ws: ws, closed: true}
      end
    end
  end

  defp record(client, body) do
    case JSON.decode(body) do
      {:ok, frame} when is_map(frame) -> %{client | frames: client.frames ++ [frame]}
      _ -> %{client | frames: client.frames ++ [%{"type" => "__undecodable__", "raw" => body}]}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
