defmodule Tightbeam.SubtreeGuidance do
  @moduledoc """
  Subtree guidance: Markdown entries a session writes for its own descendants.

  An entry belongs to the session that wrote it (the writer), named uniquely per
  writer, scoped to all descendants or to named archetypes. An entry applies to
  a session when the writer is an ancestor (by `Org.topology_parent`) and the
  scope matches the session's archetype exactly. The applicable entries render
  as one section, nearest writer first, that joins served guidance at every
  compose and is pushed to started descendants whose section changed, in the
  same transaction as the write. Entries are never copied between sessions and
  never migrate on retirement.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Org
  alias Tightbeam.Wakes

  @entries_ddl """
  CREATE TABLE IF NOT EXISTS subtree_guidance_entries (
    writerSessionKey TEXT NOT NULL,
    name             TEXT NOT NULL,
    archetypes       TEXT,
    text             TEXT NOT NULL,
    createdAt        INTEGER NOT NULL,
    updatedAt        INTEGER NOT NULL,
    PRIMARY KEY (writerSessionKey, name)
  )
  """

  @doc "Create the subtree guidance entry table."
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @entries_ddl)

  @doc """
  Store an entry under `writer_key`, replacing any earlier entry of the same
  writer and name, and queue one prompt to each started descendant whose
  section text changed. `archetypes` is nil for all descendants, or a list of
  archetype names matched exactly.
  """
  @spec set(DB.server(), String.t(), term(), term(), term()) :: {:ok, map()} | {:error, map()}
  def set(db, writer_key, name, archetypes, text) do
    with :ok <- validate_name(name),
         {:ok, archetypes} <- validate_archetypes(archetypes),
         :ok <- validate_text(text) do
      {:ok, result} =
        DB.transaction(db, fn txn ->
          pushed =
            push_around_change_in_txn(txn, writer_key, fn ->
              upsert_entry(txn, writer_key, name, archetypes, text)
            end)

          {:ok,
           %{
             writer: writer_key,
             name: name,
             scope: scope_text(archetypes),
             archetypes: archetypes,
             pushed_to: pushed
           }}
        end)

      result
    end
  end

  @doc """
  Withdraw the writer's entry named `name` and queue one prompt to each started
  descendant whose section text changed.
  """
  @spec withdraw(DB.server(), String.t(), term()) :: {:ok, map()} | {:error, map()}
  def withdraw(db, writer_key, name) do
    with :ok <- validate_name(name) do
      {:ok, result} =
        DB.transaction(db, fn txn ->
          if entry_exists?(txn, writer_key, name) do
            pushed =
              push_around_change_in_txn(txn, writer_key, fn ->
                Txn.q(
                  txn,
                  "DELETE FROM subtree_guidance_entries WHERE writerSessionKey=?1 AND name=?2",
                  [writer_key, name]
                )
              end)

            {:ok, %{writer: writer_key, withdrawn: name, pushed_to: pushed}}
          else
            names = Enum.map(own_entries(txn, writer_key), & &1.name)

            {:error,
             %{
               code: "unknown_entry",
               message:
                 "unknown_entry rule: this session has no subtree guidance entry named " <>
                   "#{name}; its entries: " <> names_or_none(names)
             }}
          end
        end)

      result
    end
  end

  @doc """
  The entries `session_key` wrote and the section that currently applies to it,
  rendered by the same code served guidance and the push use.
  """
  @spec show(DB.server(), String.t()) :: {:ok, map()} | {:error, map()}
  def show(db, session_key) do
    case session_row(db, session_key) do
      nil ->
        {:error,
         %{
           code: "unknown_session",
           message: "unknown_session rule: no session #{session_key}"
         }}

      _session ->
        {:ok,
         %{
           session: session_key,
           entries:
             Enum.map(own_entries(db, session_key), fn entry ->
               %{
                 name: entry.name,
                 scope: scope_text(entry.archetypes),
                 archetypes: entry.archetypes,
                 text: entry.text
               }
             end),
           section: section(db, session_key)
         }}
    end
  end

  @doc """
  The subtree guidance section for `session_key`, or nil when no entry applies.
  Reads current entries and current topology; `source` is a DB server or an
  open transaction.
  """
  @spec section(DB.server() | Txn.t(), String.t()) :: String.t() | nil
  def section(source, session_key) do
    case applicable_entries(source, session_key) do
      [] -> nil
      entries -> render_section(source, entries)
    end
  end

  # -- applicability ---------------------------------------------------------

  defp applicable_entries(source, session_key) do
    case session_row(source, session_key) do
      nil ->
        []

      %{archetype: archetype} ->
        ancestors = ancestors(source, session_key)
        distances = Map.new(ancestors)

        source
        |> entries_for_writers(Enum.map(ancestors, &elem(&1, 0)))
        |> Enum.filter(&scope_matches?(&1.archetypes, archetype))
        |> Enum.map(&Map.put(&1, :distance, Map.fetch!(distances, &1.writer)))
        |> Enum.sort_by(&{&1.distance, &1.name})
    end
  end

  defp scope_matches?(nil, _archetype), do: true
  defp scope_matches?(archetypes, archetype), do: archetype in archetypes

  # Ancestors as {session_key, distance}, distance 1 = parent.
  defp ancestors(source, session_key),
    do: walk_up(source, session_key, 1, [])

  defp walk_up(source, key, distance, acc) do
    sql = "SELECT #{Org.topology_parent_sql("s")} FROM sessions s WHERE s.sessionKey=?1"

    case q(source, sql, [key]) do
      [[parent]] when is_binary(parent) ->
        walk_up(source, parent, distance + 1, [{parent, distance} | acc])

      _rootless_or_missing ->
        Enum.reverse(acc)
    end
  end

  # -- rendering -------------------------------------------------------------

  defp render_section(source, entries) do
    display_names = writer_display_names(source, Enum.map(entries, & &1.writer))

    header =
      "## Subtree guidance\n\n" <>
        "The entries below were written by sessions above this session in the org. " <>
        "Where two entries conflict, follow the nearer writer (the smaller distance). " <>
        "This ordering is among these entries only."

    blocks =
      Enum.map(entries, fn entry ->
        display = Map.get(display_names, entry.writer, entry.writer)

        "### #{entry.name} — from #{display} (#{entry.writer}), " <>
          "distance #{entry.distance}, scope: #{scope_text(entry.archetypes)}\n\n" <>
          entry.text
      end)

    Enum.join([header | blocks], "\n\n")
  end

  defp scope_text(nil), do: "all descendants"
  defp scope_text(archetypes), do: "archetypes " <> Enum.join(archetypes, ", ")

  defp writer_display_names(_source, []), do: %{}

  defp writer_display_names(source, writer_keys) do
    writer_keys = Enum.uniq(writer_keys)
    placeholders = Enum.map_join(1..length(writer_keys), ",", &"?#{&1}")

    source
    |> q(
      "SELECT sessionKey, displayName FROM sessions WHERE sessionKey IN (#{placeholders})",
      writer_keys
    )
    |> Map.new(fn [key, display] -> {key, display} end)
  end

  # -- the push (R-06) -------------------------------------------------------

  # Apply `change` and queue one prompt to each started descendant of the
  # writer whose section text differs afterwards, all in the open transaction.
  # Only the writer's entries change, and they apply only inside its subtree,
  # so no other session's section can change.
  defp push_around_change_in_txn(txn, writer_key, change) do
    descendants = started_descendants(txn, writer_key)
    before = Map.new(descendants, &{&1, section(txn, &1)})
    change.()

    descendants
    |> Enum.filter(fn key -> section(txn, key) != Map.fetch!(before, key) end)
    |> Enum.sort()
    |> Enum.map(fn key ->
      Wakes.schedule_in_txn(txn, %{
        session_key: key,
        target_role: nil,
        origin: "process:tightbeam",
        prompt: push_prompt(section(txn, key)),
        due_at: System.system_time(:millisecond),
        consumer: "prompt",
        target_gate: 1
      })

      key
    end)
  end

  defp push_prompt(nil) do
    "Subtree guidance update: the subtree guidance this session was given " <>
      "earlier is withdrawn, and no subtree guidance now applies to this session."
  end

  defp push_prompt(section) do
    "Subtree guidance update. The section below is this session's complete " <>
      "current subtree guidance; it replaces any earlier subtree guidance this " <>
      "session was given.\n\n" <> section
  end

  # Active descendants of the writer that have a harness session pointer.
  defp started_descendants(txn, writer_key) do
    rows =
      Txn.q(txn, "SELECT s.sessionKey, s.state, #{Org.topology_parent_sql("s")} FROM sessions s")

    parents = Map.new(rows, fn [key, _state, parent] -> {key, parent} end)

    rows
    |> Enum.filter(fn [key, state, _parent] ->
      state == "active" and key != writer_key and descendant?(parents, key, writer_key)
    end)
    |> Enum.map(fn [key, _state, _parent] -> key end)
    |> Enum.filter(&Org.current_pointer_snapshot_in_txn(txn, &1))
  end

  defp descendant?(parents, key, writer_key), do: ancestor_of?(parents, key, writer_key)

  defp ancestor_of?(parents, key, writer_key) do
    case Map.get(parents, key) do
      nil -> false
      ^writer_key -> true
      parent -> ancestor_of?(parents, parent, writer_key)
    end
  end

  # -- storage ---------------------------------------------------------------

  defp upsert_entry(txn, writer_key, name, archetypes, text) do
    now = System.system_time(:millisecond)
    encoded = if archetypes, do: JSON.encode!(archetypes)

    Txn.q(
      txn,
      """
      INSERT INTO subtree_guidance_entries (writerSessionKey, name, archetypes, text, createdAt, updatedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?5)
      ON CONFLICT(writerSessionKey, name) DO UPDATE SET
        archetypes = excluded.archetypes,
        text = excluded.text,
        updatedAt = excluded.updatedAt
      """,
      [writer_key, name, encoded, text, now]
    )
  end

  defp entry_exists?(txn, writer_key, name) do
    Txn.q(
      txn,
      "SELECT 1 FROM subtree_guidance_entries WHERE writerSessionKey=?1 AND name=?2",
      [writer_key, name]
    ) != []
  end

  defp own_entries(source, writer_key) do
    source
    |> q(
      """
      SELECT name, archetypes, text
      FROM subtree_guidance_entries WHERE writerSessionKey=?1 ORDER BY name
      """,
      [writer_key]
    )
    |> Enum.map(fn [name, archetypes, text] ->
      %{
        name: name,
        archetypes: decode_archetypes(archetypes),
        text: text
      }
    end)
  end

  defp entries_for_writers(_source, []), do: []

  defp entries_for_writers(source, writer_keys) do
    placeholders = Enum.map_join(1..length(writer_keys), ",", &"?#{&1}")

    source
    |> q(
      """
      SELECT writerSessionKey, name, archetypes, text
      FROM subtree_guidance_entries WHERE writerSessionKey IN (#{placeholders})
      """,
      writer_keys
    )
    |> Enum.map(fn [writer, name, archetypes, text] ->
      %{writer: writer, name: name, archetypes: decode_archetypes(archetypes), text: text}
    end)
  end

  defp decode_archetypes(nil), do: nil
  defp decode_archetypes(encoded), do: JSON.decode!(encoded)

  defp session_row(source, session_key) do
    case q(
           source,
           "SELECT sessionKey, archetype FROM sessions WHERE sessionKey=?1",
           [session_key]
         ) do
      [[key, archetype]] -> %{session_key: key, archetype: archetype}
      [] -> nil
    end
  end

  # -- input validation ------------------------------------------------------

  defp validate_name(name) when is_binary(name) and name != "", do: :ok

  defp validate_name(_name),
    do: {:error, %{code: "invalid_entry", message: "invalid_entry rule: a name is required"}}

  defp validate_text(text) when is_binary(text) and text != "", do: :ok

  defp validate_text(_text),
    do:
      {:error,
       %{
         code: "invalid_entry",
         message: "invalid_entry rule: text is required; withdraw removes an entry"
       }}

  defp validate_archetypes(nil), do: {:ok, nil}

  defp validate_archetypes(archetypes) when is_list(archetypes) and archetypes != [] do
    if Enum.all?(archetypes, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(archetypes)},
      else: archetypes_error()
  end

  defp validate_archetypes(_archetypes), do: archetypes_error()

  defp archetypes_error do
    {:error,
     %{
       code: "invalid_entry",
       message:
         "invalid_entry rule: archetypes must be archetype names; " <>
           "omit them to scope to all descendants"
     }}
  end

  defp names_or_none([]), do: "none"
  defp names_or_none(names), do: Enum.join(names, ", ")

  defp q(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp q(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
