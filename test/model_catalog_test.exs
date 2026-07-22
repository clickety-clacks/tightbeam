defmodule Tightbeam.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{Archetypes, Gateway, ModelCatalog}

  @fixtures Path.join(__DIR__, "fixtures/model_catalog")

  setup do
    base_dir = Path.join(System.tmp_dir!(), "model-catalog-#{System.unique_integer([:positive])}")
    token_dir = Path.join([base_dir, "auth", "claude"])
    codex_home = Path.join(base_dir, "codex-home")
    File.mkdir_p!(token_dir)
    File.mkdir_p!(codex_home)
    File.write!(Path.join(token_dir, "oauth-token"), "fixture-token")

    claude_json = File.read!(Path.join(@fixtures, "claude_models.json"))
    codex_json = File.read!(Path.join(@fixtures, "codex_models_cache.json"))

    claude_fetch = fn
      "/v1/models?limit=100", _headers ->
        {:ok, claude_json}

      "/v1/models/claude-haiku-4-5", _headers ->
        {:ok,
         JSON.encode!(%{
           id: "claude-haiku-4-5",
           display_name: "Claude Haiku 4.5",
           max_input_tokens: 200_000,
           capabilities: %{}
         })}
    end

    codex_read = fn _path -> {:ok, codex_json} end

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Archetypes)
    end)

    %{
      base_dir: base_dir,
      codex_home: codex_home,
      claude_fetch: claude_fetch,
      codex_read: codex_read
    }
  end

  test "derives full Claude and Codex inventories from provider fixtures", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")
    await_fresh(catalog, "codex")

    {claude, :fresh} = ModelCatalog.get("claude", catalog)
    {codex, :fresh} = ModelCatalog.get("codex", catalog)

    assert Enum.map(claude, & &1.ref) == [
             "claude-opus-4-8[high]",
             "claude-opus-4-8[low]",
             "claude-opus-4-8[max]",
             "claude-opus-4-8[medium]",
             "claude-haiku-4-5"
           ]

    opus = hd(claude)
    assert opus.display_name == "Claude Opus 4.8 [high]"
    assert opus.max_input_tokens == 1_000_000
    assert opus.efforts == ["high", "low", "max", "medium"]

    assert Enum.map(codex, & &1.ref) == [
             "gpt-5.6-sol[low]",
             "gpt-5.6-sol[medium]",
             "gpt-5.6-sol[high]",
             "gpt-5.6-sol[xhigh]",
             "gpt-5.6-sol[max]",
             "gpt-5.6-sol[ultra]",
             "gpt-5.6-mini"
           ]

    refute Enum.any?(claude ++ codex, &String.contains?(&1.ref, "[1m]"))
  end

  test "effort-qualified entries for the same model get distinguishable titles", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")

    {claude, :fresh} = ModelCatalog.get("claude", catalog)
    opus = Enum.filter(claude, &(&1.efforts != []))

    assert length(opus) == 4
    assert Enum.map(opus, & &1.name) |> Enum.uniq() |> length() == 4

    assert Enum.map(opus, & &1.name) == [
             "Claude Opus 4.8 [high]",
             "Claude Opus 4.8 [low]",
             "Claude Opus 4.8 [max]",
             "Claude Opus 4.8 [medium]"
           ]

    haiku = Enum.find(claude, &(&1.ref == "claude-haiku-4-5"))
    assert haiku.name == "Claude Haiku 4.5"
  end

  test "membership carries fresh, stale, and unavailable health", ctx do
    clock =
      start_supervised!(%{id: unique_name(:clock), start: {Agent, :start_link, [fn -> 0 end]}})

    failures =
      start_supervised!(%{
        id: unique_name(:failures),
        start: {Agent, :start_link, [fn -> false end]}
      })

    fetch = fn path, headers ->
      if Agent.get(failures, & &1),
        do: {:error, :fetch_failed},
        else: ctx.claude_fetch.(path, headers)
    end

    catalog =
      start_catalog(ctx,
        ttl_ms: 10,
        now: fn -> Agent.get(clock, & &1) end,
        claude_fetch: fetch
      )

    await_fresh(catalog, "claude")

    assert ModelCatalog.member?("claude", "claude-opus-4-8[high]", catalog) == %{
             present?: true,
             health: :fresh
           }

    assert ModelCatalog.member?("claude", "absent", catalog) == %{
             present?: false,
             health: :fresh
           }

    Agent.update(clock, fn _ -> 11 end)
    Agent.update(failures, fn _ -> true end)

    assert ModelCatalog.member?("claude", "claude-opus-4-8[high]", catalog) == %{
             present?: true,
             health: :stale
           }

    await(fn -> ModelCatalog.get("claude", catalog) |> elem(1) == :stale end)

    missing = unique_name(:missing_catalog)

    start_supervised!(
      {ModelCatalog,
       name: missing,
       base_dir: Path.join(ctx.base_dir, "missing"),
       codex_home: Path.join(ctx.base_dir, "missing-codex")}
    )

    await(fn ->
      ModelCatalog.member?("claude", "anything", missing).health ==
        {:unavailable, :missing_token}
    end)
  end

  test "failed fetch, malformed JSON, and missing cache degrade without crashing readers", ctx do
    for {label, opts, harness, reason} <- [
          {:failed, [claude_fetch: fn _, _ -> {:error, :network_down} end], "claude",
           :network_down},
          {:malformed, [claude_fetch: fn _, _ -> {:ok, "{"} end], "claude", :malformed_json},
          {:missing_cache, [codex_read: fn _ -> {:error, :enoent} end], "codex", :missing_cache}
        ] do
      name = unique_name(label)
      catalog = start_catalog(ctx, Keyword.put(opts, :name, name))

      await(fn -> ModelCatalog.get(harness, catalog) == {[], {:unavailable, reason}} end)
      assert is_map(ModelCatalog.member?(harness, "absent", catalog))
    end

    Archetypes.load!(ctx.base_dir)
    assert is_map(Gateway.org_options())
  end

  test "a hung refresh never blocks a reader or concurrent org-options list", ctx do
    parent = self()

    hung_fetch = fn _path, _headers ->
      send(parent, {:fetch_started, self()})

      receive do
        :release -> {:error, :released}
      end
    end

    catalog = start_catalog(ctx, name: ModelCatalog, claude_fetch: hung_fetch)
    assert_receive {:fetch_started, fetch_pid}
    Archetypes.load!(ctx.base_dir)

    {reader_us, {[], {:unavailable, :not_derived}}} =
      :timer.tc(fn -> ModelCatalog.get("claude", catalog) end)

    {list_us, options} = :timer.tc(&Gateway.org_options/0)

    assert reader_us < 100_000
    assert list_us < 100_000
    assert options.models["claude"] == []
    send(fetch_pid, :release)
  end

  test "every derived ref validates and absent refs do not", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")
    await_fresh(catalog, "codex")

    for harness <- ["claude", "codex"], entry <- ModelCatalog.get(catalog)[harness] do
      assert ModelCatalog.member?(harness, entry.ref, catalog) == %{
               present?: true,
               health: :fresh
             }
    end

    assert ModelCatalog.member?("claude", "opus[1m]", catalog) == %{
             present?: false,
             health: :fresh
           }

    source =
      [Path.expand("../lib", __DIR__), Path.expand("../config", __DIR__)]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute source =~ "@" <> "model_catalog"
    refute source =~ "model_" <> "pins"
  end

  defp start_catalog(ctx, overrides \\ []) do
    name = Keyword.get(overrides, :name, unique_name(:catalog))

    opts =
      [
        name: name,
        base_dir: ctx.base_dir,
        codex_home: ctx.codex_home,
        claude_fetch: ctx.claude_fetch,
        codex_read: ctx.codex_read
      ]
      |> Keyword.merge(overrides)

    start_supervised!(%{id: name, start: {ModelCatalog, :start_link, [opts]}})
    name
  end

  defp await_fresh(catalog, harness) do
    await(fn -> ModelCatalog.get(harness, catalog) |> elem(1) == :fresh end)
  end

  defp await(fun, attempts \\ 100)

  defp await(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      await(fun, attempts - 1)
    end
  end

  defp await(_fun, 0), do: flunk("condition did not become true")
  defp unique_name(label), do: String.to_atom("#{label}_#{System.unique_integer([:positive])}")
end
