defmodule Tightbeam.CursorSigning do
  @moduledoc false

  import Bitwise

  @domain "tightbeam/rest-read-plane-d1/cursor/v1\0"
  @filename "rest-cursor-signing.v1"

  @enforce_keys [:record_path, :state]
  defstruct [:record_path, :state]

  @type state :: :healthy | :unprovisioned | :quarantined
  @type t :: %__MODULE__{record_path: String.t(), state: state()}

  @doc "Load the sole D1 cursor-signing material without provisioning it."
  @spec load(String.t()) :: {:ok, t()}
  def load(base_dir) when is_binary(base_dir) do
    base_dir
    |> Path.join(["secrets", @filename])
    |> load_path()
  end

  @doc false
  @spec load_path(String.t()) :: {:ok, t()}
  def load_path(path) when is_binary(path) do
    state =
      case read_material(path) do
        {:ok, _material} -> :healthy
        {:error, :enoent} -> :unprovisioned
        {:error, _reason} -> :quarantined
      end

    {:ok, %__MODULE__{record_path: path, state: state}}
  end

  @doc "Load one provider at startup without provisioning or rotating material."
  @spec load!(String.t()) :: t()
  def load!(base_dir) do
    {:ok, provider} = load(base_dir)
    provider
  end

  @doc "Validate an injected provider without changing its lifecycle state."
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{state: state}) when state in [:healthy, :unprovisioned, :quarantined],
    do: :ok

  def validate(_provider), do: {:error, :cursor_signing_invalid}

  @spec validate!(term()) :: t()
  def validate!(%__MODULE__{} = provider) do
    case validate(provider) do
      :ok -> provider
      {:error, reason} -> raise ArgumentError, "invalid cursor signing provider: #{reason}"
    end
  end

  def validate!(_provider), do: raise(ArgumentError, "invalid cursor signing provider")

  @doc "Admit D1 cursor work only while the injected provider is healthy."
  @spec admit_request(t()) :: :ok | {:error, atom()}
  def admit_request(%__MODULE__{state: :healthy}), do: :ok

  def admit_request(%__MODULE__{state: :unprovisioned}),
    do: {:error, :cursor_signing_unprovisioned}

  def admit_request(%__MODULE__{state: :quarantined}), do: {:error, :cursor_signing_quarantined}
  def admit_request(_provider), do: {:error, :cursor_signing_invalid}

  @doc "Sign canonical cursor bytes with the fixed D1 domain separator."
  @spec sign(t(), binary()) :: {:ok, binary()} | {:error, atom()}
  def sign(%__MODULE__{} = provider, payload) when is_binary(payload) do
    with :ok <- admit_request(provider),
         {:ok, material} <- current_material(provider.record_path) do
      {:ok, :crypto.mac(:hmac, :sha256, material, @domain <> payload)}
    end
  end

  def sign(_provider, _payload), do: {:error, :cursor_signing_invalid}

  @doc "Verify a D1 cursor signature without exposing key material."
  @spec verify(t(), binary(), binary()) :: {:ok, boolean()} | {:error, atom()}
  def verify(%__MODULE__{} = provider, payload, signature)
      when is_binary(payload) and is_binary(signature) do
    with {:ok, expected} <- sign(provider, payload) do
      {:ok, secure_equal?(expected, signature)}
    end
  end

  def verify(_provider, _payload, _signature), do: {:error, :cursor_signing_invalid}

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :crypto.exor(right)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &bor/2)
    |> Kernel.==(0)
  end

  defp secure_equal?(_left, _right), do: false

  defp read_material(path) do
    with {:ok, %File.Stat{type: :regular, size: 32, mode: mode}} <- File.lstat(path),
         true <- band(mode, 0o777) == 0o600,
         {:ok, material} <- File.read(path),
         true <- byte_size(material) == 32 do
      {:ok, material}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_material}
      _ -> {:error, :invalid_material}
    end
  end

  defp current_material(path) do
    case read_material(path) do
      {:ok, material} -> {:ok, material}
      {:error, _reason} -> {:error, :cursor_signing_quarantined}
    end
  end
end
