defmodule Tightbeam.RailsTest do
  use ExUnit.Case, async: false

  alias Tightbeam.Rails

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-rails-#{System.unique_integer([:positive])}")
    rails_dir = Path.join([base_dir, "identity", "rails"])
    File.mkdir_p!(rails_dir)

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Rails)
    end)

    %{base_dir: base_dir, rails_dir: rails_dir}
  end

  @valid %{
    "name" => ~s("no-history-rewrites"),
    "on" => ~s("tool-call"),
    "tool" => ~s("Bash"),
    "pattern" => ~s{"git (reset|stash|rebase|checkout \\\\.|restore|clean)"},
    "text" =>
      ~s("History-rewriting git commands are forbidden here: other agents may have uncommitted work in this tree.")
  }

  defp write_statute(ctx, overrides, file \\ "statutes.toml") do
    fields =
      @valid
      |> Map.merge(overrides)
      |> Enum.reject(fn {_k, v} -> v == :omit end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{v}" end)

    File.write!(Path.join(ctx.rails_dir, file), "[[statute]]\n" <> fields <> "\n")
  end

  test "empty and missing rails dirs are a valid empty set", ctx do
    assert Rails.load!(ctx.base_dir) == []
    assert Rails.hook_settings() == nil

    File.rm_rf!(ctx.rails_dir)
    assert Rails.load!(ctx.base_dir) == []
  end

  test "a valid gate statute loads with mode defaulted", ctx do
    write_statute(ctx, %{"mode" => :omit})

    assert [statute] = Rails.load!(ctx.base_dir)
    assert statute.name == "no-history-rewrites"
    assert statute.on == :tool_call
    assert statute.mode == :gate
    assert statute.tool == "Bash"
  end

  test "the invariant refusal: remind is not law", ctx do
    write_statute(ctx, %{"mode" => ~s("remind")})

    assert_raise ArgumentError,
                 ~r/rails never add guidance; put prose in guidance or a skill/,
                 fn -> Rails.load!(ctx.base_dir) end
  end

  test "reserved and malformed statutes fail the boot with named errors", ctx do
    cases = [
      {%{"mode" => ~s("block")}, ~r/mode "block" is reserved for a later stage/},
      {%{"check" => ~s("curl janus")},
       ~r/"check" \(predicate statutes\) is reserved for a later stage/},
      {%{"mode" => ~s("nonsense")}, ~r/unknown statute mode/},
      {%{"on" => ~s("turn-end")}, ~r/unknown statute event/},
      {%{"on" => :omit}, ~r/statute no-history-rewrites is missing "on"/},
      {%{"tool" => :omit}, ~r/is missing "tool"/},
      {%{"pattern" => :omit}, ~r/is missing "pattern"/},
      {%{"text" => :omit}, ~r/is missing "text"/},
      {%{"text" => ~s("  ")}, ~r/is missing "text"/},
      {%{"name" => :omit}, ~r/statute is missing "name"/},
      {%{"name" => ~s("Bad_Name")}, ~r/invalid statute name/},
      {%{"sevrity" => "1"}, ~r/unknown statute keys.*sevrity/},
      {%{"pattern" => ~s{"("}}, ~r/invalid gate pattern/}
    ]

    for {overrides, error} <- cases do
      write_statute(ctx, overrides)
      assert_raise ArgumentError, error, fn -> Rails.load!(ctx.base_dir) end
    end
  end

  test "duplicate names across files fail; files load in filename order", ctx do
    write_statute(ctx, %{}, "a.toml")
    write_statute(ctx, %{"name" => ~s("zz-second")}, "b.toml")

    assert Enum.map(Rails.load!(ctx.base_dir), & &1.name) == [
             "no-history-rewrites",
             "zz-second"
           ]

    write_statute(ctx, %{}, "b.toml")

    assert_raise ArgumentError, ~r/duplicate statute name: no-history-rewrites/, fn ->
      Rails.load!(ctx.base_dir)
    end
  end

  test "hook_settings compiles the byte-pinned PreToolUse entry", ctx do
    write_statute(ctx, %{})
    Rails.load!(ctx.base_dir)

    assert %{"hooks" => %{"PreToolUse" => [entry]}} = Rails.hook_settings()
    assert entry["matcher"] == "Bash"
    assert [%{"type" => "command", "command" => command}] = entry["hooks"]

    assert command ==
             "sh -c 'grep -qE \"git (reset|stash|rebase|checkout \\\\.|restore|clean)\" - || exit 0; " <>
               "echo \"[gate: no-history-rewrites] History-rewriting git commands are forbidden here: " <>
               "other agents may have uncommitted work in this tree.\" >&2; exit 2'"
  end

  test "escaping torture: ERE metacharacters and $ in pattern, single quote in text", ctx do
    write_statute(ctx, %{
      "name" => ~s("no-env-dollars"),
      "pattern" => ~s{"echo (\\\\$HOME|\\\\$PATH)\\\\."},
      "text" => ~s("Don't expand env here.")
    })

    Rails.load!(ctx.base_dir)
    %{"hooks" => %{"PreToolUse" => [entry]}} = Rails.hook_settings()
    [%{"command" => command}] = entry["hooks"]

    assert command ==
             "sh -c 'grep -qE \"echo (\\\\\\$HOME|\\\\\\$PATH)\\\\.\" - || exit 0; " <>
               "echo \"[gate: no-env-dollars] Don'\\''t expand env here.\" >&2; exit 2'"
  end

  test "probe_entry compiles the byte-pinned reserved wiring-check gate" do
    assert %{
             "matcher" => "Bash",
             "hooks" => [%{"type" => "command", "command" => command}]
           } = Rails.probe_entry()

    assert command ==
             "sh -c 'grep -qE \"tightbeam-gate-probe\" - || exit 0; " <>
               "echo \"[gate: tightbeam-probe] Spawn wiring-check probe command; " <>
               "always refused by design.\" >&2; exit 2'"
  end
end
