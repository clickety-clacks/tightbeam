defmodule Tightbeam.Wire.ResponseObservationAdapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter
  alias Tightbeam.Wire.RequestObservation

  def wrap(%{adapter: {__MODULE__, _}} = conn), do: conn
  def wrap(%{adapter: adapter} = conn), do: %{conn | adapter: {__MODULE__, adapter}}
  def unwrap(%{adapter: {__MODULE__, adapter}} = conn), do: %{conn | adapter: adapter}
  def unwrap(conn), do: conn

  @impl true
  def send_resp({module, state}, status, headers, body) do
    RequestObservation.sending(status)
    {:ok, sent, next} = module.send_resp(state, status, headers, body)
    RequestObservation.sent(status)
    {:ok, sent, {module, next}}
  end

  @impl true
  def send_file({module, state}, status, headers, path, offset, length) do
    RequestObservation.sending(status)
    {:ok, sent, next} = module.send_file(state, status, headers, path, offset, length)
    RequestObservation.sent(status)
    {:ok, sent, {module, next}}
  end

  @impl true
  def send_chunked({module, state}, status, headers) do
    RequestObservation.sending(status)
    wrap_result(module.send_chunked(state, status, headers), module)
  end

  @impl true
  def chunk({module, state}, body), do: wrap_result(module.chunk(state, body), module)
  @impl true
  def read_req_body({module, state}, opts),
    do: wrap_result(module.read_req_body(state, opts), module)

  @impl true
  def inform({module, state}, status, headers),
    do: wrap_result(module.inform(state, status, headers), module)

  @impl true
  def upgrade({module, state}, protocol, opts),
    do: wrap_result(module.upgrade(state, protocol, opts), module)

  @impl true
  def push({module, state}, path, headers) do
    if function_exported?(module, :push, 3),
      do: module.push(state, path, headers),
      else: {:error, :not_supported}
  end

  @impl true
  def get_peer_data({module, state}), do: module.get_peer_data(state)
  @impl true
  def get_http_protocol({module, state}), do: module.get_http_protocol(state)
  @impl true
  def get_sock_data(adapter), do: Plug.Conn.get_sock_data(%Plug.Conn{adapter: adapter})
  @impl true
  def get_ssl_data(adapter), do: Plug.Conn.get_ssl_data(%Plug.Conn{adapter: adapter})

  defp wrap_result({kind, body, state}, module) when kind in [:ok, :more],
    do: {kind, body, {module, state}}

  defp wrap_result({:ok, state}, module), do: {:ok, {module, state}}
  defp wrap_result(other, _module), do: other
end
