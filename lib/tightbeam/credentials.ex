defmodule Tightbeam.Credentials do
  @moduledoc """
  Per-machine credential onboarding and lifecycle.

  This process is deliberately not a refresher. Codex owns and rotates the
  live home `auth.json` while its runtime is running; Claude uses one
  non-rotating setup-token through `CLAUDE_CODE_OAUTH_TOKEN`. Expiry is
  compared only at read seams—there is no timer or sweep.
  """

  use GenServer

  alias Tightbeam.Homes

  @type provider :: :openai | :anthropic
  @type status :: :onboarded | {:needs_onboarding, term()}

  @doc "Start one lifecycle owner for this machine."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Read lifecycle and canonical credential health without refreshing."
  @spec status(provider(), GenServer.server()) :: status()
  def status(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:status, provider})

  @doc "Run the provider flow through the serialized gate/stop/write/start/resume lifecycle."
  @spec onboard(provider(), GenServer.server()) :: :ok | {:error, term()}
  def onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:onboard, provider}, :infinity)

  @doc "Record terminal evidence, gate new sessions, and park running sessions."
  @spec mark_terminal(provider(), term(), GenServer.server()) :: :ok
  def mark_terminal(provider, evidence, server \\ __MODULE__),
    do: GenServer.call(server, {:mark_terminal, provider, evidence})

  @doc "Classify only pinned terminal evidence. Unknown is always non-terminal."
  @spec terminal_evidence?(provider(), term()) :: boolean()
  def terminal_evidence?(:openai, %{
        "method" => "account/updated",
        "params" => %{"authMode" => nil, "planType" => nil}
      }),
      do: true

  def terminal_evidence?(:anthropic, %{
        "persisted_rejection" => true,
        "status" => 401,
        "error" => "invalid-token"
      }),
      do: true

  def terminal_evidence?(_provider, _evidence), do: false

  @impl true
  def init(opts) do
    {:ok,
     %{
       base_dir: Keyword.fetch!(opts, :base_dir),
       machine: Keyword.fetch!(opts, :machine),
       now: Keyword.get(opts, :now, fn -> System.system_time(:second) end),
       onboarders:
         Keyword.get(opts, :onboarders, %{
           openai: &onboard_openai/1,
           anthropic: &onboard_anthropic/1
         }),
       gate: Keyword.get(opts, :gate, fn _provider -> :ok end),
       stop: Keyword.get(opts, :stop, fn _provider -> :ok end),
       park: Keyword.get(opts, :park, fn _provider -> :ok end),
       start: Keyword.get(opts, :start, fn _provider -> :ok end),
       resume: Keyword.get(opts, :resume, fn _provider -> :ok end)
     }}
  end

  @impl true
  def handle_call({:status, provider}, _from, state) do
    {:reply, credential_status(state, provider), state}
  end

  def handle_call({:mark_terminal, provider, evidence}, _from, state) do
    if terminal_evidence?(provider, evidence) do
      state.gate.(provider)
      state.park.(provider)

      metadata =
        state
        |> read_metadata(provider)
        |> Map.merge(%{
          "provider" => Atom.to_string(provider),
          "onboarded" => true,
          "terminal" => true,
          "last_health" => "revoked"
        })

      write_metadata!(state, provider, metadata)
    end

    {:reply, :ok, state}
  end

  def handle_call({:onboard, provider}, _from, state) do
    result =
      with :ok <- state.gate.(provider),
           :ok <- state.stop.(provider),
           {:ok, credential} <- Map.fetch!(state.onboarders, provider).(state),
           :ok <- write_credential!(state, provider, credential),
           :ok <- mark_onboarded!(state, provider, credential),
           :ok <- state.start.(provider),
           :ok <- state.resume.(provider) do
        :ok
      else
        {:error, {:unsupported, :no_subscription}} = error ->
          write_metadata!(state, provider, %{
            "provider" => Atom.to_string(provider),
            "onboarded" => false,
            "terminal" => false,
            "subscription_status" => "unsupported",
            "last_health" => "no_subscription",
            "expires_at" => nil
          })

          error

        {:error, _reason} = error ->
          error
      end

    {:reply, result, state}
  end

  defp credential_status(state, provider) do
    metadata = read_metadata(state, provider)

    cond do
      metadata["subscription_status"] == "unsupported" ->
        {:needs_onboarding, {:unsupported, :no_subscription}}

      metadata["terminal"] == true ->
        {:needs_onboarding, :revoked}

      expired?(metadata["expires_at"], state.now.()) ->
        {:needs_onboarding, :expired}

      metadata["onboarded"] == true and credential_present?(state, provider) ->
        :onboarded

      true ->
        {:needs_onboarding, :missing}
    end
  end

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now) when is_integer(expires_at), do: expires_at <= now
  defp expired?(_unknown, _now), do: false

  defp credential_present?(state, :openai) do
    state.base_dir
    |> Homes.home_path(state.machine, :codex)
    |> Path.join("auth.json")
    |> File.exists?()
  end

  defp credential_present?(state, :anthropic) do
    File.regular?(credential_store_path(state, :anthropic))
  end

  defp write_credential!(state, :openai, credential) do
    path = credential_store_path(state, :openai)
    atomic_write!(path, credential.bytes)
    relink_home_entry!(state, :codex, path, "auth.json")
    :ok
  end

  defp write_credential!(state, :anthropic, credential) do
    path = credential_store_path(state, :anthropic)
    atomic_write!(path, String.trim(credential.bytes) <> "\n")
    relink_home_entry!(state, :claude, path, "oauth-token")
    :ok
  end

  defp relink_home_entry!(state, harness, source, filename) do
    home = Homes.home_path(state.base_dir, state.machine, harness)
    File.mkdir_p!(home)
    target = Path.join(home, filename)
    File.rm(target)
    File.ln_s!(source, target)
  end

  defp mark_onboarded!(state, provider, credential) do
    write_metadata!(state, provider, %{
      "provider" => Atom.to_string(provider),
      "onboarded" => true,
      "terminal" => false,
      "last_health" => "onboarded",
      "subscription_status" => Map.get(credential, :subscription_status),
      "expires_at" => Map.get(credential, :expires_at)
    })

    :ok
  end

  defp metadata_path(state, provider) do
    Path.join([
      state.base_dir,
      "auth",
      harness_name(provider),
      ".tightbeam",
      "credential.json"
    ])
  end

  defp read_metadata(state, provider) do
    case File.read(metadata_path(state, provider)) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, metadata} -> metadata
          {:error, _reason} -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp write_metadata!(state, provider, metadata) do
    atomic_write!(metadata_path(state, provider), JSON.encode!(metadata))
  end

  defp credential_store_path(state, :openai),
    do: Path.join([state.base_dir, "auth", "codex", "auth.json"])

  defp credential_store_path(state, :anthropic),
    do: Path.join([state.base_dir, "auth", "claude", "oauth-token"])

  defp harness_name(:openai), do: "codex"
  defp harness_name(:anthropic), do: "claude"

  defp atomic_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, bytes)
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
    File.chmod!(path, 0o600)
  end

  defp onboard_openai(_state) do
    temporary =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-codex-onboard-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temporary)

    try do
      case System.cmd("codex", ["login", "--device-auth"],
             env: [{"CODEX_HOME", temporary}],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:ok, %{bytes: File.read!(Path.join(temporary, "auth.json")), expires_at: nil}}

        {output, _status} ->
          {:error, {:device_auth_failed, String.trim(output)}}
      end
    after
      File.rm_rf!(temporary)
    end
  end

  defp onboard_anthropic(_state) do
    transcript =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-claude-setup-token-#{System.unique_integer([:positive])}.log"
      )

    try do
      case System.cmd("script", ["-q", transcript, "claude", "setup-token"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          bytes = File.read!(transcript) <> output

          case capture_setup_token(bytes) do
            {:ok, token} ->
              {:ok,
               %{
                 bytes: token,
                 expires_at: System.system_time(:second) + 365 * 24 * 60 * 60,
                 subscription_status: "supported"
               }}

            :error ->
              {:error, :setup_token_not_captured}
          end

        {output, _status} ->
          if String.contains?(String.downcase(output), "subscription") do
            {:error, {:unsupported, :no_subscription}}
          else
            {:error, {:setup_token_failed, String.trim(output)}}
          end
      end
    after
      File.rm(transcript)
    end
  end

  defp capture_setup_token(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reverse()
    |> Enum.find(&String.starts_with?(&1, "sk-ant-oat"))
    |> case do
      nil -> :error
      token -> {:ok, token}
    end
  end
end
