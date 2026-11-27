defmodule Tightbeam.SubtreeScope do
  @moduledoc """
  Where a rule applies (its scope) and which sessions it concerns by role.

  A rule may declare `scope = { subtree_of = "role:<name>" }`. Only the role
  name is stored. Each evaluation looks up the role's current holder, with no
  fallback: an unknown or unbound role, or one held by a session that is not
  active, covers nobody. A rule without a scope is rooted at the top of the
  session tree and covers everything, as rules always have.

  Whether a piece of work sits in the subtree depends on who it is owed to:

    * an assignment, by its current opener, or its holder when no session
      opened it;
    * a work item, by its delivery owner, or its creator when it has none;
    * anything else, by the calling session.

  That owner is in the subtree when it is the holder or sits under it in the
  session tree (`Org.topology_parent_sql/1`, the tree subtree guidance uses).

  A rule may also declare `roles = ["<name>", "<prefix>:*"]` beside
  `archetypes`. Matching a held role against those patterns is kept in
  `role_admits?/2` alone so its meaning can change without touching scope.

  Everything here is read only when `Tightbeam.FeatureFlags.subtree_rules?/0`
  is on; callers gate on it.
  """

  alias Tightbeam.{DB, Org, Roles}

  @max_depth 256

  @typedoc "What a rule's scope is judged against."
  @type refs :: %{
          optional(:assignment_id) => String.t() | nil,
          optional(:work_item_id) => String.t() | nil,
          optional(:caller) => String.t() | nil
        }

  # -- declarations ----------------------------------------------------------

  @doc """
  Validate the optional `scope` and `roles` keys of a rule entry.

  Returns `%{scope_role: name | nil, roles: [pattern]}`. `fail` raises with
  the message it is given, as each loader's own failure function does.
  """
  @spec parse!(map(), (String.t() -> no_return())) :: %{
          scope_role: String.t() | nil,
          roles: [String.t()]
        }
  def parse!(entry, fail) when is_map(entry) do
    %{scope_role: parse_scope!(Map.get(entry, "scope"), fail), roles: parse_roles!(entry, fail)}
  end

  defp parse_scope!(nil, _fail), do: nil

  defp parse_scope!(%{"subtree_of" => "role:" <> name} = scope, fail) when map_size(scope) == 1 do
    if Roles.valid_name?(name),
      do: name,
      else: fail.(~s(scope subtree_of names an invalid role: #{inspect(name)}))
  end

  defp parse_scope!(_scope, fail),
    do: fail.(~s(scope must be a table with only subtree_of = "role:<name>"))

  defp parse_roles!(entry, fail) do
    patterns = Map.get(entry, "roles", [])

    unless is_list(patterns) and Enum.all?(patterns, &is_binary/1),
      do: fail.("roles must be a list of strings")

    if Enum.uniq(patterns) != patterns, do: fail.("roles must not contain duplicates")

    Enum.each(patterns, fn pattern ->
      unless valid_pattern?(pattern),
        do: fail.(~s(roles entry #{inspect(pattern)} must be a role name or "<prefix>:*"))
    end)

    patterns
  end

  defp valid_pattern?(pattern) do
    case String.split_at(pattern, -2) do
      {prefix, ":*"} -> Roles.valid_name?(prefix)
      _ -> Roles.valid_name?(pattern)
    end
  end

  # -- the roles filter --------------------------------------------------------

  @doc """
  Whether any held role matches any declared pattern.

  A pattern is an exact role name, or `<prefix>:*`, which matches every role
  whose name starts with `<prefix>:`. This is the one place that decides what
  a `roles` entry means.
  """
  @spec role_admits?([String.t()], [String.t()]) :: boolean()
  def role_admits?(patterns, held) when is_list(patterns) and is_list(held) do
    Enum.any?(patterns, fn pattern ->
      case String.split_at(pattern, -2) do
        {prefix, ":*"} -> Enum.any?(held, &String.starts_with?(&1, prefix <> ":"))
        _ -> pattern in held
      end
    end)
  end

  def role_admits?(_patterns, _held), do: false

  @doc "Roles currently bound to `session_key`, in name order."
  @spec held_roles(DB.server() | DB.Txn.t(), String.t() | nil) :: [String.t()]
  def held_roles(_db, key) when not is_binary(key), do: []
  def held_roles(db, key), do: Roles.for_session(db, key)

  @doc "Every role binding as `%{role => session_key}`, for snapshot facts."
  @spec role_bindings(DB.server() | DB.Txn.t()) :: %{String.t() => String.t()}
  def role_bindings(db) do
    case DB.query(db, "SELECT name, boundSessionKey FROM roles WHERE boundSessionKey IS NOT NULL") do
      {:ok, rows} -> Map.new(rows, fn [name, key] -> {name, key} end)
    end
  end

  # -- scope -----------------------------------------------------------------

  @doc """
  The role's current holder when it is an active session; otherwise nil.

  Deliberately without the owner-Main fallback `Roles.resolve/2` applies:
  falling back would turn a scoped rule into a root rule.
  """
  @spec anchor_holder(DB.server() | DB.Txn.t(), String.t() | nil) :: String.t() | nil
  def anchor_holder(_db, role) when not is_binary(role), do: nil

  def anchor_holder(db, role) do
    case DB.query(
           db,
           """
           SELECT r.boundSessionKey FROM roles r
           JOIN sessions s ON s.sessionKey = r.boundSessionKey
           WHERE r.name = ?1 AND s.state = 'active'
           """,
           [role]
         ) do
      {:ok, [[key]]} when is_binary(key) -> key
      _ -> nil
    end
  end

  @doc """
  Whether work described by `refs` is covered by a rule anchored at `role`.

  A nil role is the root: it covers everything.
  """
  @spec covers?(DB.server() | DB.Txn.t(), String.t() | nil, refs()) :: boolean()
  def covers?(_db, nil, _refs), do: true

  def covers?(db, role, refs) when is_binary(role) do
    with holder when is_binary(holder) <- anchor_holder(db, role),
         owner when is_binary(owner) <- work_owner(db, refs) do
      holder in lineage(db, owner)
    else
      _ -> false
    end
  end

  @doc """
  The session the work is owed to: an assignment's current opener (its holder
  when no session opened it), a work item's delivery owner (its creator when
  it has none), or else the calling session.
  """
  @spec work_owner(DB.server() | DB.Txn.t(), refs()) :: String.t() | nil
  def work_owner(db, refs) do
    assignment_id = Map.get(refs, :assignment_id)
    work_item_id = Map.get(refs, :work_item_id)

    cond do
      is_binary(assignment_id) and assignment_id != "" ->
        assignment_owner(db, assignment_id)

      is_binary(work_item_id) and work_item_id != "" ->
        work_item_owner(db, work_item_id)

      true ->
        case Map.get(refs, :caller) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end
    end
  end

  defp assignment_owner(db, id) do
    case DB.query(
           db,
           "SELECT COALESCE(currentOpenerSessionKey, openedBySession), holderKey FROM assignments WHERE id=?1",
           [id]
         ) do
      {:ok, [[opener, _holder]]} when is_binary(opener) -> opener
      {:ok, [[nil, holder]]} when is_binary(holder) -> holder
      _ -> nil
    end
  end

  defp work_item_owner(db, id) do
    case DB.query(
           db,
           "SELECT COALESCE(deliveryOwnerSessionKey, createdBySession) FROM work_items WHERE id=?1",
           [id]
         ) do
      {:ok, [[key]]} when is_binary(key) -> key
      _ -> nil
    end
  end

  @doc "`key` followed by its ancestors in the session tree, nearest first."
  @spec lineage(DB.server() | DB.Txn.t(), String.t()) :: [String.t()]
  def lineage(db, key) when is_binary(key), do: walk_up(db, key, [key], 0)

  defp walk_up(_db, _key, acc, depth) when depth >= @max_depth, do: Enum.reverse(acc)

  defp walk_up(db, key, acc, depth) do
    sql = "SELECT #{Org.topology_parent_sql("s")} FROM sessions s WHERE s.sessionKey=?1"

    case DB.query(db, sql, [key]) do
      {:ok, [[parent]]} when is_binary(parent) ->
        if parent in acc,
          do: Enum.reverse(acc),
          else: walk_up(db, parent, [parent | acc], depth + 1)

      _ ->
        Enum.reverse(acc)
    end
  end
end
