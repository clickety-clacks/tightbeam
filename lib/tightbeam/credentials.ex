defmodule Tightbeam.Credentials do
  @moduledoc """
  Per-machine credential onboarding and lifecycle.

  This process is deliberately not a refresher. Codex owns and rotates the
  live home `auth.json` while its runtime is running; Claude uses one
  non-rotating setup-token through `CLAUDE_CODE_OAUTH_TOKEN`. Expiry is
  compared only at read seams—there is no timer or sweep.

  A host holds ONE active credential per provider, of either KIND: an API key or
  a subscription token. The kind is recorded in that provider's
  `credential.json` and is the single authority on how the credential is used—
  which environment variable carries it, which header a probe sends, whether
  rotation is even a concept. Nothing anywhere infers the kind from the
  credential file's name or shape.

  Rotation posture is a property of the kind, not of the provider: API keys are
  static, so they have no refresh and no single-writer constraint. Subscription
  is claude-static (a year-long setup-token) and codex-self-rotating (in place,
  single writer).
  """

  use GenServer

  alias Tightbeam.{Harness, Homes, Rails}

  @ssh_opts ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
  @fixture_provider? Application.compile_env(:tightbeam, :fixture_harness, false)

  @type provider :: :openai | :anthropic | :fixture_provider
  @type kind :: :api_key | :subscription
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

  @doc """
  The KIND of credential this machine holds for a provider, or `:none`.

  `:none` is the ABSENCE of a credential, not a verdict on one: a revoked or
  expired credential still has a kind, and reporting it is what lets an operator
  tell "the API key stopped working" from "nothing is installed here".
  """
  @spec kind(provider(), GenServer.server()) :: kind() | :none
  def kind(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:kind, provider})

  @doc """
  The recorded kind under a LOCAL base dir, without the lifecycle owner.

  For callers that already hold a base dir on this machine and run outside the
  supervision tree—the e2e preflight, mix tasks. Remote hosts must go through
  `kind/2`, whose owner holds the ssh destination.
  """
  @spec kind_at(String.t(), provider()) :: kind() | :none
  def kind_at(base_dir, provider) do
    case File.read(metadata_path(base_dir, provider)) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"onboarded" => true} = metadata} -> decode_kind(metadata["kind"])
          _ -> :none
        end

      {:error, _reason} ->
        :none
    end
  end

  @doc "Run the provider flow through the serialized gate/stop/write/start/resume lifecycle."
  @spec onboard(provider(), GenServer.server()) :: :ok | {:error, term()}
  def onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:onboard, provider}, :infinity)

  @doc "Begin an interactive CLI onboarding lease after gate + runtime stop."
  @spec begin_onboard(provider(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def begin_onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:begin_onboard, provider})

  @doc """
  Install the credential produced in the active onboarding lease, as `kind`.

  The kind is stated by the ceremony that produced the credential rather than
  stashed at `begin_onboard/2`, so a lease carries no opinion about what will be
  banked into it. No default arity, deliberately: an omitted kind must fail to
  COMPILE, not silently bank an API key as a subscription.
  """
  @spec finish_onboard(provider(), kind(), GenServer.server()) :: :ok | {:error, term()}
  def finish_onboard(provider, kind, server) when kind in [:api_key, :subscription],
    do: GenServer.call(server, {:finish_onboard, provider, kind}, :infinity)

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
  def terminal_evidence?(provider, evidence) do
    case Enum.find(Harness.all(), &(&1.credential_provider() == provider)) do
      nil -> false
      module -> module.classify_auth_event(evidence) == :terminal
    end
  end

  @doc false
  def store_harvested(base_dir, provider, bytes) do
    path =
      case provider do
        :openai -> Path.join([base_dir, "auth", "codex", "auth.json"])
        :anthropic -> Path.join([base_dir, "auth", "claude", "oauth-token"])
        :fixture_provider -> Path.join([base_dir, "auth", "fixture", "fixture.json"])
      end

    atomic_write!(path, bytes)
    :ok
  end

  @doc false
  def store_dir(base_dir, provider), do: Path.join([base_dir, "auth", harness_name(provider)])

  @impl true
  def init(opts) do
    {:ok,
     %{
       base_dir: Keyword.fetch!(opts, :base_dir),
       staging_base_dir: Keyword.get(opts, :staging_base_dir, Keyword.fetch!(opts, :base_dir)),
       machine: Keyword.fetch!(opts, :machine),
       ssh: Keyword.get(opts, :ssh),
       sh: Keyword.get(opts, :sh, &system_cmd/1),
       now: Keyword.get(opts, :now, fn -> System.system_time(:second) end),
       onboarders: Keyword.get(opts, :onboarders, default_onboarders()),
       gate: Keyword.get(opts, :gate, fn _provider -> :ok end),
       stop: Keyword.get(opts, :stop, fn _provider -> :ok end),
       park: Keyword.get(opts, :park, fn _provider -> :ok end),
       start: Keyword.get(opts, :start, fn _provider -> :ok end),
       resume: Keyword.get(opts, :resume, fn _provider -> :ok end),
       capture_sessions: Keyword.get(opts, :capture_sessions, fn _provider -> [] end),
       publish_sessions:
         Keyword.get(opts, :publish_sessions, fn _payload, _transition -> :ok end),
       onboarding_lease_ms: Keyword.get(opts, :onboarding_lease_ms, 1_800_000),
       log_event: Keyword.get(opts, :log_event, fn _kind, _subject, _detail -> :ok end),
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:status, provider}, _from, state) do
    state = expire_lease(state, provider)
    {:reply, credential_status(state, provider), state}
  end

  def handle_call({:kind, provider}, _from, state) do
    state = expire_lease(state, provider)
    {:reply, credential_kind(state, provider), state}
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
    state = expire_lease(state, provider)

    case Map.fetch(state.pending, provider) do
      {:ok, _lease} ->
        {:reply, {:error, :onboarding_in_progress}, state}

      :error ->
        with :ok <- state.gate.(provider),
             :ok <- state.stop.(provider) do
          path = onboarding_staging_path(state, provider)
          :ok = prepare_staging!(state, path)

          lease = %{
            path: path,
            expires_at: state.now.() + div(state.onboarding_lease_ms, 1000)
          }

          {:reply, {:ok, path}, put_in(state.pending[provider], lease)}
        else
          {:error, _reason} = error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:finish_onboard, provider, kind}, _from, state) do
    state = expire_lease(state, provider)

    case Map.fetch(state.pending, provider) do
      {:ok, %{path: path}} ->
        result =
          with {:ok, credential} <- install_staged!(state, provider, kind, path),
               :ok <- state.start.(provider),
               :ok <- mark_onboarded!(state, provider, kind, credential),
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

      {%{path: path}, pending} ->
        cleanup_staging!(state, path)
        record_onboarding_failure!(state, provider, reason)
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  # Leases expire at the READ seams only — no timer, no sweep, matching this
  # module's stated posture ("expiry is compared only at read seams"). An expired
  # lease is not a new state: it runs the cancel path, so a provider wedged by a
  # CLI that died between `begin` and `cancel` heals into exactly the condition an
  # explicit cancel would have left, without a gateway restart.
  defp expire_lease(state, provider) do
    with {:ok, %{path: path, expires_at: expires_at}} <- Map.fetch(state.pending, provider),
         true <- expires_at <= state.now.() do
      cleanup_staging!(state, path)
      record_onboarding_failure!(state, provider, :lease_expired)
      state.log_event.("credential_lease_expired", "#{provider}@#{state.machine}", nil)
      update_in(state.pending, &Map.delete(&1, provider))
    else
      _ -> state
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
           :ok <- state.start.(provider),
           :ok <- mark_onboarded!(state, provider, :subscription, credential),
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

  defp credential_kind(state, provider) do
    metadata = read_metadata(state, provider)

    if metadata["onboarded"] == true and credential_present?(state, provider) do
      decode_kind(metadata["kind"])
    else
      :none
    end
  end

  # Every credential banked before this invariant existed is a subscription BY
  # CONSTRUCTION—there was no other onboarding path—so metadata without a "kind"
  # reads as one. That is a migration default over OUR OWN recorded metadata, not
  # an inference from the credential file, which nothing here does.
  defp decode_kind("api_key"), do: :api_key
  defp decode_kind(_recorded), do: :subscription

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now) when is_integer(expires_at), do: expires_at <= now
  defp expired?(_unknown, _now), do: false

  defp credential_present?(state, provider) do
    target = credential_target(state)

    provider
    |> harnesses_for_provider()
    |> Enum.any?(fn module ->
      module.credential_ready?(
        target,
        Homes.home_path(state.base_dir, state.machine, module.id())
      )
    end)
  end

  defp write_credential!(state, :openai, credential) do
    path = credential_store_path(state, :openai)
    atomic_write!(path, credential.bytes)
    reconcile_provider_homes(state, :openai)
    :ok
  end

  defp write_credential!(state, :anthropic, credential) do
    path = credential_store_path(state, :anthropic)
    atomic_write!(path, String.trim(credential.bytes) <> "\n")
    reconcile_provider_homes(state, :anthropic)
    :ok
  end

  defp write_credential!(state, :fixture_provider, credential) do
    path = credential_store_path(state, :fixture_provider)
    atomic_write!(path, credential.bytes)
    reconcile_provider_homes(state, :fixture_provider)
    :ok
  end

  defp reconcile_provider_homes(state, provider) do
    target = credential_target(state)

    Enum.each(harnesses_for_provider(provider), fn module ->
      module.reconcile_home(
        target,
        Homes.home_path(state.base_dir, state.machine, module.id()),
        %{
          harness: module.id(),
          machine: state.machine,
          rails: Rails.hook_settings(),
          auth_dir: Path.dirname(credential_store_path(state, provider)),
          harvest_auth: false
        }
      )
    end)
  end

  defp credential_target(state),
    do: %{
      base_dir: state.staging_base_dir,
      host_config: %{ssh: state.ssh, base_dir: state.base_dir},
      host_name: state.machine,
      sh: state.sh
    }

  defp default_onboarders do
    onboarders = %{
      openai: &onboard_openai/1,
      anthropic: &onboard_anthropic/1
    }

    if @fixture_provider? do
      Map.put(onboarders, :fixture_provider, fn _state ->
        {:ok, %{bytes: "fixture-provider-credential", expires_at: nil}}
      end)
    else
      onboarders
    end
  end

  defp harnesses_for_provider(provider),
    do: Enum.filter(Harness.all(), &(&1.credential_provider() == provider))

  defp mark_onboarded!(state, provider, kind, credential) do
    write_metadata!(state, provider, %{
      "provider" => Atom.to_string(provider),
      "kind" => Atom.to_string(kind),
      "onboarded" => true,
      "terminal" => false,
      "last_health" => "onboarded",
      "subscription_status" => Map.get(credential, :subscription_status),
      "expires_at" => Map.get(credential, :expires_at)
    })

    :ok
  end

  defp metadata_path(state, provider) when is_map(state),
    do: metadata_path(state.base_dir, provider)

  defp metadata_path(base_dir, provider) when is_binary(base_dir) do
    Path.join([
      base_dir,
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

  defp credential_store_path(state, :fixture_provider),
    do: Path.join([state.base_dir, "auth", "fixture", "fixture.json"])

  defp harness_name(:openai), do: "codex"
  defp harness_name(:anthropic), do: "claude"
  defp harness_name(:fixture_provider), do: "fixture"

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

  # The staged FILENAME is per provider, not per kind: a host holds one active
  # credential per provider and the ceremony stages it under that provider's one
  # name. What differs by kind is the metadata written beside it—expiry above
  # all. An API key is static (no rotation, no refresh), so it has no expiry to
  # compare and no subscription entitlement to report.
  defp staged_credential(:openai, kind, path) do
    case File.read(Path.join(path, "auth.json")) do
      {:ok, bytes} -> {:ok, Map.put(installed_metadata(:openai, kind), :bytes, bytes)}
      {:error, reason} -> {:error, {:device_auth_failed, reason}}
    end
  end

  defp staged_credential(:anthropic, kind, path) do
    case File.read(Path.join(path, "oauth-token")) do
      {:ok, bytes} -> {:ok, Map.put(installed_metadata(:anthropic, kind), :bytes, bytes)}
      {:error, reason} -> {:error, {:setup_token_failed, reason}}
    end
  end

  defp staged_credential(:fixture_provider, kind, path) do
    case File.read(Path.join(path, "fixture.json")) do
      {:ok, bytes} -> {:ok, Map.put(installed_metadata(:fixture_provider, kind), :bytes, bytes)}
      {:error, reason} -> {:error, {:fixture_provider_failed, reason}}
    end
  end

  defp install_staged!(%{ssh: nil} = state, provider, kind, path) do
    with {:ok, credential} <- staged_credential(provider, kind, path),
         :ok <- write_credential!(state, provider, credential) do
      {:ok, credential}
    end
  end

  defp install_staged!(state, provider, kind, path) do
    source = staged_path(provider, path)
    store = credential_store_path(state, provider)

    script =
      "test -f #{shell_quote(source)} && " <>
        "mkdir -p #{shell_quote(Path.dirname(store))} && " <>
        "chmod 600 #{shell_quote(source)} && " <>
        "mv #{shell_quote(source)} #{shell_quote(store)} && " <>
        "chmod 600 #{shell_quote(store)}"

    case remote_command(state, ["sh", "-c", shell_quote(script)]) do
      {_output, 0} ->
        reconcile_provider_homes(state, provider)
        {:ok, installed_metadata(provider, kind)}

      {output, status} ->
        {:error, {:credential_install_failed, status, String.trim(output)}}
    end
  end

  # An API key does not expire and carries no subscription entitlement, so it
  # reports neither. Giving one a synthetic expiry would make `credential_status`
  # eventually demand a re-onboard for a credential that is still perfectly good.
  defp installed_metadata(_provider, :api_key), do: %{expires_at: nil}

  defp installed_metadata(:anthropic, :subscription) do
    %{
      expires_at: System.system_time(:second) + 365 * 24 * 60 * 60,
      subscription_status: "supported"
    }
  end

  defp installed_metadata(_provider, :subscription), do: %{expires_at: nil}

  defp staged_path(:openai, path), do: Path.join(path, "auth.json")
  defp staged_path(:anthropic, path), do: Path.join(path, "oauth-token")
  defp staged_path(:fixture_provider, path), do: Path.join(path, "fixture.json")

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
