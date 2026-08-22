defmodule Tightbeam.IdentityApply.FailureNormalizer do
  @moduledoc """
  Killable boundary for canonical ECMAScript failure normalization.

  The JavaScript worker owns the value. The gateway receives only the bounded,
  redacted canonical envelope or one fixed supervisor sentinel.
  """

  @deadline_ms 30_000
  @node_budget 65_536
  @byte_limit 65_536
  @failure ~s({"kind":"unsupported","type":"inspection-failure"})
  @timeout ~s({"kind":"unsupported","type":"inspection-timeout"})

  @spec deadline_ms() :: 30_000
  def deadline_ms, do: @deadline_ms

  @spec node_budget() :: 65_536
  def node_budget, do: @node_budget

  @spec inspection_failure() :: String.t()
  def inspection_failure, do: @failure

  @spec inspection_timeout() :: String.t()
  def inspection_timeout, do: @timeout

  @doc """
  Execute a fixture or adapter-owned failure capture in an isolated V8 process.

  `source` is a JavaScript function body. Its returned value is normalized. If
  it throws, the thrown value is normalized without crossing into the gateway.
  This API exists at the process boundary so callers never reflect on the value.
  """
  @spec normalize_script(String.t(), keyword()) :: String.t()
  def normalize_script(source, opts \\ []) when is_binary(source) do
    timeout = Keyword.get(opts, :timeout, @deadline_ms)
    executable = Keyword.get(opts, :executable, System.find_executable("node"))

    with path when is_binary(path) <- executable,
         {:ok, port} <- open_worker(path),
         true <- Port.command(port, JSON.encode!(%{source: source}) <> "\n") do
      receive_worker(port, timeout, "")
    else
      _ -> @failure
    end
  end

  @doc "Accept only a complete bounded JSON envelope from the worker."
  @spec canonical_envelope(String.t()) :: {:ok, String.t()} | :error
  def canonical_envelope(encoded) when is_binary(encoded) and byte_size(encoded) <= @byte_limit do
    case JSON.decode(encoded) do
      {:ok, _value} -> {:ok, encoded}
      _ -> :error
    end
  end

  def canonical_envelope(_encoded), do: :error

  defp open_worker(executable) do
    runner = Application.app_dir(:tightbeam, "priv/identity_apply/failure_normalizer_runner.js")
    normalizer = Application.app_dir(:tightbeam, "priv/identity_apply/failure_normalizer.js")

    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :use_stdio,
       :hide,
       args: [runner, normalizer]
     ])}
  rescue
    _ -> :error
  end

  defp receive_worker(port, timeout, output) do
    receive do
      {^port, {:data, data}} ->
        receive_worker(port, timeout, output <> data)

      {^port, {:exit_status, 0}} ->
        encoded = String.trim_trailing(output, "\n")

        case canonical_envelope(encoded) do
          {:ok, canonical} -> canonical
          :error -> @failure
        end

      {^port, {:exit_status, _status}} ->
        @failure
    after
      timeout ->
        Port.close(port)
        @timeout
    end
  end
end
