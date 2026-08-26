defmodule Tightbeam.ModelCatalogTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.{Archetypes, Gateway, Model, ModelCatalog, Placement, Unroutable}
  alias Tightbeam.Harness.Support

  @fixtures Path.join(__DIR__, "fixtures/model_catalog")
  @host "testhost"
  @claude_secret "sk-ant-oat01-NEVER-ON-A-COMMAND-LINE"
  @codex_secret "ey-codex-access-NEVER-ON-A-COMMAND-LINE"

  setup do
    base_dir = Path.join(System.tmp_dir!(), "model-catalog-#{System.unique_integer([:positive])}")
    db = :"model_catalog_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Placement.ensure_schema(db)
    token_dir = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(token_dir)

    File.write!(
      Path.join(token_dir, ".credentials.json"),
      ~s({"claudeAiOauth":{"accessToken":"fixture-token"}})
    )

    claude_json = fixture_body("claude_models.jsonc")
    claude_detail_json = fixture_body("claude_model_detail.jsonc")
    codex_json = fixture_body("codex_models.jsonc")

    claude_fetch = fn
      "/v1/models?limit=100", _headers ->
        {:ok, claude_json}

      "/v1/models/claude-haiku-4-5-20251001", _headers ->
        {:ok, claude_detail_json}
    end

    # Codex has no local-file path any more: on every host the catalog is one
    # HTTPS call the host itself makes, so the seam is the runner, not a reader.
    codex_sh = fn _command -> catalog_reply(codex_json) end

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Archetypes)
    end)

    %{
      base_dir: base_dir,
      db: db,
      claude_fetch: claude_fetch,
      codex_json: codex_json,
      codex_sh: codex_sh
    }
  end

  test "derives consumed Claude and Codex fields from provider captures", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")
    await_fresh(catalog, "codex")

    {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)
    {codex, :fresh} = ModelCatalog.get(@host, "codex", catalog)

    opus = Enum.find(claude, &(&1.family == "claude-opus-5"))
    assert opus.display_name == "Claude Opus 5"
    assert opus.max_input_tokens == 1_000_000
    assert opus.context == nil
    assert MapSet.new(opus.efforts) == MapSet.new(["low", "medium", "high", "xhigh", "max"])

    # ONE entry per vendor model. The effort tiers are a PROPERTY of the entry,
    # not five identities — an identity is a family and a context variant.
    assert Enum.map(codex, & &1.family) == ["gpt-5.6-sol"]

    codex_sol = Enum.find(codex, &(&1.family == "gpt-5.6-sol"))
    assert codex_sol.display_name == "GPT-5.6-Sol"
    assert codex_sol.max_input_tokens == 272_000
    assert codex_sol.efforts == ["low", "medium", "high", "xhigh", "max", "ultra"]

    assert get_in(codex_sol.capabilities, [
             "supported_reasoning_levels",
             Access.at(1),
             "effort"
           ]) ==
             "medium"

    refute Enum.any?(claude ++ codex, &(&1.context != nil))
  end

  # THE DEFECT, at the catalog. Anthropic spells a context-window variant
  # `claude-fable-5[1m]`; Tightbeam used to spell a reasoning level the same
  # way. The catalog read the vendor's bracket as ours — it stripped `[1m]`,
  # discarded that it existed, and re-attached our five effort levels — so the
  # 1M-context model silently ceased to exist and no operator could ask for it.
  test "a vendor context variant is its own model, with our efforts attached to it", ctx do
    fetch = fn "/v1/models?limit=100", _headers ->
      {:ok,
       JSON.encode!(%{
         "data" => [
           context_variant_model("claude-fable-5"),
           context_variant_model("claude-fable-5[1m]")
         ]
       })}
    end

    catalog = start_catalog(ctx, claude_fetch: fetch)
    await_fresh(catalog, "claude")
    {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)

    assert Enum.map(claude, &{&1.family, &1.context}) == [
             {"claude-fable-5", nil},
             {"claude-fable-5", "1m"}
           ]

    # The context variant carries OUR efforts, and `1m` is not one of them.
    wide = Enum.find(claude, &(&1.context == "1m"))
    assert MapSet.new(wide.efforts) == MapSet.new(["low", "high"])

    assert {:ok, %{entry: %{context: "1m"}}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-fable-5", context: "1m", effort: "high"),
               catalog
             )

    # …and it is a DIFFERENT model from the default-window one, not a synonym.
    assert {:ok, %{entry: %{context: nil}}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-fable-5", effort: "high"),
               catalog
             )

    # A context variant asked for as an EFFORT is a tier the model does not
    # offer, not a model that does not exist.
    assert {:error, %Unroutable{cause: :effort_not_offered}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("claude-fable-5", effort: "1m"),
               catalog
             )
  end

  defp context_variant_model(id) do
    %{
      "type" => "model",
      "id" => id,
      "display_name" => "Claude Fable 5",
      "max_input_tokens" => 1_000_000,
      "capabilities" => %{
        "effort" => %{
          "supported" => true,
          "low" => %{"supported" => true},
          "high" => %{"supported" => true}
        }
      }
    }
  end

  test "fills a summary row from the captured Claude detail body", ctx do
    summary =
      "claude_models.jsonc"
      |> fixture_json()
      |> Map.fetch!("data")
      |> Enum.find(&(&1["id"] == "claude-haiku-4-5-20251001"))
      |> Map.delete("capabilities")

    list_body = JSON.encode!(%{"data" => [summary]})
    detail_body = fixture_body("claude_model_detail.jsonc")

    claude_fetch = fn
      "/v1/models?limit=100", _headers -> {:ok, list_body}
      "/v1/models/claude-haiku-4-5-20251001", _headers -> {:ok, detail_body}
    end

    catalog = start_catalog(ctx, claude_fetch: claude_fetch)
    await_fresh(catalog, "claude")

    assert {[%{family: "claude-haiku-4-5-20251001", context: nil} = entry], :fresh} =
             ModelCatalog.get(@host, "claude", catalog)

    assert entry.display_name == "Claude Haiku 4.5"
    assert entry.max_input_tokens == 200_000
    assert get_in(entry.capabilities, ["thinking", "supported"])
  end

  test "claude preserves every provider capability without imposing a tier allowlist", ctx do
    claude_json =
      JSON.encode!(%{
        data: [
          %{
            id: "claude-sort-test",
            display_name: "Claude Sort Test",
            max_input_tokens: 1_000_000,
            capabilities: %{
              effort: %{
                xhigh: %{supported: true},
                max: %{supported: true},
                low: %{supported: true},
                ultra: %{supported: true},
                high: %{supported: true},
                medium: %{supported: true}
              }
            }
          }
        ]
      })

    claude_fetch = fn "/v1/models?limit=100", _headers -> {:ok, claude_json} end

    catalog = start_catalog(ctx, claude_fetch: claude_fetch)
    await_fresh(catalog, "claude")

    {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)

    assert Enum.map(claude, & &1.family) == ["claude-sort-test"]

    assert Enum.sort(hd(claude).efforts) == [
             "high",
             "low",
             "max",
             "medium",
             "ultra",
             "xhigh"
           ]
  end

  # Regression: the live endpoint and captured fixture carry an aggregate `supported`
  # boolean beside the per-level maps. The parser once rejected the whole catalog as
  # :malformed_catalog on that provider field.
  test "claude effort parser accepts the live aggregate supported boolean", ctx do
    claude_json =
      JSON.encode!(%{
        data: [
          %{
            id: "claude-live-shape",
            display_name: "Claude Live Shape",
            max_input_tokens: 1_000_000,
            capabilities: %{
              effort: %{
                supported: true,
                low: %{supported: true},
                medium: %{supported: true},
                high: %{supported: false}
              }
            }
          }
        ]
      })

    claude_fetch = fn "/v1/models?limit=100", _headers -> {:ok, claude_json} end

    catalog = start_catalog(ctx, claude_fetch: claude_fetch)
    await_fresh(catalog, "claude")

    {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)

    assert Enum.map(claude, & &1.family) == ["claude-live-shape"]
    assert Enum.sort(hd(claude).efforts) == ["low", "medium"]
  end

  test "codex preserves provider-reported effort order without tier presentation logic", ctx do
    codex_json =
      JSON.encode!(%{
        models: [
          %{
            slug: "gpt-sort-test",
            display_name: "GPT Sort Test",
            supported_reasoning_levels: [
              %{effort: "mega"},
              %{effort: "xhigh"},
              %{effort: "max"},
              %{effort: "low"},
              %{effort: "ultra"},
              %{effort: "high"},
              %{effort: "medium"}
            ]
          }
        ]
      })

    catalog = start_catalog(ctx, sh: fn _command -> catalog_reply(codex_json) end)
    await_fresh(catalog, "codex")

    {codex, :fresh} = ModelCatalog.get(@host, "codex", catalog)

    assert Enum.map(codex, & &1.family) == ["gpt-sort-test"]

    assert hd(codex).efforts == [
             "mega",
             "xhigh",
             "max",
             "low",
             "ultra",
             "high",
             "medium"
           ]
  end

  test "mixed valid and unexpectedly shaped rows degrade atomically", ctx do
    claude_valid = %{
      id: "claude-valid",
      display_name: "Claude Valid",
      max_input_tokens: 200_000,
      capabilities: %{effort: %{}}
    }

    codex_valid = %{
      slug: "gpt-valid",
      display_name: "GPT Valid",
      supported_reasoning_levels: []
    }

    claude_fetch = fn malformed ->
      fn "/v1/models?limit=100", _headers ->
        {:ok, JSON.encode!(%{data: [claude_valid, malformed]})}
      end
    end

    codex_sh = fn malformed ->
      fn _command -> catalog_reply(JSON.encode!(%{models: [codex_valid, malformed]})) end
    end

    for {label, harness, overrides} <- [
          {:claude_missing_id, "claude",
           [
             claude_fetch:
               claude_fetch.(%{
                 display_name: "Missing ID",
                 max_input_tokens: 200_000,
                 capabilities: %{effort: %{}}
               })
           ]},
          {:claude_missing_max_input_tokens, "claude",
           [
             claude_fetch:
               claude_fetch.(%{
                 id: "claude-missing-max-input-tokens",
                 display_name: "Missing Max Input Tokens",
                 capabilities: %{effort: %{}}
               })
           ]},
          {:claude_null_max_input_tokens, "claude",
           [
             claude_fetch:
               claude_fetch.(%{
                 id: "claude-null-max-input-tokens",
                 display_name: "Null Max Input Tokens",
                 max_input_tokens: nil,
                 capabilities: %{effort: %{}}
               })
           ]},
          {:codex_missing_slug, "codex",
           [
             sh:
               codex_sh.(%{
                 display_name: "Missing Slug",
                 supported_reasoning_levels: []
               })
           ]},
          {:codex_missing_supported_reasoning_levels, "codex",
           [
             sh:
               codex_sh.(%{
                 slug: "gpt-missing-supported-reasoning-levels",
                 display_name: "Missing Supported Reasoning Levels"
               })
           ]},
          {:codex_null_supported_reasoning_levels, "codex",
           [
             sh:
               codex_sh.(%{
                 slug: "gpt-null-supported-reasoning-levels",
                 display_name: "Null Supported Reasoning Levels",
                 supported_reasoning_levels: nil
               })
           ]}
        ] do
      catalog = start_catalog(ctx, Keyword.put(overrides, :name, unique_name(label)))

      await(fn ->
        ModelCatalog.get(@host, harness, catalog) == {[], {:unavailable, :malformed_catalog}}
      end)

      assert ModelCatalog.get(@host, harness, catalog) ==
               {[], {:unavailable, :malformed_catalog}}
    end
  end

  test "routing serves populated stale inventories and refuses unavailable ones", ctx do
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

    opus_high = Model.new("claude-opus-5", effort: "high")

    assert {:ok, %{harness: "claude", health: :fresh}} =
             ModelCatalog.route(@host, "claude", opus_high, catalog)

    assert {:error, %Unroutable{cause: :family_absent, health: [{"claude", :fresh}]}} =
             ModelCatalog.route(@host, "claude", Model.new("absent"), catalog)

    Agent.update(clock, fn _ -> 11 end)
    Agent.update(failures, fn _ -> true end)

    await(fn -> ModelCatalog.get(@host, "claude", catalog) |> elem(1) == :stale end)

    assert {:ok, %{harness: "claude", health: :stale}} =
             ModelCatalog.route(@host, "claude", opus_high, catalog)

    assert {:error,
            %Unroutable{
              cause: :family_absent,
              health: [{"claude", :stale}],
              offered: offered
            }} = ModelCatalog.route(@host, "claude", Model.new("absent"), catalog)

    assert Enum.any?(offered, &match?(%{entry: %{family: "claude-opus-5"}}, &1))

    missing = unique_name(:missing_catalog)

    start_supervised!(
      {ModelCatalog,
       name: missing,
       base_dir: Path.join(ctx.base_dir, "missing"),
       db: ctx.db,
       sh: ctx.codex_sh,
       credential_status: fn _provider -> :onboarded end}
    )

    await(fn ->
      match?(
        {:error,
         %Unroutable{cause: :no_catalog, health: [{"claude", {:unavailable, :missing_token}}]}},
        ModelCatalog.route(@host, "claude", Model.new("anything"), missing)
      )
    end)
  end

  # The kind resolver falls back to `:subscription` when the lifecycle owner is
  # unreachable (`default_credential_kind/2`), and that fallback must never
  # become load-bearing: the GATE is `credential_status`, which refuses the same
  # condition one line earlier. This is the test that keeps the two apart — if
  # someone ever loosens the status default the way #21 did, this goes red rather
  # than a catalog quietly deriving against a guessed kind.
  test "an unreachable lifecycle owner is refused by the gate, not routed by the kind fallback",
       ctx do
    gated = unique_name(:gated_catalog)

    start_supervised!(
      {ModelCatalog,
       name: gated,
       base_dir: ctx.base_dir,
       db: ctx.db,
       sh: fn _command -> raise "no probe may run: the credential gate must refuse first" end,
       claude_fetch: fn _path, _headers ->
         raise "no probe may run: the credential gate must refuse first"
       end}
    )

    for harness <- ["claude", "codex"] do
      await(fn ->
        match?(
          {:error,
           %Unroutable{
             cause: :no_catalog,
             health: [
               {^harness, {:unavailable, {:needs_onboarding, :credential_server_unavailable}}}
             ]
           }},
          ModelCatalog.route(@host, harness, Model.new("anything"), gated)
        )
      end)
    end
  end

  test "an unreadable credential store is the catalog health and warning reason", ctx do
    reason =
      {:credential_store_unreadable,
       %{path: Path.join(ctx.base_dir, "auth/claude"), found: :symlink, expected: :directory}}

    catalog = unique_name(:unreadable_store_catalog)

    log =
      capture_log(fn ->
        start_catalog(ctx,
          name: catalog,
          credential_status: fn _provider -> :onboarded end,
          credential_kind: fn _provider -> {:error, reason} end
        )

        for harness <- ["claude", "codex"] do
          expected = {[], {:unavailable, reason}}
          await(fn -> ModelCatalog.get(@host, harness, catalog) == expected end)
          assert ModelCatalog.get(@host, harness, catalog) == expected
        end
      end)

    assert log =~ "refresh degraded: #{inspect(reason)}"
  end

  test "failed fetch, malformed JSON, and a refused grant degrade without crashing readers",
       ctx do
    for {label, opts, harness, reason} <- [
          {:failed, [claude_fetch: fn _, _ -> {:error, :network_down} end], "claude",
           :network_down},
          {:malformed, [claude_fetch: fn _, _ -> {:ok, "{"} end], "claude", :malformed_json},
          # The vendor's own sentence, verbatim — this is the 401 body the live
          # endpoint returns for a grant that needs signing in again.
          {:refused_grant,
           [
             sh: fn _command ->
               catalog_reply(~s({"detail":"Could not parse your authentication token."}), 401)
             end
           ], "codex",
           {:rotation_retry_failed,
            %{
              initial_401:
                {:http_status, 401, ~s({"detail":"Could not parse your authentication token."})},
              initial_guidance: "sign in again to repair the original 401",
              retry_failure:
                {:http_status, 401, ~s({"detail":"Could not parse your authentication token."})}
            }}}
        ] do
      name = unique_name(label)
      catalog = start_catalog(ctx, Keyword.put(opts, :name, name))

      await(fn -> ModelCatalog.get(@host, harness, catalog) == {[], {:unavailable, reason}} end)

      assert {:error, %Unroutable{cause: :no_catalog}} =
               ModelCatalog.route(@host, harness, Model.new("absent"), catalog)
    end

    Archetypes.load!(ctx.base_dir)
    # org_options is the globals-facing form: it reads the default-named DB.
    start_supervised!({Tightbeam.DB, path: ":memory:", name: Tightbeam.DB}, id: :global_db)
    :ok = Placement.ensure_schema(Tightbeam.DB)
    assert is_map(Gateway.org_options())
  end

  # Issue #9: Claude Code rotates `.credentials.json` inside the harness home
  # (write-temp-then-rename), which severs the symlink to the store copy. The
  # store copy freezes on the pre-rotation token and the provider revokes it,
  # so every refresh 401s "revoked" against a token that is fine everywhere
  # else. The store credential here is deliberately stale/wrong; the home
  # copy under `homes/<host>/claude` is the rotated one the vendor actually
  # wrote, and only it authenticates -- proving the recovered catalog came
  # from a real harvest-and-retry, not a lucky second read of the same file.
  test "a subscription 401 harvests the rotated home credential and retries", ctx do
    stale_store = ~s({"claudeAiOauth":{"accessToken":"fixture-token-STALE"}})
    File.write!(Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"]), stale_store)

    rotated_home = ~s({"claudeAiOauth":{"accessToken":"fixture-token-ROTATED"}})
    home = Path.join([ctx.base_dir, "homes", @host, "claude"])
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".credentials.json"), rotated_home)

    claude_json = fixture_body("claude_models.jsonc")

    claude_fetch = fn
      "/v1/models?limit=100", headers ->
        if bearer(headers) == "fixture-token-ROTATED" do
          {:ok, claude_json}
        else
          {:error,
           {:http_status, 401,
            ~s({"type":"error","error":{"type":"authentication_error","message":"OAuth access token has been revoked."}})}}
        end

      "/v1/models/claude-haiku-4-5-20251001", _headers ->
        ctx.claude_fetch.("/v1/models/claude-haiku-4-5-20251001", [])
    end

    log =
      capture_log(fn ->
        catalog = start_catalog(ctx, claude_fetch: claude_fetch)
        await_fresh(catalog, "claude")

        assert {[_ | _], :fresh} = ModelCatalog.get(@host, "claude", catalog)
      end)

    refute log =~ "revoked"

    assert File.read!(Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"])) ==
             rotated_home
  end

  test "a failed rotation retry reports the original 401 and distinct retry failure", ctx do
    stale_store = ~s({"claudeAiOauth":{"accessToken":"fixture-token-STALE"}})
    File.write!(Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"]), stale_store)

    home = Path.join([ctx.base_dir, "homes", @host, "claude"])
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, ".credentials.json"),
      ~s({"claudeAiOauth":{"accessToken":"fixture-token-ROTATED"}})
    )

    revoked =
      ~s({"type":"error","error":{"type":"authentication_error","message":"OAuth access token has been revoked."}})

    fetches = :counters.new(1, [])

    claude_fetch = fn "/v1/models?limit=100", _headers ->
      :counters.add(fetches, 1, 1)

      case :counters.get(fetches, 1) do
        1 -> {:error, {:http_status, 401, revoked}}
        2 -> {:error, {:network, :etimedout}}
        count -> flunk("catalog fetched #{count} times")
      end
    end

    catalog = start_catalog(ctx, claude_fetch: claude_fetch)

    combined_failure =
      {:rotation_retry_failed,
       %{
         initial_401: {:http_status, 401, revoked},
         initial_guidance: "sign in again to repair the original 401",
         retry_failure: {:network, :etimedout}
       }}

    await(fn ->
      ModelCatalog.get(@host, "claude", catalog) ==
        {[], {:unavailable, combined_failure}}
    end)

    assert :counters.get(fetches, 1) == 2

    assert {:error, %Unroutable{} = unroutable} =
             ModelCatalog.route(@host, "claude", Model.new("anything"), catalog)

    message = Unroutable.message(unroutable)
    assert message =~ "initial_401"
    assert message =~ "sign in again to repair the original 401"
    assert message =~ "retry_failure"
    assert message =~ "etimedout"
  end

  test "an api-key 401 is never treated as a rotation and never harvested", ctx do
    store = Path.join([ctx.base_dir, "auth", "claude", ".credentials.json"])
    File.write!(store, "sk-ant-api03-STALE")

    home = Path.join([ctx.base_dir, "homes", @host, "claude"])
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".credentials.json"), "sk-ant-api03-ROTATED")

    claude_fetch = fn "/v1/models?limit=100", _headers ->
      {:error, {:http_status, 401, ~s({"detail":"API key is invalid."})}}
    end

    catalog =
      start_catalog(ctx,
        claude_fetch: claude_fetch,
        credential_kind: fn _provider -> :api_key end
      )

    await(fn ->
      ModelCatalog.get(@host, "claude", catalog) ==
        {[], {:unavailable, {:http_status, 401, ~s({"detail":"API key is invalid."})}}}
    end)

    assert File.read!(store) == "sk-ant-api03-STALE"
  end

  # The harvest reads the LOCAL filesystem, so the `ssh: nil` guard scopes it to
  # a local probe: a remote host's credential lives on that host, and a 401 from
  # its probe must fall through untouched rather than sweep this box's homes.
  # Same rotation, same 401 body -- but the owning host is remote, so the store
  # is left exactly as stale as it was.
  test "a subscription 401 on a remote host is never harvested against the local store", ctx do
    remote_base = Path.join(ctx.base_dir, "remote-root")
    store = Path.join([remote_base, "auth", "claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(store))
    stale_store = ~s({"claudeAiOauth":{"accessToken":"fixture-token-STALE"}})
    File.write!(store, stale_store)

    home = Path.join([remote_base, "homes", "sat", "claude"])
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, ".credentials.json"),
      ~s({"claudeAiOauth":{"accessToken":"fixture-token-ROTATED"}})
    )

    {:ok, _entry} =
      Placement.register_host(ctx.db, "sat", %{
        ssh: "sat.example",
        base_dir: remote_base,
        cli_bin: nil
      })

    revoked =
      ~s({"type":"error","error":{"type":"authentication_error","message":"OAuth access token has been revoked."}})

    sh = fn command ->
      if claude_probe?(command),
        do: catalog_reply(revoked, 401),
        else: catalog_reply(JSON.encode!(%{models: []}))
    end

    catalog = start_catalog(ctx, sh: sh)

    await(fn ->
      ModelCatalog.get("sat", "claude", catalog) ==
        {[], {:unavailable, {:http_status, 401, revoked}}}
    end)

    assert File.read!(store) == stale_store
  end

  defp bearer(headers) do
    {~c"authorization", raw} = List.keyfind(headers, ~c"authorization", 0)
    to_string(raw) |> String.replace_prefix("Bearer ", "")
  end

  test "missing Credentials server fails catalog refresh closed", ctx do
    parent = self()
    name = unique_name(:missing_credentials)

    refute Process.whereis(Tightbeam.Credentials)

    start_supervised!(
      {ModelCatalog,
       name: name,
       base_dir: ctx.base_dir,
       db: ctx.db,
       claude_fetch: fn path, headers ->
         send(parent, :provider_io)
         ctx.claude_fetch.(path, headers)
       end,
       sh: fn command ->
         send(parent, :provider_io)
         ctx.codex_sh.(command)
       end}
    )

    unavailable = {:unavailable, {:needs_onboarding, :credential_server_unavailable}}

    # Every REGISTERED harness, not just the two with a stub: a refresh Task is the
    # only thing that could do provider IO, and the refute below means nothing
    # while one is still in flight. Waiting for all of them to report closes that
    # set — and it stays closed because `@default_ttl_ms` is 15 minutes, so the
    # polling `get` calls here cannot dispatch a second round. That TTL is
    # load-bearing for the refute: hand this test a short `ttl_ms:`, or a second
    # host, and it goes back to racing a live Task with nothing going red.
    await(fn ->
      Enum.all?(Tightbeam.Harness.all(), fn harness ->
        ModelCatalog.get(@host, harness.wire_name(), name) == {[], unavailable}
      end)
    end)

    refute_receive :provider_io
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
    # org_options is the globals-facing form: it reads the default-named DB.
    start_supervised!({Tightbeam.DB, path: ":memory:", name: Tightbeam.DB}, id: :global_db)
    :ok = Placement.ensure_schema(Tightbeam.DB)

    {reader_us, {[], {:unavailable, :not_derived}}} =
      :timer.tc(fn -> ModelCatalog.get(@host, "claude", catalog) end)

    {list_us, options} = :timer.tc(&Gateway.org_options/0)

    # The defect is a reader QUEUED BEHIND the hung refresh, and that has a floor,
    # not a slope: it waits out `GenServer.call`'s 5s and then comes back in the
    # shape the match above already refuses. So the number only has to separate
    # "served while the fetch hangs" from that floor. Three ordered quantities,
    # measured on a 4-core linux box 2026-07-29: served costs 44-122us idle and
    # 12ms (read) / 74ms (list) with the four cores 3x oversubscribed; the bound
    # below is 1s; the blocked floor is 5s. The old 100_000 sat inside the loaded
    # range, so a busy runner failed it with nothing wrong — and a wall-clock
    # budget that a healthy machine can miss reports load as a defect.
    assert reader_us < 1_000_000
    assert list_us < 1_000_000
    assert options.models[@host]["claude"] == []
    send(fetch_pid, :release)
  end

  # THE ONE OWNER of "can this be routed, and if not why". Every cause gets a
  # POSITIVE assertion: a distinction over five cases that only refutes four of
  # them cannot catch the fifth clause going wrong, and the defect this replaced
  # was exactly a clause naming the wrong cause while every refute stayed green.
  describe "route" do
    test "routes a complete selection, and carries the provider and the entry", ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "codex")

      assert {:ok, routed} =
               ModelCatalog.route(
                 @host,
                 "codex",
                 Model.new("gpt-5.6-sol", effort: "medium"),
                 catalog
               )

      # The routed answer carries what its callers used to look up a SECOND time
      # after validation — the lookup that could not represent a miss and raised.
      assert routed.harness == "codex"
      assert routed.provider == "openai"
      assert routed.entry.family == "gpt-5.6-sol"
    end

    test "a tiered model named with NO tier needs an effort, and says which", ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "codex")

      assert {:error, %Unroutable{cause: :needs_effort} = unroutable} =
               ModelCatalog.route(@host, "codex", Model.new("gpt-5.6-sol"), catalog)

      message = Unroutable.message(unroutable)
      assert message =~ "has effort tiers"
      assert message =~ "low|medium|high"
      assert Unroutable.code(unroutable) == "invalid"

      # THE LIE THIS EXISTS TO END: the model IS in the live catalog. A refusal
      # that says otherwise sends the reader hunting for a model already there.
      refute message =~ "is not offered by"
      refute message =~ "not in a fresh harness inventory"
    end

    test "a tier the model does not offer is refused as a TIER, not as a missing model", ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "codex")

      assert {:error, %Unroutable{cause: :effort_not_offered} = unroutable} =
               ModelCatalog.route(
                 @host,
                 "codex",
                 Model.new("gpt-5.6-sol", effort: "unobtainium"),
                 catalog
               )

      message = Unroutable.message(unroutable)
      assert message =~ ~s(does not offer effort "unobtainium")
      assert message =~ "offered: low|medium|high"
      refute message =~ "is not offered by"
    end

    test "an effort named for an UNTIERED model says the model has no tiers", ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "fixture")

      assert {:error, %Unroutable{cause: :effort_not_offered} = unroutable} =
               ModelCatalog.route(
                 @host,
                 "fixture",
                 Model.new("fixture-model", effort: "medium"),
                 catalog
               )

      message = Unroutable.message(unroutable)
      assert message =~ "has no effort tiers"
      assert message =~ ~s(it names "medium")
    end

    test "a model no fresh inventory names is absent, and the refusal says what IS offered",
         ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "codex")

      assert {:error, %Unroutable{cause: :family_absent} = unroutable} =
               ModelCatalog.route(@host, "codex", Model.new("no-such-model"), catalog)

      message = Unroutable.message(unroutable)
      assert message =~ ~s("no-such-model" is not offered by codex on host testhost)
      assert message =~ "offered: gpt-5.6-sol"
      assert Unroutable.code(unroutable) == "model_unavailable"
      refute message =~ "effort tiers"
    end

    test "a catalog that could not be derived blames the CATALOG and names the repair", ctx do
      catalog =
        start_catalog(ctx,
          claude_fetch: fn _path, _headers -> {:error, :network_down} end,
          credential_status: fn _provider -> {:needs_onboarding, :no_credential} end
        )

      await(fn ->
        match?(
          {:error, %Unroutable{cause: :no_catalog}},
          ModelCatalog.route(@host, "claude", Model.new("claude-opus-5"), catalog)
        )
      end)

      assert {:error, %Unroutable{cause: :no_catalog} = unroutable} =
               ModelCatalog.route(@host, "claude", Model.new("claude-opus-5"), catalog)

      message = Unroutable.message(unroutable)
      assert message =~ "anthropic has no usable credential on testhost"
      assert message =~ "run tightbeam onboard anthropic on testhost"
      assert Unroutable.code(unroutable) == "catalog_unavailable"

      # It is not a verdict on the model: nothing here can see whether the host
      # offers it.
      refute message =~ "is not offered by"
    end

    # The codex models endpoint drops every model for a too-old client_version
    # and returns 200. This lesson lived in ONE of the four mechanisms; it is
    # asserted here because it now reaches all of them through one sentence.
    test "an empty catalog from a client_version filter blames the binary, not the grant", _ctx do
      unroutable = %Unroutable{
        cause: :no_catalog,
        host: "testhost",
        harness: "codex",
        selection: Model.new("gpt-5.6-sol", effort: "medium"),
        health: [{"codex", {:unavailable, {:empty_catalog_for_client_version, "0.99.0"}}}]
      }

      message = Unroutable.message(unroutable)
      assert message =~ ~s(EMPTY model list for client_version "0.99.0")
      assert message =~ "credential is not implicated"
      assert message =~ "upgrade codex on testhost"
      refute message =~ "onboard"
    end

    test "route/2 folds over the fleet and names the one harness that can take it", ctx do
      catalog = start_catalog(ctx)
      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")

      assert {:ok, %{harness: "codex"}} =
               ModelCatalog.route(@host, Model.new("gpt-5.6-sol", effort: "medium"), catalog)

      assert {:ok, %{harness: "claude"}} =
               ModelCatalog.route(@host, Model.new("claude-opus-5", effort: "high"), catalog)
    end

    test "a selection two harnesses could each take is ambiguous, and names them", ctx do
      catalog =
        start_catalog(ctx,
          claude_fetch: fn "/v1/models?limit=100", _headers ->
            {:ok, JSON.encode!(%{"data" => [context_variant_model("shared-model")]})}
          end,
          sh: fn _command ->
            catalog_reply(
              JSON.encode!(%{
                models: [
                  %{
                    "slug" => "shared-model",
                    "display_name" => "Shared",
                    "supported_reasoning_levels" => [
                      %{"effort" => "low"},
                      %{"effort" => "high"}
                    ],
                    "context_window" => 200_000
                  }
                ]
              })
            )
          end
        )

      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")

      assert {:error, %Unroutable{cause: :ambiguous} = unroutable} =
               ModelCatalog.route(@host, Model.new("shared-model", effort: "high"), catalog)

      message = Unroutable.message(unroutable)
      assert message =~ "claude"
      assert message =~ "codex"
      assert Unroutable.code(unroutable) == "ambiguous_ref"

      # A remedy the API cannot express is the same failure as the wrong cause: a
      # selection is a MODEL, with no harness field, and every caller of the
      # fleet answer hands one straight in.
      refute message =~ "name the harness"
      assert message =~ "name a model only one of them offers"
    end

    # The list a caller consults to ask "is this denial about routing" — the
    # gateway's spawn classifier keeps a refusal's own code only for these. Held
    # by hand, it carried the two codes the old mechanism produced, and a
    # needs-an-effort refusal came back re-labelled a placement denial.
    test "every cause has a code and a message, and the codes are published", _ctx do
      for cause <- [
            :no_catalog,
            :family_absent,
            :needs_effort,
            :effort_not_offered,
            :ambiguous
          ] do
        unroutable = %Unroutable{
          cause: cause,
          host: @host,
          harness: "claude",
          selection: Model.new("m", effort: "medium"),
          health: [{"claude", {:unavailable, :whatever}}],
          offered: [%{harness: "claude", entry: %{family: "m", context: nil, efforts: ["low"]}}]
        }

        assert is_binary(Unroutable.message(unroutable)), "#{cause} has no sentence"
        assert Unroutable.code(unroutable) in Unroutable.codes(), "#{cause}'s code is unpublished"
      end

      assert "invalid" in Unroutable.codes()
      assert "ambiguous_ref" in Unroutable.codes()
    end

    # ROUTABILITY IS A QUESTION ABOUT THE WHOLE FLEET. One harness tiering a
    # model says nothing while another offers it untiered, where a tierless
    # selection is COMPLETE and uniquely routable. Refusing on the first tiered
    # entry found is the narrower question that blocked a valid ruling.
    test "a tierless selection routes to the harness that offers the model untiered", ctx do
      catalog =
        start_catalog(ctx,
          claude_fetch: fn "/v1/models?limit=100", _headers ->
            {:ok, JSON.encode!(%{"data" => [context_variant_model("shared-model")]})}
          end,
          sh: fn _command ->
            catalog_reply(
              JSON.encode!(%{
                models: [
                  %{
                    "slug" => "shared-model",
                    "display_name" => "Shared",
                    "supported_reasoning_levels" => [],
                    "context_window" => 200_000
                  }
                ]
              })
            )
          end
        )

      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")

      assert {:ok, %{harness: "codex"}} =
               ModelCatalog.route(@host, Model.new("shared-model"), catalog)

      # …and the same fleet refuses the tierless selection's opposite by name:
      # claude has it tiered, codex untiered, so an effort claude does not offer
      # is a TIER refusal, not an absent model.
      assert {:error, %Unroutable{cause: :effort_not_offered} = unroutable} =
               ModelCatalog.route(@host, Model.new("shared-model", effort: "medium"), catalog)

      assert Unroutable.message(unroutable) =~ "claude (high|low)"
    end

    test "a fleet with no fresh catalog at all blames the catalogs, not the model", ctx do
      catalog =
        start_catalog(ctx, credential_status: fn _provider -> {:needs_onboarding, :missing} end)

      await(fn ->
        match?(
          {:error, %Unroutable{cause: :no_catalog}},
          ModelCatalog.route(@host, Model.new("claude-opus-5", effort: "high"), catalog)
        )
      end)

      assert {:error, %Unroutable{cause: :no_catalog, harness: nil} = unroutable} =
               ModelCatalog.route(@host, Model.new("claude-opus-5", effort: "high"), catalog)

      # One story per harness consulted, so nothing is hidden behind a summary.
      assert length(unroutable.health) == length(Tightbeam.Harness.all())
      assert Unroutable.message(unroutable) =~ "claude"
      assert Unroutable.message(unroutable) =~ "codex"
    end
  end

  test "every derived ref validates and absent refs do not", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")
    await_fresh(catalog, "codex")

    # Every entry contributes at least one selection: each tier for a model with
    # tiers, and the nil-effort selection for one without. Iterating
    # `entry.efforts` alone SKIPPED every untiered entry silently, and a catalog
    # of nothing but untiered models would have asserted nothing at all — so the
    # count is asserted too, and it is derived from the catalog, not a literal.
    selections =
      for harness <- ["claude", "codex"],
          entry <- ModelCatalog.get(catalog)[{@host, harness}],
          effort <- if(entry.efforts == [], do: [nil], else: entry.efforts) do
        {harness, Model.new(entry.family, context: entry.context, effort: effort)}
      end

    expected_count =
      for harness <- ["claude", "codex"],
          entry <- ModelCatalog.get(catalog)[{@host, harness}],
          reduce: 0 do
        total -> total + max(length(entry.efforts), 1)
      end

    assert length(selections) == expected_count
    assert expected_count > 0

    for {harness, selection} <- selections do
      assert {:ok, %{harness: ^harness}} = ModelCatalog.route(@host, harness, selection, catalog)
    end

    # An untiered entry REFUSES an effort, and a tiered one refuses its absence.
    # Both directions are the entry's call, and each is refused BY ITS OWN NAME:
    # neither is a missing model.
    for {harness, selection} <- selections do
      {entry, :fresh} = ModelCatalog.entry(@host, harness, selection, catalog)

      {flipped, expected} =
        if entry.efforts == [],
          do: {%{selection | effort: "medium"}, :effort_not_offered},
          else: {%{selection | effort: nil}, :needs_effort}

      assert {:error, %Unroutable{cause: ^expected}} =
               ModelCatalog.route(@host, harness, flipped, catalog)
    end

    assert {:error, %Unroutable{cause: :family_absent}} =
             ModelCatalog.route(
               @host,
               "claude",
               Model.new("opus", context: "1m", effort: "low"),
               catalog
             )

    source =
      [Path.expand("../lib", __DIR__), Path.expand("../config", __DIR__)]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute source =~ "@" <> "model_catalog"
    refute source =~ "model_" <> "pins"
  end

  # per-host-catalogs-v1. Credentials are host-local, so entitlements are, so a
  # catalog is a fact about ONE host's account and is established on that host.
  # per-host-catalogs-v1. Credentials are host-local, so entitlements are, so a
  # catalog is a fact about ONE host's account and is established on that host.
  # Both harnesses now do the same thing: a script on the owning host reads a
  # local credential, makes one HTTPS call, and returns JSON.
  describe "per-host catalogs" do
    setup ctx do
      # The satellite's base_dir is a REAL directory holding REAL grants, so the
      # no-token-bytes assertions have something to catch. If either probe ever
      # read these files locally and interpolated them, the secret would appear
      # in the command line the test captures.
      satellite_base = Path.join(ctx.base_dir, "satellite-root")
      File.mkdir_p!(Path.join([satellite_base, "auth", "claude"]))
      File.mkdir_p!(Path.join([satellite_base, "auth", "codex"]))

      File.write!(
        Path.join([satellite_base, "auth", "claude", ".credentials.json"]),
        ~s({"claudeAiOauth":{"accessToken":"#{@claude_secret}"}})
      )

      File.write!(
        Path.join([satellite_base, "auth", "codex", "auth.json"]),
        JSON.encode!(%{tokens: %{access_token: @codex_secret}})
      )

      {:ok, _entry} =
        Placement.register_host(ctx.db, "satellite", %{
          ssh: "sat.example",
          base_dir: satellite_base,
          cli_bin: nil
        })

      %{satellite_base: satellite_base}
    end

    test "each host's catalog is its own, and neither token reaches a command line", ctx do
      parent = self()

      satellite_claude =
        JSON.encode!(%{
          data: [
            %{
              id: "satellite-only",
              display_name: "Satellite Only",
              max_input_tokens: 1_000,
              capabilities: %{effort: %{}}
            }
          ]
        })

      sh = fn command ->
        send(parent, {:probe, command})

        case claude_probe?(command) do
          true -> catalog_reply(satellite_claude)
          false -> catalog_reply(ctx.codex_json)
        end
      end

      catalog = start_catalog(ctx, sh: sh)
      await_fresh(catalog, "claude", "satellite")
      await_fresh(catalog, "claude")

      # The satellite's account, not the gateway's — and the gateway's entry is
      # untouched by the satellite's answer.
      assert {[%{family: "satellite-only"}], :fresh} =
               ModelCatalog.get("satellite", "claude", catalog)

      {local, :fresh} = ModelCatalog.get(@host, "claude", catalog)
      refute Enum.any?(local, &(&1.family == "satellite-only"))

      # The eurisko method: the credential is read by the shell ON the owning
      # host, so no byte of it is in the argv, and each script says so literally.
      # The shell variable is `credential`, not `token`: this file holds whichever
      # KIND the host was onboarded on.
      claude = probe_command!(:claude)
      claude_line = Enum.join(claude, " ")
      refute claude_line =~ @claude_secret

      # A subscription credential is Claude Code's OAuth record, so the far host PARSES it
      # rather than cat-ing it -- but the property this test exists for is unchanged and
      # asserted above: the secret is captured into a shell variable on the owning host and
      # never appears in any argv. `python3` is handed the PATH, not the token.
      # The far host's own tightbeam binary reads the credential -- it is already installed
      # there and already exec'd for `harness-group`. What this replaced was a `python3`
      # one-liner parsing the vendor's JSON, which added a runtime dependency to every
      # satellite and was a THIRD copy of an extraction that already existed twice.
      #
      # The property this test exists for is stronger now, not weaker: the secret never
      # enters a shell variable at all. Only the PATH is on the command line, asserted here
      # and by the `refute` above.
      credential_file = Path.join([ctx.satellite_base, "auth", "claude", ".credentials.json"])
      assert claude_line =~ "catalog-probe anthropic subscription"
      assert claude_line =~ credential_file
      refute claude_line =~ "python3"
      refute claude_line =~ "credential=$("

      # No authorization header on the command line at all: the binary builds it from the
      # file it just read. The old form referenced a shell variable, which was safe; this
      # form has nothing to reference.
      refute claude_line =~ "authorization:"
      refute claude_line =~ "Bearer"
      assert ["ssh" | claude_rest] = claude
      assert "sat.example" in claude_rest

      codex = probe_command!(:codex, "sat.example")
      codex_line = Enum.join(codex, " ")
      refute codex_line =~ @codex_secret
      assert codex_line =~ "token=$(node -e "
      assert codex_line =~ Path.join([ctx.satellite_base, "auth", "codex", "auth.json"])
      assert codex_line =~ ~s(-H "authorization: Bearer $token")

      # The gateway's own codex probe is the same script without the ssh: one
      # shape for both localities, each reading its own host's grant.
      local_codex = probe_command!(:codex, :local)
      assert ["sh", "-c", script] = local_codex
      assert script =~ Path.join([ctx.base_dir, "auth", "codex", "auth.json"])
      refute script =~ ctx.satellite_base
    end

    test "the codex client_version comes from the binary on the owning host", ctx do
      parent = self()

      sh = fn command ->
        send(parent, {:probe, command})
        catalog_reply(ctx.codex_json)
      end

      catalog = start_catalog(ctx, sh: sh)
      await_fresh(catalog, "codex", "satellite")

      command = probe_command!(:codex, "sat.example")
      line = Enum.join(command, " ")

      # `client_version` silently filters the catalog, so it must be the version
      # the codex binary ON THAT HOST reports. A constant in our source would
      # return 200 with an empty list and blame the account.
      assert line =~ "raw=$(codex --version)"
      assert line =~ "client_version=${raw##* }"
      refute line =~ ~r/client_version=\d/

      # It is read from the host that runs the turn: the satellite's own auth.json.
      assert line =~ Path.join([ctx.satellite_base, "auth", "codex", "auth.json"])
    end

    test "a 200 with an empty model list names the client_version that produced it", ctx do
      # The endpoint's silent filter: too old a client and every model is dropped,
      # with no error at all. The reason has to carry the version or the operator
      # is left blaming a perfectly good grant.
      sh = fn _command -> catalog_reply(JSON.encode!(%{models: []})) end
      catalog = start_catalog(ctx, sh: sh)

      await(fn ->
        ModelCatalog.get(@host, "codex", catalog) ==
          {[], {:unavailable, {:empty_catalog_for_client_version, "0.145.0"}}}
      end)
    end

    # Codex OWNS auth.json and rewrites it in place as it rotates; this probe is a
    # read-only second reader, so a read can land mid-rewrite. That is an accident
    # of timing, not a verdict on the grant — and reporting it as a bad credential
    # would send the operator to re-onboard a login that is working.
    #
    # Run against the GATEWAY's own host, because that is where the extraction
    # script actually executes here: on a satellite it runs inside the remote
    # shell, which a unit test has no business reaching. The script is the real
    # one; only the hosts we cannot run on are stubbed away.
    test "a torn read of auth.json is transient, and never a credential verdict", ctx do
      auth = Path.join([ctx.base_dir, "auth", "codex", "auth.json"])
      File.mkdir_p!(Path.dirname(auth))

      whole =
        JSON.encode!(%{
          tokens: %{access_token: "tok", refresh_token: "r", account_id: "a"},
          auth_mode: "chatgpt"
        })

      # Local probes are ["sh", "-c", script] and run for real; anything bound for
      # another machine fails fast without touching the network.
      #
      # The real one is the ONLY external process the catalog suite spawns, and a
      # spawn on a shared runner has an unbounded tail, so the test says when it
      # returned instead of guessing how long it takes. Three ordered quantities,
      # measured 2026-07-29: the spawn itself is 24-38ms on the linux runner and
      # 128-168ms on the macOS one; the poll below then covers only the
      # Task -> GenServer hop that follows it (<1ms) inside its 100 x 5ms = 500ms
      # budget; the spawn gets the 10s bound of an external wait. Before this, the
      # 500ms poll covered the spawn as well — 13x the linux cost but only 3x the
      # macOS one — and one linux excursion past 500ms (run 30430140506) reported
      # it as "condition did not become true", the shape of a broken verdict
      # rather than of a slow runner.
      parent = self()

      sh = fn command ->
        if hd(command) == "sh" do
          result = Support.system_cmd_out(command)
          send(parent, {:probe_returned, elem(result, 1)})
          result
        else
          {"", 255}
        end
      end

      states = [
        # A genuine prefix of a genuine file — what a reader sees mid-rewrite.
        {:torn, binary_part(whole, 0, div(byte_size(whole), 2)),
         {:credential_read_torn, :retry_next_refresh}},
        {:no_tokens_object, JSON.encode!(%{auth_mode: "chatgpt"}),
         {:credential_missing_access_token, auth}},
        {:empty_token, JSON.encode!(%{tokens: %{access_token: ""}}),
         {:credential_missing_access_token, auth}}
      ]

      for {label, contents, expected} <- states do
        File.write!(auth, contents)
        catalog = start_catalog(ctx, name: unique_name(label), sh: sh)
        assert_receive {:probe_returned, _exit_status}, 10_000

        await(fn ->
          ModelCatalog.get(@host, "codex", catalog) == {[], {:unavailable, expected}}
        end)
      end

      # ...and a file that simply is not there is a REAL "no grant on this host",
      # which must stay distinct from a torn read of one that is.
      File.rm!(auth)
      catalog = start_catalog(ctx, name: unique_name(:absent), sh: sh)
      assert_receive {:probe_returned, _exit_status}, 10_000

      await(fn ->
        ModelCatalog.get(@host, "codex", catalog) ==
          {[], {:unavailable, {:missing_credential, auth}}}
      end)
    end

    test "an unreachable host degrades only its own entries", ctx do
      # 255 is ssh's own "could not connect".
      sh = fn command ->
        if Enum.member?(command, "sat.example"),
          do: {"", 255},
          else: catalog_reply(ctx.codex_json)
      end

      catalog = start_catalog(ctx, sh: sh)
      unreachable = {[], {:unavailable, {:probe_failed, 255, ""}}}

      # Wait for the VERDICT, not for the shape of one. `:not_derived` is itself an
      # `{:unavailable, _}`, so the old wait was satisfied before the first probe
      # had run and waited for nothing at all — leaving the assertions below racing
      # the probe the wait was there to cover.
      await(fn -> ModelCatalog.get("satellite", "claude", catalog) == unreachable end)
      await(fn -> ModelCatalog.get("satellite", "codex", catalog) == unreachable end)

      assert ModelCatalog.get("satellite", "claude", catalog) == unreachable
      assert ModelCatalog.get("satellite", "codex", catalog) == unreachable

      # The gateway's own entries are established here and stay fresh.
      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")
    end
  end

  defp claude_probe?(command), do: Enum.any?(command, &String.contains?(&1, "api.anthropic.com"))

  defp codex_probe?(command) do
    line = Enum.join(command, " ")

    String.contains?(line, "api.openai.com") or
      String.contains?(line, "token=$(node -e")
  end

  # Four probes race into one mailbox and each caller wants a different one, so a
  # record this call skipped goes BACK — it is the next call's evidence. Dropping
  # it made every assertion below depend on the order the four refresh Tasks
  # happened to finish in: whichever probe reported first was eaten by whichever
  # call came first, and the one that actually wanted it then waited out its
  # second for a message that no longer existed ("no codex probe command was
  # constructed"). Stable on an idle box, ordinary on a loaded one.
  defp probe_command!(harness, dest \\ nil, skipped \\ []) do
    receive do
      {:probe, command} = record ->
        matches_harness? =
          case harness do
            :claude -> claude_probe?(command)
            :codex -> codex_probe?(command)
          end

        matches_dest? =
          case dest do
            nil -> true
            :local -> hd(command) == "sh"
            name -> Enum.member?(command, name)
          end

        if matches_harness? and matches_dest? do
          requeue(skipped)
          command
        else
          probe_command!(harness, dest, [record | skipped])
        end
    after
      1_000 ->
        requeue(skipped)
        flunk("no #{harness} probe command was constructed")
    end
  end

  defp requeue(skipped), do: skipped |> Enum.reverse() |> Enum.each(&send(self(), &1))

  defp start_catalog(ctx, overrides \\ []) do
    name = Keyword.get(overrides, :name, unique_name(:catalog))

    opts =
      [
        name: name,
        base_dir: ctx.base_dir,
        db: ctx.db,
        claude_fetch: ctx.claude_fetch,
        sh: ctx.codex_sh,
        credential_status: fn _provider -> :onboarded end,
        credential_kind: fn _provider -> :subscription end,
        # These tests exercise catalog DERIVATION (field mapping, effort parsing,
        # health, sorting) with synthetic and fixture model ids. The claude
        # selectable-model pin is a separate subject with its own tests below, so
        # it is disabled here — otherwise every derivation test would silently
        # become a test of that table.
        claude_selectable_models: :all
      ]
      |> Keyword.merge(overrides)

    start_supervised!(%{id: name, start: {ModelCatalog, :start_link, [opts]}})
    name
  end

  defp await_fresh(catalog, harness, host \\ @host) do
    await(fn -> ModelCatalog.get(host, harness, catalog) |> elem(1) == :fresh end)
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

  # Task #41. The catalog must not advertise a model the adapter will refuse, and no
  # substitution may be smuggled in at the only place a mapping could live.
  describe "claude selectable-model pin" do
    test "withholds models the adapter refuses and keeps the ones it accepts", ctx do
      catalog =
        start_catalog(ctx,
          claude_selectable_models: Tightbeam.Harness.Claude.adapter_selectable_models()
        )

      await_fresh(catalog, "claude")
      {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)
      families = claude |> Enum.map(& &1.family) |> Enum.uniq()

      # Only selectable models survive, and the fixture's refused ones are gone.
      assert "claude-haiku-4-5-20251001" in families
      # Re-measured 2026-08-06 on gibson (production grant): a pin-probed home
      # offered and accepted claude-opus-5 and it answered a live prompt — the
      # earlier REJECTED row was the default-pin vocabulary, not the grant.
      assert "claude-opus-5" in families
      # Re-measured 2026-08-05 on gibson (CLI 2.1.221, production grant):
      # fable answers a real prompt; the July REJECTED row was one
      # environment's snapshot. Fable is now offered.
      assert "claude-fable-5" in families
      refute "claude-sonnet-4-6" in families

      assert Enum.all?(families, &(&1 in Tightbeam.Harness.Claude.adapter_selectable_models())),
             "catalog offered a model the adapter refuses: #{inspect(families)}"

      # The filter matches the vendor IDENTITY. Efforts are a property of the
      # kept entry, not part of what is matched, so they survive INTACT — which
      # means the values the fixture declares, not merely "a list". `is_list/1`
      # stayed green against every list being emptied, which is exactly the
      # damage a filter keyed on the wrong thing would do.
      sonnet_5 = Enum.find(claude, &(&1.family == "claude-sonnet-5"))

      assert MapSet.new(sonnet_5.efforts) ==
               MapSet.new(["low", "medium", "high", "xhigh", "max"])

      # …and an untiered model keeps its empty list, so "intact" is not read as
      # "non-empty" and the two cases stay distinguishable.
      haiku = Enum.find(claude, &(&1.family == "claude-haiku-4-5-20251001"))
      assert haiku.efforts == []
    end

    # Where a substitution WOULD live: `Model.parse_ref/1` is the only transform
    # between a vendor identifier and what reaches session/set_config_option. If
    # someone maps a refused model onto an accepted one, it happens here, and
    # this goes red.
    #
    # It also pins the rule that made the two suffix vocabularies collide: a
    # bracket in a VENDOR identifier is a context variant, never one of our
    # reasoning levels. Read as an effort, `claude-fable-5[1m]` would lose its
    # 1M window and send `1m` to the effort control.
    test "the vendor ref transform splits context, never effort, and never rewrites the model" do
      for refused <- ~w(claude-fable-5 claude-opus-5 fable) do
        assert Model.parse_ref(refused) == Model.new(refused),
               "#{refused} was rewritten — a substitution has been introduced"

        assert Model.parse_ref("#{refused}[1m]") == Model.new(refused, context: "1m"),
               "#{refused}[1m] did not pass through with only its context split off"
      end

      # A bracket that happens to spell one of our effort levels is STILL the
      # vendor's field, not ours. Reading it as an effort is the whole defect.
      assert Model.parse_ref("claude-sonnet-5[high]") ==
               Model.new("claude-sonnet-5", context: "high")

      assert Model.parse_ref("claude-sonnet-5[high]").effort == nil

      # And nothing renders our effort back into the vendor identifier.
      assert "claude-sonnet-5" ==
               Model.to_ref(Model.new("claude-sonnet-5", effort: "high"))
    end
  end

  # O4/I5/AC4 — a credential commit re-derives the catalog immediately, without
  # waiting for the TTL. Two behaviors, tested apart: the DELETE (a
  # needs_onboarding outcome is not cached under the full TTL, so the pull
  # backstop re-derives on the next read) and the PUSH (the wired
  # `credential-present` recognition re-derives with no read at all).
  describe "credential-present re-derivation (O4/I5/AC4)" do
    # AC4 fail-before: today a needs_onboarding outcome is cached under the full
    # TTL via `attempted_at`, so a read after the credential lands — but before
    # the TTL lapses — still returns the stale needs_onboarding entry. The clock
    # never advances here; only the world-state (credential presence) changes.
    test "a needs_onboarding outcome is not cached under the full TTL — the next read re-derives",
         ctx do
      present? =
        start_supervised!(%{
          id: unique_name(:present),
          start: {Agent, :start_link, [fn -> false end]}
        })

      status = fn _provider ->
        if Agent.get(present?, & &1), do: :onboarded, else: {:needs_onboarding, :missing}
      end

      catalog =
        start_catalog(ctx,
          ttl_ms: :timer.minutes(15),
          now: fn -> 0 end,
          credential_status: status
        )

      # First boot: no credential in the home yet → catalog is needs_onboarding.
      await(fn ->
        match?(
          {[], {:unavailable, {:needs_onboarding, :missing}}},
          ModelCatalog.get(@host, "claude", catalog)
        )
      end)

      # The credential lands in the home (world-state flips) well under the TTL;
      # the clock does NOT move, so any re-derivation is driven by the changed
      # world-state, never by a timer.
      Agent.update(present?, fn _ -> true end)

      await_fresh(catalog, "claude")
      {claude, :fresh} = ModelCatalog.get(@host, "claude", catalog)
      assert claude != []

      # End-to-end bar: placement is USABLE, not merely fresh.
      assert {:ok, %{harness: "claude"}} =
               ModelCatalog.route(
                 @host,
                 "claude",
                 Model.new("claude-sonnet-5", effort: "high"),
                 catalog
               )
    end

    # The PUSH: the wired edge itself. A credential commit files the
    # `credential-present` fact, whose recognition re-derives NOW — proven by the
    # derivation probe running with no `get/3` (no read) ever forcing it. The
    # probe (a claude `/v1/models` fetch) runs ONLY past the credential gate, so
    # its arrival is the signal that a re-derivation started from the recognition.
    test "the credential-present recognition re-derives with no read, and is provider-scoped",
         ctx do
      test_pid = self()

      claude_generation =
        start_supervised!(%{
          id: unique_name(:claude_generation),
          start: {Agent, :start_link, [fn -> 0 end]}
        })

      codex_generation =
        start_supervised!(%{
          id: unique_name(:codex_generation),
          start: {Agent, :start_link, [fn -> 0 end]}
        })

      probing_fetch = fn
        "/v1/models?limit=100" = path, headers ->
          generation = Agent.get_and_update(claude_generation, fn n -> {n + 1, n + 1} end)
          send(test_pid, {:catalog_generation, :claude, generation})
          ctx.claude_fetch.(path, headers)

        path, headers ->
          ctx.claude_fetch.(path, headers)
      end

      probing_codex = fn command ->
        generation = Agent.get_and_update(codex_generation, fn n -> {n + 1, n + 1} end)
        send(test_pid, {:catalog_generation, :codex, generation})
        ctx.codex_sh.(command)
      end

      catalog =
        start_catalog(ctx,
          ttl_ms: :timer.minutes(15),
          now: fn -> 0 end,
          credential_status: fn _provider -> :onboarded end,
          claude_fetch: probing_fetch,
          sh: probing_codex
        )

      # Recovery from needs_onboarding remains covered by the preceding pull-backstop
      # test. This provider-scope test starts settled, so every later generation is
      # owned by the credential-present action below.
      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")

      claude_before = Agent.get(claude_generation, & &1)
      codex_before = Agent.get(codex_generation, & &1)
      assert claude_before == 1
      assert codex_before == 1

      # The wired recognition fires with no get/3 afterward. The sys call is only
      # a mailbox barrier: once it returns, the preceding cast has been handled.
      ModelCatalog.credential_present(@host, :anthropic, catalog)
      barrier_state = :sys.get_state(catalog)

      claude_after = claude_before + 1
      assert_receive {:catalog_generation, :claude, ^claude_after}, 2_000
      assert Agent.get(claude_generation, & &1) == claude_after

      # Provider-scoped: an anthropic recognition re-derives the harness that
      # spends anthropic (claude) only. A wrongly launched Codex task is either
      # still marked refreshing at the barrier or has advanced its generation.
      refute get_in(barrier_state, [:entries, {@host, "codex"}, :refreshing])
      assert Agent.get(codex_generation, & &1) == codex_before
    end

    # F2 regression: a credential-present arriving WHILE a derive is in flight
    # must still re-derive once that derive completes — on the SUCCESS path too,
    # not only on error. Without the fix the {:ok} handler dropped the pending
    # recheck, so a credential replaced mid-derive stayed stale until the TTL.
    test "a credential-present mid-derive re-derives after a successful completion (recheck honored)",
         ctx do
      test_pid = self()

      gate =
        start_supervised!(%{
          id: unique_name(:gate),
          start: {Agent, :start_link, [fn -> false end]}
        })

      count =
        start_supervised!(%{id: unique_name(:count), start: {Agent, :start_link, [fn -> 0 end]}})

      gated_fetch = fn path, headers ->
        n = Agent.get_and_update(count, fn c -> {c + 1, c + 1} end)
        send(test_pid, {:fetch_started, n})
        # Hold ONLY the first derive open, so a credential-present can land while
        # it is in flight; later derives pass straight through.
        if n == 1, do: await(fn -> Agent.get(gate, & &1) end, 400)
        ctx.claude_fetch.(path, headers)
      end

      catalog =
        start_catalog(ctx,
          credential_status: fn _provider -> :onboarded end,
          claude_fetch: gated_fetch
        )

      # Derive #1 (boot) is in flight and blocked.
      assert_receive {:fetch_started, 1}, 2_000

      # A credential-present lands while #1 is in flight -> recheck is set.
      ModelCatalog.credential_present(@host, :anthropic, catalog)

      # Release #1; it completes {:ok}. The recheck must force derive #2 — the
      # success path honoring it, symmetric with the error path.
      Agent.update(gate, fn _ -> true end)
      assert_receive {:fetch_started, 2}, 2_000
    end

    # The eezo production repro (orchestrator, 2026-08-06): a CLEAN one-shot
    # ceremony, yet placement refused with `:in_progress` MINUTES after `status`
    # read onboarded. `credential_status/2` returns `:in_progress` only while the
    # onboarding lease stands (credentials.ex), and `finish_onboard` clears the
    # lease on completion — so the refusal minutes later is the CATALOG holding
    # the during-ceremony `{:needs_onboarding, :in_progress}` under the full TTL,
    # not a live status. The credential-present recognition must make placement
    # usable immediately, whatever needs_onboarding sub-reason was cached.
    test "placement is usable right after the recognition, even when the cached refusal was :in_progress",
         ctx do
      present? =
        start_supervised!(%{
          id: unique_name(:present),
          start: {Agent, :start_link, [fn -> false end]}
        })

      status = fn _provider ->
        if Agent.get(present?, & &1), do: :onboarded, else: {:needs_onboarding, :in_progress}
      end

      catalog =
        start_catalog(ctx,
          ttl_ms: :timer.minutes(15),
          now: fn -> 0 end,
          credential_status: status
        )

      opus_high = Model.new("claude-opus-5", effort: "high")

      # During the ceremony the catalog cached the lease's `:in_progress`, so
      # placement refuses — naming the catalog, on the stale reason.
      await(fn ->
        match?(
          {:error,
           %Unroutable{
             cause: :no_catalog,
             health: [{"claude", {:unavailable, {:needs_onboarding, :in_progress}}}]
           }},
          ModelCatalog.route(@host, "claude", opus_high, catalog)
        )
      end)

      # Ceremony completes: lease cleared, credential live. The wired recognition
      # fires; the clock never moves, so nothing but the fact drives this.
      Agent.update(present?, fn _ -> true end)
      ModelCatalog.credential_present(@host, :anthropic, catalog)

      # Placement succeeds NOW — within derivation latency, not a TTL later.
      await(fn -> match?({:ok, _}, ModelCatalog.route(@host, "claude", opus_high, catalog)) end)
    end

    # The injector seam (O4's mechanism half): the gateway `on_credential_present`
    # hook credentials.ex invokes at commit success. It files the durable
    # `credential-present` fact AND pokes the catalog, so placement becomes usable
    # within T_derive — exactly the end-to-end effect once O1 wires the one-line
    # invocation at finish_onboard (O1 owns the trigger-point; this proves the
    # mechanism against the published on_credential_present/1 contract).
    test "the gateway on_credential_present hook files the fact and makes placement usable",
         ctx do
      # The fact-filing transaction also writes a lifecycle event, so the full
      # schema is needed, not just the condition_facts table.
      Tightbeam.Schema.ensure_all(ctx.db)

      present? =
        start_supervised!(%{
          id: unique_name(:present),
          start: {Agent, :start_link, [fn -> false end]}
        })

      status = fn _provider ->
        if Agent.get(present?, & &1), do: :onboarded, else: {:needs_onboarding, :missing}
      end

      catalog =
        start_catalog(ctx,
          ttl_ms: :timer.minutes(15),
          now: fn -> 0 end,
          credential_status: status
        )

      opus_high = Model.new("claude-opus-5", effort: "high")

      await(fn ->
        match?(
          {:error, %Unroutable{cause: :no_catalog}},
          ModelCatalog.route(@host, "claude", opus_high, catalog)
        )
      end)

      # Credential commits; the hook fires with the provider (as O1's finish_onboard will).
      Agent.update(present?, fn _ -> true end)
      hook = Gateway.credential_present_hook(ctx.db, @host, catalog)
      assert hook.(:anthropic) == :ok

      # The durable transition fact is filed for {host, provider}, by the substrate...
      assert %{scope: "testhost:anthropic", origin: "process:tightbeam"} =
               Tightbeam.ConditionFacts.latest(ctx.db, "credential-present", "#{@host}:anthropic")

      # ...and placement is usable within T_derive, no restart, no TTL wait.
      await(fn -> match?({:ok, _}, ModelCatalog.route(@host, "claude", opus_high, catalog)) end)
    end

    # F1 (build-to-spec): the re-derivation is a NAMED PRODUCTION that RECOGNIZES
    # the credential-present fact (Tightbeam.Productions.CatalogRederive), never an
    # imperative refresh. Proof it is fact-driven, not the imperative refusal
    # I5/N2 decline: recognition re-derives ONLY when the fact is present — its
    # LHS gates on the durable fact. An imperative design would re-derive
    # regardless of the fact; this does not (refute below), and does once the
    # fact is filed (assert below).
    test "CatalogRederive re-derives only when the credential-present fact is present (fact-driven)",
         ctx do
      Tightbeam.Schema.ensure_all(ctx.db)
      test_pid = self()

      claude_generation =
        start_supervised!(%{
          id: unique_name(:claude_generation),
          start: {Agent, :start_link, [fn -> 0 end]}
        })

      probing_fetch = fn
        "/v1/models?limit=100" = path, headers ->
          generation = Agent.get_and_update(claude_generation, fn n -> {n + 1, n + 1} end)
          send(test_pid, {:catalog_generation, :claude, generation})
          ctx.claude_fetch.(path, headers)

        path, headers ->
          ctx.claude_fetch.(path, headers)
      end

      catalog =
        start_catalog(ctx,
          ttl_ms: :timer.minutes(15),
          now: fn -> 0 end,
          credential_status: fn _provider -> :onboarded end,
          claude_fetch: probing_fetch
        )

      await_fresh(catalog, "claude")
      claude_before = Agent.get(claude_generation, & &1)
      assert claude_before == 1

      # No credential-present fact exists: recognizing a fact id that names none
      # reads no row, so the LHS does NOT match and recognition is a no-op — NO
      # re-derivation. The sys call is a mailbox barrier, so unchanged generation
      # and refreshing state prove the no-match action did nothing without a
      # timing-based negative receive.
      assert :ok = Tightbeam.Productions.CatalogRederive.recognize(ctx.db, catalog, 999_999)
      no_match_state = :sys.get_state(catalog)
      refute get_in(no_match_state, [:entries, {@host, "claude"}, :refreshing])
      assert Agent.get(claude_generation, & &1) == claude_before

      # File the credential-present fact; recognizing its id re-derives — and the
      # {host, provider} come FROM the fact, not the caller. The FACT is the
      # trigger and the source.
      {:ok, %{fact_id: fact_id}} =
        Tightbeam.DB.transaction(ctx.db, fn txn ->
          Tightbeam.ConditionFacts.file_in_txn(txn, %{
            kind: "credential-present",
            scope: "#{@host}:anthropic",
            origin: "process:tightbeam"
          })
        end)

      assert :ok = Tightbeam.Productions.CatalogRederive.recognize(ctx.db, catalog, fact_id)
      _matching_barrier = :sys.get_state(catalog)

      claude_after = claude_before + 1
      assert_receive {:catalog_generation, :claude, ^claude_after}, 2_000
      assert Agent.get(claude_generation, & &1) == claude_after
    end
  end

  defp await(_fun, 0), do: flunk("condition did not become true")
  defp unique_name(label), do: String.to_atom("#{label}_#{System.unique_integer([:positive])}")

  defp fixture_json(name), do: name |> fixture_body() |> JSON.decode!()

  defp fixture_body(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
  end
end
