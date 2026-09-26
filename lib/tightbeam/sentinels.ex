defmodule Tightbeam.Sentinels do
  @moduledoc """
  Sentinels: long-running programs a learned kungfu bundle declares and the gateway
  supervises on its own host.

  A bundle declares each sentinel in its manifest (`[[sentinels]]` with `name`,
  `command` and `requires`). The sentinel's qualified name is `<bundle>/<name>`.
  Its settings live in the overlay table under the scope `sentinel:<bundle>/<name>`
  on the gateway's host; its durable run state lives in `sentinel_states`. A missing
  state row means disabled. None of this is a harness, a projection or a firehose
  resource.

  `setup/4` is the one computation behind `learn`, `kungfu setup` and `doctor`:
  the bundle's `setup.md` text and the list of what remains before each declared
  sentinel runs. An empty list means every declared sentinel is configured and
  enabled. The computation starts nothing.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Identity
  alias Tightbeam.Placement

  @states_ddl """
  CREATE TABLE IF NOT EXISTS sentinel_states (
    host          TEXT NOT NULL,
    sentinel      TEXT NOT NULL,
    state         TEXT NOT NULL CHECK (state IN ('enabled', 'disabled', 'stopped')),
    enabledBy     TEXT,
    commandSha256 TEXT,
    startedAt     INTEGER,
    reason        TEXT,
    updatedAt     INTEGER NOT NULL,
    PRIMARY KEY (host, sentinel)
  )
  """

  @doc "Create the sentinel state table."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @states_ddl)

  @doc "The overlay scope that holds one sentinel's settings."
  @spec scope(String.t()) :: String.t()
  def scope(qualified), do: "sentinel:" <> qualified

  @doc """
  Resolve a sentinel reference against the published identity.

  A qualified `<bundle>/<name>` must name a learned sentinel. A bare name resolves
  only when exactly one learned bundle declares it; otherwise the refusal lists
  every qualified candidate.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def resolve(base_dir, reference) when is_binary(reference) do
    %{revision: revision, sentinels: sentinels} = Identity.learned_sentinels(base_dir)

    matches =
      if String.contains?(reference, "/"),
        do: Enum.filter(sentinels, &(&1.qualified == reference)),
        else: Enum.filter(sentinels, &(&1.name == reference))

    case matches do
      [sentinel] ->
        {:ok, Map.put(sentinel, :revision, revision)}

      [] ->
        {:error,
         %{
           code: "unknown_sentinel",
           message:
             "unknown_sentinel rule: no learned bundle declares sentinel #{reference}; " <>
               "learned sentinels: " <> names_or_none(Enum.map(sentinels, & &1.qualified))
         }}

      several ->
        {:error,
         %{
           code: "ambiguous_sentinel",
           message:
             "ambiguous_sentinel rule: #{reference} names several sentinels; use one of: " <>
               Enum.map_join(several, ", ", & &1.qualified)
         }}
    end
  end

  def resolve(_base_dir, reference) do
    {:error,
     %{
       code: "unknown_sentinel",
       message: "unknown_sentinel rule: #{inspect(reference)} is not a name"
     }}
  end

  @doc "Every durable state row on `host`, keyed by qualified name."
  @spec states(DB.server(), String.t()) :: %{optional(String.t()) => map()}
  def states(db, host) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sentinel, state, enabledBy, commandSha256, startedAt, reason, updatedAt
        FROM sentinel_states WHERE host = ?1 ORDER BY sentinel
        """,
        [host]
      )

    Map.new(rows, fn [sentinel, state, enabled_by, sha, started_at, reason, updated_at] ->
      {sentinel,
       %{
         state: state,
         enabled_by: enabled_by,
         command_sha256: sha,
         started_at: started_at,
         reason: reason,
         updated_at: updated_at
       }}
    end)
  end

  @doc "The names among `requires` with no value in the sentinel's scope on `host`."
  @spec missing_settings(DB.server(), String.t(), map()) :: [String.t()]
  def missing_settings(db, host, sentinel) do
    present =
      db |> Placement.env_overlays(host, scope(sentinel.qualified)) |> MapSet.new(& &1.name)

    Enum.reject(sentinel.requires, &MapSet.member?(present, &1))
  end

  @doc "The sentinel's own settings on `host`, as name/value pairs."
  @spec settings(DB.server(), String.t(), String.t()) :: [{String.t(), String.t()}]
  def settings(db, host, qualified) do
    db |> Placement.env_overlays(host, scope(qualified)) |> Enum.map(&{&1.name, &1.value})
  end

  @doc """
  Record `enabled` for a resolved sentinel. Refuses while any required setting is
  missing, naming each missing name and the command that sets it. Presence only:
  the values themselves are the sentinel's to judge.
  """
  @spec enable(DB.server(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def enable(db, host, sentinel, principal) do
    case missing_settings(db, host, sentinel) do
      [] ->
        :ok = put_state(db, host, sentinel.qualified, "enabled", enabled_by: principal)
        {:ok, %{sentinel: sentinel.qualified, host: host, state: "enabled"}}

      missing ->
        {:error,
         %{
           code: "sentinel_settings_missing",
           message:
             "sentinel_settings_missing rule: #{sentinel.qualified} requires " <>
               Enum.join(missing, ", ") <>
               " on #{host}; set each with: " <>
               Enum.map_join(missing, "; ", &set_command(sentinel.qualified, &1)),
           missing: missing
         }}
    end
  end

  @doc "Record `disabled` for a resolved sentinel."
  @spec disable(DB.server(), String.t(), map()) :: {:ok, map()}
  def disable(db, host, sentinel) do
    :ok = put_state(db, host, sentinel.qualified, "disabled")
    {:ok, %{sentinel: sentinel.qualified, host: host, state: "disabled"}}
  end

  @doc "Record that an enabled sentinel was stopped by supervision, with its reason."
  @spec mark_stopped(DB.server(), String.t(), String.t(), String.t()) :: :ok
  def mark_stopped(db, host, qualified, reason) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          UPDATE sentinel_states SET state = 'stopped', reason = ?3, updatedAt = ?4
          WHERE host = ?1 AND sentinel = ?2 AND state = 'enabled'
          """,
          [host, qualified, reason, now()]
        )

        :ok
      end)

    :ok
  end

  @doc "Record the command bytes an enabled sentinel was started from."
  @spec mark_started(DB.server(), String.t(), String.t(), String.t(), integer()) :: :ok
  def mark_started(db, host, qualified, sha256, started_at) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          UPDATE sentinel_states SET commandSha256 = ?3, startedAt = ?4, updatedAt = ?4
          WHERE host = ?1 AND sentinel = ?2 AND state = 'enabled'
          """,
          [host, qualified, sha256, started_at]
        )

        :ok
      end)

    :ok
  end

  @doc "Forget every state row and setting of one bundle's sentinels on `host`."
  @spec remove_bundle(DB.server(), String.t(), String.t()) :: :ok
  def remove_bundle(db, host, bundle) do
    prefix = bundle <> "/"

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "DELETE FROM sentinel_states WHERE host = ?1 AND substr(sentinel, 1, ?2) = ?3",
          [host, String.length(prefix), prefix]
        )

        Placement.delete_bundle_sentinel_env(txn, host, bundle)
      end)

    :ok
  end

  @doc """
  The setup computation for one bundle on `host`: its published `setup.md` text and
  what remains before each sentinel it declares runs. Starts nothing.
  """
  @spec setup(String.t(), DB.server(), String.t(), String.t()) :: map()
  def setup(base_dir, db, host, bundle) do
    source = Identity.bundle_setup_source(base_dir, bundle)
    %{sentinels: learned} = Identity.learned_sentinels(base_dir)
    learned = Enum.filter(learned, &(&1.bundle == bundle))
    states = states(db, host)
    learned_names = Enum.map(learned, & &1.name)

    not_installed =
      if source.learned do
        for name <- source.shipped_sentinels, name not in learned_names do
          %{
            sentinel: "#{bundle}/#{name}",
            state: "not-installed",
            action: "run: tightbeam identity relearn"
          }
        end
      else
        []
      end

    pending =
      Enum.flat_map(learned, fn sentinel ->
        state = states |> Map.get(sentinel.qualified, %{}) |> Map.get(:state, "disabled")
        missing = missing_settings(db, host, sentinel)
        setting_items(sentinel, missing) ++ state_item(sentinel, state, states)
      end)

    %{
      bundle: bundle,
      host: host,
      learned: source.learned,
      setup_text: source.setup_text,
      sentinels: Enum.map(learned, & &1.qualified),
      pending: not_installed ++ pending
    }
  end

  @doc "The setup computation for every learned bundle that declares a sentinel."
  @spec setup_all(String.t(), DB.server(), String.t()) :: [map()]
  def setup_all(base_dir, db, host) do
    %{sentinels: learned} = Identity.learned_sentinels(base_dir)

    learned
    |> Enum.map(& &1.bundle)
    |> Enum.uniq()
    |> Enum.map(&setup(base_dir, db, host, &1))
  end

  defp setting_items(sentinel, missing) do
    Enum.map(missing, fn name ->
      %{
        sentinel: sentinel.qualified,
        state: "setting-missing",
        setting: name,
        action: "run: " <> set_command(sentinel.qualified, name)
      }
    end)
  end

  defp state_item(_sentinel, "enabled", _states), do: []

  defp state_item(sentinel, "stopped", states) do
    [
      %{
        sentinel: sentinel.qualified,
        state: "stopped",
        reason: states[sentinel.qualified].reason,
        action: "run: tightbeam sentinel enable #{sentinel.qualified}"
      }
    ]
  end

  defp state_item(sentinel, "disabled", _states) do
    [
      %{
        sentinel: sentinel.qualified,
        state: "disabled",
        action: "run: tightbeam sentinel enable #{sentinel.qualified}"
      }
    ]
  end

  defp set_command(qualified, name),
    do: "tightbeam host-env-set --sentinel #{qualified} #{name}=<value>"

  defp put_state(db, host, qualified, state, opts \\ []) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO sentinel_states (host, sentinel, state, enabledBy, updatedAt)
          VALUES (?1, ?2, ?3, ?4, ?5)
          ON CONFLICT(host, sentinel) DO UPDATE SET
            state = excluded.state,
            enabledBy = COALESCE(excluded.enabledBy, sentinel_states.enabledBy),
            reason = NULL,
            updatedAt = excluded.updatedAt
          """,
          [host, qualified, state, Keyword.get(opts, :enabled_by), now()]
        )

        :ok
      end)

    :ok
  end

  defp names_or_none([]), do: "none"
  defp names_or_none(names), do: Enum.join(names, ", ")

  defp now, do: System.system_time(:millisecond)
end
