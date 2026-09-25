defmodule Tightbeam.EngineeringIdentityEvidence do
  @moduledoc false

  alias Tightbeam.{Archetypes, Homes, Identity, Model}

  @engineering_roles ~w(
    coder guidance-reviewer guidance-writer integrator orchestrator pdo product-owner
    recon reviewer-code reviewer-spec spec-writer team-planner
  )
  @harnesses [:claude, :codex]
  @bundle_docs ~w(capabilities.md intake.md manifest.toml preferred-models.md)

  @shared_user_invariant "Keep every applicable user-specified invariant in the governing work item and any associated spec, regardless of whether it came through chat, a document, or another source. Preserve the user's meaning."

  @neutral_patterns [
    {"worktree", ~r/\bworktrees?\b/i},
    {"branch", ~r/\bbranch(es)?\b/i},
    {"spec", ~r/\bspecs?\b/i},
    {"feature", ~r/\bfeatures?\b/i},
    {"bug", ~r/\bbugs?\b/i},
    {"product-owner", ~r/\bproduct[- ]owners?\b/i},
    {"orchestrator", ~r/\borchestrators?\b/i},
    {"coder", ~r/\bcoders?\b/i}
  ]

  def run!(["--", output_arg]), do: run!([output_arg])

  def run!([output_arg]) do
    output = Path.expand(output_arg)
    refuse_existing_output!(output)
    File.mkdir_p!(output)

    source_root = File.cwd!()
    assert!(File.regular?(Path.join(source_root, "mix.exs")), "run from the repository root")

    base = Path.join(output, "composition-base")
    assert!(:initialized == Identity.init!(base), "evidence base was not freshly initialized")

    {:ok, candidate} = Identity.learn!(base, "agentic-engineering", "evidence:offline")
    {:ok, revision} = Identity.publish_live!(base, candidate)
    assert!(revision == Identity.live_revision!(base), "published revision changed")

    loaded = Archetypes.load!(base)
    assert_roles!(loaded)
    assert_model_policy!(loaded, source_root)

    baseline_skills = baseline_skills!(source_root, output)
    receipt = receipt!(base, output)
    assert_bundle_ownership!(source_root, receipt)
    copy_bundle_docs!(source_root, output)

    snapshots =
      for role <- ["default" | @engineering_roles], harness <- @harnesses do
        snapshot = Identity.snapshot_at!(base, revision, role, harness)
        write_snapshot!(output, role, harness, snapshot)
        snapshot_record(role, harness, snapshot)
      end

    assert_neutral_corpus!(base, revision, baseline_skills, source_root, output)

    source_files = source_inventory(source_root)
    git = git_subject!(source_root)

    report = %{
      "contract" => "engineering-identity-offline-evidence-v1",
      "git" => git,
      "identityRevision" => revision,
      "bundle" => %{
        "name" => "agentic-engineering",
        "rootArchetype" => "orchestrator",
        "receiptPaths" => receipt["paths"]
      },
      "harnesses" => Enum.map(@harnesses, &Atom.to_string/1),
      "roles" => ["default" | @engineering_roles],
      "snapshots" => snapshots,
      "baselineSkills" => Enum.map(baseline_skills, & &1["name"]),
      "sourceFiles" => source_files,
      "providerLimit" =>
        "Offline source/default-resolution evidence only. No provider request ran, and no actual provider model, effort, context, or availability is claimed."
    }

    File.write!(Path.join(output, "report.json"), JSON.encode!(report))
    IO.puts("engineering-identity-evidence: ok #{Path.join(output, "report.json")}")
  end

  def run!(_args) do
    raise ArgumentError,
          "usage: mix run --no-start scripts/engineering_identity_evidence.exs -- <new-output-directory>"
  end

  defp refuse_existing_output!(output) do
    if File.exists?(output) do
      raise ArgumentError, "output directory already exists: #{output}"
    end
  end

  defp assert_roles!(loaded) do
    expected = Enum.sort(["default" | @engineering_roles])
    assert!(Enum.sort(Map.keys(loaded)) == expected, "unexpected shipped archetype inventory")
    assert!(loaded["pdo"].skills == ~w(repository-retirement human-communication), "PDO skills")

    for role <- @engineering_roles -- ["pdo"] do
      assert!("human-communication" not in loaded[role].skills, "#{role} human-communication")
    end
  end

  defp assert_model_policy!(loaded, source_root) do
    assert_default!(loaded, "pdo", :codex, "gpt-6-sol", "low")
    assert_default!(loaded, "orchestrator", :codex, "gpt-6-sol", "low")
    assert_default!(loaded, "coder", :codex, "gpt-6-luna", "max")
    assert_default!(loaded, "spec-writer", :claude, "claude-opus-5-5", "high")
    assert_default!(loaded, "reviewer-code", :claude, "claude-opus-5-5", "high")
    assert_default!(loaded, "reviewer-spec", :codex, "gpt-6-astra", "high")

    policy =
      File.read!(Path.join(source_root, "priv/kungfu/agentic-engineering/preferred-models.md"))

    shared =
      File.read!(
        Path.join(
          source_root,
          "priv/kungfu/agentic-engineering/guidance/preferred-models.md"
        )
      )

    for expected <- [
          "| Product delivery orchestration | gpt-6-sol[low] |",
          "| Executive or delegated lane orchestration | gpt-6-sol[low] |",
          "| Well-scoped or sustained implementation under an understood architecture | gpt-6-luna[max] |",
          "| Specification under product rulings | claude-opus-5-5[high] |",
          "Codex producer: claude-opus-5-5[high]; Claude producer: gpt-6-astra[high]"
        ] do
      assert!(String.contains?(policy, expected), "missing model-policy row #{inspect(expected)}")
    end

    for expected <- [
          "Codex-authored work uses Claude claude-opus-5-5/high",
          "Claude-authored work uses Codex gpt-6-astra/high",
          "including producer model overrides",
          "Expand nicknames to canonical models above",
          "Catalog presence alone does not establish access"
        ] do
      assert!(
        String.contains?(shared, expected),
        "missing shared model policy #{inspect(expected)}"
      )
    end

    assert!(
      String.contains?(policy, "bounded availability/context exception"),
      "bounded exception"
    )
  end

  defp assert_default!(loaded, role, harness, family, effort) do
    archetype = Map.fetch!(loaded, role)
    expected = Model.new(family, effort: effort)
    assert!(archetype.defaults == %{harness: harness, model: expected}, "#{role} defaults")
    assert!(archetype.model_preferences == [expected], "#{role} model preference")
  end

  defp baseline_skills!(source_root, output) do
    names = Homes.baseline_skill_names()
    assert!(length(names) == 9, "expected exactly nine baseline skills")
    assert!("tightbeam-dispatching" in names, "dispatching baseline skill missing")

    Enum.map(names, fn name ->
      source = Path.join(source_root, "priv/skills/#{name}/SKILL.md")
      bytes = File.read!(source)
      destination = Path.join(output, "baseline-skills/#{name}/SKILL.md")
      write!(destination, bytes)

      %{
        "name" => name,
        "path" => Path.relative_to(destination, output),
        "bytes" => byte_size(bytes),
        "sha256" => sha256(bytes),
        "body" => bytes
      }
    end)
  end

  defp receipt!(base, output) do
    source = Path.join(base, "identity/kungfu/agentic-engineering/installed.toml")
    bytes = File.read!(source)
    write!(Path.join(output, "bundle/installed.toml"), bytes)
    Toml.decode!(bytes)
  end

  defp assert_bundle_ownership!(source_root, receipt) do
    manifest =
      source_root
      |> Path.join("priv/kungfu/agentic-engineering/manifest.toml")
      |> File.read!()
      |> Toml.decode!()

    assert!(manifest["root_archetype"] == "orchestrator", "bundle root changed")

    for required <- [
          "archetypes/pdo.toml",
          "guidance/archetype-roster.md",
          "guidance/delivery-coordination.md"
        ] do
      assert!(required in receipt["paths"], "receipt omits #{required}")
    end
  end

  defp copy_bundle_docs!(source_root, output) do
    for name <- @bundle_docs do
      source = Path.join(source_root, "priv/kungfu/agentic-engineering/#{name}")
      write!(Path.join(output, "bundle/docs/#{name}"), File.read!(source))
    end
  end

  defp write_snapshot!(output, role, harness, snapshot) do
    root = Path.join(output, "snapshots/#{role}/#{harness}")
    write!(Path.join(root, "guidance.md"), snapshot.guidance)

    for {name, body} <- snapshot.skills do
      write!(Path.join(root, "skills/#{name}/SKILL.md"), body)
    end

    metadata = %{
      "revision" => snapshot.revision,
      "renderContract" => snapshot.render_contract,
      "guidanceBytes" => byte_size(snapshot.guidance),
      "guidanceSha256" => snapshot.guidance_digest,
      "electedSkills" => snapshot.archetype.skills,
      "materializedSkills" => snapshot.skills |> Map.keys() |> Enum.sort(),
      "defaults" => defaults_map(snapshot.archetype.defaults),
      "modelPreferences" => Enum.map(snapshot.archetype.model_preferences, &model_map/1)
    }

    write!(Path.join(root, "metadata.json"), JSON.encode!(metadata))
  end

  defp snapshot_record(role, harness, snapshot) do
    %{
      "role" => role,
      "harness" => Atom.to_string(harness),
      "guidanceBytes" => byte_size(snapshot.guidance),
      "guidanceSha256" => snapshot.guidance_digest,
      "electedSkills" => snapshot.archetype.skills,
      "materializedSkills" => snapshot.skills |> Map.keys() |> Enum.sort(),
      "defaults" => defaults_map(snapshot.archetype.defaults),
      "modelPreferences" => Enum.map(snapshot.archetype.model_preferences, &model_map/1)
    }
  end

  defp assert_neutral_corpus!(base, revision, baseline_skills, source_root, output) do
    operating_manual =
      File.read!(Path.join(source_root, "priv/guidance/operating-manual.md"))

    write!(Path.join(output, "substrate/operating-manual.md"), operating_manual)
    assert!(String.contains?(operating_manual, "# Operating tightbeam"), "operating manual")
    assert!(occurrences(operating_manual, @shared_user_invariant) == 1, "shared user invariant")

    facts = available_bundle_facts(source_root)

    for harness <- @harnesses do
      snapshot = Identity.snapshot_at!(base, revision, "default", harness)
      assert!(occurrences(snapshot.guidance, facts) == 1, "#{harness} bundle facts occurrence")
      neutral_guidance = String.replace(snapshot.guidance, facts, "", global: false)

      corpus =
        Enum.join(
          [
            neutral_guidance
            | Map.values(snapshot.skills) ++ Enum.map(baseline_skills, & &1["body"])
          ],
          "\n"
        )

      assert!(
        occurrences(corpus, @shared_user_invariant) == 1,
        "neutral #{harness} shared invariant"
      )

      remaining = String.replace(corpus, @shared_user_invariant, "", global: false)

      for {concept, pattern} <- @neutral_patterns do
        assert!(not Regex.match?(pattern, remaining), "neutral #{harness} contains #{concept}")
      end
    end
  end

  defp available_bundle_facts(source_root) do
    source_root
    |> Path.join("priv/kungfu/*/manifest.toml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join("\n\n", fn path ->
      manifest = path |> File.read!() |> Toml.decode!()
      name = path |> Path.dirname() |> Path.basename()
      phrases = Enum.map_join(manifest["phrases"], "\n", &"- #{&1}")
      "### `#{name}`\nPurpose: #{manifest["purpose"]}\nPhrases:\n#{phrases}"
    end)
  end

  defp source_inventory(source_root) do
    paths =
      Path.wildcard(
        Path.join(source_root, "priv/kungfu/agentic-engineering/**/*"),
        match_dot: true
      ) ++
        [Path.join(source_root, "priv/guidance/operating-manual.md")] ++
        Path.wildcard(Path.join(source_root, "priv/skills/*/SKILL.md"))

    paths
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      bytes = File.read!(path)

      %{
        "path" => Path.relative_to(path, source_root),
        "bytes" => byte_size(bytes),
        "sha256" => sha256(bytes)
      }
    end)
  end

  defp git_subject!(source_root) do
    %{
      "commit" => git!(source_root, ["rev-parse", "HEAD"]),
      "tree" => git!(source_root, ["rev-parse", "HEAD^{tree}"]),
      "status" => git!(source_root, ["status", "--short"])
    }
  end

  defp git!(source_root, args) do
    case System.cmd("git", args, cd: source_root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp defaults_map(defaults) do
    %{}
    |> maybe_put("harness", defaults[:harness] && Atom.to_string(defaults[:harness]))
    |> maybe_put("model", defaults[:model] && model_map(defaults[:model]))
  end

  defp model_map(model) do
    %{"family" => model.family, "effort" => model.effort, "context" => model.context}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp occurrences(haystack, needle), do: length(:binary.matches(haystack, needle))
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise("engineering identity evidence failed: #{message}")
end

Tightbeam.EngineeringIdentityEvidence.run!(System.argv())
