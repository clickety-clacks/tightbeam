defmodule Tightbeam.GithubCredentials do
  @moduledoc """
  The first-class GitHub credential kind.

  GitHub CLI owns every secret under one profile home. This module resolves
  that home, validates only filesystem metadata, projects its path, and owns
  the two non-secret database seams: profile bindings and capability
  observations. It never opens `hosts.yml` and it has no byte-storage API.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Id

  @profile ~r/^[a-z0-9][a-z0-9-]{0,62}$/
  @binding_states ~w(
    missing_cli needs_onboarding hollow live expired insufficient_scope
    git_unready revoked present_but_unverified unknown
  )
  @observation_states ~w(
    profile_not_elected missing_cli needs_onboarding hollow live expired
    insufficient_scope git_unready revoked present_but_unverified unknown
    ambiguous_hostname projection_override malformed_tool_call rule_runtime_failure
    inert_legacy_residue
  )
  @operation_classes ~w(malformed gh git onboarding rotation revocation migration health)
  @attempts ~w(onboarding rotation revocation)

  @ddl """
  CREATE TABLE IF NOT EXISTS github_profile_bindings (
    machine       TEXT NOT NULL CHECK(length(trim(machine)) > 0),
    profile       TEXT NOT NULL CHECK(length(profile) BETWEEN 1 AND 63),
    hostname      TEXT NOT NULL CHECK(length(trim(hostname)) > 0),
    account       TEXT,
    state         TEXT NOT NULL CHECK(state IN (
                    'missing_cli','needs_onboarding','hollow','live','expired',
                    'insufficient_scope','git_unready','revoked',
                    'present_but_unverified','unknown'
                  )),
    mutationAttempt TEXT CHECK(mutationAttempt IN ('onboarding','rotation','revocation')),
    principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    createdAt     INTEGER NOT NULL CHECK(createdAt >= 0),
    updatedAt     INTEGER NOT NULL CHECK(updatedAt >= createdAt),
    PRIMARY KEY (machine, profile, hostname)
  );
  CREATE INDEX IF NOT EXISTS github_profile_bindings_machine_hostname
    ON github_profile_bindings (machine, hostname);

  CREATE TABLE IF NOT EXISTS github_capability_observations (
    id             TEXT PRIMARY KEY,
    dedupeKey      TEXT UNIQUE,
    kind           TEXT NOT NULL CHECK(kind = 'github'),
    machine        TEXT NOT NULL CHECK(length(trim(machine)) > 0),
    profile        TEXT,
    hostname       TEXT,
    account        TEXT,
    state          TEXT NOT NULL CHECK(state IN (
                     'profile_not_elected','missing_cli','needs_onboarding','hollow',
                     'live','expired','insufficient_scope','git_unready','revoked',
                     'present_but_unverified','unknown','ambiguous_hostname',
                     'projection_override','malformed_tool_call','rule_runtime_failure',
                     'inert_legacy_residue'
                   )),
    cause          TEXT NOT NULL CHECK(length(trim(cause)) > 0),
    principal      TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    operationClass TEXT NOT NULL CHECK(operationClass IN (
                     'malformed','gh','git','onboarding','rotation','revocation',
                     'migration','health'
                   )),
    phase          TEXT NOT NULL CHECK(length(trim(phase)) > 0),
    ruleName       TEXT,
    protocol       TEXT,
    sanitizedRemote TEXT,
    observedAt     INTEGER NOT NULL CHECK(observedAt >= 0)
  );
  CREATE INDEX IF NOT EXISTS github_capability_observations_lookup
    ON github_capability_observations (machine, profile, hostname, observedAt, id);

  CREATE TRIGGER IF NOT EXISTS github_capability_observations_append_only_update
  BEFORE UPDATE ON github_capability_observations
  BEGIN
    SELECT RAISE(ABORT, 'github capability observations are append-only');
  END;

  CREATE TRIGGER IF NOT EXISTS github_capability_observations_append_only_delete
  BEFORE DELETE ON github_capability_observations
  BEGIN
    SELECT RAISE(ABORT, 'github capability observations are append-only');
  END;
  """

  @type binding :: %{
          machine: String.t(),
          profile: String.t(),
          hostname: String.t(),
          account: String.t() | nil,
          state: String.t(),
          mutation_attempt: String.t() | nil,
          principal: String.t(),
          created_at: non_neg_integer(),
          updated_at: non_neg_integer()
        }

  @doc false
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Validate one explicit, non-secret credential profile."
  @spec validate_profile!(term()) :: String.t()
  def validate_profile!(profile) when is_binary(profile) do
    if Regex.match?(@profile, profile) do
      profile
    else
      raise ArgumentError,
            "invalid GitHub credential profile #{inspect(profile)}; expected #{@profile.source}"
    end
  end

  def validate_profile!(profile) do
    raise ArgumentError,
          "invalid GitHub credential profile #{inspect(profile)}; expected #{@profile.source}"
  end

  @doc "Resolve the sole provider-owned home for `{machine, profile}`."
  @spec home(String.t(), String.t(), String.t()) :: String.t()
  def home(base_dir, machine, profile) do
    validate_machine!(machine)
    validate_profile!(profile)
    Path.join([base_dir, "credential-homes", machine, "github", profile])
  end

  @doc "Return the path-only projection for one explicit election."
  @spec projection(String.t(), String.t(), String.t()) :: [{String.t(), String.t()}]
  def projection(base_dir, machine, profile) do
    [
      {"TIGHTBEAM_GITHUB_PROFILE", validate_profile!(profile)},
      {"GH_CONFIG_DIR", home(base_dir, machine, profile)}
    ]
  end

  @doc "Enumerate provider secret paths without opening either path."
  @spec secret_paths(String.t()) :: [String.t()]
  def secret_paths(home) when is_binary(home), do: [Path.join(home, "hosts.yml")]

  @doc "Inspect only metadata for the inert 0.1 residue; never open or mutate it."
  @spec inert_legacy_residue(String.t()) :: :absent | {:present, map()} | {:unknown, atom()}
  def inert_legacy_residue(base_dir) do
    path = Path.join([base_dir, "auth", "github", "gh"])

    case File.lstat(path) do
      {:ok, stat} ->
        {:present, %{type: stat.type, mode: Bitwise.band(stat.mode, 0o777), size: stat.size}}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  @doc "Validate provider-home metadata without reading secret bytes."
  @spec storage(String.t()) :: :absent | :valid | {:hollow, String.t()}
  def storage(home) when is_binary(home) do
    hosts = Path.join(home, "hosts.yml")

    with {:home, {:ok, home_stat}} <- {:home, File.lstat(home)},
         :ok <- private_directory(home_stat, "credential home"),
         :ok <- private_credential_ancestors(home),
         {:hosts, {:ok, hosts_stat}} <- {:hosts, File.lstat(hosts)},
         :ok <- private_regular_file(hosts_stat) do
      :valid
    else
      {:home, {:error, :enoent}} -> :absent
      {:hosts, {:error, :enoent}} -> :absent
      {:home, {:error, reason}} -> {:hollow, "credential_home_lstat_#{reason}"}
      {:hosts, {:error, reason}} -> {:hollow, "hosts_yml_lstat_#{reason}"}
      {:error, cause} -> {:hollow, cause}
    end
  end

  defp private_credential_ancestors(home) do
    home
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take(4)
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      case File.lstat(directory) do
        {:ok, stat} ->
          case private_directory(stat, "credential home ancestor") do
            :ok -> {:cont, :ok}
            {:error, cause} -> {:halt, {:error, cause}}
          end

        {:error, reason} ->
          {:halt, {:error, "credential_home_ancestor_lstat_#{reason}"}}
      end
    end)
  end

  @doc "Return the machine-wide configured-hostname recognition index."
  @spec hostname_index(DB.server(), String.t()) :: MapSet.t(String.t())
  def hostname_index(db \\ DB, machine) do
    validate_machine!(machine)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT hostname FROM github_profile_bindings WHERE machine = ?1 ORDER BY hostname",
        [machine]
      )

    rows |> Enum.map(&hd/1) |> MapSet.new()
  end

  @doc "Read one elected-profile binding."
  @spec binding(DB.server(), String.t(), String.t(), String.t()) :: binding() | nil
  def binding(db \\ DB, machine, profile, hostname) do
    validate_machine!(machine)
    validate_profile!(profile)
    hostname = normalize_hostname!(hostname)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT machine, profile, hostname, account, state, mutationAttempt,
               principal, createdAt, updatedAt
        FROM github_profile_bindings
        WHERE machine = ?1 AND profile = ?2 AND hostname = ?3
        """,
        [machine, profile, hostname]
      )

    case rows do
      [row] -> binding_row(row)
      [] -> nil
    end
  end

  @doc "Create or update one non-secret profile binding through its sole mutation seam."
  @spec upsert_binding(DB.server(), map()) :: {:ok, binding()} | {:error, Exception.t()}
  def upsert_binding(db \\ DB, attrs) do
    DB.transaction(db, fn txn -> upsert_binding_in_txn(txn, attrs) end)
  end

  @doc "Begin one serialized provider mutation while preserving prior observed state."
  @spec begin_mutation(DB.server(), map()) :: {:ok, binding()} | {:error, Exception.t()}
  def begin_mutation(db \\ DB, attrs) do
    DB.transaction(db, fn txn ->
      machine = attrs |> fetch_string!(:machine) |> validate_machine!()
      profile = attrs |> fetch_string!(:profile) |> validate_profile!()
      hostname = attrs |> fetch_string!(:hostname) |> normalize_hostname!()
      principal = fetch_string!(attrs, :principal)
      attempt = attrs |> fetch_string!(:mutation_attempt) |> member!(@attempts, :mutation_attempt)

      prior =
        case Txn.q(
               txn,
               "SELECT account, state FROM github_profile_bindings WHERE machine=?1 AND profile=?2 AND hostname=?3",
               [machine, profile, hostname]
             ) do
          [[account, state]] -> %{account: account, state: state}
          [] -> %{account: nil, state: "needs_onboarding"}
        end

      upsert_binding_in_txn(txn, %{
        machine: machine,
        profile: profile,
        hostname: hostname,
        account: prior.account,
        state: prior.state,
        mutation_attempt: attempt,
        principal: principal
      })
    end)
  end

  @doc "Append one non-secret capability observation through its sole event seam."
  @spec append_observation(DB.server(), map()) :: {:ok, map()} | {:error, Exception.t()}
  def append_observation(db \\ DB, attrs) do
    DB.transaction(db, fn txn -> append_observation_in_txn(txn, attrs) end)
  end

  @doc "Commit one provider mutation result and its observation atomically."
  @spec commit_outcome(DB.server(), map(), map()) ::
          {:ok, %{binding: binding(), observation: map()}} | {:error, Exception.t()}
  def commit_outcome(db \\ DB, binding_attrs, observation_attrs) do
    DB.transaction(db, fn txn ->
      binding = upsert_binding_in_txn(txn, binding_attrs)
      observation = append_observation_in_txn(txn, observation_attrs)
      %{binding: binding, observation: observation}
    end)
  end

  @doc false
  def normalize_hostname!(hostname) when is_binary(hostname) do
    hostname = hostname |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if hostname != "" and
         Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$/, hostname) and
         not String.contains?(hostname, "..") do
      hostname
    else
      raise ArgumentError, "invalid GitHub hostname #{inspect(hostname)}"
    end
  end

  def normalize_hostname!(hostname),
    do: raise(ArgumentError, "invalid GitHub hostname #{inspect(hostname)}")

  defp upsert_binding_in_txn(%Txn{} = txn, attrs) do
    machine = attrs |> fetch_string!(:machine) |> validate_machine!()
    profile = attrs |> fetch_string!(:profile) |> validate_profile!()
    hostname = attrs |> fetch_string!(:hostname) |> normalize_hostname!()
    state = attrs |> fetch_string!(:state) |> member!(@binding_states, :state)
    attempt = Map.get(attrs, :mutation_attempt)
    if attempt, do: member!(attempt, @attempts, :mutation_attempt)
    principal = fetch_string!(attrs, :principal)
    account = optional_string(attrs, :account)
    now = Map.get(attrs, :at, System.system_time(:millisecond))

    Txn.q(
      txn,
      """
      INSERT INTO github_profile_bindings
        (machine, profile, hostname, account, state, mutationAttempt,
         principal, createdAt, updatedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
      ON CONFLICT(machine, profile, hostname) DO UPDATE SET
        account = excluded.account,
        state = excluded.state,
        mutationAttempt = excluded.mutationAttempt,
        principal = excluded.principal,
        updatedAt = excluded.updatedAt
      """,
      [machine, profile, hostname, account, state, attempt, principal, now]
    )

    [
      [
        row_machine,
        row_profile,
        row_hostname,
        row_account,
        row_state,
        row_attempt,
        row_principal,
        created_at,
        updated_at
      ]
    ] =
      Txn.q(
        txn,
        """
        SELECT machine, profile, hostname, account, state, mutationAttempt,
               principal, createdAt, updatedAt
        FROM github_profile_bindings
        WHERE machine = ?1 AND profile = ?2 AND hostname = ?3
        """,
        [machine, profile, hostname]
      )

    binding_row([
      row_machine,
      row_profile,
      row_hostname,
      row_account,
      row_state,
      row_attempt,
      row_principal,
      created_at,
      updated_at
    ])
  end

  defp append_observation_in_txn(%Txn{} = txn, attrs) do
    id = Map.get(attrs, :id, "gco_" <> Id.uuid4())
    machine = attrs |> fetch_string!(:machine) |> validate_machine!()
    profile = optional_profile(attrs)
    hostname = optional_hostname(attrs)
    state = attrs |> fetch_string!(:state) |> member!(@observation_states, :state)
    cause = fetch_string!(attrs, :cause)
    principal = fetch_string!(attrs, :principal)

    operation_class =
      attrs |> fetch_string!(:operation_class) |> member!(@operation_classes, :operation_class)

    phase = fetch_string!(attrs, :phase)
    observed_at = Map.get(attrs, :observed_at, System.system_time(:millisecond))
    dedupe_key = optional_string(attrs, :dedupe_key)

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO github_capability_observations
        (id, dedupeKey, kind, machine, profile, hostname, account, state, cause,
         principal, operationClass, phase, ruleName, protocol, sanitizedRemote, observedAt)
      VALUES (?1, ?2, 'github', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
      """,
      [
        id,
        dedupe_key,
        machine,
        profile,
        hostname,
        optional_string(attrs, :account),
        state,
        cause,
        principal,
        operation_class,
        phase,
        optional_string(attrs, :rule),
        optional_string(attrs, :protocol),
        optional_string(attrs, :sanitized_remote),
        observed_at
      ]
    )

    selected_id =
      if dedupe_key do
        [[existing]] =
          Txn.q(
            txn,
            "SELECT id FROM github_capability_observations WHERE dedupeKey = ?1",
            [dedupe_key]
          )

        existing
      else
        id
      end

    %{id: selected_id, observed_at: observed_at, state: state}
  end

  defp binding_row([
         machine,
         profile,
         hostname,
         account,
         state,
         attempt,
         principal,
         created_at,
         updated_at
       ]) do
    %{
      machine: machine,
      profile: profile,
      hostname: hostname,
      account: account,
      state: state,
      mutation_attempt: attempt,
      principal: principal,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp private_directory(%File.Stat{type: :directory, mode: mode}, label) do
    if private_mode?(mode), do: :ok, else: {:error, "#{label}_permissions"}
  end

  defp private_directory(%File.Stat{}, label), do: {:error, "#{label}_not_directory"}

  defp private_regular_file(%File.Stat{type: :regular, mode: mode, size: size, links: links}) do
    cond do
      size == 0 -> {:error, "hosts_yml_empty"}
      not private_mode?(mode) -> {:error, "hosts_yml_permissions"}
      links != 1 -> {:error, "hosts_yml_link_count"}
      true -> :ok
    end
  end

  defp private_regular_file(%File.Stat{}), do: {:error, "hosts_yml_not_regular"}

  defp private_mode?(mode), do: Bitwise.band(mode, 0o077) == 0

  defp validate_machine!(machine) when is_binary(machine) do
    if machine != "" and machine not in [".", ".."] and
         not String.contains?(machine, ["/", "\\", <<0>>]) do
      machine
    else
      raise ArgumentError, "invalid registered machine #{inspect(machine)}"
    end
  end

  defp validate_machine!(machine),
    do: raise(ArgumentError, "invalid registered machine #{inspect(machine)}")

  defp optional_profile(attrs) do
    case Map.get(attrs, :profile) do
      nil -> nil
      profile -> validate_profile!(profile)
    end
  end

  defp optional_hostname(attrs) do
    case Map.get(attrs, :hostname) do
      nil -> nil
      hostname -> normalize_hostname!(hostname)
    end
  end

  defp fetch_string!(attrs, key) do
    case Map.fetch!(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError, "#{key} must be nil or a non-empty string, got: #{inspect(value)}"
    end
  end

  defp member!(value, allowed, field) do
    if value in allowed do
      value
    else
      raise ArgumentError, "invalid GitHub #{field}: #{inspect(value)}"
    end
  end
end
