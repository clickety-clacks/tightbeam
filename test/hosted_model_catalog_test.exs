defmodule Tightbeam.HostedModelCatalogTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Model, ModelCatalog, Placement, Unroutable}

  @host "manifest-host"

  setup do
    base = Path.join(System.tmp_dir!(), "hosted-catalog-#{System.unique_integer([:positive])}")
    db = String.to_atom("hosted_catalog_db_#{System.unique_integer([:positive])}")
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, db: db, document: bundled_document()}
  end

  test "Claude offering comes only from the manifest and carries gates, aliases, status and profiles",
       ctx do
    old = start_catalog(ctx, "2.1.220")
    await_health(old, :fresh)
    {entries, :fresh} = ModelCatalog.get(@host, "claude", old)
    refute Enum.any?(entries, &(&1.family == "claude-fable-5-1"))
    assert Enum.any?(entries, &(&1.family == "claude-opus-5"))

    assert [%{name: "Fable 5.1", min_version: "2.1.257", current_version: "2.1.220"}] =
             @host |> ModelCatalog.metadata("claude", old) |> Map.fetch!(:version_blocks)

    selection = Model.new("claude-fable-5-1", context: "1m", effort: "high")

    assert {:error,
            %Unroutable{
              cause: :family_absent,
              version_block: %{slug: "claude-fable-5-1"}
            } = refusal} =
             ModelCatalog.route(@host, "claude", selection, old)

    assert Unroutable.message(refusal) =~
             "Claude Code v2.1.220 is too old for Fable 5.1; needs v2.1.257"

    assert {:error, %Unroutable{version_block: %{slug: "claude-fable-5-1"}} = refusal} =
             ModelCatalog.route(@host, selection, old)

    assert Unroutable.message(refusal) =~ "claude on host #{@host}"

    current = start_catalog(ctx, "2.1.257")
    await_health(current, :fresh)
    {entries, :fresh} = ModelCatalog.get(@host, "claude", current)

    assert Enum.any?(entries, fn entry ->
             entry.family == "claude-fable-5-1" and entry.context == "1m" and
               entry.status == "current" and entry.profile == "fable-5"
           end)

    assert {:ok, %{entry: %{family: "claude-fable-5-1"}}} =
             ModelCatalog.route(@host, "claude", Model.new("fable", effort: "high"), current)

    refute Enum.any?(entries, &String.contains?(&1.family, "["))
  end

  test "an unknown Claude slug passes through unchanged with nearest family defaults", ctx do
    catalog = start_catalog(ctx, "2.1.257")
    await_health(catalog, :fresh)
    selection = Model.new("claude-fable-future", context: "1m", effort: "max")

    assert {:ok, %{entry: entry}} = ModelCatalog.route(@host, "claude", selection, catalog)

    assert {entry.family, entry.context, entry.profile, entry.max_input_tokens} ==
             {"claude-fable-future", "1m", "fable-5", 1_000_000}

    assert entry.efforts == ~w(low medium high xhigh max)

    bare = Model.new("claude-not-in-manifest", context: "2m", effort: "max")
    assert {:ok, %{entry: bare_entry}} = ModelCatalog.route(@host, "claude", bare, catalog)
    assert bare_entry.family == "claude-not-in-manifest"
    assert bare_entry.context == "2m"
    assert bare_entry.profile == nil
    assert bare_entry.capabilities == %{}
  end

  test "credential rejection remains typed and manifest health remains independently fresh",
       ctx do
    catalog =
      start_catalog(ctx, "2.1.257", fn _provider, _host ->
        {:credential_rejected, %{status: 401, cause: :invalid_grant}}
      end)

    await(fn ->
      match?(
        {[], {:unavailable, {:credential_rejected, _reason}}},
        ModelCatalog.get(@host, "claude", catalog)
      )
    end)

    assert ModelCatalog.manifest_health(@host, "claude", catalog) == :fresh

    assert {:error, %Unroutable{} = refusal} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-sonnet-5", effort: "medium"),
               catalog
             )

    assert Unroutable.message(refusal) =~ "credential"
    assert Unroutable.message(refusal) =~ "rejected"
  end

  defp start_catalog(ctx, version, credential_status \\ fn _provider, _host -> :onboarded end) do
    name = String.to_atom("hosted_catalog_#{System.unique_integer([:positive])}")
    snapshot = %{document: ctx.document, source: :bundled, health: :fresh}

    start_supervised!(%{
      id: name,
      start:
        {ModelCatalog, :start_link,
         [
           [
             name: name,
             base_dir: ctx.base,
             db: ctx.db,
             hosts: fn -> %{@host => %{base_dir: ctx.base, ssh: nil}} end,
             credential_status: credential_status,
             credential_kind: :subscription,
             model_manifest: fn -> snapshot end,
             claude_code_version: version,
             sh: fn _command -> {"unavailable", 1} end
           ]
         ]}
    })
  end

  defp bundled_document do
    :tightbeam
    |> Application.app_dir("priv/model-manifest.json")
    |> File.read!()
    |> JSON.decode!()
  end

  defp await_health(catalog, health),
    do: await(fn -> elem(ModelCatalog.get(@host, "claude", catalog), 1) == health end)

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
end
