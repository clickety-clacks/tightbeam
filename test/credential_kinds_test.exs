defmodule Tightbeam.CredentialKindsTest do
  @moduledoc """
  credential-kinds-v1: both kinds, both harnesses, per host.

  FAIL-BEFORE: every api-key assertion in this file is red against the tree that
  precedes the invariant — there is no ANTHROPIC_API_KEY or OPENAI_API_KEY path
  anywhere in `lib/`, so the launch, catalog and liveness seams all answer with
  the subscription shape regardless of what the host holds.

  WHAT THIS FILE DOES NOT PROVE. Every assertion here is about OUR side of the
  boundary: which route is called, which header is sent, which environment
  variable carries the credential, that no secret reaches a command line. That a
  VALID api key returns 200 from either vendor is not proven anywhere in the
  suite, because no api key was reachable from this fleet on 2026-07-28 to record
  one — see credential-kinds-v1 and the unproven row in docs/SMOKE.md. The
  recorded fixtures used below are real 401s, captured live; nothing here is a
  200 anyone invented.
  """

  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Credentials, ModelCatalog}
  alias Tightbeam.Harness.{Claude, Codex}

  setup do
    base = Path.join(System.tmp_dir!(), "tb-cred-kinds-#{System.unique_integer([:positive])}")
    db = :"cred_kinds_db_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.DB, path: ":memory:", name: db})
    :ok = Tightbeam.Placement.ensure_schema(db)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, db: db}
  end

  defp stage!(base, provider, filename, bytes) do
    path = Path.join([base, "auth", provider, filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp platform_fixture_body do
    [__DIR__, "fixtures", "model_catalog", "openai_platform_models.jsonc"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "//"))
    |> Enum.join("\n")
  end

  # ------------------------------------------------------------------
  # The store: one authority, and it is the metadata
  # ------------------------------------------------------------------

  describe "the credential store records the kind" do
    test "an API key banks with the kind recorded and no expiry", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(staging, ".credentials.json"), "sk-ant-api03-staged")
      assert :ok = Credentials.finish_onboard(:anthropic, :api_key, lease_id, server)

      metadata =
        [ctx.base, "auth", "claude", ".tightbeam", "credential.json"]
        |> Path.join()
        |> File.read!()
        |> JSON.decode!()

      assert metadata["kind"] == "api_key"
      assert metadata["onboarded"] == true

      # Invariant 6: API keys are static. A synthetic expiry would eventually make
      # `credential_status` demand a re-onboard for a credential that still works.
      assert metadata["expires_at"] == nil
      assert metadata["subscription_status"] == nil

      assert Credentials.status(:anthropic, server) == :onboarded
      assert Credentials.kind(:anthropic, server) == :api_key
      assert Credentials.kind_at(ctx.base, :anthropic) == :api_key
    end

    test "a subscription banks with its kind and keeps its expiry", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(
        Path.join(staging, ".credentials.json"),
        ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-staged"}})
      )
      assert :ok = Credentials.finish_onboard(:anthropic, :subscription, lease_id, server)

      metadata =
        [ctx.base, "auth", "claude", ".tightbeam", "credential.json"]
        |> Path.join()
        |> File.read!()
        |> JSON.decode!()

      assert metadata["kind"] == "subscription"
      assert is_integer(metadata["expires_at"])
      assert metadata["subscription_status"] == "supported"
      assert Credentials.kind(:anthropic, server) == :subscription
    end

    test "no credential is its own state, not a kind", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      assert Credentials.kind(:anthropic, server) == :none
      assert Credentials.kind(:openai, server) == :none
      assert Credentials.kind_at(ctx.base, :openai) == :none
    end

    test "both providers on one host can hold different kinds", ctx do
      {:ok, server} = Credentials.start_link(name: nil, base_dir: ctx.base, machine: "eezo")

      {:ok, claude_staging, claude_lease_id} = Credentials.begin_onboard(:anthropic, server)
      File.write!(Path.join(claude_staging, ".credentials.json"), "sk-ant-api03-staged")
      :ok = Credentials.finish_onboard(:anthropic, :api_key, claude_lease_id, server)

      {:ok, codex_staging, codex_lease_id} = Credentials.begin_onboard(:openai, server)
      File.write!(Path.join(codex_staging, "auth.json"), ~s({"tokens":{"access_token":"t"}}))
      :ok = Credentials.finish_onboard(:openai, :subscription, codex_lease_id, server)

      assert Credentials.kind(:anthropic, server) == :api_key
      assert Credentials.kind(:openai, server) == :subscription
    end
  end

  # ------------------------------------------------------------------
  # Seam 1: env injection
  # ------------------------------------------------------------------

  describe "claude env injection dispatches on kind" do
    defp launch_opts(kind) do
      [
        common_env: [{"COMMON", "1"}],
        remote_env: ["REMOTE=1"],
        lineage: "tb-kinds",
        rails: nil,
        statutes: false,
        credential_kind: kind,
        ensure_workdir: fn _host, _cwd, _content, _opts -> :ok end,
        sh_out: nil
      ]
    end

    defp target(base, ssh) do
      %{
        base_dir: base,
        host_name: "vector",
        host_config: %{base_dir: base, ssh: ssh},
        adapter_binary: Path.join(base, "adapter"),
        sh: fn _command -> {"", 0} end
      }
    end

    test "a local api-key host gets ANTHROPIC_API_KEY and nothing else", ctx do
      stage!(ctx.base, "claude", ".credentials.json", "sk-ant-api03-local\n")

      plan = Claude.prepare_launch(target(ctx.base, nil), "/home", launch_opts(:api_key))
      env = Keyword.fetch!(plan, :env)

      assert {"ANTHROPIC_API_KEY", "sk-ant-api03-local"} in env
      refute Enum.any?(env, fn {name, _value} -> name == "CLAUDE_CODE_OAUTH_TOKEN" end)

      # Exactly one credential variable, never two and never an empty one: an
      # empty ANTHROPIC_API_KEY beside a real token is a precedence puzzle, not a
      # fallback.
      assert length(Enum.filter(env, fn {name, _} -> credential_variable?(name) end)) == 1
    end

    # A subscription credential is NOT injected, and that is the contract rather than an
    # omission. It is an OAuth record carrying a refresh token, and Claude Code refreshes it
    # in place in its config dir -- so it is linked into the home and the harness owns it.
    # An environment variable has nowhere to put a refresh token, so injecting the access
    # token would work until it lapsed and then fail with no way back.
    test "a local subscription host gets no credential in its environment at all", ctx do
      stage!(ctx.base, "claude", ".credentials.json", ~s({"claudeAiOauth":{"accessToken":"a"}}))

      plan = Claude.prepare_launch(target(ctx.base, nil), "/home", launch_opts(:subscription))
      env = Keyword.fetch!(plan, :env)

      assert Enum.filter(env, fn {name, _} -> credential_variable?(name) end) == []
      assert {"CLAUDE_CONFIG_DIR", "/home"} in env
    end

    test "a remote host expands its own credential and puts no secret in any argv", ctx do
      stage!(ctx.base, "claude", ".credentials.json", "sk-ant-api03-remote\n")

      plan =
        Claude.prepare_launch(
          target(ctx.base, "vector@remote"),
          "/home",
          launch_opts(:api_key)
        )

      argv = Keyword.fetch!(plan, :cmd)
      serialized = Enum.join(argv, " ")

      assert serialized =~ "ANTHROPIC_API_KEY=$(cat "
      refute serialized =~ "CLAUDE_CODE_OAUTH_TOKEN"

      # The credential is read by the REMOTE shell. No byte of it appears in a
      # command line on either machine, which is the property the subscription
      # path already had — an API key is equally a secret.
      refute serialized =~ "sk-ant-api03-remote"
      refute Enum.any?(Keyword.fetch!(plan, :env), fn {_n, v} -> v =~ "sk-ant" end)
    end

    test "codex's launch plan does not vary by kind", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"OPENAI_API_KEY":"sk-proj-x"}))

      keyed = Codex.prepare_launch(target(ctx.base, nil), "/home", launch_opts(:api_key))
      subbed = Codex.prepare_launch(target(ctx.base, nil), "/home", launch_opts(:subscription))

      # Codex reads its credential out of auth.json itself, so the kind cannot
      # reach the launch. Pinned rather than assumed.
      assert Keyword.fetch!(keyed, :env) == Keyword.fetch!(subbed, :env)
      assert Keyword.fetch!(keyed, :cmd) == Keyword.fetch!(subbed, :cmd)
    end

    defp credential_variable?(name),
      do: name in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]
  end

  # ------------------------------------------------------------------
  # Seam 2: catalog derivation
  # ------------------------------------------------------------------

  describe "catalog derivation dispatches on kind" do
    @claude_body JSON.encode!(%{
                   "data" => [
                     %{
                       "id" => "claude-sonnet-5",
                       "display_name" => "Sonnet 5",
                       "max_input_tokens" => 200_000,
                       "capabilities" => %{"effort" => %{"low" => %{"supported" => true}}}
                     }
                   ]
                 })

    test "an api-key claude host sends x-api-key on the same route", ctx do
      stage!(ctx.base, "claude", ".credentials.json", "sk-ant-api03-catalog")
      owner = self()

      fetch = fn path, headers ->
        send(owner, {:claude_probe, path, Enum.map(headers, fn {n, _v} -> to_string(n) end)})
        {:ok, @claude_body}
      end

      assert {:ok, [entry]} =
               Claude.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :api_key,
                 options: %{claude_fetch: fetch, claude_selectable_models: :all}
               })

      assert entry.ref == "claude-sonnet-5[low]"
      assert_receive {:claude_probe, path, names}
      assert path =~ "/v1/models"
      assert "x-api-key" in names
      refute "authorization" in names
    end

    test "a subscription claude host still sends a bearer token", ctx do
      stage!(ctx.base, "claude", ".credentials.json", ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-catalog"}}))
      owner = self()

      fetch = fn _path, headers ->
        send(
          owner,
          {:claude_probe, Enum.map(headers, fn {n, v} -> {to_string(n), to_string(v)} end)}
        )

        {:ok, @claude_body}
      end

      assert {:ok, [_entry]} =
               Claude.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :subscription,
                 options: %{claude_fetch: fetch, claude_selectable_models: :all}
               })

      assert_receive {:claude_probe, headers}
      assert {"authorization", "Bearer sk-ant-oat01-catalog"} in headers
      refute Enum.any?(headers, fn {name, _} -> name == "x-api-key" end)
    end

    test "an api-key codex host reads the platform route, not the account route", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"OPENAI_API_KEY":"sk-proj-catalog"}))
      owner = self()

      sh = fn command ->
        send(owner, {:codex_probe, Enum.join(command, " ")})
        {~s({"data":[{"id":"gpt-5.6-sol","object":"model"}]}) <> "\n200", 0}
      end

      assert {:ok, [entry]} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :api_key,
                 options: %{sh: sh}
               })

      assert_receive {:codex_probe, script}
      assert script =~ "api.openai.com/v1/models"
      refute script =~ "chatgpt.com"

      # The native field codex itself writes in api-key mode, not a shape we sniff.
      assert script =~ "OPENAI_API_KEY"

      # `client_version` is the ACCOUNT route's silent filter. Asking the host for
      # a codex version it will not use would turn "codex is not on this PATH"
      # into a catalog failure.
      refute script =~ "codex --version"

      # The platform route answers with bare ids: no display name, no effort
      # tiers, no context window. The catalog says so rather than inventing them.
      assert entry.ref == "gpt-5.6-sol"
      assert entry.display_name == "gpt-5.6-sol"
      assert entry.efforts == []
      assert entry.max_input_tokens == nil
      assert entry.provider == :openai
    end

    # Recorded reality, the #89/#99 api-key exercise (2026-07-28): the platform
    # route listed 125 bare ids; codex-acp REFUSED the platform id
    # `gpt-5.1-codex` at session/set_config_option (-32602 Invalid params) and
    # ACCEPTED `gpt-5.6-sol`, which ran a real turn on the same adapter+auth.
    # The fixture is that payload's shape trimmed to those two adjudicated ids.
    test "an api-key codex catalog withholds platform ids the adapter refuses", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"OPENAI_API_KEY":"sk-proj-selectable"}))
      sh = fn _command -> {platform_fixture_body() <> "\n200", 0} end

      assert {:ok, entries} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :api_key,
                 options: %{sh: sh}
               })

      # The catalog must not advertise what the adapter will refuse: spawns
      # validated against `gpt-5.1-codex` and then -32602'd at model apply.
      assert Enum.map(entries, & &1.ref) == ["gpt-5.6-sol"]
    end

    test "the injectable seam lifts the api-key selectable pin", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"OPENAI_API_KEY":"sk-proj-unpinned"}))
      sh = fn _command -> {platform_fixture_body() <> "\n200", 0} end

      assert {:ok, entries} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :api_key,
                 options: %{sh: sh, codex_selectable_models: :all}
               })

      assert Enum.map(entries, & &1.ref) == ["gpt-5.1-codex", "gpt-5.6-sol"]
    end

    test "the subscription catalog is not filtered by the api-key pin", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"tokens":{"access_token":"t"}}))

      # The account route lists only what the CLI accepts (one shared source),
      # so a slug outside the api-key pin must survive on the subscription kind.
      sh = fn _command ->
        {~s({"models":[{"slug":"gpt-x-future","display_name":"Future",) <>
           ~s("supported_reasoning_levels":[{"effort":"medium"}]}]}) <> "\n200 0.145.0", 0}
      end

      assert {:ok, [entry]} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :subscription,
                 options: %{sh: sh}
               })

      assert entry.ref == "gpt-x-future[medium]"
    end

    test "an empty api-key catalog is not blamed on a client version", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"OPENAI_API_KEY":"sk-proj-empty"}))
      sh = fn _command -> {~s({"data":[]}) <> "\n200", 0} end

      assert {:error, :empty_inventory} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :api_key,
                 options: %{sh: sh}
               })
    end

    test "an empty subscription catalog still names the client version that filtered it", ctx do
      stage!(ctx.base, "codex", "auth.json", ~s({"tokens":{"access_token":"t"}}))
      sh = fn _command -> {~s({"models":[]}) <> "\n200 0.145.0", 0} end

      assert {:error, {:empty_catalog_for_client_version, "0.145.0"}} =
               Codex.fetch_catalog(%{
                 base_dir: ctx.base,
                 credential_kind: :subscription,
                 options: %{sh: sh}
               })
    end
  end

  # ------------------------------------------------------------------
  # The ceremony speaks the wire vocabulary end to end (invariant 2)
  # ------------------------------------------------------------------

  describe "the onboarding ceremony replies in wire spellings" do
    # FAIL-BEFORE (#100): the finish reply returned the STORE spelling
    # (`credential_kind: :api_key`), so the CLI printed "api_key" on a wire
    # whose contract — and every other surface, via `wire_credential_kind/1` —
    # says "apiKey". The camelizer rewrites keys, not atom values.
    test "the finish reply names the banked kind as apiKey, not api_key", ctx do
      :ok = Tightbeam.Devices.ensure_schema(ctx.db)

      {:ok, _rows} =
        Tightbeam.DB.query(
          ctx.db,
          "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
          ["kind-admin", System.system_time(:second)]
        )

      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard =
        Tightbeam.Gateway.handlers(%{
          base_dir: ctx.base,
          db: ctx.db,
          onboarding_lease_ms: 1_800_000
        })["onboard"]

      call = %{
        origin: "user:kind-admin",
        params: %{provider: "anthropic", kind: "apiKey"}
      }

      assert %{status: "ready", staging_path: staging, lease_id: lease_id} =
               onboard.(put_in(call.params[:phase], "begin"))

      File.write!(Path.join(staging, ".credentials.json"), "sk-ant-api03-ceremony")

      assert %{provider: :anthropic, credential_kind: "apiKey", status: "onboarded"} =
               onboard.(
                 call
                 |> put_in([:params, :phase], "finish")
                 |> put_in([:params, :lease_id], lease_id)
               )

      # The wire translation did not leak into the store, whose spelling is its
      # own (invariant: one authority per vocabulary).
      assert Credentials.kind(:anthropic, Credentials) == :api_key
    end

    # FAIL-BEFORE (#106): the begin reply echoed the STORE spelling
    # (`kind: :api_key`), so the ceremony's opening line said "api_key" on a
    # wire whose contract — and every other surface, via
    # `wire_credential_kind/1` — says "apiKey". Same camelizer gap as the
    # finish reply: it rewrites keys, not atom values.
    test "the begin reply names the leased kind as apiKey, not api_key", ctx do
      :ok = Tightbeam.Devices.ensure_schema(ctx.db)

      {:ok, _rows} =
        Tightbeam.DB.query(
          ctx.db,
          "INSERT INTO users (userId, isAdmin, createdAt) VALUES (?1, 1, ?2)",
          ["kind-admin", System.system_time(:second)]
        )

      start_supervised!({Credentials, name: Credentials, base_dir: ctx.base, machine: "testhost"})

      onboard =
        Tightbeam.Gateway.handlers(%{
          base_dir: ctx.base,
          db: ctx.db,
          onboarding_lease_ms: 1_800_000
        })["onboard"]

      call = %{
        origin: "user:kind-admin",
        params: %{provider: "anthropic", phase: "begin"}
      }

      assert %{provider: :anthropic, kind: "apiKey", status: "ready", lease_id: lease_id} =
               onboard.(put_in(call.params[:kind], "apiKey"))

      # Release the lease so the subscription spelling gets its own ceremony.
      onboard.(
        call
        |> put_in([:params, :phase], "cancel")
        |> put_in([:params, :lease_id], lease_id)
      )

      assert %{provider: :anthropic, kind: "subscription", status: "ready"} =
               onboard.(put_in(call.params[:kind], "subscription"))

      # A lease banks nothing, and the wire translation did not leak into the
      # store, whose spelling is its own (invariant: one authority per
      # vocabulary).
      assert Credentials.kind(:anthropic, Credentials) == :none
    end
  end

  # ------------------------------------------------------------------
  # Acceptance 2: mixed fleet
  # ------------------------------------------------------------------

  describe "a mixed fleet derives per-host catalogs per-host kind" do
    test "gateway on a subscription and satellite on an API key", ctx do
      gateway_dir = Path.join(ctx.base, "gateway")
      satellite_dir = Path.join(ctx.base, "satellite")
      File.mkdir_p!(gateway_dir)

      register_hosts(ctx.db, %{
        "satellite" => %{ssh: "tb@satellite", base_dir: satellite_dir}
      })

      owner = self()

      sh = fn command ->
        script = List.last(command)
        send(owner, {:probe, script})

        if String.contains?(script, "api.openai.com") do
          {~s({"data":[{"id":"gpt-5.6-sol","object":"model"}]}) <> "\n200", 0}
        else
          {~s({"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","supported_reasoning_levels":[{"effort":"medium"}]}]}) <>
             "\n200 0.145.0", 0}
        end
      end

      {:ok, catalog} =
        ModelCatalog.start_link(
          name: nil,
          base_dir: gateway_dir,
          db: ctx.db,
          sh: sh,
          credential_status: fn _provider, _host -> :onboarded end,
          credential_kind: fn _provider, host ->
            if host == "satellite", do: :api_key, else: :subscription
          end
        )

      # Each host's entry is derived against ITS OWN kind, and the two differ in
      # a way only the kind explains: the satellite's api-key catalog carries a
      # bare id (the platform route states no effort tiers), while the gateway's
      # subscription catalog carries the effort-qualified ref the account route
      # does state. Two correct answers about two accounts, not a stale copy of
      # one another.
      assert eventually(fn ->
               {sat, _} = ModelCatalog.get("satellite", "codex", catalog)
               {gw, _} = ModelCatalog.get(local_host(), "codex", catalog)

               Enum.map(sat, & &1.ref) == ["gpt-5.6-sol"] and
                 Enum.map(gw, & &1.ref) == ["gpt-5.6-sol[medium]"]
             end)

      probes = drain_probes([])

      # The satellite reached the PLATFORM route and the gateway the ACCOUNT
      # route — the routing, not just the parsing, followed each host's kind.
      assert Enum.any?(probes, &String.contains?(&1, "api.openai.com/v1/models"))
      assert Enum.any?(probes, &String.contains?(&1, "chatgpt.com/backend-api/codex/models"))
    end

    defp local_host, do: Tightbeam.Placement.local_host_name()

    defp drain_probes(acc) do
      receive do
        {:probe, script} -> drain_probes([script | acc])
      after
        200 -> acc
      end
    end

    defp eventually(check, attempts \\ 50) do
      cond do
        check.() -> true
        attempts == 0 -> false
        true -> Process.sleep(20) && eventually(check, attempts - 1)
      end
    end
  end

  # ------------------------------------------------------------------
  # Seam 3: liveness
  # ------------------------------------------------------------------

  describe "liveness probes the route its kind can reach" do
    test "a rejected api key is dead, from the vendor's own recorded refusal" do
      # RECORDED LIVE 2026-07-28 against api.anthropic.com with an invalid key.
      # The vendor's answer to `x-api-key` ("API key is invalid.") is a different
      # sentence from its answer to a bearer token ("Invalid bearer token"), which
      # is the evidence that the header is not interchangeable.
      transport = fixture_transport("claude-dead-api-key.json")

      assert {:dead, {:http_status, 401}} =
               Claude.credential_live?(
                 %{host_config: %{ssh: nil}, sh: fn _ -> {"", 0} end},
                 "/vector/home",
                 transport: transport,
                 timeout_ms: 500,
                 credential_kind: :api_key
               )
    end

    test "the api-key probe names the api-key header, not a bearer scheme" do
      owner = self()

      transport = fn _target, %{command: command} ->
        send(owner, {:command, command})
        {:ok, %{status: 401, headers: %{}, body: "{}"}}
      end

      Claude.credential_live?(
        %{host_config: %{ssh: nil}, sh: fn _ -> {"", 0} end},
        "/vector/home",
        transport: transport,
        timeout_ms: 500,
        credential_kind: :api_key
      )

      assert_receive {:command, command}

      # The header NAME rides in argv; the credential does not — it is read from
      # disk inside the script, on the host that owns it.
      assert "x-api-key" in command
      refute Enum.any?(command, &(&1 == "Bearer "))
    end

    defp fixture_transport(name) do
      recording =
        :tightbeam
        |> Application.app_dir(Path.join("priv/credential_live", name))
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("response")

      fn _target, _request ->
        {:ok,
         %{
           status: recording["status"],
           headers: recording["headers"],
           body: JSON.encode!(recording["body"])
         }}
      end
    end
  end
end
