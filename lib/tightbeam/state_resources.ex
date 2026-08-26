defmodule Tightbeam.StateResources do
  @moduledoc """
  Canonical public item serializers shared by state reads and the firehose.

  Every resource enters the public wire through one named function here.
  Storage-secret field names are impossible to emit from this seam.
  """

  @secret_keys MapSet.new(["cliToken", "token", "identityToken"])

  @turn_select """
  SELECT t.seq, t.sessionKey, t.messageId, t.wakeId, t.origin, t.roleRef,
         t.roleFallback, t.assignmentId, t.jobRef, t.model, t.thinkingLevel,
         t.modelContext, t.harness, t.replyAttention, t.status, t.owner,
         t.adapterGen, t.requestRef, t.error, t.createdAt, t.startedAt,
         t.endedAt, t.publishedAt
  FROM turns AS t
  """

  alias Tightbeam.{
    AdminProjection,
    Artifacts,
    Assignments,
    DB,
    Devices,
    Identity,
    Org,
    ReadMarkers,
    Wakes,
    WorkItems
  }

  alias Tightbeam.DB.Txn

  @admin_field_order %{
    "config" => ~w(key value updatedAt rowVersion),
    "host environment" => ~w(host harness name value valuePresent updatedAt rowVersion),
    "hosts" => ~w(host rowVersion),
    "users" => ~w(userId isAdmin createdAt rowVersion),
    "identity" => ~w(name liveRevision state sessionRevisions staleness conflicts rowVersion),
    "kungfu" =>
      ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion)
  }

  def query_work_item(db, id, call) do
    case WorkItems.__handle__(db, "work-item-get", %{call | params: %{work_item_id: id}}) do
      %{workItem: row} -> row
      %{"workItem" => row} -> row
      _ -> nil
    end
  end

  def query_assignment(db, id, call) do
    case Assignments.__handle__(db, "assignment-get", %{call | params: %{assignment_id: id}}) do
      %{assignment: row} -> row
      %{"assignment" => row} -> row
      _ -> nil
    end
  end

  def query_wake(db, id), do: Wakes.get(db, id)
  def query_session(db, id), do: Org.get(db, id)

  def query_role(db, id) do
    case Tightbeam.DB.query(
           db,
           "SELECT name, boundSessionKey, ownerUserId, createdAt, updatedAt FROM roles WHERE name = ?1",
           [id]
         ) do
      {:ok, [[name, bound_session_key, owner_user_id, created_at, updated_at]]} ->
        %{
          name: name,
          bound_session_key: bound_session_key,
          owner_user_id: owner_user_id,
          created_at: created_at,
          updated_at: updated_at
        }

      {:ok, []} ->
        nil
    end
  end

  def query_artifact(db, id), do: Artifacts.get(db, id)

  def query_device(db, id) do
    case Devices.by_id(db, id) do
      nil -> nil
      device -> Map.put(device, :row_version, Devices.version(db, id) || device.created_at)
    end
  end

  @doc "Canonical config query; a filter map selects the deterministic collection."
  def query_config(source, filters) when is_map(filters) do
    filters = collection_filters!("config", filters, ~w(key))
    {where, params} = collection_where(filters, [{"key", "s.key"}])

    query(
      source,
      """
      SELECT s.key, s.value, s.updatedAt, v.rowVersion
      FROM org_settings AS s
      JOIN admin_projection_versions AS v
        ON v.resource = 'config' AND v.primaryKey = s.key
      #{where}
      ORDER BY s.key
      """,
      params
    )
    |> Enum.map(&config_row/1)
  end

  def query_config(source, key) do
    case query(
           source,
           """
           SELECT s.key, s.value, s.updatedAt, v.rowVersion
           FROM org_settings AS s
           JOIN admin_projection_versions AS v
             ON v.resource = 'config' AND v.primaryKey = s.key
           WHERE s.key = ?1
           """,
           [key]
         ) do
      [row] ->
        config_row(row)

      [] ->
        nil
    end
  end

  @doc "Canonical host-environment detail query. It never selects the secret value table."
  def query_host_environment(source, filters) when is_map(filters) do
    host = filters[:host] || filters["host"]
    harness = filters[:harness] || filters["harness"]
    name = filters[:name] || filters["name"]

    {where, params} =
      [
        {"host", host},
        {"harness", harness},
        {"name", name}
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{field, value}, index}, params ->
        {"#{field} = ?#{index}", params ++ [value]}
      end)
      |> then(fn {clauses, params} ->
        suffix = if clauses == [], do: "", else: " WHERE " <> Enum.join(clauses, " AND ")
        {suffix, params}
      end)

    query(
      source,
      """
      SELECT host, harness, name, valuePresent, updatedAt, rowVersion
      FROM host_environment_projection#{where}
      ORDER BY host, harness, name
      """,
      params
    )
    |> Enum.map(fn [row_host, row_harness, row_name, value_present, updated_at, row_version] ->
      %{
        host: row_host,
        harness: row_harness,
        name: row_name,
        value: nil,
        value_present: value_present == 1,
        updated_at: updated_at,
        row_version: row_version
      }
    end)
  end

  def query_host_environment(source, host, harness, name) do
    case query(
           source,
           """
           SELECT host, harness, name, valuePresent, updatedAt, rowVersion
           FROM host_environment_projection
           WHERE host = ?1 AND harness = ?2 AND name = ?3
           """,
           [host, harness, name]
         ) do
      [[row_host, row_harness, row_name, value_present, updated_at, row_version]] ->
        %{
          host: row_host,
          harness: row_harness,
          name: row_name,
          value: nil,
          value_present: value_present == 1,
          updated_at: updated_at,
          row_version: row_version
        }

      [] ->
        nil
    end
  end

  @doc "Canonical host query. No connection or filesystem field is selected."
  def query_host(source, filters) when is_map(filters) do
    filters = collection_filters!("hosts", filters, ~w(host))
    {where, params} = collection_where(filters, [{"host", "h.name"}])

    query(
      source,
      """
      SELECT h.name, v.rowVersion
      FROM hosts AS h
      JOIN admin_projection_versions AS v
        ON v.resource = 'hosts' AND v.primaryKey = h.name
      #{where}
      ORDER BY h.name
      """,
      params
    )
    |> Enum.map(&host_row/1)
  end

  def query_host(source, host) do
    case query(
           source,
           """
           SELECT h.name, v.rowVersion
           FROM hosts AS h
           JOIN admin_projection_versions AS v
             ON v.resource = 'hosts' AND v.primaryKey = h.name
           WHERE h.name = ?1
           """,
           [host]
         ) do
      [row] -> host_row(row)
      [] -> nil
    end
  end

  @doc "Canonical user query shared by user.added and user.promoted."
  def query_user(source, filters) when is_map(filters) do
    filters = collection_filters!("users", filters, ~w(userId))
    {where, params} = collection_where(filters, [{"userId", "u.userId"}])

    query(
      source,
      """
      SELECT u.userId, u.isAdmin, u.createdAt, v.rowVersion
      FROM users AS u
      JOIN admin_projection_versions AS v
        ON v.resource = 'users' AND v.primaryKey = u.userId
      #{where}
      ORDER BY u.createdAt, u.userId
      """,
      params
    )
    |> Enum.map(&user_row/1)
  end

  def query_user(source, id) do
    case query(
           source,
           """
           SELECT u.userId, u.isAdmin, u.createdAt, v.rowVersion
           FROM users AS u
           JOIN admin_projection_versions AS v
             ON v.resource = 'users' AND v.primaryKey = u.userId
           WHERE u.userId = ?1
           """,
           [id]
         ) do
      [row] ->
        user_row(row)

      [] ->
        nil
    end
  end

  @doc "Canonical served-identity query. Only committed stamps are readable."
  def query_identity(source, filters) when is_map(filters) do
    filters = collection_filters!("identity", filters, ~w(name state))

    source
    |> stamped_collection("identity")
    |> Enum.filter(&collection_item_matches?(&1, filters))
    |> Enum.sort_by(&Map.fetch!(&1, "name"))
  end

  def query_identity(source, name) when is_binary(name),
    do: AdminProjection.stamped_item(source, "identity", name)

  @doc "Canonical kungfu query. Only committed, sanitized stamps are readable."
  def query_kungfu(source, filters) when is_map(filters) do
    filters = collection_filters!("kungfu", filters, ~w(status rootArchetype))

    source
    |> stamped_collection("kungfu")
    |> Enum.filter(&collection_item_matches?(&1, filters))
    |> Enum.sort_by(&Map.fetch!(&1, "name"))
  end

  def query_kungfu(source, name), do: AdminProjection.stamped_item(source, "kungfu", name)

  @doc false
  def identity_snapshot(db, base_dir) do
    status = Identity.status(base_dir)
    live = status.live_revision

    session_revisions =
      db
      |> Org.list_for_user("", true)
      |> Enum.flat_map(fn session ->
        if is_binary(session.identity_revision),
          do: [{session.session_key, session.identity_revision}],
          else: []
      end)
      |> Map.new()

    %{
      "name" => "served",
      "liveRevision" => live,
      "state" => state_name(status.state),
      "sessionRevisions" => session_revisions,
      "staleness" =>
        session_revisions
        |> Enum.flat_map(fn {session_key, revision} ->
          if revision == live, do: [], else: [session_key]
        end)
        |> Enum.sort(),
      "conflicts" => Enum.sort(status.conflicting_paths)
    }
  end

  @doc false
  def kungfu_snapshot(base_dir, name), do: Identity.public_kungfu(base_dir, name)

  @doc false
  def kungfu_names(base_dir), do: Identity.public_kungfu_names(base_dir)
  def query_read_marker(db, user_id, scope_key), do: ReadMarkers.get(db, user_id, scope_key)
  def query_critical_state(db, session_key), do: Tightbeam.CriticalLeases.get(db, session_key)

  def query_production(db, seq) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        """
        SELECT seq, at, jobRef, assignmentId, sessionKey, kind, detail
        FROM causal_events WHERE seq = ?1 AND kind = 'prod_fired'
        """,
        [seq]
      )

    case rows do
      [[event_seq, at, job_ref, assignment_id, session_key, kind, detail]] ->
        %{
          seq: event_seq,
          at: at,
          job_ref: job_ref,
          assignment_id: assignment_id,
          session_key: session_key,
          kind: kind,
          detail: JSON.decode!(detail)
        }

      [] ->
        nil
    end
  end

  def query_turn(db, session_key, message_id) do
    {:ok, rows} =
      Tightbeam.DB.query(
        db,
        @turn_select <>
          """
          LEFT JOIN messages AS m ON m.id = t.messageId
          WHERE t.sessionKey = ?1 AND (t.messageId = ?2 OR m.clientMessageId = ?2)
          ORDER BY t.seq DESC LIMIT 1
          """,
        [session_key, message_id]
      )

    case rows do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  def query_turn_in_txn(txn, seq) do
    case Tightbeam.DB.Txn.q(txn, @turn_select <> " WHERE t.seq = ?1", [seq]) do
      [row] -> turn_row(row)
      [] -> nil
    end
  end

  def work_item(row), do: public(row)
  def assignment(row), do: public(row)
  def attest(row), do: public(row)
  def wake(row), do: public(row)
  def production(row), do: row |> public() |> correlate("eventId", "seq")
  def turn(row), do: row |> public() |> correlate("turnSeq", "seq")
  def decision_request(row), do: public(row)
  def session(row), do: public(row)
  def role(row), do: row |> public() |> correlate("role", "name")
  def artifact(row), do: public(row)
  def message(row), do: public(row)

  def condition_fact(row) do
    row = public(row)
    fact_id = row["factId"] || row["id"]

    row
    |> Map.put_new("factId", fact_id)
    |> Map.put("rowVersion", fact_id)
  end

  def critical_state(row), do: public(row)
  def device(row), do: row |> public() |> correlate("deviceId", "id")
  @doc "Closed config serializer."
  def config(row) do
    reject_public_shape_drift!(row, "config")

    exact!(
      "config",
      %{
        "key" => required_string!(row, :key),
        "value" => nullable_string!(value(row, :value), "value"),
        "updatedAt" => required_integer!(row, :updated_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed, value-free host-environment serializer."
  def host_environment(row) do
    reject_public_shape_drift!(row, "host environment")

    exact!(
      "host environment",
      %{
        "host" => required_string!(row, :host),
        "harness" => required_string!(row, :harness),
        "name" => required_string!(row, :name),
        "value" => nil,
        "valuePresent" => required_boolean!(row, :value_present),
        "updatedAt" => required_integer!(row, :updated_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed host serializer."
  def host(row) do
    reject_public_shape_drift!(row, "hosts")

    exact!(
      "hosts",
      %{"host" => required_string!(row, :host), "rowVersion" => required_version!(row)}
    )
  end

  @doc "Closed user serializer shared by user.added and user.promoted."
  def user(row) do
    reject_public_shape_drift!(row, "users")

    exact!(
      "users",
      %{
        "userId" => required_string!(row, :user_id),
        "isAdmin" => required_boolean!(row, :is_admin),
        "createdAt" => required_integer!(row, :created_at),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed served-identity serializer."
  def identity(row) do
    reject_public_shape_drift!(row, "identity")
    state = required_string!(row, :state)

    unless state in ~w(ready relearn_conflicted) do
      raise ArgumentError, "identity state must be ready or relearn_conflicted"
    end

    exact!(
      "identity",
      %{
        "name" => required_string!(row, :name),
        "liveRevision" => required_string!(row, :live_revision),
        "state" => state,
        "sessionRevisions" => sorted_string_map!(value(row, :session_revisions)),
        "staleness" => sorted_strings!(value(row, :staleness), "staleness"),
        "conflicts" => sorted_strings!(value(row, :conflicts), "conflicts"),
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Closed, sanitized kungfu serializer."
  def kungfu(row) do
    reject_public_shape_drift!(row, "kungfu")
    status = required_string!(row, :status)

    unless status in ~w(available installed) do
      raise ArgumentError, "kungfu status must be available or installed"
    end

    documents =
      value(row, :documents)
      |> required_list!("documents")
      |> Enum.map(fn document ->
        %{
          "path" => required_string!(document, :path),
          "content" => required_string!(document, :content),
          "sha256" => required_string!(document, :sha256)
        }
      end)
      |> Enum.sort_by(& &1["path"])

    exact!(
      "kungfu",
      %{
        "name" => required_string!(row, :name),
        "purpose" => required_string!(row, :purpose),
        "phrases" => sorted_strings!(value(row, :phrases), "phrases"),
        "rootArchetype" => required_string!(row, :root_archetype),
        "installedRevision" =>
          nullable_string!(value(row, :installed_revision), "installedRevision"),
        "status" => status,
        "documents" => documents,
        "rowVersion" => required_version!(row)
      }
    )
  end

  @doc "Encode one admin item in its ruled field order with compact UTF-8 JSON."
  def encode_admin_item(resource, item) do
    fields = Map.fetch!(@admin_field_order, resource)

    encoded =
      Enum.map_join(fields, ",", fn field ->
        JSON.encode!(field) <>
          ":" <> encode_admin_field(resource, field, Map.fetch!(item, field))
      end)

    "{" <> encoded <> "}"
  end

  @doc false
  def admin_resource?(resource), do: Map.has_key?(@admin_field_order, resource)
  def read_marker(row), do: public(row)
  def observation(row), do: public(row)

  defp turn_row([
         seq,
         session_key,
         message_id,
         wake_id,
         origin,
         role_ref,
         role_fallback,
         assignment_id,
         job_ref,
         model,
         thinking_level,
         model_context,
         harness,
         reply_attention,
         status,
         owner,
         adapter_gen,
         request_ref,
         error,
         created_at,
         started_at,
         ended_at,
         published_at
       ]) do
    %{
      seq: seq,
      session_key: session_key,
      message_id: message_id,
      wake_id: wake_id,
      origin: origin,
      role_ref: role_ref,
      role_fallback: role_fallback == 1,
      assignment_id: assignment_id,
      job_ref: job_ref,
      model: model,
      thinking_level: thinking_level,
      model_context: model_context,
      harness: harness,
      reply_attention: reply_attention == 1,
      status: status,
      owner: owner,
      adapter_gen: adapter_gen,
      request_ref: request_ref,
      error: error,
      created_at: created_at,
      started_at: started_at,
      ended_at: ended_at,
      published_at: published_at
    }
  end

  defp correlate(row, primary, source) do
    case row[source] do
      nil -> row
      value -> Map.put_new(row, primary, value)
    end
  end

  defp exact!(resource, item) do
    expected = Map.fetch!(@admin_field_order, resource)

    if Enum.sort(Map.keys(item)) == Enum.sort(expected) do
      item
    else
      raise ArgumentError, "#{resource} projection fields do not match the ruled contract"
    end
  end

  defp reject_public_shape_drift!(row, resource) when is_map(row) do
    keys = Map.keys(row)

    if keys != [] and Enum.all?(keys, &is_binary/1) do
      expected = Map.fetch!(@admin_field_order, resource)

      unless Enum.sort(keys) == Enum.sort(expected) do
        raise ArgumentError, "#{resource} public item has an extra or missing field"
      end
    end

    :ok
  end

  defp value(row, field) when is_map(row) do
    camel = field |> Atom.to_string() |> camel_key()

    [field, Atom.to_string(field), camel]
    |> Enum.find_value(fn key ->
      if Map.has_key?(row, key), do: {:found, Map.fetch!(row, key)}, else: nil
    end)
    |> case do
      {:found, found} -> found
      nil -> nil
    end
  end

  defp required_string!(row, field) do
    case value(row, field) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{field} must be a non-empty string"
    end
  end

  defp nullable_string!(nil, _field), do: nil
  defp nullable_string!(value, _field) when is_binary(value), do: value

  defp nullable_string!(_value, field),
    do: raise(ArgumentError, "#{field} must be a string or null")

  defp required_integer!(row, field) do
    case value(row, field) do
      value when is_integer(value) -> value
      _ -> raise ArgumentError, "#{field} must be an integer"
    end
  end

  defp required_version!(row) do
    case value(row, :row_version) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "rowVersion must be a positive integer"
    end
  end

  defp required_boolean!(row, field) do
    case value(row, field) do
      value when is_boolean(value) -> value
      _ -> raise ArgumentError, "#{field} must be a boolean"
    end
  end

  defp required_list!(value, _field) when is_list(value), do: value
  defp required_list!(_value, field), do: raise(ArgumentError, "#{field} must be an array")

  defp sorted_strings!(value, field) do
    value
    |> required_list!(field)
    |> then(fn values ->
      if Enum.all?(values, &is_binary/1),
        do: Enum.sort(values),
        else: raise(ArgumentError, "#{field} must contain only strings")
    end)
  end

  defp sorted_string_map!(value) when is_map(value) do
    value |> sorted_string_pairs!() |> Map.new()
  end

  defp sorted_string_map!(_value),
    do: raise(ArgumentError, "sessionRevisions must be a string-to-string map")

  defp encode_admin_field("identity", "sessionRevisions", value) do
    encoded =
      value
      |> sorted_string_pairs!()
      |> Enum.map_join(",", fn {key, item} ->
        JSON.encode!(key) <> ":" <> JSON.encode!(item)
      end)

    "{" <> encoded <> "}"
  end

  defp encode_admin_field(_resource, _field, value), do: JSON.encode!(value)

  defp sorted_string_pairs!(value) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end) do
      Enum.sort_by(value, &elem(&1, 0))
    else
      raise ArgumentError, "sessionRevisions must be a string-to-string map"
    end
  end

  defp sorted_string_pairs!(_value),
    do: raise(ArgumentError, "sessionRevisions must be a string-to-string map")

  defp state_name(:ready), do: "ready"
  defp state_name(:relearn_conflicted), do: "relearn_conflicted"
  defp state_name(value) when is_binary(value), do: value
  defp state_name(_value), do: raise(ArgumentError, "unknown identity state")

  defp config_row([key, value, updated_at, row_version]) do
    %{
      key: key,
      value: if(key == "default-archetype", do: value, else: nil),
      updated_at: updated_at,
      row_version: row_version
    }
  end

  defp host_row([name, row_version]), do: %{host: name, row_version: row_version}

  defp user_row([user_id, is_admin, created_at, row_version]) do
    %{
      user_id: user_id,
      is_admin: is_admin == 1,
      created_at: created_at,
      row_version: row_version
    }
  end

  defp collection_filters!(resource, filters, allowed) do
    Enum.reduce(filters, %{}, fn {key, value}, normalized ->
      field = if is_atom(key), do: Atom.to_string(key), else: key

      unless is_binary(field) and field in allowed do
        raise ArgumentError, "unsupported #{resource} collection filter #{inspect(key)}"
      end

      if Map.has_key?(normalized, field) do
        raise ArgumentError, "duplicate #{resource} collection filter #{inspect(field)}"
      end

      cond do
        is_nil(value) -> normalized
        is_binary(value) -> Map.put(normalized, field, value)
        true -> raise ArgumentError, "#{resource} collection filter #{field} must be a string"
      end
    end)
  end

  defp collection_where(filters, fields) do
    {clauses, params} =
      fields
      |> Enum.reduce({[], []}, fn {field, column}, {clauses, params} ->
        case Map.fetch(filters, field) do
          {:ok, value} ->
            index = length(params) + 1
            {clauses ++ ["#{column} = ?#{index}"], params ++ [value]}

          :error ->
            {clauses, params}
        end
      end)

    where = if clauses == [], do: "", else: "WHERE " <> Enum.join(clauses, " AND ")
    {where, params}
  end

  defp stamped_collection(source, resource) do
    query(
      source,
      """
      SELECT item, rowVersion
      FROM admin_projection_versions
      WHERE resource = ?1 AND item IS NOT NULL
      ORDER BY primaryKey
      """,
      [resource]
    )
    |> Enum.map(fn [item, row_version] ->
      item
      |> JSON.decode!()
      |> Map.put("rowVersion", row_version)
    end)
  end

  defp collection_item_matches?(item, filters) do
    Enum.all?(filters, fn {field, value} -> item[field] == value end)
  end

  defp camel_key(field) do
    field
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
      [] -> ""
    end
  end

  defp query(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp query(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp public(row) when is_struct(row), do: row |> Map.from_struct() |> public()

  defp public(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {wire_key(key), public(value)} end)
    |> Map.reject(fn {key, _value} -> MapSet.member?(@secret_keys, key) end)
    |> ensure_row_version()
  end

  defp public(rows) when is_list(rows), do: Enum.map(rows, &public/1)
  defp public(value) when is_atom(value), do: Atom.to_string(value)
  defp public(value), do: value

  defp ensure_row_version(row) do
    version = row["rowVersion"] || natural_version(row)

    if is_integer(version), do: Map.put_new(row, "rowVersion", version), else: row
  end

  defp natural_version(row) do
    ~w(updatedAt endedAt firedAt canceledAt closedAt retiredAt ruledAt withdrawnAt startedAt createdAt openedAt ts seq id)
    |> Enum.map(&row[&1])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp wire_key(key) when is_binary(key), do: key

  defp wire_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
      [] -> ""
    end
  end

  defp wire_key(key), do: to_string(key)
end
