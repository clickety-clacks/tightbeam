defmodule Tightbeam.IdentityApply.RuntimeAdapter do
  @moduledoc """
  Recoverable logical-effect boundary for identity apply.

  The gateway names an effect once. This adapter stores call state and the
  terminal receipt under that effect ID, so executor recovery asks status
  before it considers another invoke. Reload owns close, target activation,
  and prior-context restoration as one logical operation.
  """

  alias Tightbeam.{
    AdapterCoordinator,
    Archetypes,
    Harness,
    Identity,
    IdentityApply,
    Org,
    Placement
  }

  alias Tightbeam.Acp.Adapter

  @type config :: map()

  @required_capabilities %{
    "durableEffectStatus" => true,
    "runnerStopCoalescing" => true,
    "readOnlySnapshot" => true,
    "reloadCoalescing" => true,
    "reloadReadback" => true,
    "targetStaging" => true,
    "atomicReplacement" => true,
    "exactPriorContextRestore" => true
  }

  @spec capabilities(map(), config()) :: :supported | :unsupported
  def capabilities(session, config) do
    case Map.get(config, :identity_apply_capabilities) do
      fun when is_function(fun, 1) ->
        fun.(session)

      _ ->
        harness = Harness.parse!(session.harness)

        if harness.identity_apply_capabilities() == @required_capabilities,
          do: :supported,
          else: :unsupported
    end
  end

  @spec snapshot(config(), GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(config, db, session_key) do
    session = Org.get(db, session_key)
    harness = Harness.parse!(session.harness).id()
    coordinator = Map.get(config, :adapter_coordinator, AdapterCoordinator)
    key = {harness, "shared", session.host}

    pointer = Org.current_pointer(db, session_key)
    context_id = pointer && pointer.harness_session_id

    with {:ok, adapter, generation} <- AdapterCoordinator.adapter_for(coordinator, key),
         {:ok, adapter_snapshot} <- Adapter.identity_context_snapshot(adapter, context_id) do
      resident = adapter_snapshot.resident

      {:ok,
       %{
         "contextId" => context_id,
         "identityRevision" => session.identity_revision,
         "model" => session.model && Tightbeam.Model.to_ref(session.model),
         "workdir" => Placement.workdir_path(config, session),
         "historyPointer" => pointer && pointer.source_session_ref,
         "sessionIncarnation" => session_incarnation(session, pointer),
         "adapterGeneration" => generation,
         "resident" => resident,
         "runnable" => true,
         "harness" => session.harness,
         "host" => session.host
       }}
    end
  end

  @spec status(config(), GenServer.server(), String.t()) ::
          :not_started | :in_progress | {:succeeded, map()} | {:failed, map()} | {:error, term()}
  def status(config, db, effect_id) do
    case adapter_module(config) do
      __MODULE__ -> status_effect(config, db, effect_id)
      module -> module.status(config, db, effect_id)
    end
  end

  @spec invoke(config(), GenServer.server(), String.t()) ::
          {:succeeded, map()} | {:failed, map()} | {:error, term()}
  def invoke(config, db, effect_id) do
    case adapter_module(config) do
      __MODULE__ -> invoke_effect(config, db, effect_id)
      module -> module.invoke(config, db, effect_id)
    end
  end

  @doc false
  def status_effect(_config, db, effect_id) do
    case IdentityApply.effect(db, effect_id) do
      %{state: "not-started"} -> :not_started
      %{state: "in-progress"} -> :in_progress
      %{state: "succeeded", receipt: receipt} -> {:succeeded, receipt}
      %{state: "failed", receipt: receipt} -> {:failed, receipt}
      nil -> {:error, :unknown_effect}
    end
  end

  @doc false
  def invoke_effect(config, db, effect_id) do
    case IdentityApply.start_effect(db, effect_id) do
      :terminal -> terminal_effect_result(db, effect_id)
      :already_started -> status_effect(config, db, effect_id) |> started_status()
      :started -> perform_effect(config, db, IdentityApply.effect(db, effect_id))
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp perform_effect(_config, db, %{phase: "runner-stop"} = effect) do
    turn_seq = effect.request["interruptedTurnSeq"] || effect.request["interrupted_turn_seq"]

    receipt =
      case Tightbeam.SessionLane.stop_canceled(effect.session_key, turn_seq) do
        :ok ->
          %{
            "state" => "succeeded",
            "result" => "stopped",
            "interruptedTurnSeq" => turn_seq
          }

        :not_running ->
          %{
            "state" => "succeeded",
            "result" => "already-stopped",
            "interruptedTurnSeq" => turn_seq
          }

        :no_lane ->
          %{
            "state" => "succeeded",
            "result" => "already-stopped",
            "interruptedTurnSeq" => turn_seq
          }
      end

    finish_and_return(db, effect.effect_id, receipt)
  end

  defp perform_effect(config, db, %{phase: "reload"} = effect) do
    request = effect.request
    session = Org.get(db, effect.session_key)
    target_revision = request["targetRevision"] || request["target_revision"]
    prior = request["priorContext"] || request["prior_context"] || %{}

    receipt =
      case reload_context(config, db, session, target_revision, prior) do
        {:ok, context_id, pointer_reason} ->
          %{
            "state" => "succeeded",
            "targetContextId" => context_id,
            "targetRevision" => target_revision,
            "pointerReason" => pointer_reason,
            "runnable" => true
          }

        {:error, reason} ->
          case restore_prior(config, db, session, prior) do
            {:ok, prior_context_id} ->
              %{
                "state" => "failed",
                "class" => %{"effectDisposition" => "terminal", "name" => safe_class(reason)},
                "priorContextId" => prior_context_id,
                "priorRevision" => prior["identityRevision"],
                "runnable" => true
              }

            {:error, restore_reason} ->
              %{
                "state" => "failed",
                "class" => %{
                  "effectDisposition" => "retryable",
                  "name" => "prior-context-not-proven",
                  "restoreClass" => safe_class(restore_reason)
                }
              }
          end
      end

    finish_and_return(db, effect.effect_id, receipt)
  end

  defp reload_context(config, _db, session, revision, prior) do
    harness = Harness.parse!(session.harness).id()
    coordinator = Map.get(config, :adapter_coordinator, AdapterCoordinator)
    key = {harness, "shared", session.host}

    with {:ok, adapter, _generation} <- AdapterCoordinator.adapter_for(coordinator, key),
         snapshot <- target_snapshot(config, session, harness, revision),
         cwd <- Placement.holder_workdir(config, session),
         mcp <- Tightbeam.Gateway.mcp_servers_for_archetype(session.archetype, Archetypes),
         {:ok, context_id, reason} <-
           activate_target(adapter, session, prior, cwd, mcp, snapshot.guidance) do
      {:ok, context_id, reason}
    end
  end

  defp activate_target(adapter, session, prior, cwd, mcp, guidance) do
    Adapter.identity_replace_session(
      adapter,
      prior["contextId"],
      prior["resident"] == true,
      session.model,
      cwd,
      mcp,
      guidance
    )
  end

  defp restore_prior(_config, _db, _session, %{"contextId" => nil}), do: {:ok, nil}

  defp restore_prior(config, _db, session, prior) do
    context_id = prior["contextId"]
    revision = prior["identityRevision"]

    if is_binary(context_id) and is_binary(revision) do
      harness = Harness.parse!(session.harness).id()
      coordinator = Map.get(config, :adapter_coordinator, AdapterCoordinator)
      key = {harness, "shared", session.host}

      with {:ok, adapter, _generation} <- AdapterCoordinator.adapter_for(coordinator, key),
           snapshot <- target_snapshot(config, session, harness, revision),
           cwd <- Placement.holder_workdir(config, session),
           mcp <- Tightbeam.Gateway.mcp_servers_for_archetype(session.archetype, Archetypes),
           {:ok, _} <-
             Adapter.load_session(adapter, context_id, session.model, cwd, mcp, snapshot.guidance) do
        {:ok, context_id}
      end
    else
      {:error, :prior_context_unavailable}
    end
  end

  defp target_snapshot(config, session, harness, revision) do
    config.base_dir
    |> Identity.snapshot_at!(revision, session.archetype, harness)
    |> then(&Placement.materialize_identity(config, session, &1))
  end

  defp finish_and_return(db, effect_id, receipt) do
    receipt = IdentityApply.finish_effect(db, effect_id, receipt)

    case receipt["state"] do
      "succeeded" -> {:succeeded, receipt}
      "failed" -> {:failed, receipt}
    end
  end

  defp terminal_effect_result(db, effect_id) do
    case IdentityApply.effect(db, effect_id) do
      %{state: "succeeded", receipt: receipt} -> {:succeeded, receipt}
      %{state: "failed", receipt: receipt} -> {:failed, receipt}
    end
  end

  defp started_status(:in_progress), do: {:error, :in_progress}
  defp started_status({:succeeded, receipt}), do: {:succeeded, receipt}
  defp started_status({:failed, receipt}), do: {:failed, receipt}
  defp started_status(other), do: other

  defp adapter_module(config), do: Map.get(config, :identity_apply_runtime_adapter, __MODULE__)

  defp session_incarnation(session, nil), do: "unstarted:#{session.created_at}"

  defp session_incarnation(_session, pointer), do: "pointer:#{pointer.source_session_ref}"

  defp safe_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_class(_), do: "adapter-failure"
end
