defmodule Tightbeam.FeatureSmokeHomeTest do
  use ExUnit.Case, async: true

  alias Tightbeam.{FeatureSmokeHome, Homes}

  @config "model = \"operator-model\"\n"
  @projected_config @config <> "[features]\nguardian_approval = false\n"

  setup do
    base = Path.join(System.tmp_dir!(), "tb-smoke-home-#{System.unique_integer([:positive])}")
    home = Homes.home_path(base, "fixture", :codex)
    File.mkdir_p!(Path.join(home, "sessions"))
    File.write!(Path.join(home, "sessions/history.jsonl"), "synthetic durable history\n")
    File.write!(Path.join(home, "config.toml"), @config)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, home: home}
  end

  test "shared HOME accepts independent cache growth during real projection", context do
    # Deliberately no product/plugin/version allowlist: this is an independent
    # synthetic writer, not a claim about who wrote the preserved E2E leaf.
    cache = Path.join(context.home, "arbitrary-harness-cache/new/entry.json")

    writer =
      Task.async(fn ->
        File.mkdir_p!(Path.dirname(cache))
        File.write!(cache, "synthetic cache")
      end)

    project(context)
    :ok = Task.await(writer)
    assert :ok == FeatureSmokeHome.verify_owned!(context.home, :codex)
    assert File.read!(cache) == "synthetic cache"

    assert File.read!(Path.join(context.home, "sessions/history.jsonl")) ==
             "synthetic durable history\n"
  end

  test "shared HOME still refuses every missing required projection leaf", context do
    project(context)

    for relative <- Homes.owned_entries(:codex) do
      path = Path.join(context.home, relative)
      saved = snapshot(context.home)[relative]
      File.rm!(path)

      assert_raise RuntimeError, "local deployment HOME missing owned path: #{path}", fn ->
        FeatureSmokeHome.verify_owned!(context.home, :codex)
      end

      case saved do
        {:symlink, target} -> File.ln_s!(target, path)
        {:file, bytes} -> File.write!(path, bytes)
      end
    end
  end

  test "shared check also uses Claude's actual owned projection", %{base: base} do
    %{home_path: home} =
      Homes.project(base, %{machine: "fixture", harness: :claude, rails: "synthetic rails"})

    File.write!(Path.join(home, "unrelated-runtime-state"), "independent")
    assert :ok == FeatureSmokeHome.verify_owned!(home, :claude)
    File.rm!(Path.join(home, "settings.json"))

    assert_raise RuntimeError, ~r/missing owned path.*settings.json/, fn ->
      FeatureSmokeHome.verify_owned!(home, :claude)
    end
  end

  test "directory cannot stand in for an owned projection leaf", context do
    project(context)
    path = Path.join(context.home, "hooks.json")
    File.rm!(path)
    File.mkdir!(path)

    assert_raise RuntimeError, "local deployment HOME missing owned path: #{path}", fn ->
      FeatureSmokeHome.verify_owned!(context.home, :codex)
    end
  end

  test "owned-path traversal does not follow a symlinked parent", context do
    project(context)
    manifest_dir = Path.join(context.home, ".tightbeam")
    elsewhere = Path.join(context.base, "elsewhere")
    File.rename!(manifest_dir, elsewhere)
    File.ln_s!(elsewhere, manifest_dir)

    assert_raise RuntimeError, ~r/missing owned path.*manifest/, fn ->
      FeatureSmokeHome.verify_owned!(context.home, :codex)
    end
  end

  test "isolated real projection and redelivery change only their declared paths", context do
    verify_isolated!(context, fn -> project(context) end)
    verify_isolated!(context, fn -> project(context, "replacement") end)

    assert File.read!(Path.join(context.home, "sessions/history.jsonl")) ==
             "synthetic durable history\n"
  end

  test "isolated write-set oracle rejects unexpected projector files and empty directories",
       context do
    for relative <- ["unexpected-projection.json", "unexpected-directory"] do
      path = Path.join(context.home, relative)

      assert_raise ExUnit.AssertionError, ~r/unexpected projection changes/, fn ->
        verify_isolated!(context, fn ->
          project(context)
          if Path.extname(relative) == "", do: File.mkdir!(path), else: File.write!(path, "stray")
        end)
      end

      File.rm_rf!(path)
    end
  end

  test "isolated write-set oracle rejects destroyed or rewritten durable state", context do
    path = Path.join(context.home, "sessions/history.jsonl")

    for damage <- [fn -> File.rm!(path) end, fn -> File.write!(path, "overwritten") end] do
      File.write!(path, "synthetic durable history\n")

      assert_raise ExUnit.AssertionError, ~r/unexpected projection changes/, fn ->
        verify_isolated!(context, fn ->
          project(context)
          damage.()
        end)
      end
    end
  end

  test "partial config ownership does not excuse destruction of operator settings", context do
    assert_raise ExUnit.AssertionError, ~r/unexpected projection changes: config.toml/, fn ->
      verify_isolated!(context, fn ->
        project(context)

        File.write!(
          Path.join(context.home, "config.toml"),
          "[features]\nguardian_approval = false\n"
        )
      end)
    end
  end

  defp project(%{base: base, home: home}, marker \\ "initial") do
    # The actual local Codex reconciliation boundary called by Placement,
    # including its surgical default-model config write (not a whole owned file).
    Tightbeam.Harness.Codex.reconcile_home(
      %{base_dir: base, host_name: "fixture", host_config: %{ssh: nil, base_dir: base}},
      home,
      %{
        harness: :codex,
        machine: "fixture",
        rails: JSON.encode!(%{"hooks" => %{"PreToolUse" => []}, "fixture" => marker}),
        default_model: nil
      }
    )
  end

  defp verify_isolated!(%{home: home}, project) do
    before = snapshot(home)
    project.()
    FeatureSmokeHome.verify_owned!(home, :codex)
    after_projection = snapshot(home)
    allowed = MapSet.new(Homes.owned_entries(:codex) ++ ["config.toml"])

    unexpected =
      (Map.keys(before) ++ Map.keys(after_projection))
      |> Enum.uniq()
      |> Enum.filter(&(before[&1] != after_projection[&1]))
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.sort()

    assert unexpected == [], "unexpected projection changes: #{inspect(unexpected)}"

    assert after_projection["config.toml"] == {:file, @projected_config},
           "unexpected projection changes: config.toml lost operator settings"
  end

  # This whole-HOME observation is valid ONLY in the synthetic exclusive-writer
  # fixture. It includes symlink targets, file bytes, and empty directories.
  defp snapshot(root, relative \\ "") do
    path = Path.join(root, relative)

    case File.lstat!(path).type do
      :directory ->
        case File.ls!(path) do
          [] ->
            %{relative => :empty_directory}

          names ->
            Enum.reduce(names, %{}, &Map.merge(&2, snapshot(root, Path.join(relative, &1))))
        end

      :symlink ->
        %{relative => {:symlink, File.read_link!(path)}}

      _ ->
        %{relative => {:file, File.read!(path)}}
    end
  end
end
