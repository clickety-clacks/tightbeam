defmodule Mix.Tasks.Tightbeam.Catalog.DiffTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Tightbeam.Catalog.Diff

  test "working-set model absent from the live catalog is drift" do
    with_guidance(["known", "vanished"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]"]), path)

      assert status == 1
      assert diff.missing_from_catalog == ["vanished"]
      assert diff.new_arrivals == []
    end)
  end

  test "live model outside the working set is informational" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "new[high]"]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == ["new[high]"]

      report = Diff.format(diff, :human)
      assert report =~ "MISSING FROM CATALOG (drift): none"
      assert report =~ "NEW ARRIVALS (info):\n  - new[high]"
    end)
  end

  test "all working-set models live has zero exit status even with new arrivals" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "new[high]"]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == ["new[high]"]
    end)
  end

  test "json output has the catalog diff shape" do
    with_guidance(["known", "retired"], fn path ->
      {_status, diff} = Diff.evaluate(inventories(["known[low]", "new[xhigh]"]), path)

      assert {:ok,
              %{
                "missing_from_catalog" => ["retired"],
                "new_arrivals" => ["new[xhigh]"],
                "live" => ["known[low]", "new[xhigh]"],
                "working_set" => ["known", "retired"]
              }} = JSON.decode(Diff.format(diff, :json))
    end)
  end

  test "bare and effort-qualified refs normalize to the same model" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "known[medium]"]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == []
    end)
  end

  test "ignores non-capsule bullets and stops at the next level-two heading" do
    with_guidance(["known"], fn path ->
      File.write!(path, File.read!(path) <> "\n- **outside** — not in the working set\n")

      {status, diff} = Diff.evaluate(inventories(["known[low]"]), path)

      assert status == 0
      assert diff.working_set == ["known"]
    end)
  end

  test "raises a classified error when the working-set section is absent" do
    with_guidance(["known"], fn path ->
      File.write!(path, "# Preferred models\n")

      assert_raise Mix.Error,
                   ~r/preferred_models_parse_failed: Working set \(capsules\) section not found/,
                   fn -> Diff.evaluate(inventories(["known"]), path) end
    end)
  end

  test "refuses with a classified not-installed error when the working set is absent" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-missing-working-set-#{System.unique_integer([:positive])}.md"
      )

    assert_raise Mix.Error,
                 ~r/working_set_not_installed:.*agentic-engineering.*tightbeam learn agentic-engineering/,
                 fn -> Diff.evaluate(inventories(["known"]), missing) end
  end

  test "task refuses a neutral org before fetching the live catalog" do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-neutral-catalog-diff-#{System.unique_integer([:positive])}"
      )

    assert_raise Mix.Error, ~r/working_set_not_installed:/, fn ->
      Diff.run(["--base-dir", base_dir])
    end
  end

  @tag :external
  if :external not in ExUnit.configuration()[:include] do
    @tag skip: "run with --only external"
  end

  test "real working set is present in the live catalog" do
    base_dir = Diff.base_dir()

    guidance_path =
      Path.join([
        base_dir,
        "identity",
        "kungfu",
        "agentic-engineering",
        "preferred-models.md"
      ])

    assert {:ok, inventories} = Diff.fetch_live(base_dir)
    {status, diff} = Diff.evaluate(inventories, guidance_path)
    assert status == 0, inspect(diff.missing_from_catalog)
  end

  defp inventories(refs) do
    %{
      "claude" => Enum.map(refs, &%{ref: &1}),
      "codex" => []
    }
  end

  defp with_guidance(refs, fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-catalog-diff-#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "preferred-models.md")
    File.mkdir_p!(dir)

    body =
      """
      # Preferred models

      ## Working set (capsules)

      #{Enum.map_join(refs, "\n", &"- **#{&1}** — capsule")}
      - [Flynn: confirm the set — add/drop as needed]

      ## Activity

      - **activity-model** — not a working-set capsule
      """

    File.write!(path, body)

    try do
      fun.(path)
    after
      File.rm_rf!(dir)
    end
  end
end
