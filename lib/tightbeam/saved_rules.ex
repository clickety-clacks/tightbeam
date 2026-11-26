defmodule Tightbeam.SavedRules do
  @moduledoc false

  alias Tightbeam.{DB, FeatureFlags, RailScope, Rules, SubtreeScope}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS saved_rules (
    revision INTEGER PRIMARY KEY,
    role TEXT NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('rule','reaction','reminder')),
    definition TEXT NOT NULL,
    contentSha256 TEXT NOT NULL,
    checkBytesBase64 TEXT,
    authoredBy TEXT NOT NULL REFERENCES sessions(sessionKey),
    authoredAt INTEGER NOT NULL,
    endedAt INTEGER,
    endedBy TEXT REFERENCES sessions(sessionKey)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS saved_rules_current
    ON saved_rules(role, name) WHERE endedAt IS NULL;
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  def command(db, verb, call) do
    if FeatureFlags.subtree_rules?() do
      {:ok, result} = DB.transaction(db, &execute(&1, verb, call))
      result
    else
      %{code: "feature_disabled", message: "saved rules require subtree_rules"}
    end
  end

  defp execute(txn, "rule-set", %{principal: principal, params: params}) do
    role = params[:role]

    with {:ok, author} <- active_holder(txn, principal, role),
         {:ok, entries, hash} <- validate(role, params[:toml]) do
      now = System.system_time(:millisecond)

      rules =
        Enum.map(entries, fn {name, kind, definition, bytes} ->
          end_current(txn, role, name, author, now)

          [[revision]] =
            Txn.q(
              txn,
              """
              INSERT INTO saved_rules(role,name,kind,definition,contentSha256,authoredBy,authoredAt,checkBytesBase64)
              VALUES(?1,?2,?3,?4,?5,?6,?7,?8) RETURNING revision
              """,
              [role, name, kind, definition, hash, author, now, bytes]
            )

          %{name: name, kind: kind, revision: revision, content_sha256: hash}
        end)

      %{role: role, rules: rules}
    else
      {:error, error} -> error
    end
  end

  defp execute(txn, "rule-withdraw", %{principal: principal, params: params}) do
    role = params[:role]
    name = params[:name]

    with {:ok, author} <- active_holder(txn, principal, role) do
      case end_current(txn, role, name, author, System.system_time(:millisecond)) do
        [[revision]] -> %{role: role, name: name, withdrawn_revision: revision}
        [] -> %{code: "not_found", message: "no active saved rule named #{inspect(name)}"}
      end
    else
      {:error, error} -> error
    end
  end

  defp execute(txn, "rule-show", %{params: params}) do
    %{rules: show(txn, params[:role], params[:session_key])}
  end

  defp active_holder(txn, {:session, author}, role) when is_binary(author) and is_binary(role) do
    if SubtreeScope.anchor_holder(txn, role) == author do
      {:ok, author}
    else
      {:error,
       %{code: "denied", message: "only the current active holder of #{role} may edit its rules"}}
    end
  end

  defp active_holder(_txn, _principal, _role),
    do:
      {:error,
       %{
         code: "denied",
         message: "editing a saved rule requires the role's active session holder"
       }}

  defp validate(role, toml) when is_binary(toml) do
    hash = Base.encode16(:crypto.hash(:sha256, toml), case: :lower)

    with {:ok, manifest} <- Toml.decode(toml),
         entries <- entries!(role, manifest) do
      compiled =
        Enum.map(entries, fn {name, kind, definition} ->
          encoded = JSON.encode!(definition)
          rule = Rules.compile_saved!(role, kind, JSON.decode!(encoded), hash)
          {{name, kind, encoded, check_bytes(rule)}, rule}
        end)

      statutes = for {{_, "rule", _, _}, rule} <- compiled, do: rule
      if statutes != [], do: Rules.validate_saved_statutes!(statutes)

      {:ok, Enum.map(compiled, &elem(&1, 0)), hash}
    else
      {:error, reason} -> invalid("invalid TOML: #{inspect(reason)}")
    end
  rescue
    error in [ArgumentError, File.Error] -> invalid(Exception.message(error))
  end

  defp validate(_role, _toml), do: invalid("expected TOML text")

  defp check_bytes(%{check: %{identity_path: path}, base_dir: base_dir}) do
    [base_dir, "identity", path]
    |> Path.join()
    |> File.read!()
    |> Base.encode64()
  end

  defp check_bytes(_rule), do: nil

  defp invalid(message), do: {:error, %{code: "invalid_saved_rule", message: message}}

  defp entries!(role, manifest) when map_size(manifest) > 0 do
    scope = %{"subtree_of" => "role:" <> role}

    entries =
      for {kind, definitions} <- Enum.sort(manifest),
          definition <- definitions!(kind, definitions) do
        unless is_map(definition) and Map.get(definition, "scope", scope) == scope do
          raise ArgumentError, "saved rules must use their own role's subtree"
        end

        name = definition["name"]

        unless is_binary(name) and String.trim(name) != "" do
          raise ArgumentError, "each saved rule must have a name"
        end

        {name, kind, Map.put(definition, "scope", scope)}
      end

    names = Enum.map(entries, &elem(&1, 0))
    if Enum.uniq(names) != names, do: raise(ArgumentError, "duplicate saved rule names")
    entries
  end

  defp entries!(_role, _manifest), do: raise(ArgumentError, "expected at least one saved rule")

  defp definitions!(kind, entries)
       when kind in ["rule", "reaction", "reminder"] and is_list(entries) and entries != [],
       do: entries

  defp definitions!(kind, _entries),
    do: raise(ArgumentError, "unsupported saved-rule section or empty entries: #{inspect(kind)}")

  defp end_current(txn, role, name, author, now) do
    Txn.q(
      txn,
      """
      UPDATE saved_rules SET endedAt=?3,endedBy=?4
      WHERE role=?1 AND name=?2 AND endedAt IS NULL RETURNING revision
      """,
      [role, name, now, author]
    )
  end

  def compiled(db, kind, verb \\ nil) do
    if FeatureFlags.subtree_rules?() do
      rows(db, kind, verb)
      |> Enum.map(fn [role, _, entry_kind, definition, hash, revision, _, _, bytes] ->
        compile_row(role, entry_kind, definition, hash, revision, bytes)
      end)
    else
      []
    end
  end

  def anchored_to(txn, keys) do
    if FeatureFlags.subtree_rules?() and keys != [] do
      Txn.q(
        txn,
        """
        SELECT s.role, s.name FROM saved_rules s
        JOIN roles r ON r.name=s.role
        WHERE s.endedAt IS NULL AND r.boundSessionKey IN (SELECT value FROM json_each(?1))
        ORDER BY s.role,s.name
        """,
        [JSON.encode!(keys)]
      )
      |> Enum.map(fn [role, name] -> %{role: role, name: name} end)
    else
      []
    end
  end

  defp show(txn, role, session) do
    lineage = if is_binary(session), do: SubtreeScope.lineage(txn, session), else: []

    for [anchor, name, kind, definition, hash, revision, author, at, bytes] <- rows(txn, nil),
        is_nil(role) or role == anchor,
        holder <- [SubtreeScope.anchor_holder(txn, anchor)],
        is_nil(session) or is_nil(holder) or
          (holder in lineage and
             audience_matches?(
               txn,
               session,
               compile_row(anchor, kind, definition, hash, revision, bytes)
             )) do
      %{
        role: anchor,
        name: name,
        kind: kind,
        revision: revision,
        authored_by: author,
        authored_at: at,
        content_sha256: hash,
        anchor_session_key: holder,
        covers_nobody: is_nil(holder)
      }
    end
  end

  defp compile_row(role, kind, definition, hash, revision, bytes) do
    bytes = if bytes, do: Base.decode64!(bytes)
    Rules.compile_saved!(role, kind, JSON.decode!(definition), hash, revision, bytes)
  end

  defp audience_matches?(txn, session, rule) do
    case Txn.q(txn, "SELECT archetype FROM sessions WHERE sessionKey=?1 AND state='active'", [
           session
         ]) do
      [[archetype]] ->
        roles = SubtreeScope.held_roles(txn, session)

        rule[:policy_context] == "organization" or
          RailScope.matches_participants?(rule.archetypes, rule.roles, [
            %{archetype: archetype, roles: roles}
          ])

      [] ->
        false
    end
  end

  defp rows(db, kind, verb \\ nil) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT role,name,kind,definition,contentSha256,revision,authoredBy,authoredAt,checkBytesBase64
        FROM saved_rules
        WHERE endedAt IS NULL
          AND (?1 IS NULL OR (?1='rule' AND kind='rule') OR (?1='reaction' AND kind!='rule'))
          AND (?2 IS NULL OR json_extract(definition,'$.verb')=?2
               OR EXISTS (SELECT 1 FROM json_each(definition,'$.verbs') WHERE value=?2))
        ORDER BY role,name
        """,
        [kind, verb]
      )

    rows
  end
end
