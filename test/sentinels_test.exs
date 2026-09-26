defmodule Tightbeam.SentinelsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Identity, Model, Org, Placement, Schema}
  alias Tightbeam.{SentinelSupervisor, Sentinels}

  # Two synthetic bundles that each declare a sentinel named "watch", so a bare
  # name is ambiguous and each qualified name is distinct.
  @bundles ~w(alpha-bundle beta-bundle)

  setup do
    root = Path.join(System.tmp_dir!(), "tb-sentinels-#{System.unique_integer([:positive])}")
    bundles = Path.join(root, "kungfu")
    base = Path.join(root, "runtime")
    Enum.each(@bundles, &write_bundle!(bundles, &1))

    previous = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    Application.put_env(:tightbeam, :kungfu_bundle_root_dir, bundles)

    db = :"sentinels_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, previous),
        else: Application.delete_env(:tightbeam, :kungfu_bundle_root_dir)

      File.rm_rf!(root)
    end)

    %{root: root, bundles: bundles, base: base, db: db, host: Placement.local_host_name()}
  end

  describe "manifest declarations" do
    test "each malformed sentinel declaration is refused by name", ctx do
      cases = [
        {~s(name = "watch"\ncommand = "sentinels/watch"\nrequires = []\nextra = 1),
         ~r/unknown keys extra/},
        {~s(name = "../watch"\ncommand = "sentinels/watch"\nrequires = []),
         ~r/sentinel name must match/},
        {~s(name = "watch"\ncommand = "../outside"\nrequires = []),
         ~r/command must be a file path inside the bundle/},
        {~s(name = "watch"\ncommand = "manifest.toml"\nrequires = []),
         ~r/command must be a file path inside the bundle/},
        {~s(name = "watch"\ncommand = "sentinels/watch"\nrequires = ["lower"]),
         ~r/requires must be a list of names/},
        {~s(name = "watch"\ncommand = "sentinels/absent"\nrequires = []),
         ~r/command sentinels\/absent, which the bundle does not ship/}
      ]

      for {declaration, message} <- cases do
        write_manifest!(ctx.bundles, "alpha-bundle", "[[sentinels]]\n#{declaration}\n")
        assert_raise ArgumentError, message, fn -> learn!(ctx.base, "alpha-bundle") end
      end

      duplicate = """
      [[sentinels]]
      name = "watch"
      command = "sentinels/watch"
      requires = []

      [[sentinels]]
      name = "watch"
      command = "sentinels/watch"
      requires = []
      """

      write_manifest!(ctx.bundles, "alpha-bundle", duplicate)

      assert_raise ArgumentError, ~r/declares sentinel watch twice/, fn ->
        learn!(ctx.base, "alpha-bundle")
      end
    end

    test "learned commands are executable, bundle-namespaced and distinct", ctx do
      learn_both!(ctx)
      dir = Path.join(ctx.base, "identity")

      for bundle <- @bundles do
        path = "kungfu/#{bundle}/sentinels/watch"
        {tree, 0} = System.cmd("git", ["-C", dir, "ls-tree", "tightbeam/live", "--", path])
        assert tree =~ ~r/^100755 blob /
      end

      assert %{sentinels: sentinels} = Identity.learned_sentinels(ctx.base)

      assert Enum.sort(Enum.map(sentinels, &{&1.qualified, &1.command_path})) == [
               {"alpha-bundle/watch", "kungfu/alpha-bundle/sentinels/watch"},
               {"beta-bundle/watch", "kungfu/beta-bundle/sentinels/watch"}
             ]
    end
  end

  describe "names" do
    test "a bare name shared by two bundles is ambiguous; qualified names resolve", ctx do
      learn_both!(ctx)

      assert {:error, %{code: "ambiguous_sentinel", message: message}} =
               Sentinels.resolve(ctx.base, "watch")

      assert message =~ "alpha-bundle/watch"
      assert message =~ "beta-bundle/watch"

      assert {:ok, %{qualified: "beta-bundle/watch", requires: ["WATCH_TARGET", "WATCH_EXTRA"]}} =
               Sentinels.resolve(ctx.base, "beta-bundle/watch")

      assert {:error, %{code: "unknown_sentinel"}} =
               Sentinels.resolve(ctx.base, "alpha-bundle/other")
    end

    test "a bare name declared by one bundle resolves", ctx do
      Identity.init!(ctx.base)
      learn!(ctx.base, "alpha-bundle")
      assert {:ok, %{qualified: "alpha-bundle/watch"}} = Sentinels.resolve(ctx.base, "watch")
    end
  end

  describe "setup computation" do
    test "learning starts nothing and reports what remains until the list is empty", ctx do
      learn_both!(ctx)

      assert Sentinels.states(ctx.db, ctx.host) == %{}
      refute File.exists?(Path.join(ctx.base, "sentinels"))

      setup = Sentinels.setup(ctx.base, ctx.db, ctx.host, "alpha-bundle")
      assert setup.setup_text == "Synthetic setup for alpha-bundle.\n"
      assert setup.sentinels == ["alpha-bundle/watch"]

      assert Enum.map(setup.pending, &{&1.state, &1[:setting]}) == [
               {"setting-missing", "WATCH_TARGET"},
               {"setting-missing", "WATCH_EXTRA"},
               {"disabled", nil}
             ]

      assert hd(setup.pending).action ==
               "run: tightbeam host-env-set --sentinel alpha-bundle/watch WATCH_TARGET=<value>"

      {:ok, sentinel} = Sentinels.resolve(ctx.base, "alpha-bundle/watch")

      assert {:error,
              %{
                code: "sentinel_settings_missing",
                missing: ["WATCH_TARGET", "WATCH_EXTRA"],
                message: message
              }} =
               Sentinels.enable(ctx.db, ctx.host, sentinel, "user:flynn")

      assert message =~
               "set each with: tightbeam host-env-set --sentinel alpha-bundle/watch WATCH_TARGET=<value>; " <>
                 "tightbeam host-env-set --sentinel alpha-bundle/watch WATCH_EXTRA=<value>"

      set_settings!(ctx, "alpha-bundle/watch", %{"WATCH_TARGET" => "a", "WATCH_EXTRA" => "b"})

      assert [%{state: "disabled"}] =
               Sentinels.setup(ctx.base, ctx.db, ctx.host, "alpha-bundle").pending

      assert {:ok, %{state: "enabled"}} =
               Sentinels.enable(ctx.db, ctx.host, sentinel, "user:flynn")

      assert Sentinels.setup(ctx.base, ctx.db, ctx.host, "alpha-bundle").pending == []

      assert ["beta-bundle"] ==
               ctx.base
               |> Sentinels.setup_all(ctx.db, ctx.host)
               |> Enum.reject(&(&1.pending == []))
               |> Enum.map(& &1.bundle)
    end

    test "kungfu-setup and sentinel-list report names and states, never values", ctx do
      learn_both!(ctx)
      set_settings!(ctx, "alpha-bundle/watch", %{"WATCH_TARGET" => "synthetic-secret-value"})
      handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base})

      setup = handlers["kungfu-setup"].(%{origin: "process:any", params: %{name: "alpha-bundle"}})
      assert setup.bundle == "alpha-bundle"
      assert Enum.map(setup.pending, & &1.state) == ["setting-missing", "disabled"]

      listed = handlers["sentinel-list"].(%{origin: "process:any", params: %{}})

      assert [
               %{sentinel: "alpha-bundle/watch", state: "disabled", missing: ["WATCH_EXTRA"]},
               _beta
             ] =
               listed.sentinels

      refute inspect(setup) =~ "synthetic-secret-value"
      refute inspect(listed) =~ "synthetic-secret-value"
    end
  end

  describe "sentinel settings" do
    test "sentinel scope stays out of harness environments and results carry names only", ctx do
      learn_both!(ctx)
      handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base})

      set =
        handlers["host-env-set"].(%{
          origin: "user:flynn",
          params: %{
            sentinel: "alpha-bundle/watch",
            name: "WATCH_TARGET",
            value: "synthetic-secret-value"
          }
        })

      assert %{sentinel: "alpha-bundle/watch", name: "WATCH_TARGET", changed: true} = set

      listed =
        handlers["host-env-list"].(%{
          origin: "user:flynn",
          params: %{sentinel: "alpha-bundle/watch"}
        })

      assert [%{name: "WATCH_TARGET"}] = listed.settings
      assert listed.missing == ["WATCH_EXTRA"]
      refute inspect({set, listed}) =~ "synthetic-secret-value"

      assert %{overlays: []} = handlers["host-env-list"].(%{origin: "user:flynn", params: %{}})

      {:ok, [[projected]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM host_environment_projection")
      assert projected == 0

      assert %{code: "sentinel_scope_conflict"} =
               handlers["host-env-set"].(%{
                 origin: "user:flynn",
                 params: %{
                   sentinel: "alpha-bundle/watch",
                   harness: "claude",
                   name: "WATCH_TARGET",
                   value: "x"
                 }
               })

      assert %{code: "sentinel_host_not_local"} =
               handlers["host-env-set"].(%{
                 origin: "user:flynn",
                 params: %{
                   sentinel: "alpha-bundle/watch",
                   host: "elsewhere",
                   name: "WATCH_TARGET",
                   value: "x"
                 }
               })

      assert %{code: "ambiguous_sentinel"} =
               handlers["host-env-set"].(%{
                 origin: "user:flynn",
                 params: %{sentinel: "watch", name: "WATCH_TARGET", value: "x"}
               })

      assert %{removed: true} =
               handlers["host-env-unset"].(%{
                 origin: "user:flynn",
                 params: %{sentinel: "alpha-bundle/watch", name: "WATCH_TARGET"}
               })
    end

    test "removing a bundle forgets its states and settings and leaves the other's", ctx do
      learn_both!(ctx)
      set_settings!(ctx, "alpha-bundle/watch", %{"WATCH_TARGET" => "a", "WATCH_EXTRA" => "b"})
      set_settings!(ctx, "beta-bundle/watch", %{"WATCH_TARGET" => "c", "WATCH_EXTRA" => "d"})
      enable!(ctx, "alpha-bundle/watch")
      enable!(ctx, "beta-bundle/watch")

      assert :ok = Sentinels.remove_bundle(ctx.db, ctx.host, "alpha-bundle")

      assert Map.keys(Sentinels.states(ctx.db, ctx.host)) == ["beta-bundle/watch"]
      assert Sentinels.settings(ctx.db, ctx.host, "alpha-bundle/watch") == []

      assert Enum.sort(Sentinels.settings(ctx.db, ctx.host, "beta-bundle/watch")) == [
               {"WATCH_EXTRA", "d"},
               {"WATCH_TARGET", "c"}
             ]
    end
  end

  describe "supervision" do
    setup ctx do
      System.put_env("TIGHTBEAM_TOKEN", "synthetic-token")
      System.put_env("WATCH_EXTRA", "inherited-leak")

      on_exit(fn ->
        System.delete_env("TIGHTBEAM_TOKEN")
        System.delete_env("WATCH_EXTRA")
      end)

      ctx
    end

    test "a supervisor with nothing enabled starts nothing", ctx do
      learn_both!(ctx)
      start_supervisor!(ctx)
      refute File.exists?(Path.join(ctx.base, "sentinels"))
    end

    test "a child runs the published bytes with only its own settings and attribution", ctx do
      learn_both!(ctx)

      set_settings!(ctx, "alpha-bundle/watch", %{
        "WATCH_TARGET" => "alpha-value",
        "WATCH_EXTRA" => "e"
      })

      set_settings!(ctx, "beta-bundle/watch", %{
        "WATCH_TARGET" => "beta-value",
        "BETA_ONLY" => "f"
      })

      enable!(ctx, "alpha-bundle/watch")
      # Removed after enable: the child must not inherit the gateway's value instead.
      true =
        Placement.unset_sentinel_env(
          ctx.db,
          ctx.host,
          "sentinel:alpha-bundle/watch",
          "WATCH_EXTRA",
          %{}
        )

      start_supervisor!(ctx)
      run_dir = Path.join([ctx.base, "sentinels", "alpha-bundle", "watch"])
      env_file = Path.join(run_dir, "env.out")
      assert wait_until(fn -> File.exists?(env_file) and File.read!(env_file) =~ "END_OF_ENV" end)

      env =
        env_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "=", parts: 2) do
            [name, value] -> [{name, value}]
            _continuation -> []
          end
        end)
        |> Map.new()

      assert env["TIGHTBEAM_AS_PROCESS"] == "sentinel:alpha-bundle/watch"
      assert env["TIGHTBEAM_BASE_DIR"] == ctx.base
      assert env["WATCH_TARGET"] == "alpha-value"
      assert String.starts_with?(env["PATH"], "/synthetic/cli/bin:")
      refute Map.has_key?(env, "TIGHTBEAM_TOKEN")
      refute Map.has_key?(env, "WATCH_EXTRA")
      refute Map.has_key?(env, "BETA_ONLY")
      # The watcher keeps its state where it would outside Tightbeam.
      refute Map.get(env, "XDG_STATE_HOME", "") =~ ctx.base

      sha =
        :crypto.hash(:sha256, command_bytes("alpha-bundle")) |> Base.encode16(case: :lower)

      assert File.read!(Path.join(run_dir, "sentinel.log")) =~
               ~r/start alpha-bundle\/watch revision=[0-9a-f]+ sha256=#{sha}/

      assert %{state: "enabled", command_sha256: ^sha} =
               Sentinels.states(ctx.db, ctx.host)["alpha-bundle/watch"]

      refute File.exists?(Path.join([ctx.base, "sentinels", "beta-bundle"]))
    end

    test "repeated fast exits stop the sentinel and wake its enabler once", ctx do
      Org.create(ctx.db, %{
        session_key: Org.personal_session_key("flynn"),
        display_name: "Flynn",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

      File.write!(Path.join(ctx.bundles, "alpha-bundle/sentinels/watch"), "#!/bin/sh\nexit 3\n")
      learn_both!(ctx)
      set_settings!(ctx, "alpha-bundle/watch", %{"WATCH_TARGET" => "a", "WATCH_EXTRA" => "b"})
      enable!(ctx, "alpha-bundle/watch")

      supervisor = start_supervisor!(ctx, backoff_unit_ms: 1)

      assert wait_until(fn ->
               match?(
                 %{state: "stopped"},
                 Sentinels.states(ctx.db, ctx.host)["alpha-bundle/watch"]
               )
             end)

      %{reason: reason} = Sentinels.states(ctx.db, ctx.host)["alpha-bundle/watch"]
      assert reason =~ "exited 5 times in a row"
      assert reason =~ "last status 3"

      log =
        File.read!(Path.join([ctx.base, "sentinels", "alpha-bundle", "watch", "sentinel.log"]))

      assert length(Regex.scan(~r/ exit alpha-bundle\/watch status=3/, log)) == 5

      {:ok, wakes} = DB.query(ctx.db, "SELECT sessionKey, origin, prompt FROM wakes")

      assert [[session_key, "process:tightbeam", prompt]] = wakes
      assert session_key == Org.personal_session_key("flynn")
      assert prompt =~ "Sentinel alpha-bundle/watch on #{ctx.host} is stopped"
      assert prompt =~ "tightbeam sentinel enable alpha-bundle/watch"

      assert [%{state: "stopped", action: "run: tightbeam sentinel enable alpha-bundle/watch"}] =
               Sentinels.setup(ctx.base, ctx.db, ctx.host, "alpha-bundle").pending

      # Children that exit at once never take the supervisor down with them.
      assert Process.alive?(supervisor)
    end
  end

  defp write_bundle!(root, bundle) do
    dir = Path.join(root, bundle)
    role = "#{bundle}-role"
    File.mkdir_p!(Path.join(dir, "archetypes"))
    File.mkdir_p!(Path.join(dir, "guidance"))
    File.mkdir_p!(Path.join(dir, "sentinels"))

    File.write!(Path.join(dir, "archetypes/#{role}.toml"), """
    name = "#{role}"
    skills = []

    [guidance]
    text = '#include "#{role}.md"'
    """)

    File.write!(Path.join(dir, "guidance/#{role}.md"), "Synthetic guidance for #{bundle}.\n")
    File.write!(Path.join(dir, "setup.md"), "Synthetic setup for #{bundle}.\n")
    File.write!(Path.join(dir, "sentinels/watch"), command_bytes(bundle))

    write_manifest!(root, bundle, """
    [[sentinels]]
    name = "watch"
    command = "sentinels/watch"
    requires = ["WATCH_TARGET", "WATCH_EXTRA"]
    """)
  end

  defp write_manifest!(root, bundle, sentinels) do
    File.write!(Path.join([root, bundle, "manifest.toml"]), """
    purpose = "Synthetic sentinel proof for #{bundle}."
    root_archetype = "#{bundle}-role"

    #{sentinels}
    """)
  end

  # Records its environment, then waits to be stopped.
  defp command_bytes(bundle) do
    "#!/bin/sh\n# #{bundle}\nenv > env.tmp\necho END_OF_ENV >> env.tmp\nmv env.tmp env.out\nexec sleep 600\n"
  end

  defp learn!(base, bundle) do
    case Identity.learn!(base, bundle, "test") do
      {:ok, candidate} -> {:ok, _revision} = Identity.publish_live!(base, candidate)
      other -> flunk("learn #{bundle}: #{inspect(other)}")
    end
  end

  defp learn_both!(ctx) do
    Identity.init!(ctx.base)
    Enum.each(@bundles, &learn!(ctx.base, &1))
  end

  defp set_settings!(ctx, qualified, settings) do
    for {name, value} <- settings do
      {:ok, _} =
        Placement.set_sentinel_env(
          ctx.db,
          ctx.host,
          Sentinels.scope(qualified),
          name,
          value,
          "user:flynn",
          %{}
        )
    end
  end

  defp enable!(ctx, qualified) do
    {:ok, sentinel} = Sentinels.resolve(ctx.base, qualified)
    {:ok, %{state: "enabled"}} = Sentinels.enable(ctx.db, ctx.host, sentinel, "user:flynn")
  end

  defp start_supervisor!(ctx, opts \\ []) do
    start_supervised!(
      {SentinelSupervisor,
       [
         db: ctx.db,
         base_dir: ctx.base,
         cli_bin: "/synthetic/cli/bin/tightbeam",
         host: ctx.host,
         name: :"sentinel_supervisor_#{System.unique_integer([:positive])}"
       ] ++ opts}
    )
  end

  # Check-side wait: how long to watch for an effect, never a setup budget.
  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, deadline)
    end
  end
end
