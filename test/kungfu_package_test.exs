defmodule Tightbeam.KungfuPackageTest do
  # Swaps the global shipped-bundle root, so it cannot run beside other tests.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Identity, Reminders}

  @shipped Path.expand("../priv/kungfu", __DIR__)
  @fixture Path.expand("support/fixtures/kungfu", __DIR__)
  @engineering Path.join(@fixture, "agentic-engineering")
  @reminders ~w(terminal-action work-item-routing work-item-slate critical-lease-retire identity-staleness remedy-pending)

  setup do
    root = Path.join(System.tmp_dir!(), "kungfu-package-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    previous_source = Application.get_env(:tightbeam, :identity_source_dir)
    Application.delete_env(:tightbeam, :identity_source_dir)

    on_exit(fn ->
      restore_env(:kungfu_bundle_root_dir, previous_root)
      restore_env(:identity_source_dir, previous_source)
      File.rm_rf!(root)
    end)

    %{base: Path.join(root, "org")}
  end

  defp restore_env(key, nil), do: Application.delete_env(:tightbeam, key)
  defp restore_env(key, value), do: Application.put_env(:tightbeam, key, value)

  defp ship!(root), do: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, root)

  defp publish!(base, candidate) do
    assert {:ok, revision} = Identity.publish_live!(base, candidate)
    revision
  end

  defp identity_path(base, relative), do: Path.join([base, "identity", relative])

  defp receipt_paths(base, name) do
    base
    |> identity_path("kungfu/#{name}/installed.toml")
    |> File.read!()
    |> Toml.decode!()
    |> Map.fetch!("paths")
  end

  test "the package does not ship agentic-engineering and offers uncle-enzo first", ctx do
    ship!(@shipped)

    refute File.exists?(Application.app_dir(:tightbeam, "priv/kungfu/agentic-engineering"))
    refute "agentic-engineering" in Identity.available_bundle_names()

    bundles = Identity.available_bundles()

    assert [%{name: "uncle-enzo", primary: true, root_archetype: "uncle-enzo.exec"} | rest] =
             bundles

    refute Enum.any?(rest, & &1.primary)
    assert Enum.map(rest, & &1.name) == Enum.sort(Enum.map(rest, & &1.name))

    assert_raise ArgumentError, ~r/unknown kungfu bundle agentic-engineering/, fn ->
      Identity.learn!(ctx.base, "agentic-engineering", "test")
    end

    # The refused learn above already seeded the neutral identity.
    assert :noop = Identity.init!(ctx.base)
    guidance = Identity.snapshot!(ctx.base, "default", :codex).guidance

    [_, offers] = String.split(guidance, "## Available kungfu bundles in this Tightbeam build")
    assert [_, first | _] = String.split(offers, "### `")
    assert String.starts_with?(first, "uncle-enzo`")

    assert offers =~
             "### `uncle-enzo`\nPrimary: when more than one bundle fits the user's goal, offer this one first.\nPurpose: "

    refute guidance =~ "### `agentic-engineering`"
  end

  test "each shipped kungfu publishes with all its rule references resolved", %{base: base} do
    ship!(@shipped)

    for bundle <- Identity.available_bundle_names() do
      bundle_base = Path.join(base, bundle)
      assert {:ok, candidate} = Identity.learn!(bundle_base, bundle, "test")
      publish!(bundle_base, candidate)
    end
  end

  test "no shipped file names the removed bundle" do
    offenders =
      Application.app_dir(:tightbeam, "priv")
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn path ->
        bytes = File.read!(path)
        String.valid?(bytes) and bytes =~ "agentic-engineering"
      end)

    assert offenders == []
  end

  test "files every install needs keep the bytes the engineering bundle shipped" do
    for kind <- @reminders do
      shipped = File.read!(Application.app_dir(:tightbeam, "priv/reminders/#{kind}.md"))
      assert shipped == File.read!(Path.join(@engineering, "reminders/#{kind}.md"))
      assert Reminders.default(kind) == shipped
    end

    for file <- ~w(SKILL.md LICENSE-asd-ste100-skill) do
      assert File.read!(Path.join(@shipped, "uncle-enzo/skills/human-communication/#{file}")) ==
               File.read!(Path.join(@engineering, "skills/human-communication/#{file}"))
    end
  end

  test "the test bundle root is the shipped bundles plus the retired engineering fixture" do
    assert Enum.sort(File.ls!(@fixture)) ==
             Enum.sort(["agentic-engineering" | File.ls!(@shipped)])

    for name <- File.ls!(@shipped) do
      link = Path.join(@fixture, name)
      assert {:ok, %{type: :symlink}} = File.lstat(link)
      assert Path.expand(File.read_link!(link), @fixture) == Path.join(@shipped, name)
    end
  end

  test "an org that learned agentic-engineering keeps it, learns uncle-enzo, relearns and unlearns it",
       ctx do
    # A 0.1.16-style org: the engineering bundle was shipped when it was learned.
    ship!(@fixture)
    assert :initialized = Identity.init!(ctx.base)
    assert {:ok, candidate} = Identity.learn!(ctx.base, "agentic-engineering", "test")
    publish!(ctx.base, candidate)
    engineering_receipt = receipt_paths(ctx.base, "agentic-engineering")

    # The upgraded build no longer ships it. Nothing the org learned goes missing.
    ship!(@shipped)
    assert Identity.snapshot!(ctx.base, "agentic-engineering.coder", :codex).guidance != ""
    assert Identity.missing_installed_kungfu(ctx.base) == []
    assert "agentic-engineering" in Identity.public_kungfu_names(ctx.base)

    # Learning the primary bundle keeps every engineering file and its executable watcher.
    assert {:ok, candidate} = Identity.learn!(ctx.base, "uncle-enzo", "test")
    publish!(ctx.base, candidate)

    for path <- engineering_receipt do
      assert File.regular?(identity_path(ctx.base, path)), path
    end

    watcher = identity_path(ctx.base, "kungfu/agentic-engineering/sentinels/landing-watch")
    assert Bitwise.band(File.stat!(watcher).mode, 0o111) != 0
    assert receipt_paths(ctx.base, "agentic-engineering") == engineering_receipt
    assert "skills/human-communication/SKILL.md" in engineering_receipt
    assert "skills/human-communication/SKILL.md" in receipt_paths(ctx.base, "uncle-enzo")

    assert {:ok, _} = Tightbeam.Sentinels.resolve(ctx.base, "agentic-engineering/landing-watch")
    assert {:ok, enzo} = Tightbeam.Sentinels.resolve(ctx.base, "uncle-enzo/github-watch")
    assert enzo.requires == ["GH_CONFIG_DIR"]
    assert {:ok, _} = Tightbeam.Sentinels.resolve_event(ctx.base, "landing.settled")
    assert {:ok, _} = Tightbeam.Sentinels.resolve_event(ctx.base, "uncle-enzo/github-watch/pr.settled")

    # Relearn refreshes the shipped bundle and leaves the retained one as it was.
    assert {:ok, candidate} = Identity.relearn!(ctx.base, "test")
    publish!(ctx.base, candidate)
    assert receipt_paths(ctx.base, "agentic-engineering") == engineering_receipt
    assert Identity.snapshot!(ctx.base, "agentic-engineering.coder", :codex).guidance != ""

    # An org elects the shared skill on the exec role, as the live org overlay does.
    exec = identity_path(ctx.base, "kungfu/uncle-enzo/archetypes/exec.toml")

    candidate =
      Identity.edit!(
        ctx.base,
        "uncle-enzo.exec",
        :manifest,
        String.replace(File.read!(exec), "skills = []", ~s(skills = ["human-communication"])),
        "test"
      )

    publish!(ctx.base, candidate)

    # Unlearn keeps the path uncle-enzo still claims and removes everything else.
    candidate = Identity.unlearn!(ctx.base, "agentic-engineering", "test")
    publish!(ctx.base, candidate)

    refute File.exists?(identity_path(ctx.base, "kungfu/agentic-engineering"))
    refute "agentic-engineering" in Identity.public_kungfu_names(ctx.base)

    for path <- engineering_receipt -- receipt_paths(ctx.base, "uncle-enzo") do
      refute File.exists?(identity_path(ctx.base, path)), path
    end

    assert File.regular?(identity_path(ctx.base, "skills/human-communication/SKILL.md"))
    exec = Identity.snapshot!(ctx.base, "uncle-enzo.exec", :codex)
    assert Map.has_key?(exec.skills, "human-communication")
    assert Identity.missing_installed_kungfu(ctx.base) == []
  end
end
