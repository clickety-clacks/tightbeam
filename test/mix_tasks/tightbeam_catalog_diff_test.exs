defmodule Mix.Tasks.Tightbeam.Catalog.DiffTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Tightbeam.Catalog.Diff

  test "working-set model absent from the live catalog is drift" do
    with_guidance(["known", "vanished"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known"]), path)

      assert status == 1
      assert diff.missing_from_catalog == ["vanished"]
      assert diff.new_arrivals == []
    end)
  end

  test "live model outside the working set is informational" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known", "new"]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == ["new"]

      report = Diff.format(diff, :human)
      assert report =~ "MISSING FROM CATALOG (drift): none"
      assert report =~ "NEW ARRIVALS (info):\n  - new"
    end)
  end

  test "all working-set models live has zero exit status even with new arrivals" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known", "new"]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == ["new"]
    end)
  end

  test "json output has the catalog diff shape" do
    with_guidance(["known", "retired"], fn path ->
      {_status, diff} = Diff.evaluate(inventories(["known", "new"]), path)

      assert {:ok,
              %{
                "missing_from_catalog" => ["retired"],
                "new_arrivals" => ["new"],
                "live" => ["known", "new"],
                "working_set" => ["known", "retired"]
              }} = JSON.decode(Diff.format(diff, :json))
    end)
  end

  # A context variant is a DIFFERENT model, not a spelling of the same one. It
  # used to be normalized away with the effort suffix, so a newly entitled
  # 1M-context model never showed up as an arrival for anyone to characterize.
  test "a context variant of a known model is its own arrival" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known", {"known", "1m"}]), path)

      assert status == 0
      assert diff.missing_from_catalog == []
      assert diff.new_arrivals == ["known[1m]"]
    end)
  end

  test "ignores non-capsule bullets and stops at the next level-two heading" do
    with_guidance(["known"], fn path ->
      File.write!(path, File.read!(path) <> "\n- **outside** — not in the working set\n")

      {status, diff} = Diff.evaluate(inventories(["known"]), path)

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

  test "a learned org reads the working set from the installed engineering table" do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-learned-catalog-diff-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)
    assert :initialized = Tightbeam.Identity.init!(base_dir)
    assert {:ok, _revision} = Tightbeam.Identity.learn!(base_dir, "agentic-engineering", "test")

    path = Diff.working_set_path(base_dir)

    assert path ==
             Path.join([
               base_dir,
               "identity",
               "kungfu",
               "agentic-engineering",
               "preferred-models.md"
             ])

    {_status, diff} = Diff.evaluate(%{"claude" => [], "codex" => []}, path)
    assert diff.working_set != []
  end

  @tag :external
  if :external not in ExUnit.configuration()[:include] do
    @tag skip: "run with --only external"
  end

  test "real working set is present in the live catalog" do
    base_dir = Diff.base_dir()

    guidance_path = Diff.working_set_path(base_dir)

    assert {:ok, inventories} = Diff.fetch_live(base_dir)
    {status, diff} = Diff.evaluate(inventories, guidance_path)
    assert status == 0, inspect(diff.missing_from_catalog)
  end

  # A catalog entry names a MODEL — family plus the vendor's context variant
  # when there is one. Effort tiers are a property of the entry, so they never
  # appear in what the diff compares.
  defp inventories(models) do
    %{
      "claude" =>
        Enum.map(models, fn
          {family, context} -> %{family: family, context: context, efforts: ["low"]}
          family -> %{family: family, context: nil, efforts: ["low"]}
        end),
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
