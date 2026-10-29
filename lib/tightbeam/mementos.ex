defmodule Tightbeam.Mementos do
  @moduledoc """
  Declared, opaque record metadata. History is append-only; ordinary reads use
  the current table and never reconstruct a value from previous writes.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @record_kinds ~w(work_item assignment attest)
  @name ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/
  @declarations_key {__MODULE__, :declarations}
  @page_bytes 1_048_576

  defmodule Refusal do
    @moduledoc false
    defexception [:code, :message, :details, :admission]
  end

  @doc false
  def declarations!(entries, path) when is_list(entries) do
    declarations =
      Enum.map(entries, fn entry ->
        unless is_map(entry), do: invalid!(path, "memento must be a table")
        unknown = Map.keys(entry) -- ~w(name records many)

        if unknown != [],
          do:
            invalid!(
              path,
              "memento #{inspect(entry["name"])} has unknown keys #{Enum.join(unknown, ", ")}"
            )

        name = entry["name"]
        records = entry["records"]
        many = Map.get(entry, "many", false)

        unless is_binary(name) and Regex.match?(@name, name),
          do: invalid!(path, "memento name must match [A-Za-z0-9][A-Za-z0-9_-]*")

        unless is_list(records) and records != [] and
                 Enum.all?(records, &(&1 in @record_kinds)) and
                 length(Enum.uniq(records)) == length(records),
               do:
                 invalid!(
                   path,
                   "memento #{name} records must be a nonempty subset of #{Enum.join(@record_kinds, ", ")}"
                 )

        unless is_boolean(many), do: invalid!(path, "memento #{name} many must be boolean")
        %{name: name, records: records, many: many}
      end)

    Enum.each(Enum.frequencies_by(declarations, & &1.name), fn {name, count} ->
      if count > 1, do: invalid!(path, "declares memento #{name} twice")
    end)

    declarations
  end

  def declarations!(_, path), do: invalid!(path, "mementos must be an array of tables")

  defp invalid!(path, message), do: raise(ArgumentError, "kungfu manifest #{message}: #{path}")

  @doc false
  def read_declarations!(law_base, revision) do
    declarations =
      law_base
      |> Path.join("identity/kungfu/*/manifest.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        bundle = path |> Path.dirname() |> Path.basename()
        manifest = path |> File.read!() |> Toml.decode!()

        for declaration <- declarations!(Map.get(manifest, "mementos", []), path) do
          qualified = bundle <> "/" <> declaration.name
          {qualified, Map.merge(declaration, %{qualified: qualified, bundle: bundle})}
        end
      end)
      |> Map.new()

    %{revision: revision, names: declarations}
  end

  @doc false
  def with_declarations(declarations, fun) do
    previous = Process.get(@declarations_key, :absent)
    Process.put(@declarations_key, declarations)

    try do
      fun.()
    after
      if previous == :absent,
        do: Process.delete(@declarations_key),
        else: Process.put(@declarations_key, previous)
    end
  end

  def declarations do
    Process.get(@declarations_key) || Tightbeam.Rules.effective_snapshot().declarations
  end

  @doc false
  def protect(fun) do
    Tightbeam.Rules.with_snapshot(fun)
  rescue
    error in Refusal ->
      error.admission || error.details || %{code: error.code, message: error.message}
  end

  @doc false
  def with_comparison!(call, nil), do: Map.delete(call, :memento_comparison_value)

  def with_comparison!(call, value) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) <= 1024,
      do:
        refuse!(
          "memento_comparison_bounds",
          "comparison value must be UTF-8 text of at most 1024 bytes"
        )

    Map.put(call, :memento_comparison_value, value)
  end

  @doc false
  def prepare_call!(%{verb: "memento-set"} = call) do
    {kind, id} = record!(call.params[:record])

    if kind == "attest",
      do: refuse!("memento_record_immutable", "attest mementos can only be filed inline")

    values = call.params[:values]
    clear = Map.get(call.params, :clear, false)

    values =
      case {clear, values} do
        {true, nil} -> []
        {false, [_ | _] = values} -> values
        _ -> refuse!("memento_value_bounds", "supply values or clear, exclusively")
      end

    params = Map.drop(call.params, [:assignment_id, :work_item_id, :reviews_assignment_id])

    params =
      Map.put(params, if(kind == "assignment", do: :assignment_id, else: :work_item_id), id)

    call
    |> Map.put(:params, params)
    |> Map.put(:memento_target, {kind, id})
    |> Map.put(:memento_writes, prepare!(kind, [{call.params[:name], values}]))
    |> Map.put(:memento_revision, declarations().revision)
  end

  def prepare_call!(%{verb: verb} = call)
      when verb in ~w(work-item-create assign dispatch attest) do
    kind =
      case verb do
        "work-item-create" -> "work_item"
        "attest" -> "attest"
        _ -> "assignment"
      end

    call
    |> Map.put(:memento_writes, prepare!(kind, Map.get(call.params, :mementos, [])))
    |> Map.put(:memento_revision, declarations().revision)
  end

  def prepare_call!(call), do: call

  def record!(record) when is_binary(record) do
    case String.split(record, ":", parts: 2) do
      [kind, id] when kind in @record_kinds and id != "" ->
        {kind, id}

      _ ->
        refuse!(
          "memento_record_kind",
          "record must be work_item:<id>, assignment:<id> or attest:<id>"
        )
    end
  end

  def record!(_), do: refuse!("memento_record_kind", "record must name a kind and id")

  defp assert_record!(db, kind, id) do
    table =
      case kind do
        "work_item" -> "work_items"
        "assignment" -> "assignments"
        "attest" -> "attests"
      end

    case query(db, "SELECT 1 FROM #{table} WHERE id=?1", [id]) do
      {:ok, [[1]]} -> :ok
      {:ok, []} -> refuse!("memento_record_not_found", "unknown #{kind}:#{id}")
    end
  end

  defp query(%Txn{} = txn, sql, params), do: {:ok, Txn.q(txn, sql, params)}
  defp query(db, sql, params), do: DB.query(db, sql, params)

  @doc false
  def __handle__(db, "memento-set", original) do
    protect(fn ->
      snapshot = Tightbeam.Rules.effective_snapshot()

      result =
        DB.transaction(db, fn txn ->
          Tightbeam.Rules.with_snapshot(snapshot, fn ->
            call = prepare_call!(Map.put(original, :verb, "memento-set"))
            {kind, id} = call.memento_target
            assert_record!(txn, kind, id)
            call = admit_in_txn!(txn, call)
            append_inline!(txn, kind, id, call)

            {%{record: "#{kind}:#{id}", mementos: current(txn, kind, id)},
             call.memento_close_effects}
          end)
        end)

      case result do
        {:ok, {value, effects}} ->
          handlers =
            Map.get(original, :rule_effect_handlers) || Tightbeam.Gateway.handlers(%{db: db})

          Tightbeam.Dispatch.close_rule_effects(db, handlers, effects)
          value

        {:error, error} ->
          raise error
      end
    end)
  end

  def __handle__(db, "mementos", call) do
    protect(fn ->
      {kind, id} = record!(call.params[:record])
      assert_record!(db, kind, id)

      if Map.get(call.params, :history, false) do
        name = if call.params[:name], do: history_name!(call.params.name)
        opts = [name: name, cursor: call.params[:cursor], limit: call.params[:limit] || 100]
        Map.put(history(db, kind, id, opts), :record, "#{kind}:#{id}")
      else
        %{record: "#{kind}:#{id}", mementos: current(db, kind, id)}
      end
    end)
  end

  defp history_name!(name) when is_binary(name) do
    if String.contains?(name, "/"), do: name, else: resolve!(name).qualified
  end

  defp history_name!(_), do: refuse!("unknown_memento", "memento name must be a string")

  @doc false
  def admit_in_txn!(%Txn{} = txn, original) do
    :ok = Tightbeam.Rules.assert_session_contract_in_txn!(txn, original)
    call = prepare_call!(original)
    writes = call.memento_writes
    if writes != [], do: authenticated!(call[:principal])

    # Keep all decisions dry until every name has passed. A later refusal rolls
    # back the record. Dispatch evaluates a host call before its handler; direct
    # callers still need that host decision here.
    calls =
      if(call.verb == "memento-set" or call[:rules_prechecked],
        do: [],
        else: [Map.put(call, :memento_admission, :host)]
      ) ++
        Enum.map(writes, fn write ->
          call
          |> Map.put(:memento_writes, [write])
          |> Map.put(:memento_admission, :write)
          |> Map.put(:memento_rule_verb, "memento-set")
        end)

    {to_close, to_consume} =
      Enum.reduce(calls, {[], []}, fn admitted_call, {closed, consumed} ->
        {decision, close, consume} = Tightbeam.Rules.decide(txn, admitted_call)
        close = closed ++ close

        case decision do
          :allow -> {close, consumed ++ consume}
          _ -> refuse_decision!(admitted_call, decision, close)
        end
      end)

    for ruling_id <- Enum.uniq(to_consume) do
      unless Tightbeam.Escalation.consume_in_txn(txn, ruling_id, call.verb, call.origin) do
        refuse!("rule_denied", "ruling authorization was no longer available")
      end
    end

    to_close = silent_closed_write(txn, call, to_close)

    Map.put(call, :memento_close_effects, to_close)
  end

  # A successful closed-record metadata write must stay silent. Advisory
  # notices do not change admission; episode recovery still belongs to its actor.
  defp silent_closed_write(txn, %{verb: "memento-set", memento_target: {kind, id}}, effects) do
    if Enum.any?(effects, &match?({:notice, _, _, _}, &1)) do
      table = if kind == "assignment", do: "assignments", else: "work_items"

      case Txn.q(txn, "SELECT state FROM #{table} WHERE id=?1", [id]) do
        [[state]] when state != "open" -> Enum.reject(effects, &match?({:notice, _, _, _}, &1))
        _ -> effects
      end
    else
      effects
    end
  end

  defp silent_closed_write(_txn, _call, effects), do: effects

  defp refuse_decision!(_call, {:deny, error}, []) do
    raise Refusal, code: error.code, message: error[:message], details: error
  end

  defp refuse_decision!(call, decision, to_close) do
    raise Refusal,
      code: "rule_denied",
      message: "transactional rule admission refused",
      admission: {:memento_admission, call, decision, to_close}
  end

  @doc false
  def append_inline!(%Txn{} = txn, kind, id, call) do
    writes = Map.get(call, :memento_writes, [])

    if writes != [] do
      unless call.memento_revision == declarations().revision,
        do:
          refuse!(
            "memento_identity_changed",
            "published identity changed during admission; retry"
          )

      append_in_txn!(txn, kind, id, writes, call.principal, call.memento_revision)
    end

    :ok
  end

  @doc "Resolve a declared qualified or unambiguous bare name."
  def resolve!(name) when is_binary(name) do
    names = declarations().names

    case Map.get(names, name) do
      nil ->
        candidates = names |> Map.values() |> Enum.filter(&(&1.name == name))

        case candidates do
          [declaration] ->
            declaration

          [] ->
            refuse!(
              "unknown_memento",
              "unknown memento: #{name}; declared: #{names |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
            )

          many ->
            refuse!(
              "ambiguous_memento",
              "ambiguous memento #{name}: #{many |> Enum.map(& &1.qualified) |> Enum.sort() |> Enum.join(", ")}"
            )
        end

      declaration ->
        declaration
    end
  end

  def resolve!(_), do: refuse!("unknown_memento", "memento name must be a string")

  @doc "Validate opaque strings and preserve first-seen value order."
  def values!(values) when is_list(values) do
    unless length(values) <= 32 and
             Enum.all?(values, fn value ->
               is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value) and
                 not String.contains?(value, <<0>>)
             end),
           do:
             refuse!(
               "memento_value_bounds",
               "a write accepts at most 32 UTF-8 values of 1–1024 bytes without NUL"
             )

    Enum.uniq(values)
  end

  def values!(_), do: refuse!("memento_value_bounds", "memento values must be a list of strings")

  @doc "Normalize an ordered list of inline name/value pairs into qualified writes."
  def prepare!(record_kind, entries) when record_kind in @record_kinds and is_list(entries) do
    {order, grouped} =
      Enum.reduce(entries, {[], %{}}, fn entry, {order, grouped} ->
        {name, values} = entry_values!(entry)
        declaration = resolve!(name)

        unless record_kind in declaration.records,
          do:
            refuse!(
              "memento_record_kind",
              "#{declaration.qualified} allows #{Enum.join(declaration.records, ", ")}"
            )

        name = declaration.qualified
        order = if Map.has_key?(grouped, name), do: order, else: [name | order]
        {order, Map.update(grouped, name, values, &(&1 ++ values))}
      end)

    for name <- Enum.reverse(order) do
      declaration = resolve!(name)
      values = values!(Map.fetch!(grouped, name))

      if not declaration.many and length(values) > 1,
        do: refuse!("memento_single_value", "#{name} allows only one value")

      {name, values}
    end
  end

  def prepare!(_, _),
    do: refuse!("memento_record_kind", "expected a covered record kind and a list of mementos")

  defp entry_values!({name, values}) when is_list(values), do: {name, values}
  defp entry_values!(%{"name" => name, "value" => value}), do: {name, [value]}
  defp entry_values!(%{name: name, value: value}), do: {name, [value]}

  defp entry_values!(_),
    do: refuse!("memento_value_bounds", "inline mementos require name/value pairs")

  @ddl """
  CREATE TABLE IF NOT EXISTS memento_history (
    id INTEGER PRIMARY KEY,
    recordKind TEXT NOT NULL CHECK(recordKind IN ('work_item','assignment','attest')),
    recordId TEXT NOT NULL,
    name TEXT NOT NULL,
    valueJson TEXT NOT NULL,
    byKind TEXT NOT NULL CHECK(byKind IN ('session','user')),
    byRef TEXT NOT NULL,
    identityRevision TEXT NOT NULL,
    ts INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS memento_history_record ON memento_history(recordKind,recordId,id);
  CREATE INDEX IF NOT EXISTS memento_history_key ON memento_history(recordKind,recordId,name,id);
  CREATE TABLE IF NOT EXISTS memento_current (
    recordKind TEXT NOT NULL,
    recordId TEXT NOT NULL,
    name TEXT NOT NULL,
    valueJson TEXT NOT NULL,
    historyId INTEGER NOT NULL REFERENCES memento_history(id),
    PRIMARY KEY(recordKind,recordId,name)
  ) WITHOUT ROWID;
  CREATE TRIGGER IF NOT EXISTS memento_history_immutable_update
    BEFORE UPDATE ON memento_history BEGIN SELECT RAISE(ABORT,'memento_history_immutable'); END;
  CREATE TRIGGER IF NOT EXISTS memento_history_immutable_delete
    BEFORE DELETE ON memento_history BEGIN SELECT RAISE(ABORT,'memento_history_immutable'); END;
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)
  def schema_in_txn(%Txn{} = txn), do: Txn.exec(txn, @ddl)

  def attach(%Txn{} = txn, kind, %{id: id} = record),
    do: Map.put(record, :mementos, current(txn, kind, id))

  def attach(db, kind, %{id: id} = record),
    do: Map.put(record, :mementos, current(db, kind, id))

  @doc "Read current lists by an indexed record range, including cleared names."
  def current(%Txn{} = txn, kind, id) do
    txn
    |> Txn.q(
      "SELECT name,valueJson FROM memento_current WHERE recordKind=?1 AND recordId=?2 ORDER BY name",
      [kind, id]
    )
    |> Map.new(fn [name, values] -> {name, JSON.decode!(values)} end)
  end

  def current(db, kind, id) do
    {:ok, rows} =
      query(
        db,
        "SELECT name,valueJson FROM memento_current WHERE recordKind=?1 AND recordId=?2 ORDER BY name",
        [kind, id]
      )

    Map.new(rows, fn [name, values] -> {name, JSON.decode!(values)} end)
  end

  @doc "Read one current list without consulting history."
  def current(%Txn{} = txn, kind, id, name) do
    case Txn.q(
           txn,
           "SELECT valueJson FROM memento_current WHERE recordKind=?1 AND recordId=?2 AND name=?3",
           [kind, id, name]
         ) do
      [] -> []
      [[values]] -> JSON.decode!(values)
    end
  end

  def current(db, kind, id, name) do
    case DB.query(
           db,
           "SELECT valueJson FROM memento_current WHERE recordKind=?1 AND recordId=?2 AND name=?3",
           [kind, id, name]
         ) do
      {:ok, []} -> []
      {:ok, [[values]]} -> JSON.decode!(values)
    end
  end

  @doc false
  def append_in_txn!(%Txn{} = txn, kind, id, writes, principal, revision) do
    {by_kind, by_ref} = authenticated!(principal)

    unless is_binary(revision),
      do: refuse!("memento_identity_unavailable", "published identity revision is unavailable")

    for {name, values} <- writes do
      encoded = JSON.encode!(values)

      [[history_id]] =
        Txn.q(
          txn,
          """
          INSERT INTO memento_history(recordKind,recordId,name,valueJson,byKind,byRef,identityRevision,ts)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8) RETURNING id
          """,
          [kind, id, name, encoded, by_kind, by_ref, revision, System.system_time(:millisecond)]
        )

      Txn.q(
        txn,
        """
        INSERT INTO memento_current(recordKind,recordId,name,valueJson,historyId)
        VALUES (?1,?2,?3,?4,?5)
        ON CONFLICT(recordKind,recordId,name) DO UPDATE SET
          valueJson=excluded.valueJson, historyId=excluded.historyId
        """,
        [kind, id, name, encoded, history_id]
      )

      history_id
    end
  end

  def authenticated!({kind, ref}) when kind in [:session, :user, :process] and is_binary(ref),
    do: {Atom.to_string(kind), ref}

  def authenticated!(_),
    do:
      refuse!(
        "memento_unauthenticated",
        "memento writes require an authenticated caller"
      )

  @doc "Read a bounded keyset page in committed append order."
  def history(db, kind, id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    unless is_integer(limit) and limit in 1..1000,
      do: refuse!("memento_history_limit", "history limit must be between 1 and 1000")

    name = Keyword.get(opts, :name)
    cursor = decode_cursor!(Keyword.get(opts, :cursor), kind, id, name)
    name_clause = if name, do: " AND name=?4", else: ""
    params = if name, do: [kind, id, cursor, name], else: [kind, id, cursor]

    # Read incrementally: a 1,000-row page of maximum values must not allocate
    # 32 MiB only to discard it at the response cap. Each seek resumes at the
    # preceding id, with no offset or replay of already returned history.
    page(db, kind, id, name, name_clause, params, limit, [], 0)
  end

  defp page(db, kind, id, name, name_clause, params, remaining, rows, size) do
    {:ok, next} =
      DB.query(
        db,
        """
        SELECT id,name,valueJson,byKind,byRef,identityRevision,ts FROM memento_history
        WHERE recordKind=?1 AND recordId=?2 AND id>?3#{name_clause} ORDER BY id LIMIT 1
        """,
        params
      )

    case next do
      [] ->
        %{history: Enum.reverse(rows), hasMore: false, cursor: nil}

      [[row_id, row_name, json, by_kind, by_ref, revision, ts]] ->
        row = %{
          id: row_id,
          name: row_name,
          values: JSON.decode!(json),
          byKind: by_kind,
          byRef: by_ref,
          identityRevision: revision,
          ts: ts
        }

        # Include the complete envelope and continuation cursor in the cap.
        next_size = size + byte_size(JSON.encode!(row)) + if(rows == [], do: 0, else: 1)
        next_cursor = encode_cursor(kind, id, name, row_id)

        envelope_size =
          byte_size(
            JSON.encode!(%{
              record: "#{kind}:#{id}",
              history: [],
              hasMore: true,
              cursor: next_cursor
            })
          )

        if remaining == 0 or next_size + envelope_size > @page_bytes do
          %{
            history: Enum.reverse(rows),
            hasMore: true,
            cursor: encode_cursor(kind, id, name, Enum.at(params, 2))
          }
        else
          page(
            db,
            kind,
            id,
            name,
            name_clause,
            List.replace_at(params, 2, row_id),
            remaining - 1,
            [row | rows],
            next_size
          )
        end
    end
  end

  defp encode_cursor(kind, id, name, after_id),
    do: [kind, id, name, after_id] |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp decode_cursor!(nil, _kind, _id, _name), do: 0

  defp decode_cursor!(cursor, kind, id, name) when is_binary(cursor) do
    with {:ok, bytes} <- Base.url_decode64(cursor, padding: false),
         {:ok, [^kind, ^id, ^name, after_id]} <- JSON.decode(bytes),
         true <- is_integer(after_id) and after_id >= 0 do
      after_id
    else
      _ -> refuse!("memento_history_cursor", "cursor does not identify this history request")
    end
  end

  defp decode_cursor!(_, _, _, _), do: refuse!("memento_history_cursor", "invalid history cursor")

  def refuse!(code, message), do: raise(Refusal, code: code, message: message)
end
