defmodule Tightbeam.DocsComposition52 do
  @moduledoc false

  def run! do
    source = File.cwd!()
    sha = System.fetch_env!("CI_SOURCE_SHA")
    output = Path.expand(System.fetch_env!("DOCS_EVIDENCE"))
    runner_temp = Path.expand(System.fetch_env!("RUNNER_TEMP"))
    assert!(String.starts_with?(output, runner_temp <> "/"), "output outside runner temp")
    assert!(not File.exists?(Path.join(output, "composition")), "composition already exists")
    assert!(not List.keymember?(Application.started_applications(), :tightbeam, 0), "app started")
    assert!(git!(source, ["rev-parse", "HEAD"]) == sha, "source SHA mismatch")
    assert!(git!(source, ["status", "--porcelain"]) == "", "dirty source")

    inventory_path = Path.join(source, "scripts/docs_composition_52.json")
    inventory_bytes = File.read!(inventory_path)
    inventory = JSON.decode!(inventory_bytes)
    assert!(inventory["count"] == 52, "inventory count")
    assert!(inventory["versions"] == ["parent", "candidate"], "versions")
    assert!(inventory["harnesses"] == ["claude", "codex"], "harnesses")
    assert!(length(inventory["roles"]) == 13, "role count")

    manual_path = "priv/guidance/operating-manual.md"
    after_body = File.read!(Path.join(source, manual_path))
    before_body = git_bytes!(source, ["show", inventory["parent"] <> ":" <> manual_path])
    reviewed_body = git_bytes!(source, ["show", inventory["reviewed_manual_commit"] <> ":" <> manual_path])
    assert!(after_body == reviewed_body, "reviewed manual changed")
    assert!(digest(after_body) == inventory["manual_sha256"], "candidate manual hash")
    assert!(digest(before_body) == inventory["parent_manual_sha256"], "parent manual hash")
    before_paragraph = paragraph!(before_body, "Before you end a turn")
    after_paragraph = paragraph!(after_body, "Advance actionable work immediately")
    assert!(String.replace(before_body, before_paragraph, after_paragraph, global: false) == after_body, "non-paragraph change")

    # This task's only shipped input change is the manual paragraph. Every
    # archetype, skill and other guidance file must still match the parent.
    changed = git!(source, ["diff", "--name-only", inventory["parent"], sha, "priv"])
    assert!(changed == manual_path, "unexpected shipped input change")

    base = Path.join(output, "composition/identity-base")
    File.mkdir_p!(Path.dirname(base))
    :initialized = Tightbeam.Identity.init!(base)
    prior_live = Tightbeam.Identity.live_revision!(base)
    {:ok, learned} = Tightbeam.Identity.learn!(base, "agentic-engineering", "docs:offline")
    candidate = learned.candidate_revision
    assert!(Tightbeam.Identity.live_revision!(base) == prior_live, "learn published")
    identity = Path.join(base, "identity")
    git!(identity, ["checkout", "--detach", candidate])
    actual_roles = Path.wildcard(Path.join(identity, "archetypes/*.toml")) |> Enum.map(&Path.basename(&1, ".toml")) |> Enum.sort()
    assert!(actual_roles == inventory["roles"], "role inventory mismatch")

    # The org-local override selects the exact parent manual for the baseline;
    # all other revision inputs remain the learned candidate's identical bytes.
    override = Path.join(identity, "guidance/operating-manual.md")
    assert!(not File.exists?(override), "unexpected org-local manual")
    File.write!(override, before_body)
    git!(identity, ["add", "guidance/operating-manual.md"])
    git!(identity, ["-c", "user.name=Offline docs evidence", "-c", "user.email=docs@invalid", "commit", "-m", "Exact parent manual comparison"])
    parent_revision = git!(identity, ["rev-parse", "HEAD"])

    rows = for role <- inventory["roles"], harness <- [:claude, :codex] do
      before = Tightbeam.Identity.snapshot_at!(base, parent_revision, role, harness)
      after_snapshot = Tightbeam.Identity.snapshot_at!(base, candidate, role, harness)
      assert!(occurrences(before.guidance, before_paragraph) == 1, "parent paragraph reach")
      assert!(occurrences(after_snapshot.guidance, after_paragraph) == 1, "candidate paragraph reach")
      assert!(String.replace(before.guidance, before_paragraph, after_paragraph, global: false) == after_snapshot.guidance, "unrelated composed bytes changed")
      assert!(before.skills == after_snapshot.skills, "skills changed")

      for {label, snapshot} <- [{"parent", before}, {"candidate", after_snapshot}] do
        name = "#{label}-#{role}-#{harness}"
        path = Path.join(output, "composition/views/" <> name <> ".md")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, snapshot.guidance)
        skills = for {skill, bytes} <- Enum.sort(snapshot.skills) do
          skill_path = Path.join(output, "composition/skills/#{name}/#{skill}.md")
          File.mkdir_p!(Path.dirname(skill_path))
          File.write!(skill_path, bytes)
          %{name: skill, sha256: digest(bytes)}
        end
        %{version: label, role: role, harness: harness, revision: snapshot.revision,
          render_contract: snapshot.render_contract, bytes: byte_size(snapshot.guidance),
          sha256: digest(snapshot.guidance), skills: skills}
      end
    end |> List.flatten()

    assert!(length(rows) == inventory["count"], "52-view inventory incomplete")
    assert!(Tightbeam.Identity.live_revision!(base) == prior_live, "private live ref changed")
    assert!(git!(source, ["status", "--porcelain"]) == "", "source dirt after composition")
    report = %{contract: inventory["contract"], source: sha,
      tree: git!(source, ["rev-parse", "HEAD^{tree}"]),
      parent: git!(source, ["rev-parse", "HEAD^"]), rows: rows,
      inventory_sha256: digest(inventory_bytes),
      driver_sha256: digest(File.read!(Path.join(source, "scripts/docs_composition_52.exs"))),
      limitation: "Offline no-start private snapshots only; no provider, served identity, apply or publication."}
    File.write!(Path.join(output, "composition/report.json"), JSON.encode!(report))
    IO.puts("PASS 52 supported parent/candidate snapshots")
  end

  defp paragraph!(body, start) do
    [_, suffix] = String.split(body, start, parts: 2)
    [paragraph, _] = String.split(start <> suffix, "\n\n## 3.", parts: 2)
    paragraph
  end

  defp git_bytes!(cwd, args) do
    case System.cmd("git", ["-c", "core.hooksPath=/dev/null" | args], cd: cwd) do
      {bytes, 0} -> bytes
      {bytes, status} -> raise "git failed #{status}: #{inspect(args)} #{bytes}"
    end
  end

  defp git!(cwd, args), do: git_bytes!(cwd, args) |> String.trim()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp occurrences(body, text), do: length(:binary.matches(body, text))
  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise("docs composition refused: " <> message)
end

Tightbeam.DocsComposition52.run!()
