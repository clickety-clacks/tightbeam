defmodule Tightbeam.MementoShippedPolicyTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Gateway, Identity, MementoCutover, Rules}
  @moduletag tmp_dir: true

  setup %{tmp_dir: base} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    dir = Path.join(base, "identity")
    File.mkdir_p!(Path.join(dir, "rules"))
    File.mkdir_p!(Path.join(dir, "guidance"))

    File.cp!(
      "priv/seed/guidance/operating-model.md",
      Path.join(dir, "guidance/operating-model.md")
    )

    prior = commit(dir)
    git(dir, ["branch", "-M", "main"])
    git(dir, ["branch", "tightbeam/live"])
    git(dir, ["branch", "tightbeam/upstream"])
    config = %{base_dir: base, db: db}
    verbs = config |> Gateway.handlers() |> Map.keys()
    Gateway.load_law!(config, verbs)
    active = Rules.effective_snapshot()

    source = Path.expand("priv/kungfu/agentic-engineering")
    target = Path.join(dir, "kungfu/agentic-engineering")
    File.mkdir_p!(target)
    File.cp!(Path.join(source, "manifest.toml"), Path.join(target, "manifest.toml"))

    for path <- Path.wildcard(Path.join(source, "rules/*.toml")) do
      File.cp!(path, Path.join(dir, "rules/" <> Path.basename(path)))
    end

    revision = commit(dir)

    %{
      db: db,
      dir: dir,
      config: config,
      verbs: verbs,
      prior: prior,
      revision: revision,
      active: active
    }
  end

  test "shipped cutover rules leave the published admission contract legacy", ctx do
    law = Gateway.prepare_law!(ctx.config, ctx.revision, ctx.verbs)
    assert law.policy.requested_admission_contract == %{}
    inventory = MementoCutover.policy_inventory!(law.policy)
    assert Enum.any?(inventory.rules, &(&1.name == "engineering-cutover-effects"))
    assert Rules.effective_snapshot() == ctx.active
    assert Rules.active_admission_contract("attest") == "legacy"
    assert Identity.live_revision!(ctx.config.base_dir) == ctx.prior
  end

  defp commit(dir) do
    git(dir, ["init"])
    git(dir, ["add", "."])
    git(dir, ["commit", "--allow-empty", "-m", "policy candidate"])
    git(dir, ["rev-parse", "HEAD"])
  end

  defp git(dir, args) do
    {output, status} =
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"] ++ args,
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end
end
