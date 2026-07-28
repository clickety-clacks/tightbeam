defmodule Tightbeam.ModelCatalogTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Archetypes, Gateway, ModelCatalog, Placement}
  alias Tightbeam.Harness.Support

  @fixtures Path.join(__DIR__, "fixtures/model_catalog")
  @host "testhost"
  @claude_secret "sk-ant-oat01-NEVER-ON-A-COMMAND-LINE"
  @codex_secret "ey-codex-access-NEVER-ON-A-COMMAND-LINE"

  setup do
    base_dir = Path.join(System.tmp_dir!(), "model-catalog-#{System.unique_integer([:positive])}")
    token_dir = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(token_dir)
    File.write!(Path.join(token_dir, "oauth-token"), "fixture-token")

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

    opus = Enum.find(claude, &(&1.ref == "claude-opus-5[low]"))
    assert opus.display_name == "Claude Opus 5"
    assert opus.max_input_tokens == 1_000_000
    assert MapSet.new(opus.efforts) == MapSet.new(["low", "medium", "high", "xhigh", "max"])

    assert Enum.map(codex, & &1.ref) == [
             "gpt-5.6-sol[low]",
             "gpt-5.6-sol[medium]",
             "gpt-5.6-sol[high]",
             "gpt-5.6-sol[xhigh]",
             "gpt-5.6-sol[max]",
             "gpt-5.6-sol[ultra]"
           ]

    codex_medium = Enum.find(codex, &(&1.ref == "gpt-5.6-sol[medium]"))
    assert codex_medium.display_name == "GPT-5.6-Sol"
    assert codex_medium.max_input_tokens == 272_000

    assert get_in(codex_medium.capabilities, [
             "supported_reasoning_levels",
             Access.at(1),
             "effort"
           ]) ==
             "medium"

    refute Enum.any?(claude ++ codex, &String.contains?(&1.ref, "[1m]"))
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

    assert {[%{ref: "claude-haiku-4-5-20251001"} = entry], :fresh} =
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

    assert Enum.map(claude, & &1.ref) == [
             "claude-sort-test[high]",
             "claude-sort-test[low]",
             "claude-sort-test[max]",
             "claude-sort-test[medium]",
             "claude-sort-test[ultra]",
             "claude-sort-test[xhigh]"
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

    assert Enum.map(claude, & &1.ref) == [
             "claude-live-shape[low]",
             "claude-live-shape[medium]"
           ]
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

    assert Enum.map(codex, & &1.ref) == [
             "gpt-sort-test[mega]",
             "gpt-sort-test[xhigh]",
             "gpt-sort-test[max]",
             "gpt-sort-test[low]",
             "gpt-sort-test[ultra]",
             "gpt-sort-test[high]",
             "gpt-sort-test[medium]"
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

    assert ModelCatalog.member?(@host, "claude", "claude-opus-5[high]", catalog) == %{
             present?: true,
             health: :fresh
           }

    assert ModelCatalog.member?(@host, "claude", "absent", catalog) == %{
             present?: false,
             health: :fresh
           }

    Agent.update(clock, fn _ -> 11 end)
    Agent.update(failures, fn _ -> true end)

    assert ModelCatalog.member?(@host, "claude", "claude-opus-5[high]", catalog) == %{
             present?: true,
             health: :stale
           }

    await(fn -> ModelCatalog.get(@host, "claude", catalog) |> elem(1) == :stale end)

    missing = unique_name(:missing_catalog)

    start_supervised!(
      {ModelCatalog,
       name: missing,
       base_dir: Path.join(ctx.base_dir, "missing"),
       sh: ctx.codex_sh,
       credential_status: fn _provider -> :onboarded end}
    )

    await(fn ->
      ModelCatalog.member?(@host, "claude", "anything", missing).health ==
        {:unavailable, :missing_token}
    end)
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
           {:http_status, 401, ~s({"detail":"Could not parse your authentication token."})}}
        ] do
      name = unique_name(label)
      catalog = start_catalog(ctx, Keyword.put(opts, :name, name))

      await(fn -> ModelCatalog.get(@host, harness, catalog) == {[], {:unavailable, reason}} end)
      assert is_map(ModelCatalog.member?(@host, harness, "absent", catalog))
    end

    Archetypes.load!(ctx.base_dir)
    assert is_map(Gateway.org_options())
  end

  test "missing Credentials server fails catalog refresh closed", ctx do
    parent = self()
    name = unique_name(:missing_credentials)

    refute Process.whereis(Tightbeam.Credentials)

    start_supervised!(
      {ModelCatalog,
       name: name,
       base_dir: ctx.base_dir,
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

    await(fn ->
      ModelCatalog.get(@host, "claude", name) == {[], unavailable} and
        ModelCatalog.get(@host, "codex", name) == {[], unavailable}
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

    {reader_us, {[], {:unavailable, :not_derived}}} =
      :timer.tc(fn -> ModelCatalog.get(@host, "claude", catalog) end)

    {list_us, options} = :timer.tc(&Gateway.org_options/0)

    assert reader_us < 100_000
    assert list_us < 100_000
    assert options.models[@host]["claude"] == []
    send(fetch_pid, :release)
  end

  test "every derived ref validates and absent refs do not", ctx do
    catalog = start_catalog(ctx)
    await_fresh(catalog, "claude")
    await_fresh(catalog, "codex")

    for harness <- ["claude", "codex"],
        entry <- ModelCatalog.get(catalog)[{@host, harness}] do
      assert ModelCatalog.member?(@host, harness, entry.ref, catalog) == %{
               present?: true,
               health: :fresh
             }
    end

    assert ModelCatalog.member?(@host, "claude", "opus[1m]", catalog) == %{
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
      File.write!(Path.join([satellite_base, "auth", "claude", "oauth-token"]), @claude_secret)

      File.write!(
        Path.join([satellite_base, "auth", "codex", "auth.json"]),
        JSON.encode!(%{tokens: %{access_token: @codex_secret}})
      )

      {:ok, _entry} =
        Placement.register_host(ctx.base_dir, "satellite", %{
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
      assert {[%{ref: "satellite-only"}], :fresh} =
               ModelCatalog.get("satellite", "claude", catalog)

      {local, :fresh} = ModelCatalog.get(@host, "claude", catalog)
      refute Enum.any?(local, &(&1.ref == "satellite-only"))

      # The eurisko method: the token is read by the shell ON the owning host, so
      # no byte of it is in the argv, and each script says so literally.
      claude = probe_command!(:claude)
      claude_line = Enum.join(claude, " ")
      refute claude_line =~ @claude_secret

      assert claude_line =~
               "token=$(cat #{Path.join([ctx.satellite_base, "auth", "claude", "oauth-token"])})"

      assert claude_line =~ ~s(-H "authorization: Bearer $token")
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
      sh = fn command ->
        if hd(command) == "sh", do: Support.system_cmd_out(command), else: {"", 255}
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

        await(fn ->
          ModelCatalog.get(@host, "codex", catalog) == {[], {:unavailable, expected}}
        end)
      end

      # ...and a file that simply is not there is a REAL "no grant on this host",
      # which must stay distinct from a torn read of one that is.
      File.rm!(auth)
      catalog = start_catalog(ctx, name: unique_name(:absent), sh: sh)

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

      await(fn ->
        match?({[], {:unavailable, _}}, ModelCatalog.get("satellite", "claude", catalog))
      end)

      assert {[], {:unavailable, {:probe_failed, 255, ""}}} =
               ModelCatalog.get("satellite", "claude", catalog)

      assert {[], {:unavailable, {:probe_failed, 255, ""}}} =
               ModelCatalog.get("satellite", "codex", catalog)

      # The gateway's own entries are established here and stay fresh.
      await_fresh(catalog, "claude")
      await_fresh(catalog, "codex")
    end
  end

  defp claude_probe?(command), do: Enum.any?(command, &String.contains?(&1, "api.anthropic.com"))

  defp probe_command!(harness, dest \\ nil) do
    receive do
      {:probe, command} ->
        matches_harness? = claude_probe?(command) == (harness == :claude)

        matches_dest? =
          case dest do
            nil -> true
            :local -> hd(command) == "sh"
            name -> Enum.member?(command, name)
          end

        if matches_harness? and matches_dest?,
          do: command,
          else: probe_command!(harness, dest)
    after
      1_000 -> flunk("no #{harness} probe command was constructed")
    end
  end

  defp start_catalog(ctx, overrides \\ []) do
    name = Keyword.get(overrides, :name, unique_name(:catalog))

    opts =
      [
        name: name,
        base_dir: ctx.base_dir,
        claude_fetch: ctx.claude_fetch,
        sh: ctx.codex_sh,
        credential_status: fn _provider -> :onboarded end,
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
      refs = Enum.map(claude, & &1.ref)
      bases = refs |> Enum.map(&String.replace(&1, ~r/\[.*\]$/, "")) |> Enum.uniq()

      # Only selectable bases survive, and the fixture's refused ones are gone.
      assert "claude-haiku-4-5-20251001" in bases
      refute "claude-opus-5" in bases
      refute "claude-fable-5" in bases
      refute "claude-sonnet-4-6" in bases

      assert Enum.all?(bases, &(&1 in Tightbeam.Harness.Claude.adapter_selectable_models())),
             "catalog offered a base the adapter refuses: #{inspect(bases)}"

      # The filter matches the BASE ref, so effort suffixes are preserved, not eaten.
      assert Enum.any?(refs, &String.contains?(&1, "["))
    end

    # Where a substitution WOULD live: parse_model_ref is the only transform between a
    # requested ref and what reaches session/set_config_option. If someone maps a
    # refused model onto an accepted one, it happens here, and this goes red.
    test "the only ref transform strips effort and never rewrites the model" do
      for refused <- ~w(claude-fable-5 claude-opus-5 fable) do
        assert Tightbeam.Acp.Adapter.parse_model_ref(refused) == {refused, nil},
               "#{refused} was rewritten — a substitution has been introduced"

        assert Tightbeam.Acp.Adapter.parse_model_ref("#{refused}[medium]") == {refused, "medium"},
               "#{refused}[medium] did not pass through with only its effort split off"
      end

      assert Tightbeam.Acp.Adapter.parse_model_ref("claude-sonnet-5[high]") ==
               {"claude-sonnet-5", "high"}
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
