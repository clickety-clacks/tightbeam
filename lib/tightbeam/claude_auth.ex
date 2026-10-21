defmodule Tightbeam.ClaudeAuth do
  @moduledoc """
  Durable authority for Claude subscription authentication.

  Local observations only create uncertainty.  A terminal decision can be
  accepted only for a live, fenced attempt whose opaque credential instance
  and independently generated material epoch are still current.
  """

  alias Tightbeam.{DB, Id}
  alias Tightbeam.DB.Txn

  @provider "anthropic"
  @kind "subscription"

  @ddl """
  CREATE TABLE IF NOT EXISTS claude_auth_instances (
    id TEXT PRIMARY KEY, host TEXT NOT NULL, provider TEXT NOT NULL,
    kind TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('current','superseded')),
    activatedAt INTEGER NOT NULL, supersededAt INTEGER
  );
  CREATE UNIQUE INDEX IF NOT EXISTS claude_auth_one_current
    ON claude_auth_instances(host,provider,kind) WHERE state='current';

  CREATE TABLE IF NOT EXISTS claude_auth_attempts (
    id TEXT PRIMARY KEY, instanceId TEXT NOT NULL REFERENCES claude_auth_instances(id),
    host TEXT NOT NULL, triggerAt INTEGER NOT NULL, deadlineAt INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN
      ('pending_fence','fenced','success','unknown','stale','converted_terminal')),
    epochId TEXT, resultClass TEXT, reason TEXT, finishedAt INTEGER,
    CHECK((state='fenced' AND epochId IS NOT NULL) OR state!='fenced')
  );
  CREATE UNIQUE INDEX IF NOT EXISTS claude_auth_one_active_attempt
    ON claude_auth_attempts(host,instanceId)
    WHERE state IN ('pending_fence','fenced');

  CREATE TABLE IF NOT EXISTS claude_auth_observations (
    id TEXT PRIMARY KEY, attemptId TEXT NOT NULL REFERENCES claude_auth_attempts(id),
    instanceId TEXT NOT NULL REFERENCES claude_auth_instances(id),
    observedAt INTEGER NOT NULL, source TEXT NOT NULL,
    resultClass TEXT NOT NULL, epochId TEXT, reason TEXT
  );

  CREATE TABLE IF NOT EXISTS claude_auth_incidents (
    id TEXT PRIMARY KEY, instanceId TEXT NOT NULL REFERENCES claude_auth_instances(id),
    class TEXT NOT NULL CHECK(class IN ('unconfirmed','auth-dead')),
    state TEXT NOT NULL CHECK(state IN ('open','resolved')),
    openedAt INTEGER NOT NULL, resolvedAt INTEGER, resolution TEXT,
    decisionId TEXT
  );
  CREATE UNIQUE INDEX IF NOT EXISTS claude_auth_one_open_incident
    ON claude_auth_incidents(instanceId,class) WHERE state='open';

  CREATE TABLE IF NOT EXISTS claude_auth_decisions (
    id TEXT PRIMARY KEY, instanceId TEXT NOT NULL UNIQUE REFERENCES claude_auth_instances(id),
    attemptId TEXT NOT NULL UNIQUE REFERENCES claude_auth_attempts(id),
    epochId TEXT NOT NULL, decidedAt INTEGER NOT NULL,
    projectionState TEXT NOT NULL DEFAULT 'incident'
      CHECK(projectionState IN ('incident','metadata','park_ownership','park_delivery','complete')),
    lastError TEXT
  );

  CREATE TABLE IF NOT EXISTS claude_auth_parks (
    decisionId TEXT PRIMARY KEY REFERENCES claude_auth_decisions(id),
    state TEXT NOT NULL CHECK(state IN ('owned','delivered','complete')),
    ownedAt INTEGER NOT NULL, completedAt INTEGER
  );
  """

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Create the first opaque instance for an existing installed credential."
  def ensure_instance(db \\ DB, host, at \\ now()) do
    {:ok, instance} = DB.transaction(db, &ensure_instance_in_txn(&1, host, at))
    instance
  end

  @doc "Supersede prior evidence when onboarding atomically activates a replacement."
  def activate(db \\ DB, host, at \\ now()) do
    {:ok, instance} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE claude_auth_instances SET state='superseded',supersededAt=?1 WHERE host=?2 AND provider=?3 AND kind=?4 AND state='current'",
          [at, host, @provider, @kind]
        )

        Txn.q(
          txn,
          "UPDATE claude_auth_attempts SET state='stale',resultClass='credential-replaced',finishedAt=?1 WHERE host=?2 AND state IN ('pending_fence','fenced')",
          [at, host]
        )

        Txn.q(
          txn,
          "UPDATE claude_auth_incidents SET state='resolved',resolvedAt=?1,resolution='credential-replaced' WHERE state='open' AND instanceId IN (SELECT id FROM claude_auth_instances WHERE host=?2 AND state='superseded')",
          [at, host]
        )

        id = Id.uuid4()

        Txn.q(
          txn,
          "INSERT INTO claude_auth_instances(id,host,provider,kind,state,activatedAt) VALUES(?1,?2,?3,?4,'current',?5)",
          [id, host, @provider, @kind, at]
        )

        id
      end)

    instance
  end

  @doc "Retain a local-none or unfenced-401 trigger and create/join one attempt."
  def trigger(db \\ DB, host, source, at \\ now(), diagnostic \\ nil)
      when source in ["local-none", "unfenced-401"] do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        instance = ensure_instance_in_txn(txn, host, at)
        existing = active_attempt(txn, host, instance)
        attempt = existing || new_attempt(txn, host, instance, at)
        open_incident(txn, instance, "unconfirmed", at, nil)
        observe(txn, attempt, instance, at, source, "epoch-unproved", nil, diagnostic || source)

        %{
          attempt_id: attempt,
          instance_id: instance,
          deadline_at: at + 10_000,
          started?: is_nil(existing)
        }
      end)

    result
  end

  @doc "Mint a fresh secret-independent epoch after the managed-home fence is acquired."
  def fence_acquired(db \\ DB, attempt_id, instance_id) do
    epoch = Id.uuid4()

    DB.transaction(db, fn txn ->
      current = current_instance(txn, attempt_host(txn, attempt_id))

      case Txn.q(txn, "SELECT state,instanceId FROM claude_auth_attempts WHERE id=?1", [
             attempt_id
           ]) do
        [["pending_fence", ^instance_id]] when current == instance_id ->
          Txn.q(
            txn,
            "UPDATE claude_auth_attempts SET state='fenced',epochId=?1 WHERE id=?2 AND state='pending_fence'",
            [epoch, attempt_id]
          )

          {:ok, epoch}

        _ ->
          :stale
      end
    end)
    |> unwrap()
  end

  @doc "Finish success/unknown/stale before releasing the temporary hold."
  def finish(db \\ DB, attempt_id, class, reason \\ nil, at \\ now())
      when class in [:success, :unknown, :stale] do
    DB.transaction(db, fn txn ->
      case attempt_row(txn, attempt_id) do
        nil ->
          :stale

        %{state: state} when state not in ["pending_fence", "fenced"] ->
          :duplicate

        row ->
          terminal = Atom.to_string(class)

          Txn.q(
            txn,
            "UPDATE claude_auth_attempts SET state=?1,resultClass=?1,reason=?2,finishedAt=?3 WHERE id=?4",
            [terminal, redact(reason), at, attempt_id]
          )

          observe(
            txn,
            attempt_id,
            row.instance_id,
            at,
            "confirmation",
            terminal,
            row.epoch_id,
            redact(reason)
          )

          if class == :success,
            do: resolve_incident(txn, row.instance_id, "unconfirmed", at, "provider-accepted")

          :ok
      end
    end)
    |> unwrap()
  end

  @doc "Atomically accept a fenced current 401 and establish the admission gate."
  def accept_terminal(db \\ DB, attempt_id, instance_id, epoch_id, fence_live, at \\ now())
      when is_boolean(fence_live) do
    DB.transaction(db, fn txn ->
      row = attempt_row(txn, attempt_id)
      host = row && row.host

      cond do
        not fence_live ->
          :stale

        is_nil(row) ->
          :stale

        row.state != "fenced" ->
          :stale

        row.instance_id != instance_id or row.epoch_id != epoch_id ->
          :stale

        current_instance(txn, host) != instance_id ->
          :stale

        true ->
          decision = Id.uuid4()

          Txn.q(
            txn,
            "UPDATE claude_auth_attempts SET state='converted_terminal',resultClass='rejected-401',finishedAt=?1 WHERE id=?2",
            [at, attempt_id]
          )

          Txn.q(
            txn,
            "INSERT OR IGNORE INTO claude_auth_decisions(id,instanceId,attemptId,epochId,decidedAt) VALUES(?1,?2,?3,?4,?5)",
            [decision, instance_id, attempt_id, epoch_id, at]
          )

          [[decision_id]] =
            Txn.q(txn, "SELECT id FROM claude_auth_decisions WHERE instanceId=?1", [instance_id])

          observe(
            txn,
            attempt_id,
            instance_id,
            at,
            "fenced-confirmation",
            "rejected-401",
            epoch_id,
            "http-401"
          )

          resolve_incident(txn, instance_id, "unconfirmed", at, "promoted")
          open_incident(txn, instance_id, "auth-dead", at, decision_id)
          decision_id
      end
    end)
    |> unwrap()
  end

  def own_park(db \\ DB, decision_id, at \\ now()) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "INSERT OR IGNORE INTO claude_auth_parks(decisionId,state,ownedAt) VALUES(?1,'owned',?2)",
        [decision_id, at]
      )

      Txn.q(
        txn,
        "UPDATE claude_auth_decisions SET projectionState='park_delivery',lastError=NULL WHERE id=?1 AND projectionState IN ('incident','metadata','park_ownership')",
        [decision_id]
      )

      :ok
    end)
    |> unwrap()
  end

  def complete_park(db \\ DB, decision_id, at \\ now()) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE claude_auth_parks SET state='complete',completedAt=COALESCE(completedAt,?2) WHERE decisionId=?1",
        [decision_id, at]
      )

      Txn.q(
        txn,
        "UPDATE claude_auth_decisions SET projectionState='complete',lastError=NULL WHERE id=?1",
        [decision_id]
      )

      :ok
    end)
    |> unwrap()
  end

  def advance_decision(db \\ DB, decision_id, step, error \\ nil)
      when step in ~w(incident metadata park_ownership park_delivery complete) do
    DB.transaction(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE claude_auth_decisions SET projectionState=?1,lastError=?2 WHERE id=?3",
        [step, redact(error), decision_id]
      )

      :ok
    end)
    |> unwrap()
  end

  def fail_decision(db \\ DB, decision_id, error) do
    DB.transaction(db, fn txn ->
      Txn.q(txn, "UPDATE claude_auth_decisions SET lastError=?1 WHERE id=?2", [
        redact(error),
        decision_id
      ])

      :ok
    end)
    |> unwrap()
  end

  @doc "Delivered work is positive only for the retained current logical instance."
  def observe_success(db \\ DB, host, instance_id, at \\ now()) do
    DB.transaction(db, &observe_success_in_txn(&1, host, instance_id, at))
    |> unwrap()
  end

  def observe_success_in_txn(%Txn{} = txn, host, instance_id, at \\ now()) do
    if current_instance(txn, host) == instance_id do
      attempts =
        Txn.q(
          txn,
          "SELECT id,epochId FROM claude_auth_attempts WHERE instanceId=?1 AND triggerAt<=?2 AND state IN ('pending_fence','fenced')",
          [instance_id, at]
        )

      Enum.each(attempts, fn [attempt_id, epoch_id] ->
        observe(
          txn,
          attempt_id,
          instance_id,
          at,
          "normal-turn",
          "service-observed",
          epoch_id,
          "delivered-turn"
        )
      end)

      Txn.q(
        txn,
        "UPDATE claude_auth_attempts SET state='stale',resultClass='normal-turn-success',finishedAt=?1 WHERE instanceId=?2 AND triggerAt<=?1 AND state IN ('pending_fence','fenced')",
        [at, instance_id]
      )

      resolve_incident(txn, instance_id, "unconfirmed", at, "normal-turn-success")
      :ok
    else
      :stale
    end
  end

  @doc "Admissions wait during a bounded attempt and fail after a terminal decision."
  def admission(db \\ DB, host, at \\ now()) do
    :ok = ensure_schema(db)

    {:ok, rows} =
      DB.transaction(db, fn txn ->
        expired =
          Txn.q(
            txn,
            "SELECT a.id,a.instanceId,a.epochId FROM claude_auth_attempts a JOIN claude_auth_instances i ON i.id=a.instanceId WHERE a.host=?1 AND i.state='current' AND a.state IN ('pending_fence','fenced') AND a.deadlineAt<=?2",
            [host, at]
          )

        Enum.each(expired, fn [attempt, instance, epoch] ->
          Txn.q(
            txn,
            "UPDATE claude_auth_attempts SET state='unknown',resultClass='unknown',reason='confirmation-deadline',finishedAt=?1 WHERE id=?2 AND state IN ('pending_fence','fenced')",
            [at, attempt]
          )

          observe(
            txn,
            attempt,
            instance,
            at,
            "confirmation",
            "unknown",
            epoch,
            "confirmation-deadline"
          )
        end)

        Txn.q(
          txn,
          "SELECT i.id, EXISTS(SELECT 1 FROM claude_auth_decisions d WHERE d.instanceId=i.id), EXISTS(SELECT 1 FROM claude_auth_attempts a WHERE a.instanceId=i.id AND a.state IN ('pending_fence','fenced')) FROM claude_auth_instances i WHERE i.host=?1 AND i.provider=?2 AND i.kind=?3 AND i.state='current'",
          [host, @provider, @kind]
        )
      end)

    case rows do
      [] -> :eligible
      [[_instance, 1, _]] -> :terminal
      [[_instance, 0, 1]] -> :held
      [[instance, 0, 0]] -> {:eligible, instance}
    end
  end

  def interrupted_attempts(db \\ DB, host, at \\ now()) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        rows =
          Txn.q(
            txn,
            "SELECT id,instanceId FROM claude_auth_attempts WHERE host=?1 AND state IN ('pending_fence','fenced')",
            [host]
          )

        Enum.map(rows, fn [id, instance] ->
          Txn.q(
            txn,
            "UPDATE claude_auth_attempts SET state='unknown',resultClass='interrupted',reason='process-restart',finishedAt=?1 WHERE id=?2",
            [at, id]
          )

          new_attempt(txn, host, instance, at)
        end)
      end)

    result
  end

  def pending_decisions(db \\ DB, host) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT d.id,d.projectionState,d.lastError FROM claude_auth_decisions d JOIN claude_auth_instances i ON i.id=d.instanceId WHERE i.host=?1 AND i.state='current' AND d.projectionState!='complete' ORDER BY d.decidedAt",
        [host]
      )

    Enum.map(rows, fn [id, step, error] -> %{id: id, step: step, error: error} end)
  end

  @doc "True only while a decision belongs to the current logical credential instance."
  def current_decision?(db \\ DB, decision_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT 1 FROM claude_auth_decisions d JOIN claude_auth_instances i ON i.id=d.instanceId WHERE d.id=?1 AND i.state='current' AND d.projectionState!='complete' LIMIT 1",
        [decision_id]
      )

    rows == [[1]]
  end

  defp ensure_instance_in_txn(txn, host, at) do
    case current_instance(txn, host) do
      nil ->
        id = Id.uuid4()

        Txn.q(
          txn,
          "INSERT INTO claude_auth_instances(id,host,provider,kind,state,activatedAt) VALUES(?1,?2,?3,?4,'current',?5)",
          [id, host, @provider, @kind, at]
        )

        id

      id ->
        id
    end
  end

  defp current_instance(txn, host) do
    case Txn.q(
           txn,
           "SELECT id FROM claude_auth_instances WHERE host=?1 AND provider=?2 AND kind=?3 AND state='current'",
           [host, @provider, @kind]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp new_attempt(txn, host, instance, at) do
    id = Id.uuid4()

    Txn.q(
      txn,
      "INSERT INTO claude_auth_attempts(id,instanceId,host,triggerAt,deadlineAt,state) VALUES(?1,?2,?3,?4,?5,'pending_fence')",
      [id, instance, host, at, at + 10_000]
    )

    id
  end

  defp active_attempt(txn, host, instance) do
    case Txn.q(
           txn,
           "SELECT id FROM claude_auth_attempts WHERE host=?1 AND instanceId=?2 AND state IN ('pending_fence','fenced')",
           [host, instance]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  defp attempt_host(txn, id) do
    case Txn.q(txn, "SELECT host FROM claude_auth_attempts WHERE id=?1", [id]) do
      [[host]] -> host
      [] -> nil
    end
  end

  defp attempt_row(txn, id) do
    case Txn.q(
           txn,
           "SELECT host,instanceId,state,epochId FROM claude_auth_attempts WHERE id=?1",
           [id]
         ) do
      [[host, instance, state, epoch]] ->
        %{host: host, instance_id: instance, state: state, epoch_id: epoch}

      [] ->
        nil
    end
  end

  defp observe(txn, attempt, instance, at, source, class, epoch, reason) do
    Txn.q(
      txn,
      "INSERT INTO claude_auth_observations(id,attemptId,instanceId,observedAt,source,resultClass,epochId,reason) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
      [Id.uuid4(), attempt, instance, at, source, class, epoch, redact(reason)]
    )
  end

  defp open_incident(txn, instance, class, at, decision) do
    Txn.q(
      txn,
      "INSERT OR IGNORE INTO claude_auth_incidents(id,instanceId,class,state,openedAt,decisionId) VALUES(?1,?2,?3,'open',?4,?5)",
      [Id.uuid4(), instance, class, at, decision]
    )
  end

  defp resolve_incident(txn, instance, class, at, resolution) do
    Txn.q(
      txn,
      "UPDATE claude_auth_incidents SET state='resolved',resolvedAt=?1,resolution=?2 WHERE instanceId=?3 AND class=?4 AND state='open'",
      [at, resolution, instance, class]
    )
  end

  defp redact(nil), do: nil
  defp redact(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp redact(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp redact(_reason), do: "unavailable"
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: {:error, error}
  defp now, do: System.system_time(:millisecond)
end
