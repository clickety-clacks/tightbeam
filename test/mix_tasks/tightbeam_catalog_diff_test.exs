defmodule Mix.Tasks.Tightbeam.Catalog.DiffTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Tightbeam.Catalog.Diff

  test "detects uncharacterized live refs" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "new[high]"]), path)

      assert status == 1
      assert diff.uncharacterized == ["new[high]"]
      assert diff.vanished == []
    end)
  end

  test "detects vanished characterized refs" do
    with_guidance(["known", "retired[low]"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[high]"]), path)

      assert status == 1
      assert diff.uncharacterized == []
      assert diff.vanished == ["retired[low]"]
    end)
  end

  test "clean coverage has zero exit status" do
    with_guidance(["known"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "known[high]"]), path)

      assert status == 0
      assert diff.uncharacterized == []
      assert diff.vanished == []
    end)
  end

  test "json output has the catalog diff shape" do
    with_guidance(["known", "retired"], fn path ->
      {_status, diff} = Diff.evaluate(inventories(["known[low]", "new[xhigh]"]), path)

      assert {:ok,
              %{
                "uncharacterized" => ["new[xhigh]"],
                "vanished" => ["retired"],
                "live" => ["known[low]", "new[xhigh]"],
                "characterized" => ["known", "retired"]
              }} = JSON.decode(Diff.format(diff, :json))
    end)
  end

  test "bare and effort-qualified refs normalize to the same model" do
    with_guidance(["known[xhigh]"], fn path ->
      {status, diff} = Diff.evaluate(inventories(["known[low]", "known[medium]"]), path)

      assert status == 0
      assert diff.uncharacterized == []
      assert diff.vanished == []
    end)
  end

  @tag :external
  if :external not in ExUnit.configuration()[:include] do
    @tag skip: "run with --only external"
  end

  test "live catalog is fully characterized" do
    base_dir = Diff.base_dir()
    guidance_path = Path.join([base_dir, "identity", "guidance", "model-selection.md"])

    assert {:ok, inventories} = Diff.fetch_live(base_dir)
    result = Diff.evaluate(inventories, guidance_path)
    assert {0, _diff} = result, inspect(result)
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

    path = Path.join(dir, "model-selection.md")
    File.mkdir_p!(dir)

    body =
      """
      # Choosing a model for a job

      Characterizations — the entries below are examples; replace them with this org's models and
      judgments:
      #{Enum.map_join(refs, "\n", &"- `#{&1}`: characterization")}

      Format for an entry: guidance.
      """

    File.write!(path, body)

    try do
      fun.(path)
    after
      File.rm_rf!(dir)
    end
  end
end
