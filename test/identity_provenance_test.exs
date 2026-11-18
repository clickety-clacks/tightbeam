defmodule Tightbeam.Identity.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Tightbeam.Identity.Provenance

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "identity-provenance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/kungfu/agentic-engineering"))

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir}
  end

  test "a receipt owns its recorded item path even after the item is edited", ctx do
    receipt = Path.join(ctx.base_dir, "identity/kungfu/agentic-engineering/installed.toml")

    File.write!(
      receipt,
      "name = \"agentic-engineering\"\npaths = [\"archetypes/coder.toml\"]\n"
    )

    assert :substrate ==
             Provenance.owner_for_path(ctx.base_dir, "identity/archetypes/support-agent.toml")

    assert {:kungfu, "agentic-engineering"} ==
             Provenance.owner_for_path(ctx.base_dir, "archetypes/coder.toml")

    File.mkdir_p!(Path.join(ctx.base_dir, "identity/archetypes"))
    File.write!(Path.join(ctx.base_dir, "identity/archetypes/coder.toml"), "org edit")

    assert {:kungfu, "agentic-engineering"} ==
             Provenance.owner_for_path(ctx.base_dir, "identity/archetypes/coder.toml")

    assert ["coder"] == Provenance.archetype_names(ctx.base_dir, "agentic-engineering")
  end

  test "receipt ownership supports namespaced bundle paths", ctx do
    receipt = Path.join(ctx.base_dir, "identity/kungfu/agentic-engineering/installed.toml")

    File.write!(
      receipt,
      "name = \"agentic-engineering\"\npaths = [\"kungfu/agentic-engineering/archetypes/pdo.toml\"]\n"
    )

    assert {:kungfu, "agentic-engineering"} ==
             Provenance.owner_for_path(
               ctx.base_dir,
               "identity/kungfu/agentic-engineering/archetypes/pdo.toml"
             )

    assert ["pdo"] == Provenance.archetype_names(ctx.base_dir, "agentic-engineering")
  end

  test "duplicate receipt claims are reported instead of guessed", ctx do
    second = Path.join(ctx.base_dir, "identity/kungfu/other/installed.toml")
    File.mkdir_p!(Path.dirname(second))

    File.write!(
      Path.join(ctx.base_dir, "identity/kungfu/agentic-engineering/installed.toml"),
      "name = \"agentic-engineering\"\npaths = [\"archetypes/coder.toml\"]\n"
    )

    File.write!(second, "name = \"other\"\npaths = [\"archetypes/coder.toml\"]\n")

    assert_raise ArgumentError, ~r/agentic-engineering, other/, fn ->
      Provenance.owner_for_path(ctx.base_dir, "archetypes/coder.toml")
    end
  end
end
