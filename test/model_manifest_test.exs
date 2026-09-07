defmodule Tightbeam.ModelManifestTest do
  use ExUnit.Case, async: true

  alias Tightbeam.ModelManifest

  setup do
    base = Path.join(System.tmp_dir!(), "manifest-loader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, bundled: Application.app_dir(:tightbeam, "priv/model-manifest.json")}
  end

  test "the release-bundled document validates and is closed over its references", ctx do
    assert {:ok, document} = ctx.bundled |> File.read!() |> ModelManifest.validate()
    assert document["version"] == 1

    assert get_in(document, ["providers", "claude", "defaults", "chat"]) ==
             "claude-sonnet-5"
  end

  test "validation names duplicate slugs, alias conflicts, dangling profiles, defaults, and gates",
       ctx do
    document = bundled_document(ctx)
    [first | _] = get_in(document, ["providers", "claude", "models"])

    duplicate = put_in(document, ["providers", "claude", "models"], [first, first])
    assert {:error, {:invalid_field, path, _}} = ModelManifest.validate(duplicate)
    assert path =~ "slug"

    alias_conflict = Map.put(first, "aliases", [first["slug"]])
    invalid = put_in(document, ["providers", "claude", "models"], [alias_conflict])

    assert {:error, {:invalid_field, path, :duplicate_or_conflicting}} =
             ModelManifest.validate(invalid)

    assert path =~ "aliases"

    dangling = Map.put(first, "profile", "absent")
    invalid = put_in(document, ["providers", "claude", "models"], [dangling])
    assert {:error, {:invalid_field, path, :missing_profile}} = ModelManifest.validate(invalid)
    assert path =~ "profile"

    invalid = put_in(document, ["providers", "claude", "defaults", "chat"], "absent")
    assert {:error, {:invalid_field, path, :unknown_slug}} = ModelManifest.validate(invalid)
    assert path =~ "defaults.chat"

    bad_gate =
      first
      |> put_in(["adapter", "claudeCode", "minVersion"], "2.0.0")
      |> put_in(["adapter", "claudeCode", "maxVersionExclusive"], "2.0.0")

    invalid = put_in(document, ["providers", "claude", "models"], [bad_gate])

    assert {:error, {:invalid_field, path, :empty_version_range}} =
             ModelManifest.validate(invalid)

    assert path =~ "claudeCode"

    assert {:error, {:invalid_field, "providers", :non_string_name}} =
             ModelManifest.validate(%{"version" => 1, "providers" => %{claude: %{}}})
  end

  test "a remote success atomically becomes last-good and survives restart", ctx do
    remote = manifest_with_slug(ctx, "claude-remote")
    name = unique_name()

    start_manifest(name, ctx,
      fetch: fn _url, _timeout -> {:ok, remote} end,
      ttl_ms: :timer.hours(1)
    )

    await(fn -> ModelManifest.get(name).health == :fresh end)
    assert %{source: :remote} = snapshot = ModelManifest.get(name)
    assert model_slugs(snapshot) == ["claude-remote"]

    cache = Path.join(ctx.base, "model-manifest.json")
    assert {:ok, _document} = cache |> File.read!() |> ModelManifest.validate()
    assert Path.wildcard(cache <> ".tmp-*") == []

    stop_supervised!(name)
    restarted = unique_name()
    start_manifest(restarted, ctx, fetch: fn _url, _timeout -> {:error, :offline} end)

    assert %{source: :disk, health: :stale} = ModelManifest.get(restarted)
    assert model_slugs(ModelManifest.get(restarted)) == ["claude-remote"]
  end

  test "malformed nested remote data leaves the loader alive on last-good", ctx do
    valid = File.read!(ctx.bundled)
    document = JSON.decode!(valid)
    [first | rest] = get_in(document, ["providers", "claude", "models"])
    malformed_first = Map.put(first, "adapter", "not-a-map")

    malformed =
      document
      |> put_in(["providers", "claude", "models"], [malformed_first | rest])
      |> JSON.encode!()

    {:ok, results} = Agent.start_link(fn -> [{:ok, valid}, {:ok, malformed}] end)

    fetch = fn _url, _timeout ->
      Agent.get_and_update(results, fn [result | remaining] -> {result, remaining} end)
    end

    name = unique_name()
    start_manifest(name, ctx, fetch: fetch, ttl_ms: :timer.hours(1))
    await(fn -> ModelManifest.get(name).health == :fresh end)

    snapshot = ModelManifest.get(name)
    pid = Process.whereis(name)
    send(pid, :refresh_due)
    await(fn -> ModelManifest.get(name).health == :stale end)

    assert Process.whereis(name) == pid
    assert Process.alive?(pid)
    assert ModelManifest.get(name).document == snapshot.document
    assert {:error, {:invalid_field, path, :wrong_shape}} = ModelManifest.validate(malformed)
    assert path =~ ".adapter"
  end

  test "invalid remote leaves bundled last-good active and a hung fetch never holds readers",
       ctx do
    parent = self()
    name = unique_name()

    start_manifest(name, ctx,
      fetch: fn _url, _timeout ->
        send(parent, {:fetch_started, self()})

        receive do
          :release -> {:ok, "{}"}
        end
      end
    )

    assert_receive {:fetch_started, worker}
    {micros, snapshot} = :timer.tc(fn -> ModelManifest.get(name) end)
    assert micros < 100_000
    assert snapshot.source == :bundled
    send(worker, :release)
    await(fn -> match?({:unavailable, _reason}, ModelManifest.get(name).health) end)
  end

  test "failure retries once per retry window and success waits for the hourly TTL", ctx do
    parent = self()
    name = unique_name()

    fetch = fn _url, _timeout ->
      send(parent, {:fetch, self()})

      receive do
        {:finish, result} -> result
      end
    end

    start_manifest(name, ctx, fetch: fetch, retry_ms: 20, ttl_ms: 100)
    assert_receive {:fetch, first}
    Enum.each(1..10, fn _ -> ModelManifest.get(name) end)
    refute_receive {:fetch, _worker}

    send(first, {:finish, {:error, :offline}})
    assert_receive {:fetch, second}, 200
    send(second, {:finish, {:ok, manifest_with_slug(ctx, "claude-fresh")}})
    await(fn -> ModelManifest.get(name).health == :fresh end)
    refute_receive {:fetch, _worker}, 50
    assert_receive {:fetch, _third}, 200
  end

  defp start_manifest(name, ctx, opts) do
    opts =
      Keyword.merge(
        [name: name, base_dir: ctx.base, bundled_path: ctx.bundled],
        opts
      )

    start_supervised!(%{id: name, start: {ModelManifest, :start_link, [opts]}})
  end

  defp bundled_document(ctx), do: ctx.bundled |> File.read!() |> JSON.decode!()

  defp manifest_with_slug(ctx, slug) do
    model = %{"slug" => slug, "name" => slug, "aliases" => [], "status" => "current"}

    ctx
    |> bundled_document()
    |> put_in(["providers", "claude", "models"], [model])
    |> put_in(["providers", "claude", "defaults", "chat"], slug)
    |> JSON.encode!()
  end

  defp model_slugs(snapshot),
    do: Enum.map(get_in(snapshot.document, ["providers", "claude", "models"]), & &1["slug"])

  defp await(fun, attempts \\ 100)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      await(fun, attempts - 1)
    end
  end

  defp unique_name, do: String.to_atom("model_manifest_#{System.unique_integer([:positive])}")
end
