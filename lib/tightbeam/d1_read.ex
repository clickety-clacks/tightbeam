defmodule Tightbeam.D1Read do
  @moduledoc false

  alias Tightbeam.{DB, Identity}

  @resources %{
    config: %{resource: "config", route: "config.collection", filters: ~w(key), order: ~w(key)},
    host_environment: %{
      resource: "host environment",
      route: "host_environment.collection",
      filters: ~w(host harness name),
      order: ~w(host harness name)
    },
    hosts: %{resource: "hosts", route: "hosts.collection", filters: ~w(host), order: ~w(host)},
    users: %{
      resource: "users",
      route: "users.collection",
      filters: ~w(userId),
      order: ~w(userId)
    },
    identity: %{
      resource: "identity",
      route: "identity.collection",
      filters: ~w(name state),
      order: ~w(name)
    },
    kungfu: %{
      resource: "kungfu",
      route: "kungfu.collection",
      filters: ~w(status rootArchetype),
      order: ~w(name)
    }
  }

  @doc "The sole maintenance-line D1 resource catalog."
  def spec(resource), do: Map.fetch!(@resources, resource)

  @doc "Administrative resources are owner-admin only; hosts are organization-visible."
  def visible?(:hosts, _is_admin), do: true
  def visible?(_resource, is_admin), do: is_admin

  @doc "Read and redact a fixed-shape D1 collection from current 0.1.9 sources."
  def collection(db, base_dir, resource, filters) do
    resource
    |> rows(db, base_dir)
    |> Enum.filter(&matches?(&1, filters))
    |> Enum.sort_by(&tuple(resource, &1))
  end

  def detail(db, base_dir, resource, id) do
    collection(db, base_dir, resource, %{})
    |> Enum.find(&(detail_id(resource, &1) == id))
  end

  def tuple(resource, item), do: Enum.map(spec(resource).order, &Map.fetch!(item, &1))

  @doc "Encode one public D1 item in its ruled field order without map-order drift."
  def encode(resource, item) do
    fields =
      case resource do
        :config ->
          ~w(key value updatedAt rowVersion)

        :host_environment ->
          ~w(host harness name value valuePresent updatedAt rowVersion)

        :hosts ->
          ~w(host rowVersion)

        :users ->
          ~w(userId isAdmin createdAt rowVersion)

        :identity ->
          ~w(name liveRevision state sessionRevisions staleness conflicts rowVersion)

        :kungfu ->
          ~w(name purpose phrases rootArchetype installedRevision status documents rowVersion)
      end

    "{" <>
      Enum.map_join(fields, ",", &(JSON.encode!(&1) <> ":" <> JSON.encode!(Map.fetch!(item, &1)))) <>
      "}"
  end

  defp rows(:config, db, _base_dir) do
    {:ok, rows} = DB.query(db, "SELECT key, value, updatedAt FROM org_settings ORDER BY key")

    Enum.map(rows, fn [key, value, updated_at] ->
      %{
        "key" => key,
        "value" => if(key == "default-archetype", do: value, else: nil),
        "updatedAt" => updated_at,
        "rowVersion" => updated_at
      }
    end)
  end

  defp rows(:host_environment, db, _base_dir) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT host, harness, name, setAt FROM harness_env_overlays ORDER BY host, harness, name"
      )

    Enum.map(rows, fn [host, harness, name, updated_at] ->
      %{
        "host" => host,
        "harness" => harness,
        "name" => name,
        "value" => nil,
        "valuePresent" => true,
        "updatedAt" => updated_at,
        "rowVersion" => updated_at
      }
    end)
  end

  defp rows(:hosts, db, _base_dir) do
    {:ok, rows} = DB.query(db, "SELECT name FROM hosts ORDER BY name")
    Enum.map(rows, fn [host] -> %{"host" => host, "rowVersion" => 1} end)
  end

  defp rows(:users, db, _base_dir) do
    {:ok, rows} =
      DB.query(db, "SELECT userId, isAdmin, createdAt FROM users ORDER BY userId")

    Enum.map(rows, fn [user_id, is_admin, created_at] ->
      %{
        "userId" => user_id,
        "isAdmin" => is_admin == 1,
        "createdAt" => created_at,
        "rowVersion" => created_at
      }
    end)
  end

  defp rows(:identity, db, base_dir) do
    status = Identity.status(base_dir)

    {:ok, revisions} =
      DB.query(
        db,
        "SELECT sessionKey, identityRevision FROM sessions WHERE identityRevision IS NOT NULL ORDER BY sessionKey"
      )

    session_revisions = Map.new(revisions, fn [key, revision] -> {key, revision} end)
    live_revision = status.live_revision

    [
      %{
        "name" => "served",
        "liveRevision" => live_revision,
        "state" => Atom.to_string(status.state),
        "sessionRevisions" => session_revisions,
        "staleness" =>
          session_revisions
          |> Enum.flat_map(fn {key, revision} ->
            if revision == live_revision, do: [], else: [key]
          end)
          |> Enum.sort(),
        "conflicts" => Enum.sort(status.conflicting_paths),
        "rowVersion" => 1
      }
    ]
  end

  defp rows(:kungfu, _db, _base_dir) do
    Identity.available_bundles()
    |> Enum.map(fn bundle ->
      %{
        "name" => bundle.name,
        "purpose" => bundle.purpose,
        "phrases" => Enum.sort(bundle.phrases),
        "rootArchetype" => bundle.root_archetype,
        "installedRevision" => nil,
        "status" => "available",
        "documents" => bundle_documents(bundle.name),
        "rowVersion" => 1
      }
    end)
  end

  defp matches?(item, filters) do
    Enum.all?(filters, fn {field, values} ->
      Map.get(item, field) in values
    end)
  end

  defp detail_id(:config, item), do: item["key"]
  defp detail_id(:hosts, item), do: item["host"]
  defp detail_id(:users, item), do: item["userId"]
  defp detail_id(:identity, item), do: item["name"]
  defp detail_id(:kungfu, item), do: item["name"]

  defp bundle_documents(name) do
    root = Application.app_dir(:tightbeam, Path.join("priv/kungfu", name))

    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path ->
      content = File.read!(path)

      %{
        "path" => Path.relative_to(path, root),
        "content" => content,
        "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      }
    end)
    |> Enum.sort_by(& &1["path"])
  end
end
