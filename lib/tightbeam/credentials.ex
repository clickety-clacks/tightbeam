defmodule Tightbeam.Credentials do
  require Logger

  @moduledoc """
  Per-machine credential onboarding and lifecycle.

  This process is deliberately not a refresher. Codex owns and rotates the
  live home `auth.json` while its runtime is running. A Claude subscription is
  Claude Code's own `.credentials.json`: an OAuth record with a refresh token,
  linked into the harness home and rotated there by Claude Code. A Claude API
  key is a bare secret in the same filename and remains environment-injected.
  Expiry is compared only at read seams—there is no timer or sweep.

  A host holds ONE active credential per provider, of either KIND: an API key or
  a subscription token. The kind is recorded in that provider's
  `credential.json` and is the single authority on how the credential is used—
  which environment variable carries it, which header a probe sends, whether
  rotation is even a concept. Nothing anywhere infers the kind from the
  credential file's name or shape.

  Rotation posture is a property of the kind, not of the provider: API keys are
  static, so they have no refresh and no single-writer constraint. Subscription
  credentials are self-rotating in place and therefore single-writer for both
  Claude and Codex.
  """

  use GenServer

  alias Tightbeam.{ClaudeAuth, CommandEdge, Harness, HarnessHealth, Homes, Rails}
  alias Tightbeam.CommandEdge.CredentialPark

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
  @spec kind(provider(), GenServer.server()) :: kind() | :none | {:error, term()}
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

  @doc "Begin an interactive CLI onboarding lease after gating new work, without stopping the serving runtime."
  @spec begin_onboard(provider(), GenServer.server()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def begin_onboard(provider, server \\ __MODULE__),
    do: GenServer.call(server, {:begin_onboard, provider}, :infinity)

  @doc """
  Install the credential produced in the identified active onboarding lease, as `kind`.

  The kind is stated by the ceremony that produced the credential rather than
  stashed at `begin_onboard/2`, so a lease carries no opinion about what will be
  banked into it. No default arity, deliberately: an omitted kind must fail to
  COMPILE, not silently bank an API key as a subscription.
  """
  @spec finish_onboard(provider(), kind(), String.t(), GenServer.server()) ::
          :ok | {:error, term()}
  def finish_onboard(provider, kind, lease_id, server)
      when kind in [:api_key, :subscription] and is_binary(lease_id),
      do: GenServer.call(server, {:finish_onboard, provider, kind, lease_id}, :infinity)

  @doc "Cancel the identified active onboarding lease without restarting the old credential."
  @spec cancel_onboard(provider(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def cancel_onboard(provider, lease_id, server \\ __MODULE__),
    do: cancel_onboard(provider, lease_id, nil, server)

  @doc "Cancel an onboarding lease and record a provider-classified failure."
  @spec cancel_onboard(provider(), String.t(), term(), GenServer.server()) ::
          :ok | {:error, term()}
  def cancel_onboard(provider, lease_id, reason, server),
    do: GenServer.call(server, {:cancel_onboard, provider, lease_id, reason})

  @doc "Record terminal evidence, gate new sessions, and park running sessions."
  @spec mark_terminal(provider(), term(), GenServer.server()) :: :ok | {:error, term()}
  def mark_terminal(provider, evidence, server \\ __MODULE__),
    do: GenServer.call(server, {:mark_terminal, provider, evidence}, :infinity)

  @doc "Retain non-authoritative Claude subscription auth evidence and confirm it."
  def observe_auth(source, evidence, server \\ __MODULE__)
      when source in [:local_none, :unfenced_401],
      do: GenServer.call(server, {:observe_auth, source, evidence}, :infinity)

  @doc false
  def observe_success(instance, server),
    do: GenServer.call(server, {:observe_success, instance})

  @doc "Classify only pinned terminal evidence. Unknown is always non-terminal."
  @spec terminal_evidence?(provider(), term()) :: boolean()
  def terminal_evidence?(provider, evidence) do
    case Enum.find(Harness.all(), &(&1.credential_provider() == provider)) do
      nil -> false
      module -> module.classify_auth_event(evidence) == :terminal
    end
  end

  @doc false
  def store_harvested(base_dir, provider, bytes, source \\ "a harness home") do
    path =
      case provider do
        :openai -> Path.join([base_dir, "auth", "codex", "auth.json"])
        :anthropic -> Path.join([base_dir, "auth", "claude", ".credentials.json"])
        :fixture_provider -> Path.join([base_dir, "auth", "fixture", "fixture.json"])
      end

    refuse_hollow!(provider, bytes, source)
    atomic_write!(path, bytes)
    :ok
  end

  @doc """
  Refuse a credential that is present but carries nothing usable.

  A hollow record — keys there, values empty or zero — is the one shape that survives every
  existing check and then fails at the only moment nobody is watching: the next turn, as
  `authentication_failed`, hours later, with no path back to the write that caused it. It
  cost two coder sessions before it was traced. So it is refused HERE, at the write, where
  the file that produced it can still be named.

  The vendor owns the credential inside a harness home and rotates it in place, and
  `Homes.sweep_auth/2` harvests every home into the ONE shared store at gateway boot. That
  makes an unvalidated harvest a poisoning: one agent's hollow file becomes every agent's
  credential, and the reboot re-applies it. Refusing to write is therefore only half of it —
  the existing good credential must survive the refusal, which is why this runs BEFORE the
  write rather than validating after.

  The deep check is anthropic-only ON PURPOSE. That is the record shape this incident
  produced and the one shape verified against a live file; openai and fixture get the blank
  check alone, because inventing structure a file never had is how this area breaks.

  What decides the deep test is the PRESENCE of the `claudeAiOauth` key, not its type. A
  populated object is inspected field by field; a present but unusable one — `null`, `""`, a
  list, a bare string — is hollow on its face, because the key announces an OAuth record and
  carries nothing to authenticate with. Bytes with no such key are left alone, which is what
  keeps an api key working: it is banked as a BARE STRING under this same filename, so a
  check that assumed JSON would refuse every api_key install.
  """
  @spec refuse_hollow!(provider(), binary(), String.t()) :: :ok
  def refuse_hollow!(provider, bytes, source) do
    case refuse_hollow(provider, bytes, source) do
      :ok -> :ok
      {:error, {:hollow_credential, %{sentence: sentence}}} -> raise sentence
    end
  end

  @doc """
  The same judgement on the ordinary error channel, for callers that have one.

  The onboarding ceremony threads `with :ok <- write_credential!(...)`, and a RAISE there
  does not reach the operator as a refusal -- it kills the `Credentials` GenServer, and the
  caller sees an exit rather than the sentence. Which is the same lesson as the boot path,
  arriving from a different direction: the refusal has to travel by whatever route the
  caller already uses to report failure, or announcing it costs more than the dirt did.
  """
  @spec refuse_hollow(provider(), binary(), String.t()) :: :ok | {:error, term()}
  def refuse_hollow(provider, bytes, source) do
    case hollow(provider, bytes) do
      nil ->
        :ok

      found ->
        sentence =
          "refusing to bank a hollow #{provider} credential from #{source}: #{found}. " <>
            "Nothing was banked — the credential on this host is unchanged. A credential " <>
            "with no usable token cannot authenticate a turn, and writing it would report " <>
            "success now and fail every session later. Delete that file and re-run " <>
            "`tightbeam onboard #{provider}`."

        {:error, {:hollow_credential, %{source: source, found: found, sentence: sentence}}}
    end
  end

  defp hollow(_provider, bytes) when not is_binary(bytes), do: "it is not readable bytes"

  defp hollow(provider, bytes) do
    if String.trim(bytes) == "" do
      "the credential is empty"
    else
      deep_hollow(provider, bytes)
    end
  end

  # A PRESENT `claudeAiOauth` that is not a usable object is hollow for the same reason an
  # empty token is: the key says "this is an OAuth record" and then carries nothing to
  # authenticate with. Keying on the key's PRESENCE rather than on its type is what closes
  # `null`, `""` and any other non-map value, and it invents no structure -- it is the same
  # field the check already turns on.
  #
  # NOT CLAIMED, deliberately: an UNWRAPPED record (a top-level `accessToken` with no
  # `claudeAiOauth` around it). That is not a shape the vendor writes, and refusing it would
  # assert a credential format nobody has observed -- the mistake `anthropic_oauth.rs` warns
  # about where it declines to invent structure a file never had. If it is ever seen in the
  # wild it earns a check with evidence behind it. Until then this is a named narrow scope,
  # not an oversight.
  defp deep_hollow(:anthropic, bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) ->
        hollow_oauth(oauth)

      {:ok, %{"claudeAiOauth" => _unusable}} ->
        "claudeAiOauth is present but is not an OAuth record"

      _ ->
        nil
    end
  end

  defp deep_hollow(_provider, _bytes), do: nil

  # Each answer names the FIELD, not just "invalid": the operator reading this has a file in
  # front of them and needs to know which value went missing.
  defp hollow_oauth(oauth) do
    cond do
      blank_token?(Map.get(oauth, "accessToken")) ->
        "claudeAiOauth.accessToken is empty"

      # Present-but-empty only. An OMITTED refresh token is a different record (a setup
      # token has none), and refusing it here would reject credentials that work.
      Map.has_key?(oauth, "refreshToken") and blank_token?(Map.get(oauth, "refreshToken")) ->
        "claudeAiOauth.refreshToken is present but empty, so the credential could never renew"

      match?(expiry when is_integer(expiry) and expiry <= 0, Map.get(oauth, "expiresAt")) ->
        "claudeAiOauth.expiresAt is #{Map.get(oauth, "expiresAt")}, so the credential is born expired"

      true ->
        nil
    end
  end

  defp blank_token?(nil), do: true
  defp blank_token?(token) when is_binary(token), do: String.trim(token) == ""
  defp blank_token?(_other), do: true

  @doc false
  def store_dir(base_dir, provider), do: Path.join([base_dir, "auth", harness_name(provider)])

  @impl true
  def init(opts) do
    machine = Keyword.fetch!(opts, :machine)
    db = Keyword.get(opts, :db)
    if db, do: :ok = ClaudeAuth.ensure_schema(db)

    interrupted = if db, do: ClaudeAuth.interrupted_attempts(db, machine), else: []
    recoveries = if db, do: ClaudeAuth.pending_decisions(db, machine), else: []

    recovered_attempts =
      Enum.map(interrupted, fn attempt_id ->
        %{
          attempt_id: attempt_id,
          instance_id: ClaudeAuth.ensure_instance(db, machine),
          deadline_at: System.system_time(:millisecond) + 10_000
        }
      end)

    Enum.each(recovered_attempts, &send(self(), {:run_confirmation, &1}))

    Enum.each(recoveries, &send(self(), {:recover_terminal, &1.id}))

    {:ok,
     %{
       base_dir: Keyword.fetch!(opts, :base_dir),
       db: db,
       staging_base_dir: Keyword.get(opts, :staging_base_dir, Keyword.fetch!(opts, :base_dir)),
       log_event: Keyword.get(opts, :log_event, fn _kind, _subject, _detail -> :ok end),
       machine: machine,
       ssh: Keyword.get(opts, :ssh),
       sh: Keyword.get(opts, :sh, &system_cmd/1),
       sh_out:
         Keyword.get_lazy(opts, :sh_out, fn ->
           if Keyword.has_key?(opts, :sh),
             do: Keyword.fetch!(opts, :sh),
             else: &system_cmd_out/1
         end),
       now: Keyword.get(opts, :now, fn -> System.system_time(:second) end),
       onboarders: Keyword.get(opts, :onboarders, default_onboarders()),
       gate: Keyword.get(opts, :gate, fn _provider -> :ok end),
       stop: Keyword.get(opts, :stop, fn _provider -> :ok end),
       park_edge:
         opts
         |> Keyword.get(:park_edge, CommandEdge.request_to(Tightbeam.AdapterCoordinator))
         |> CommandEdge.validate_request!(),
       park_targets: Keyword.get(opts, :park_targets, default_park_targets(machine)),
       park_requests: :gen_server.reqids_new(),
       park_pending: %{},
       park_deferred: %{},
       start: Keyword.get(opts, :start, fn _provider, _kind -> :ok end),
       resume: Keyword.get(opts, :resume, fn _provider -> :ok end),
       on_credential_present: Keyword.get(opts, :on_credential_present, fn _provider -> :ok end),
       capture_sessions: Keyword.get(opts, :capture_sessions, fn _provider -> [] end),
       publish_sessions:
         Keyword.get(opts, :publish_sessions, fn _payload, _transition -> :ok end),
       onboarding_lease_ms: Keyword.get(opts, :onboarding_lease_ms, 1_800_000),
       present_but_unverified: %{},
       pending: %{},
       acquire_confirmation_fence:
         Keyword.get(opts, :acquire_confirmation_fence, fn _provider, _attempt_id, _timeout ->
           {:error, :confirmation_fence_unavailable}
         end),
       confirm_subscription:
         Keyword.get(opts, :confirm_subscription, fn _provider, _epoch, _context, _timeout ->
           {:unknown, :confirmation_unavailable}
         end),
       confirmation_fence_live:
         Keyword.get(opts, :confirmation_fence_live, fn _provider -> false end),
       confirmation_tasks: Map.new(recovered_attempts, &{&1.attempt_id, %{attempt: &1}})
     }}
  end

  def handle_call({:observe_auth, source, evidence}, _from, state) do
    if state.db && credential_kind(state, :anthropic) == :subscription do
      source = if source == :local_none, do: "local-none", else: "unfenced-401"

      attempt =
        ClaudeAuth.trigger(
          state.db,
          state.machine,
          source,
          System.system_time(:millisecond),
          Tightbeam.Harness.Claude.probe_binding_diagnostic(evidence)
        )

      write_auth_health(state, "unconfirmed", attempt.attempt_id)

      state =
        if attempt.started? do
          send(self(), {:run_confirmation, attempt})
          put_in(state.confirmation_tasks[attempt.attempt_id], %{attempt: attempt})
        else
          state
        end

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:observe_success, instance}, _from, state) do
    case ClaudeAuth.admission(state.db, state.machine) do
      {:eligible, ^instance} -> write_auth_health(state, "service_observed", nil)
      _other -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:status, provider}, _from, state) do
    state = expire_lease(state, provider)
    {:reply, credential_status(state, provider), state}
  end

  def handle_call({:kind, provider}, _from, state) do
    {:reply, credential_kind(state, provider), state}
  end

  def handle_call({:mark_terminal, provider, evidence}, from, state) do
    cond do
      not terminal_evidence?(provider, evidence) ->
        {:reply, :ok, state}

      pending = state.park_pending[provider] ->
        pending = update_in(pending.waiters, &[from | &1])
        {:noreply, put_in(state.park_pending[provider], pending)}

      true ->
        case read_metadata(state, provider) do
          {:ok, metadata} ->
            first_transition? = metadata["terminal"] != true
            recovery? = metadata["park_pending"] == true

            if first_transition? or recovery? do
              state.gate.(provider)
              captured = capture_sessions(state, provider)

              write_metadata!(
                state,
                provider,
                Map.merge(metadata, %{
                  "provider" => Atom.to_string(provider),
                  "onboarded" => true,
                  "terminal" => true,
                  "last_health" => "revoked",
                  "park_pending" => true
                })
              )

              command = %CredentialPark{
                provider: provider,
                machine: state.machine,
                adapter_keys: Map.fetch!(state.park_targets, provider),
                observed_at: System.system_time(:millisecond)
              }

              {:pending, park_requests} =
                CommandEdge.request(state.park_edge, command, provider, state.park_requests)

              pending = %{waiters: [from], captured: captured}

              {:noreply,
               %{
                 state
                 | park_requests: park_requests,
                   park_pending: Map.put(state.park_pending, provider, pending)
               }}
            else
              {:reply, :ok, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:onboard, :anthropic} = request, from, state)
      when map_size(state.confirmation_tasks) > 0,
      do: defer_credential_call(:anthropic, request, from, state)

  def handle_call({:onboard, provider} = request, from, %{park_pending: pending} = state)
      when is_map_key(pending, provider) do
    defer_credential_call(provider, request, from, state)
  end

  def handle_call({:onboard, provider}, _from, state) do
    perform_onboard(provider, state)
  end

  def handle_call({:begin_onboard, :anthropic} = request, from, state)
      when map_size(state.confirmation_tasks) > 0,
      do: defer_credential_call(:anthropic, request, from, state)

  def handle_call(
        {:begin_onboard, provider} = request,
        from,
        %{park_pending: pending} = state
      )
      when is_map_key(pending, provider) do
    defer_credential_call(provider, request, from, state)
  end

  def handle_call({:begin_onboard, provider}, _from, state) do
    state = expire_lease(state, provider)
    {previous, pending} = Map.pop(state.pending, provider)
    state = %{state | pending: pending}

    if previous, do: cleanup_staging!(state, previous.path)

    with :ok <- state.gate.(provider) do
      path = onboarding_staging_path(state, provider)
      lease_id = Tightbeam.Id.uuid4()
      :ok = prepare_staging!(state, path)

      lease = %{
        id: lease_id,
        path: path,
        expires_at: state.now.() + div(state.onboarding_lease_ms, 1000)
      }

      {:reply, {:ok, path, lease_id}, put_in(state.pending[provider], lease)}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:finish_onboard, :anthropic, _kind, _lease} = request, from, state)
      when map_size(state.confirmation_tasks) > 0,
      do: defer_credential_call(:anthropic, request, from, state)

  def handle_call(
        {:finish_onboard, provider, _kind, _lease_id} = request,
        from,
        %{park_pending: pending} = state
      )
      when is_map_key(pending, provider) do
    defer_credential_call(provider, request, from, state)
  end

  def handle_call({:finish_onboard, provider, kind, lease_id}, _from, state) do
    state = expire_lease(state, provider)

    case Map.fetch(state.pending, provider) do
      {:ok, %{id: ^lease_id, path: path}} ->
        {result, state} = finish_staged_onboard(state, provider, kind, path)

        cleanup_staging!(state, path)
        {:reply, result, update_in(state.pending, &Map.delete(&1, provider))}

      _missing_or_superseded ->
        {:reply, {:error, :onboarding_lease_superseded}, state}
    end
  end

  def handle_call({:cancel_onboard, :anthropic, _lease, _reason} = request, from, state)
      when map_size(state.confirmation_tasks) > 0,
      do: defer_credential_call(:anthropic, request, from, state)

  def handle_call(
        {:cancel_onboard, provider, _lease_id, _reason} = request,
        from,
        %{park_pending: pending} = state
      )
      when is_map_key(pending, provider) do
    defer_credential_call(provider, request, from, state)
  end

  def handle_call({:cancel_onboard, provider, lease_id, reason}, _from, state) do
    case Map.fetch(state.pending, provider) do
      {:ok, %{id: ^lease_id, path: path}} ->
        cleanup_staging!(state, path)
        record_onboarding_failure!(state, provider, reason)
        {:reply, :ok, update_in(state.pending, &Map.delete(&1, provider))}

      _missing_or_superseded ->
        {:reply, {:error, :onboarding_lease_superseded}, state}
    end
  end

  @impl true
  def handle_info({:run_confirmation, attempt}, state) do
    case state.confirmation_tasks[attempt.attempt_id] do
      %{pid: pid} when is_pid(pid) ->
        {:noreply, state}

      nil ->
        {:noreply, state}

      task ->
        owner = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            result = run_confirmation(state, attempt)
            send(owner, {:confirmation_finished, attempt, result})
          end)

        timer =
          Process.send_after(
            self(),
            {:confirmation_deadline, attempt.attempt_id},
            max(attempt.deadline_at - System.system_time(:millisecond), 0)
          )

        task = Map.merge(task, %{pid: pid, monitor: monitor, timer: timer})
        {:noreply, put_in(state.confirmation_tasks[attempt.attempt_id], task)}
    end
  end

  def handle_info({:confirmation_finished, attempt, {:terminal, epoch}}, state) do
    if Map.has_key?(state.confirmation_tasks, attempt.attempt_id) do
      state = finish_confirmation_task(state, attempt.attempt_id)
      fence_live = state.confirmation_fence_live.(:anthropic)

      case ClaudeAuth.accept_terminal(
             state.db,
             attempt.attempt_id,
             attempt.instance_id,
             epoch,
             fence_live
           ) do
        decision when is_binary(decision) ->
          begin_confirmed_terminal(state, decision)

        _stale ->
          ClaudeAuth.finish(state.db, attempt.attempt_id, :stale, "lost-live-fence")
          {:noreply, resume_credential_calls(:anthropic, state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:confirmation_finished, attempt, result}, state) do
    if Map.has_key?(state.confirmation_tasks, attempt.attempt_id) do
      state = finish_confirmation_task(state, attempt.attempt_id)

      case result do
        :success -> write_auth_health(state, "service_observed", nil)
        :unknown -> write_auth_health(state, "unconfirmed", nil)
        _other -> :ok
      end

      {:noreply, resume_credential_calls(:anthropic, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:confirmation_deadline, attempt_id}, state) do
    case state.confirmation_tasks[attempt_id] do
      nil ->
        {:noreply, state}

      task ->
        if is_pid(task[:pid]), do: Process.exit(task.pid, :kill)
        ClaudeAuth.finish(state.db, attempt_id, :unknown, "confirmation-deadline")
        write_auth_health(state, "unconfirmed", nil)
        state = finish_confirmation_task(state, attempt_id)
        {:noreply, resume_credential_calls(:anthropic, state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.confirmation_tasks, fn {_attempt, task} -> task[:monitor] == monitor end) do
      nil ->
        {:noreply, state}

      {attempt_id, _task} ->
        ClaudeAuth.finish(state.db, attempt_id, :unknown, {:confirmation_task_exit, reason})
        write_auth_health(state, "unconfirmed", nil)
        state = finish_confirmation_task(state, attempt_id)
        {:noreply, resume_credential_calls(:anthropic, state)}
    end
  end

  def handle_info({:recover_terminal, decision}, state) do
    begin_confirmed_terminal(state, decision)
  end

  @impl true
  def handle_info(message, state) when map_size(state.park_pending) > 0 do
    case CommandEdge.check_response(message, state.park_requests) do
      {:answered, provider, result, park_requests} ->
        finish_park(provider, result, %{state | park_requests: park_requests})

      {:failed, provider, reason, park_requests} ->
        finish_park(provider, {:error, {:park_request_failed, reason}}, %{
          state
          | park_requests: park_requests
        })

      :no_request ->
        {:noreply, state}

      :no_reply ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp perform_onboard(_provider, %{ssh: destination} = state) when is_binary(destination) do
    {:reply, {:error, :interactive_onboarding_required_on_machine}, state}
  end

  defp perform_onboard(provider, state) do
    result =
      with :ok <- state.gate.(provider),
           :ok <- state.stop.(provider),
           {:ok, credential} <- Map.fetch!(state.onboarders, provider).(state),
           :ok <- write_credential!(state, provider, credential),
           :ok <- state.start.(provider, :subscription),
           :ok <- mark_onboarded!(state, provider, :subscription, credential),
           :ok <- state.on_credential_present.(provider),
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

  defp finish_park(provider, result, state) do
    pending = Map.fetch!(state.park_pending, provider)

    result =
      if result == :ok do
        case read_metadata(state, provider) do
          {:ok, metadata} ->
            write_metadata!(state, provider, Map.put(metadata, "park_pending", false))
            if pending[:decision_id], do: ClaudeAuth.complete_park(state.db, pending.decision_id)
            publish_sessions(state, pending.captured, :terminal)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        result
      end

    if result != :ok do
      state.log_event.(
        "credential_park_unconfirmed",
        "#{provider}@#{state.machine}",
        inspect(result)
      )
    end

    Enum.each(pending.waiters, &GenServer.reply(&1, result))

    state = update_in(state.park_pending, &Map.delete(&1, provider))
    {:noreply, resume_credential_calls(provider, state)}
  end

  defp defer_credential_call(provider, request, from, state) do
    deferred =
      Map.update(state.park_deferred, provider, [{request, from}], &[{request, from} | &1])

    {:noreply, %{state | park_deferred: deferred}}
  end

  defp resume_credential_calls(provider, state) do
    {deferred, park_deferred} = Map.pop(state.park_deferred, provider, [])
    state = %{state | park_deferred: park_deferred}

    deferred
    |> Enum.reverse()
    |> Enum.reduce(state, fn {request, from}, state ->
      case handle_call(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          state

        {:noreply, state} ->
          state
      end
    end)
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

  # Leases expire at the READ seams only — no timer, no sweep, matching this
  # module's stated posture ("expiry is compared only at read seams"). An expired
  # lease is not a new state: it runs the cancel path, so a provider wedged by a
  # CLI that died between `begin` and `cancel` heals into exactly the condition an
  # explicit cancel would have left, without a gateway restart. It does NOT write
  # provider health — `record_onboarding_failure!` no-ops for `:lease_expired` —
  # because a timeout observed nothing about the credential; recording one as a
  # verdict would be a failure stored as a plausible fact.
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
    cond do
      cause = state.present_but_unverified[provider] ->
        {:needs_onboarding, {:present_but_unverified, cause}}

      Map.has_key?(state.pending, provider) ->
        {:needs_onboarding, :in_progress}

      true ->
        credential_status_from_metadata(state, provider)
    end
  end

  defp credential_status_from_metadata(state, provider) do
    case read_metadata(state, provider) do
      {:ok, metadata} ->
        cond do
          cause = metadata["present_but_unverified"] ->
            {:needs_onboarding, {:present_but_unverified, cause}}

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

      {:error, reason} ->
        {:needs_onboarding, reason}
    end
  end

  defp credential_kind(state, provider) do
    case read_metadata(state, provider) do
      {:ok, metadata} ->
        if metadata["onboarded"] == true and credential_present?(state, provider) do
          decode_kind(metadata["kind"])
        else
          :none
        end

      {:error, reason} ->
        {:error, reason}
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

  # The hollow check returns rather than raises here: both callers thread
  # `with :ok <- write_credential!(...)`, so an error tuple reaches the operator as the
  # refusal it is, while a raise would kill this GenServer and surface as an exit.
  defp write_credential!(state, :openai, credential) do
    with :ok <- refuse_hollow(:openai, credential.bytes, "the onboarding ceremony") do
      atomic_write!(credential_store_path(state, :openai), credential.bytes)
      reconcile_provider_homes(state, :openai)
      :ok
    end
  end

  defp write_credential!(state, :anthropic, credential) do
    with :ok <- refuse_hollow(:anthropic, credential.bytes, "the onboarding ceremony") do
      atomic_write!(
        credential_store_path(state, :anthropic),
        String.trim(credential.bytes) <> "\n"
      )

      reconcile_provider_homes(state, :anthropic)
      :ok
    end
  end

  defp write_credential!(state, :fixture_provider, credential) do
    with :ok <- refuse_hollow(:fixture_provider, credential.bytes, "the onboarding ceremony") do
      atomic_write!(credential_store_path(state, :fixture_provider), credential.bytes)
      reconcile_provider_homes(state, :fixture_provider)
      :ok
    end
  end

  defp reconcile_provider_homes(state, provider) do
    target = credential_target(state)

    Enum.each(harnesses_for_provider(provider), fn module ->
      home = Homes.home_path(state.base_dir, state.machine, module.id())

      module.reconcile_home(
        target,
        home,
        %{
          harness: module.id(),
          machine: state.machine,
          rails: Rails.hook_settings(),
          auth_dir: Path.dirname(credential_store_path(state, provider)),
          harvest_auth: false
        }
      )

      warm_home(module, target, home)
    end)
  end

  # Give the harness one run before anyone asks it what it can do.
  #
  # Some harnesses learn an account's entitlements only by asking the server and cache the
  # answer in their home; a catalog derived from a cold home reports a subset as the truth.
  # It does not recover on its own -- an incomplete catalog means nothing can be placed, so
  # no session spawns, so the cache never fills. Warming here, where the credential has just
  # been proven, is what breaks that circle.
  #
  # Best effort by construction: a harness need not implement it, and a warm that fails must
  # not fail an onboarding whose credential already validated.
  #
  # Triggered by a credential WRITE, not by the home's existence -- which holds only because
  # `Tightbeam.Homes` never removes a home. Its moduledoc carries the warning for anyone
  # who changes that.
  defp warm_home(module, target, home) do
    if function_exported?(module, :warm_home, 2) do
      case module.warm_home(target, home) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.info(
            "#{module.id()} home was not warmed on #{inspect(target.host_name)}: " <>
              "#{inspect(reason)} — its catalog will fill in on first use"
          )
      end
    end
  end

  defp credential_target(state),
    do: %{
      base_dir: state.staging_base_dir,
      host_config: %{ssh: state.ssh, base_dir: state.base_dir},
      host_name: state.machine,
      sh: state.sh,
      sh_out: state.sh_out
    }

  # No anthropic entry: the subscription ceremony lives in the Rust CLI
  # (`ceremonies.rs`), which is what an operator actually runs and the only copy
  # that reads the token off a replayed screen and validates it before banking.
  defp default_onboarders do
    onboarders = %{
      openai: &onboard_openai/1
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

  defp default_park_targets(machine) do
    Harness.all()
    |> Enum.group_by(& &1.credential_provider(), &{&1.id(), "shared", machine})
  end

  # A FAILED ONBOARDING LEAVES THE ORG FAILED — it never restores the previous
  # credential. Ruled by Mike 2026-08-14 after the credential-swap incident:
  # "we have no business adding security ON TOP of codex or claude logins."
  #
  # The substrate stores what the operator gave it and reports what the vendor
  # said when it was used. It holds no opinion about whether a vendor login is
  # valid — the vendor owns that, and the only honest test is a real turn.
  #
  # The restore this replaced was worse than a wedge. An operator whose login
  # fails believes the system is stopped, and may have CHOSEN that ("I was
  # running out of tokens anyway, I'll leave it logged out"). Silently reviving
  # the previous credential resumed real spend against an account they believed
  # was disconnected — a state contradicting the operator's model, which the
  # substrate must never construct. It also deadlocked recovery: activation
  # fails while the adapter's circuit is latched open, so every attempt to
  # install a WORKING credential was reverted, and the latch is guaranteed
  # precisely when the old credential has stopped working — the only reason
  # anyone swaps one. Failure correlated with need.
  #
  # ACCEPTED COST, explicitly: a bad login can now displace a working
  # credential. That is recoverable by signing in again, and it is honest.
  # ORDER IS THE INVARIANT: the durable not-onboarded marker commits BEFORE the
  # credential is installed (Sol xhigh review, blocking 1 and 2). Installing
  # first leaves two windows in which the PRIOR credential's `onboarded: true`
  # metadata outlives it and comes to describe the new, never-activated
  # candidate — so a restarted gateway reads the org healthy on a credential
  # nothing ever verified. That is the same lie the rollback told, reached from
  # the other side.
  #
  # Marking first means a metadata failure refuses while the store is still
  # untouched: prior credential, prior metadata, consistent with each other and
  # with what the operator was told. And a crash at any point after the mark
  # leaves the org readably failed, which is the honest reading of an
  # onboarding that did not finish.
  defp finish_staged_onboard(state, provider, kind, path) do
    with :ok <- prepare_staged_activation(state, provider, kind),
         {:ok, credential} <- install_staged!(state, provider, kind, path) do
      case activate_staged_credential(state, provider, kind, credential) do
        :ok ->
          result =
            with :ok <- state.on_credential_present.(provider),
                 captured <- capture_sessions(state, provider),
                 :ok <- state.resume.(provider) do
              publish_sessions(state, captured, :onboarded)
              :ok
            end

          {result, update_in(state.present_but_unverified, &Map.delete(&1, provider))}

        failure ->
          failed_finish(state, provider, kind, failure)
      end
    else
      failure -> {failure, state}
    end
  end

  defp prepare_staged_activation(state, provider, kind) do
    metadata_write_for_finish(fn ->
      write_metadata!(state, provider, %{
        "provider" => Atom.to_string(provider),
        "kind" => Atom.to_string(kind),
        "onboarded" => false,
        "terminal" => false,
        "last_health" => "present_but_unverified",
        "present_but_unverified" => %{
          "finish" => "credential activation has not committed"
        }
      })
    end)
  end

  defp activate_staged_credential(state, provider, kind, credential) do
    with :ok <- state.stop.(provider),
         :ok <- start_for_finish(state, provider, kind),
         :ok <- mark_onboarded_for_finish(state, provider, kind, credential) do
      :ok
    end
  end

  defp start_for_finish(state, provider, kind) do
    state.start.(provider, kind)
  rescue
    error -> {:error, {:credential_start_failed, {:exception, Exception.message(error)}}}
  catch
    caught_kind, reason -> {:error, {:credential_start_failed, {caught_kind, reason}}}
  end

  defp mark_onboarded_for_finish(state, provider, kind, credential) do
    metadata_write_for_finish(fn -> mark_onboarded!(state, provider, kind, credential) end)
  end

  # Fail CLOSED and VISIBLE: the staged credential stays installed, the org
  # reads as not-onboarded, and the cause carries the failure verbatim so a
  # reader learns what the vendor or the runtime actually said. `status/1`
  # serves `present_but_unverified` from both the in-memory map and the durable
  # marker, so the refusal survives a gateway restart — a failed login must not
  # look healthy again just because the process bounced.
  #
  # If THIS marker write fails too, the durable cause falls back to the
  # pre-activation marker's "credential activation has not committed", which
  # `finish_staged_onboard/4` committed before anything was installed. That is
  # less specific than the vendor's own words — a known, accepted degradation
  # (Sol xhigh review, important 1) — but it still fails closed, which is the
  # property that matters. The verbatim reason reaches the caller in the
  # returned compound error either way.
  defp failed_finish(state, provider, kind, failure) do
    cause = %{"finish" => inspect(failure)}

    marker_result =
      write_metadata_result(state, provider, %{
        "provider" => Atom.to_string(provider),
        "kind" => Atom.to_string(kind),
        "onboarded" => false,
        "terminal" => false,
        "last_health" => "present_but_unverified",
        "present_but_unverified" => cause
      })

    result =
      case marker_result do
        :ok ->
          failure

        {:error, marker_failure} ->
          {:error,
           {:onboarding_failed_and_marker_failed, %{finish: failure, marker: marker_failure}}}
      end

    {result, put_in(state.present_but_unverified[provider], cause)}
  end

  defp write_metadata_result(state, provider, metadata) do
    metadata_write_for_finish(fn -> write_metadata!(state, provider, metadata) end)
  end

  defp metadata_write_for_finish(write) do
    write.()
    :ok
  rescue
    error -> {:error, {:credential_metadata_write_failed, Exception.message(error)}}
  catch
    caught_kind, reason ->
      {:error, {:credential_metadata_write_failed, {caught_kind, reason}}}
  end

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

    if not is_nil(state.db) and provider == :anthropic and kind == :subscription do
      ClaudeAuth.activate(state.db, state.machine)
    end

    :ok
  end

  defp run_confirmation(state, attempt) do
    timeout = remaining(attempt.deadline_at, 5_000)

    case bounded(
           fn ->
             state.acquire_confirmation_fence.(:anthropic, attempt.attempt_id, timeout)
           end,
           timeout
         ) do
      :ok ->
        run_fenced_confirmation(state, attempt, nil)

      {:ok, context} ->
        run_fenced_confirmation(state, attempt, context)

      {:error, reason} ->
        ClaudeAuth.finish(state.db, attempt.attempt_id, :unknown, reason)
        :unknown

      :timeout ->
        ClaudeAuth.finish(state.db, attempt.attempt_id, :unknown, "fence-timeout")
        :unknown
    end
  end

  defp run_fenced_confirmation(state, attempt, context) do
    case ClaudeAuth.fence_acquired(state.db, attempt.attempt_id, attempt.instance_id) do
      {:ok, epoch} ->
        timeout = remaining(attempt.deadline_at, 5_000)

        case bounded(
               fn -> state.confirm_subscription.(:anthropic, epoch, context, timeout) end,
               timeout
             ) do
          :accepted ->
            ClaudeAuth.finish(state.db, attempt.attempt_id, :success, "http-2xx")
            :success

          :rejected ->
            {:terminal, epoch}

          {:unknown, reason} ->
            ClaudeAuth.finish(state.db, attempt.attempt_id, :unknown, reason)
            :unknown

          other ->
            ClaudeAuth.finish(state.db, attempt.attempt_id, :unknown, other)
            :unknown
        end

      :stale ->
        ClaudeAuth.finish(state.db, attempt.attempt_id, :stale, "lost-currentness")
        :stale
    end
  end

  defp bounded(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> :timeout
      {:exit, _reason} -> {:error, :operation_failed}
    end
  end

  defp remaining(deadline, cap) do
    deadline
    |> Kernel.-(System.system_time(:millisecond))
    |> max(1)
    |> min(cap)
  end

  defp begin_confirmed_terminal(state, decision) do
    if not ClaudeAuth.current_decision?(state.db, decision) do
      {:noreply, resume_credential_calls(:anthropic, state)}
    else
      project_confirmed_terminal(state, decision)
    end
  end

  defp project_confirmed_terminal(state, decision) do
    HarnessHealth.observe(state.db, %{
      correlation_id: "provider-auth-decision:#{decision}",
      harness: "claude",
      host: state.machine,
      failure_class: "auth-dead",
      evidence_kind: "authoritative-provider",
      session_key: nil,
      assignment_id: nil,
      observed_at: System.system_time(:millisecond),
      cause: "fenced subscription rejection",
      principal: "process:tightbeam/provider:anthropic"
    })

    ClaudeAuth.advance_decision(state.db, decision, "metadata")
    captured = capture_sessions(state, :anthropic)
    {:ok, metadata} = read_metadata(state, :anthropic)

    write_metadata!(
      state,
      :anthropic,
      Map.merge(metadata, %{
        "terminal" => true,
        "last_health" => "revoked",
        "park_pending" => true,
        "terminal_decision" => decision
      })
    )

    ClaudeAuth.advance_decision(state.db, decision, "park_ownership")
    :ok = ClaudeAuth.own_park(state.db, decision)

    command = %CredentialPark{
      provider: :anthropic,
      machine: state.machine,
      adapter_keys: Map.fetch!(state.park_targets, :anthropic),
      observed_at: System.system_time(:millisecond),
      decision_id: decision
    }

    {:pending, requests} =
      CommandEdge.request(state.park_edge, command, :anthropic, state.park_requests)

    pending = %{waiters: [], captured: captured, decision_id: decision}

    {:noreply,
     %{
       state
       | park_requests: requests,
         park_pending: Map.put(state.park_pending, :anthropic, pending)
     }}
  rescue
    error ->
      ClaudeAuth.fail_decision(state.db, decision, Exception.message(error))
      {:noreply, state}
  end

  defp finish_confirmation_task(state, attempt_id) do
    case Map.pop(state.confirmation_tasks, attempt_id) do
      {nil, tasks} ->
        %{state | confirmation_tasks: tasks}

      {task, tasks} ->
        if is_reference(task[:timer]), do: Process.cancel_timer(task.timer)
        if is_reference(task[:monitor]), do: Process.demonitor(task.monitor, [:flush])
        %{state | confirmation_tasks: tasks}
    end
  end

  defp write_auth_health(state, health, attempt) do
    with {:ok, metadata} <- read_metadata(state, :anthropic) do
      write_metadata!(
        state,
        :anthropic,
        metadata
        |> Map.put("last_health", health)
        |> Map.put("auth_unconfirmed", health == "unconfirmed")
        |> Map.put("confirmation_attempt", attempt)
      )
    end

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
    store = store_dir(state.base_dir, provider)

    case File.lstat(store) do
      {:ok, %{type: :directory}} -> read_local_metadata(state, provider)
      {:ok, %{type: type}} -> unreadable_store(store, type, :directory)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> unreadable_store(store, {:unreadable, reason}, :directory)
    end
  end

  defp read_metadata(state, provider) do
    store = store_dir(state.base_dir, provider)

    case remote_test(state, "-L", store) do
      true ->
        unreadable_store(store, :symlink, :directory)

      false ->
        read_remote_store(state, provider, store)

      {:error, reason} ->
        unreadable_store(store, reason, :directory)
    end
  end

  defp read_local_metadata(state, provider) do
    path = metadata_path(state, provider)

    case File.read(path) do
      {:ok, bytes} -> decode_metadata(bytes, path)
      {:error, :enoent} -> unreadable_store(path, :missing, :readable_file)
      {:error, reason} -> unreadable_store(path, {:unreadable, reason}, :readable_file)
    end
  end

  defp read_remote_store(state, provider, store) do
    case remote_test(state, "-d", store) do
      true ->
        read_remote_metadata(state, provider)

      false ->
        classify_remote_non_directory(state, store)

      {:error, reason} ->
        unreadable_store(store, reason, :directory)
    end
  end

  defp classify_remote_non_directory(state, store) do
    case remote_test(state, "-f", store) do
      true ->
        unreadable_store(store, :regular, :directory)

      false ->
        case remote_test(state, "-e", store) do
          true -> unreadable_store(store, :other, :directory)
          false -> classify_remote_absence(state, store)
          {:error, reason} -> unreadable_store(store, reason, :directory)
        end

      {:error, reason} ->
        unreadable_store(store, reason, :directory)
    end
  end

  defp read_remote_metadata(state, provider) do
    path = metadata_path(state, provider)

    case remote_command(state, ["cat", path]) do
      {bytes, 0} ->
        decode_metadata(bytes, path)

      {output, status} ->
        unreadable_store(path, {:read_failed, status, String.trim(output)}, :readable_file)
    end
  end

  defp remote_test(state, operator, path) do
    case remote_command(state, ["test", operator, path]) do
      {_output, 0} -> true
      {_output, 1} -> false
      {output, status} -> {:error, {:probe_failed, status, String.trim(output)}}
    end
  end

  defp classify_remote_absence(state, store) do
    parent = Path.dirname(store)

    with true <- remote_test(state, "-d", parent),
         true <- remote_test(state, "-x", parent) do
      {:ok, %{}}
    else
      false -> unreadable_store(parent, :untraversable, :traversable_directory)
      {:error, reason} -> unreadable_store(parent, reason, :traversable_directory)
    end
  end

  defp decode_metadata(bytes, path) do
    case JSON.decode(bytes) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _other} -> unreadable_store(path, :invalid_json, :valid_json_object)
      {:error, _reason} -> unreadable_store(path, :invalid_json, :valid_json_object)
    end
  end

  defp unreadable_store(path, found, expected) do
    {:error, {:credential_store_unreadable, %{path: path, found: found, expected: expected}}}
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
    do: Path.join([state.base_dir, "auth", "claude", ".credentials.json"])

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

  # `.credentials.json` -- Claude Code's own name, because this file is LINKED into the
  # harness home and read by the harness directly. A subscription credential is the OAuth
  # record it refreshes in place; an API key is a bare secret. Same path, two contents.
  defp staged_credential(:anthropic, kind, path) do
    case File.read(Path.join(path, ".credentials.json")) do
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
  defp staged_path(:anthropic, path), do: Path.join(path, ".credentials.json")
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

  defp system_cmd_out([binary | args]), do: System.cmd(binary, args)

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
