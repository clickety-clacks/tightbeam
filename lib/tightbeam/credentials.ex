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

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]

  @type provider :: :openai | :anthropic
  @type status :: :onboarded | {:needs_onboarding, term()}

  @doc "Start one lifecycle owner for this machine."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Resolve the lifecycle owner registered for a machine."
  @spec server(String.t()) :: GenServer.server()
  def server(machine) do
    local_machine =
      Application.get_env(:tightbeam, :local_host_name) ||
        (
          {:ok, name} = :inet.gethostname()
          List.to_string(name)
        )

    case machine == local_machine do
      true -> __MODULE__
      false -> {:global, {__MODULE__, machine}}
    end
  end

  @doc "Read lifecycle and canonical credential health without refreshing."
  @spec status(provider(), GenServer.server()) :: status()
  def status(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:status, provider})

  @doc "Run the provider flow through the serialized gate/stop/write/start/resume lifecycle."
  @spec onboard(provider(), GenServer.server()) :: :ok | {:error, term()}
  def onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:onboard, provider}, :infinity)

  @doc "Begin an interactive CLI onboarding lease after gate + runtime stop."
  @spec begin_onboard(provider(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def begin_onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:begin_onboard, provider})

  @doc "Install the credential produced in the active onboarding lease."
  @spec finish_onboard(provider(), GenServer.server()) :: :ok | {:error, term()}
  def finish_onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:finish_onboard, provider}, :infinity)

  @doc "Cancel the active onboarding lease without restarting the old credential."
  @spec cancel_onboard(provider(), GenServer.server()) :: :ok
  def cancel_onboard(provider, server \\ __MODULE__),
    do: cancel_onboard(provider, nil, server)

  @doc "Cancel an onboarding lease and record a provider-classified failure."
  @spec cancel_onboard(provider(), term(), GenServer.server()) :: :ok
  def cancel_onboard(provider, reason, server),
    do: GenServer.call(server, {:cancel_onboard, provider, reason})

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
       ssh: Keyword.get(opts, :ssh),
       sh: Keyword.get(opts, :sh, &system_cmd/1),
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
       resume: Keyword.get(opts, :resume, fn _provider -> :ok end),
       capture_sessions: Keyword.get(opts, :capture_sessions, fn _provider -> [] end),
       publish_sessions:
         Keyword.get(opts, :publish_sessions, fn _payload, _transition -> :ok end),
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:status, provider}, _from, state) do
    {:reply, credential_status(state, provider), state}
  end

  def handle_call({:mark_terminal, provider, evidence}, _from, state) do
    if terminal_evidence?(provider, evidence) do
      metadata = read_metadata(state, provider)

      if metadata["terminal"] != true do
        state.gate.(provider)
        captured = capture_sessions(state, provider)
        park_result = state.park.(provider)

        write_metadata!(
          state,
          provider,
          Map.merge(metadata, %{
            "provider" => Atom.to_string(provider),
            "onboarded" => true,
            "terminal" => true,
            "last_health" => "revoked"
          })
        )

        if park_result == :ok do
          publish_sessions(state, captured, :terminal)
        end
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:onboard, provider}, _from, state) do
    perform_onboard(provider, state)
  end

  def handle_call({:begin_onboard, provider}, _from, state) do
    case Map.fetch(state.pending, provider) do
      {:ok, _path} ->
        {:reply, {:error, :onboarding_in_progress}, state}

      :error ->
        with :ok <- state.gate.(provider),
             :ok <- state.stop.(provider) do
          path = onboarding_staging_path(state, provider)
          :ok = prepare_staging!(state, path)
          {:reply, {:ok, path}, put_in(state.pending[provider], path)}
        else
          {:error, _reason} = error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:finish_onboard, provider}, _from, state) do
    case Map.fetch(state.pending, provider) do
      {:ok, path} ->
        result =
          with {:ok, credential} <- install_staged!(state, provider, path),
               :ok <- mark_onboarded!(state, provider, credential),
               :ok <- state.start.(provider),
               captured <- capture_sessions(state, provider),
               :ok <- state.resume.(provider) do
            publish_sessions(state, captured, :onboarded)
            :ok
          end

        cleanup_staging!(state, path)
        {:reply, result, update_in(state.pending, &Map.delete(&1, provider))}

      :error ->
        {:reply, {:error, :onboarding_not_started}, state}
    end
  end

  def handle_call({:cancel_onboard, provider, reason}, _from, state) do
    case Map.pop(state.pending, provider) do
      {nil, pending} ->
        {:reply, :ok, %{state | pending: pending}}

      {path, pending} ->
        cleanup_staging!(state, path)
        record_onboarding_failure!(state, provider, reason)
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  defp perform_onboard(_provider, %{ssh: destination} = state) when is_binary(destination) do
    {:reply, {:error, :interactive_onboarding_required_on_machine}, state}
  end

  defp perform_onboard(provider, state) do
    result =
      with :ok <- state.gate.(provider),
           :ok <- state.stop.(provider),
           {:ok, credential} <- Map.fetch!(state.onboarders, provider).(state),
           :ok <- write_credential!(state, provider, credential),
           :ok <- mark_onboarded!(state, provider, credential),
           :ok <- state.start.(provider),
           captured <- capture_sessions(state, provider),
           :ok <- state.resume.(provider) do
        publish_sessions(state, captured, :onboarded)
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

  defp capture_sessions(state, provider) do
    try do
      state.capture_sessions.(provider)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp publish_sessions(state, captured, transition) do
    try do
      state.publish_sessions.(captured, transition)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp record_onboarding_failure!(state, provider, :unsupported_no_subscription) do
    write_metadata!(state, provider, %{
      "provider" => Atom.to_string(provider),
      "onboarded" => false,
      "terminal" => false,
      "subscription_status" => "unsupported",
      "last_health" => "no_subscription",
      "expires_at" => nil
    })
  end

  defp record_onboarding_failure!(_state, _provider, _reason), do: :ok

  defp credential_status(state, provider) do
    metadata = read_metadata(state, provider)

    cond do
      Map.has_key?(state.pending, provider) ->
        {:needs_onboarding, :in_progress}

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

  defp credential_present?(%{ssh: nil} = state, :openai) do
    state.base_dir
    |> Homes.home_path(state.machine, :codex)
    |> Path.join("auth.json")
    |> File.exists?()
  end

  defp credential_present?(%{ssh: nil} = state, :anthropic) do
    File.regular?(credential_store_path(state, :anthropic))
  end

  defp credential_present?(state, provider) do
    remote_success?(state, ["test", "-e", canonical_path(state, provider)])
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

  defp read_metadata(%{ssh: nil} = state, provider) do
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

  defp read_metadata(state, provider) do
    case remote_command(state, ["cat", metadata_path(state, provider)]) do
      {bytes, 0} ->
        case JSON.decode(bytes) do
          {:ok, metadata} -> metadata
          {:error, _reason} -> %{}
        end

      {_bytes, _status} ->
        %{}
    end
  end

  defp write_metadata!(%{ssh: nil} = state, provider, metadata) do
    atomic_write!(metadata_path(state, provider), JSON.encode!(metadata))
  end

  defp write_metadata!(state, provider, metadata) do
    path = metadata_path(state, provider)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    encoded = JSON.encode!(metadata)

    script =
      "mkdir -p #{shell_quote(Path.dirname(path))}; " <>
        "printf %s #{shell_quote(encoded)} > #{shell_quote(temporary)} && " <>
        "chmod 600 #{shell_quote(temporary)} && " <>
        "mv #{shell_quote(temporary)} #{shell_quote(path)} && " <>
        "chmod 600 #{shell_quote(path)}"

    remote_ok!(state, ["sh", "-c", shell_quote(script)])
  end

  defp credential_store_path(state, :openai),
    do: Path.join([state.base_dir, "auth", "codex", "auth.json"])

  defp credential_store_path(state, :anthropic),
    do: Path.join([state.base_dir, "auth", "claude", "oauth-token"])

  defp canonical_path(state, :openai),
    do: Path.join(Homes.home_path(state.base_dir, state.machine, :codex), "auth.json")

  defp canonical_path(state, :anthropic), do: credential_store_path(state, :anthropic)

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

  defp staged_credential(:openai, path) do
    case File.read(Path.join(path, "auth.json")) do
      {:ok, bytes} -> {:ok, %{bytes: bytes, expires_at: nil}}
      {:error, reason} -> {:error, {:device_auth_failed, reason}}
    end
  end

  defp staged_credential(:anthropic, path) do
    case File.read(Path.join(path, "oauth-token")) do
      {:ok, bytes} ->
        {:ok,
         %{
           bytes: bytes,
           expires_at: System.system_time(:second) + 365 * 24 * 60 * 60,
           subscription_status: "supported"
         }}

      {:error, reason} ->
        {:error, {:setup_token_failed, reason}}
    end
  end

  defp install_staged!(%{ssh: nil} = state, provider, path) do
    with {:ok, credential} <- staged_credential(provider, path),
         :ok <- write_credential!(state, provider, credential) do
      {:ok, credential}
    end
  end

  defp install_staged!(state, provider, path) do
    source = staged_path(provider, path)
    store = credential_store_path(state, provider)
    home_entry = canonical_path(state, provider)

    script =
      "test -f #{shell_quote(source)} && " <>
        "mkdir -p #{shell_quote(Path.dirname(store))} #{shell_quote(Path.dirname(home_entry))} && " <>
        "chmod 600 #{shell_quote(source)} && " <>
        "mv #{shell_quote(source)} #{shell_quote(store)} && " <>
        "chmod 600 #{shell_quote(store)} && " <>
        "rm -f #{shell_quote(home_entry)} && " <>
        "ln -s #{shell_quote(store)} #{shell_quote(home_entry)}"

    case remote_command(state, ["sh", "-c", shell_quote(script)]) do
      {_output, 0} -> {:ok, installed_metadata(provider)}
      {output, status} -> {:error, {:credential_install_failed, status, String.trim(output)}}
    end
  end

  defp installed_metadata(:openai), do: %{expires_at: nil}

  defp installed_metadata(:anthropic) do
    %{
      expires_at: System.system_time(:second) + 365 * 24 * 60 * 60,
      subscription_status: "supported"
    }
  end

  defp staged_path(:openai, path), do: Path.join(path, "auth.json")
  defp staged_path(:anthropic, path), do: Path.join(path, "oauth-token")

  defp onboarding_staging_path(%{ssh: nil}, provider) do
    Path.join(
      System.tmp_dir!(),
      "tightbeam-#{provider}-onboard-#{System.unique_integer([:positive])}"
    )
  end

  defp onboarding_staging_path(state, provider) do
    Path.join([
      state.base_dir,
      "staging",
      "credential-onboarding",
      "#{provider}-#{System.unique_integer([:positive])}"
    ])
  end

  defp prepare_staging!(%{ssh: nil}, path) do
    File.mkdir_p!(path)
    :ok
  end

  defp prepare_staging!(state, path) do
    remote_ok!(state, ["mkdir", "-p", path])
  end

  defp cleanup_staging!(%{ssh: nil}, path) do
    File.rm_rf!(path)
    :ok
  end

  defp cleanup_staging!(state, path) do
    remote_ok!(state, ["rm", "-rf", "--", path])
  end

  defp remote_success?(state, command) do
    match?({_output, 0}, remote_command(state, command))
  end

  defp remote_ok!(state, command) do
    case remote_command(state, command) do
      {_output, 0} -> :ok
      {output, status} -> raise "remote credential command failed (#{status}): #{output}"
    end
  end

  defp remote_command(state, command) do
    state.sh.(["ssh" | @ssh_opts] ++ [state.ssh | command])
  end

  defp system_cmd([binary | args]) do
    System.cmd(binary, args, stderr_to_stdout: true)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
