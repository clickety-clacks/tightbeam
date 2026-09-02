defmodule Tightbeam.ExecDesks do
  @moduledoc """
  The deterministic, off-by-default shell for a worker's inbound exec.

  This module deliberately has no provider client. The future NOTE surface has
  one explicit seam: it is not reachable from this deterministic shell. The
  exec records an elected binding, preserves source wake identity, and gives
  callers the bounded timing, grouping, citation, escalation, and
  credential-selection decisions they need to make their own transaction atomic.
  """

  alias Tightbeam.{DB, Gateway, Id, Org, Wakes}
  alias Tightbeam.DB.Txn

  @policy_revision "exec-desks-v1"
  @ddl """
  CREATE TABLE IF NOT EXISTS exec_desk_bindings (
    workerSessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
    execId TEXT NOT NULL UNIQUE,
    policyRevision TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)),
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS exec_desk_bundles (
    bundleId TEXT PRIMARY KEY,
    workerSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    execId TEXT NOT NULL REFERENCES exec_desk_bindings(execId),
    policyRevision TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('open','delivered','expired')),
    createdAt INTEGER NOT NULL,
    terminalAt INTEGER,
    terminalCause TEXT
  );
  CREATE TABLE IF NOT EXISTS exec_desk_bundle_members (
    bundleId TEXT NOT NULL REFERENCES exec_desk_bundles(bundleId),
    wakeId TEXT NOT NULL REFERENCES wakes(wakeId),
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    PRIMARY KEY (bundleId, wakeId),
    UNIQUE (bundleId, ordinal)
  );
  CREATE TABLE IF NOT EXISTS exec_desk_annotations (
    annotationId TEXT PRIMARY KEY,
    wakeId TEXT REFERENCES wakes(wakeId),
    bundleId TEXT REFERENCES exec_desk_bundles(bundleId),
    workerSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    execId TEXT NOT NULL REFERENCES exec_desk_bindings(execId),
    citedKind TEXT NOT NULL,
    citedId TEXT NOT NULL,
    createdAt INTEGER NOT NULL,
    CHECK ((wakeId IS NULL) != (bundleId IS NULL)),
    UNIQUE (wakeId, citedKind, citedId),
    UNIQUE (bundleId, citedKind, citedId)
  );
  """

  @type timing :: :now | :next
  @type candidate :: %{
          required(:provider) => atom() | String.t(),
          required(:onboarded?) => boolean()
        }

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @spec policy_revision() :: String.t()
  def policy_revision, do: @policy_revision

  @doc "Install or inhibit a binding.  No binding is enabled implicitly."
  @spec bind_in_txn(Txn.t(), String.t(), String.t(), boolean(), non_neg_integer()) :: :ok
  def bind_in_txn(%Txn{} = txn, worker, exec_id, enabled, at)
      when is_binary(worker) and is_binary(exec_id) and is_boolean(enabled) and is_integer(at) and
             at >= 0 do
    Txn.q(
      txn,
      """
      INSERT INTO exec_desk_bindings
        (workerSessionKey, execId, policyRevision, enabled, createdAt, updatedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?5)
      ON CONFLICT(workerSessionKey) DO UPDATE SET
        execId=excluded.execId, policyRevision=excluded.policyRevision,
        enabled=excluded.enabled, updatedAt=excluded.updatedAt
      """,
      [worker, exec_id, @policy_revision, if(enabled, do: 1, else: 0), at]
    )

    :ok
  end

  @spec enabled_in_txn?(Txn.t(), String.t()) :: boolean()
  def enabled_in_txn?(%Txn{} = txn, worker) when is_binary(worker) do
    Txn.q(
      txn,
      "SELECT 1 FROM exec_desk_bindings WHERE workerSessionKey=?1 AND enabled=1 AND policyRevision=?2",
      [worker, @policy_revision]
    ) != []
  end

  @doc "The only timing decision an exec may make."
  @spec timing(String.t() | nil, String.t()) :: timing()
  def timing("fyi", _origin), do: :next
  def timing("status-query", _origin), do: :next
  def timing("input-needed", _origin), do: :now
  def timing("blocker", _origin), do: :now
  def timing("algedonic", _origin), do: :now
  def timing(_class, origin) when is_binary(origin), do: :now

  @doc "One source stays direct; a BUNDLE is representable only for two or more sources."
  @spec group([map()]) :: {:direct, map()} | {:bundle, [map()]}
  def group([source]), do: {:direct, source}
  def group([first, second | rest]), do: {:bundle, [first, second | rest]}

  @doc "Persist an ordered BUNDLE only after the binding elected this worker's exec."
  @spec open_bundle_in_txn(Txn.t(), String.t(), [String.t()], non_neg_integer()) :: String.t()
  def open_bundle_in_txn(%Txn{} = txn, worker, wake_ids, at)
      when is_binary(worker) and is_list(wake_ids) and is_integer(at) and at >= 0 do
    case {binding_in_txn(txn, worker), wake_ids} do
      {%{enabled: true, exec_id: exec_id}, [_, _ | _]} ->
        validate_bundle_members!(txn, worker, wake_ids)
        bundle_id = "b_" <> Id.uuid4()

        Txn.q(
          txn,
          """
          INSERT INTO exec_desk_bundles
            (bundleId, workerSessionKey, execId, policyRevision, state, createdAt)
          VALUES (?1, ?2, ?3, ?4, 'open', ?5)
          """,
          [bundle_id, worker, exec_id, @policy_revision, at]
        )

        wake_ids
        |> Enum.with_index(1)
        |> Enum.each(fn {wake_id, ordinal} ->
          Txn.q(
            txn,
            "INSERT INTO exec_desk_bundle_members (bundleId, wakeId, ordinal) VALUES (?1, ?2, ?3)",
            [bundle_id, wake_id, ordinal]
          )
        end)

        bundle_id

      {_binding, [_]} ->
        raise ArgumentError, "a BUNDLE requires more than one source wake"

      {_binding, _} ->
        raise ArgumentError, "an enabled exec binding is required for a BUNDLE"
    end
  end

  @doc "Terminal bundle state is named; source members are never deleted or rewritten."
  @spec terminalize_bundle_in_txn(
          Txn.t(),
          String.t(),
          :delivered | :expired,
          String.t() | nil,
          non_neg_integer()
        ) :: :ok
  def terminalize_bundle_in_txn(%Txn{} = txn, bundle_id, state, cause, at)
      when is_binary(bundle_id) and state in [:delivered, :expired] and
             (is_binary(cause) or is_nil(cause)) and is_integer(at) and at >= 0 do
    Txn.q(
      txn,
      """
      UPDATE exec_desk_bundles SET state=?2, terminalAt=?3, terminalCause=?4
      WHERE bundleId=?1 AND state='open'
      """,
      [bundle_id, Atom.to_string(state), at, cause]
    )

    if Txn.changes(txn) == 1, do: :ok, else: raise(ArgumentError, "BUNDLE is not open")
  end

  @doc "Append the worker delivery and terminalize the BUNDLE in one caller-owned transaction."
  def deliver_bundle_in_txn(txn, bundle_id, worker, origin, prompt, at, opts \\ []) do
    if open_bundle_for_worker_in_txn(txn, bundle_id, worker) do
      case Gateway.deliver_prompt_in_txn(txn, worker, origin, prompt, opts) do
        {:appended, ^worker, _message, _opts} = delivery ->
          :ok = terminalize_bundle_in_txn(txn, bundle_id, :delivered, nil, at)
          delivery

        other ->
          other
      end
    else
      raise ArgumentError, "BUNDLE is not open for this worker"
    end
  end

  @doc """
  Admit one pending source wake through an elected exec before its worker turn.

  The source wake and worker turn commit together. Callers retain the ordinary
  Gateway path when no binding is enabled; any non-delivery rolls this
  transaction back so the source wake stays pending for retry.
  """
  @spec deliver_source_wake_in_txn(
          Txn.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: :not_elected | tuple()
  def deliver_source_wake_in_txn(%Txn{} = txn, wake_id, worker, origin, prompt, opts)
      when is_binary(wake_id) and is_binary(worker) and is_binary(origin) and is_binary(prompt) and
             is_list(opts) do
    if enabled_in_txn?(txn, worker) do
      delivery_opts =
        opts
        |> Keyword.put(:wake_id, wake_id)
        |> Keyword.delete(:fire_wake_in_txn)

      case Gateway.deliver_prompt_in_txn(txn, worker, origin, prompt, delivery_opts) do
        {:appended, ^worker, _message, _opts} = delivery ->
          fire_source_wake_in_txn(txn, wake_id)
          delivery

        {:duplicate, _message} = delivery ->
          fire_source_wake_in_txn(txn, wake_id)
          delivery

        other ->
          raise ArgumentError, "exec source wake delivery did not commit: #{inspect(other)}"
      end
    else
      :not_elected
    end
  end

  @doc "Resolve a policy-selected parent in the same owner transaction as its send."
  @spec effective_parent_in_txn(Txn.t(), String.t()) :: String.t()
  def effective_parent_in_txn(%Txn{} = txn, worker),
    do: Org.effective_parent_in_txn(txn, worker).session_key

  @doc "Write one row-citing annotation; empty or duplicate citations are refusals."
  @spec annotate_in_txn(
          Txn.t(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: :ok
  def annotate_in_txn(%Txn{} = txn, target, worker, exec_id, cited_kind, cited_id, at)
      when is_binary(worker) and is_binary(exec_id) and is_binary(cited_kind) and cited_kind != "" and
             is_binary(cited_id) and cited_id != "" and is_integer(at) and at >= 0 do
    {wake_id, bundle_id} = annotation_target!(target)
    validate_annotation_binding!(txn, worker, exec_id)
    validate_annotation_target!(txn, worker, wake_id, bundle_id)

    Txn.q(
      txn,
      """
      INSERT INTO exec_desk_annotations
        (annotationId, wakeId, bundleId, workerSessionKey, execId, citedKind, citedId, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      ["ann_" <> Id.uuid4(), wake_id, bundle_id, worker, exec_id, cited_kind, cited_id, at]
    )

    :ok
  end

  @doc "Try only recorded onboarded providers, in the policy's declared order."
  @spec ringdown([candidate()], (candidate() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term(), candidate()} | {:error, [term()]}
  def ringdown(candidates, call) when is_list(candidates) and is_function(call, 1) do
    Enum.reduce_while(candidates, {:error, []}, fn candidate, {:error, reasons} ->
      if Map.get(candidate, :onboarded?) == true do
        case call.(candidate) do
          {:ok, result} -> {:halt, {:ok, result, candidate}}
          {:error, reason} -> {:cont, {:error, [reason | reasons]}}
        end
      else
        {:cont, {:error, [{:not_onboarded, Map.fetch!(candidate, :provider)} | reasons]}}
      end
    end)
    |> then(fn
      {:error, reasons} -> {:error, Enum.reverse(reasons)}
      result -> result
    end)
  end

  defp annotation_target!(%{wake_id: wake_id}) when is_binary(wake_id), do: {wake_id, nil}
  defp annotation_target!(%{bundle_id: bundle_id}) when is_binary(bundle_id), do: {nil, bundle_id}

  defp annotation_target!(_),
    do: raise(ArgumentError, "annotation target must name one wake or BUNDLE")

  defp binding_in_txn(txn, worker) do
    case Txn.q(
           txn,
           "SELECT execId, enabled FROM exec_desk_bindings WHERE workerSessionKey=?1 AND policyRevision=?2",
           [worker, @policy_revision]
         ) do
      [[exec_id, 1]] -> %{exec_id: exec_id, enabled: true}
      _ -> nil
    end
  end

  defp open_bundle_for_worker_in_txn(txn, bundle_id, worker) do
    Txn.q(
      txn,
      "SELECT 1 FROM exec_desk_bundles WHERE bundleId=?1 AND workerSessionKey=?2 AND state='open'",
      [bundle_id, worker]
    ) != []
  end

  defp fire_source_wake_in_txn(txn, wake_id) do
    Txn.q(
      txn,
      "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1 AND state='pending'",
      [wake_id, System.system_time(:millisecond)]
    )

    if Txn.changes(txn) == 1 do
      Wakes.publish_change_in_txn(txn, "wake.fired", wake_id)
    else
      raise ArgumentError, "exec source wake is not pending"
    end
  end

  defp validate_bundle_members!(txn, worker, wake_ids) do
    if Enum.uniq(wake_ids) != wake_ids do
      raise ArgumentError, "a BUNDLE cannot contain a source wake twice"
    end

    Enum.each(wake_ids, fn wake_id ->
      case Txn.q(
             txn,
             "SELECT 1 FROM wakes WHERE wakeId=?1 AND sessionKey=?2 AND state='pending'",
             [wake_id, worker]
           ) do
        [[1]] -> :ok
        _ -> raise ArgumentError, "BUNDLE source wake is not pending for this worker"
      end
    end)
  end

  defp validate_annotation_binding!(txn, worker, exec_id) do
    case binding_in_txn(txn, worker) do
      %{enabled: true, exec_id: ^exec_id} -> :ok
      _ -> raise ArgumentError, "an enabled matching exec binding is required for ANNOTATE"
    end
  end

  defp validate_annotation_target!(txn, worker, wake_id, nil) do
    case Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1 AND sessionKey=?2", [wake_id, worker]) do
      [[1]] -> :ok
      _ -> raise ArgumentError, "annotation wake is not owned by this worker"
    end
  end

  defp validate_annotation_target!(txn, worker, nil, bundle_id) do
    if open_bundle_for_worker_in_txn(txn, bundle_id, worker) do
      :ok
    else
      raise ArgumentError, "annotation BUNDLE is not open for this worker"
    end
  end
end
