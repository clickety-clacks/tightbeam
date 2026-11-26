defmodule Tightbeam.OriginTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

  alias Tightbeam.Origin

  test "parse and class read the closed class set structurally" do
    assert Origin.parse("user:flynn") == {:user, "flynn"}
    assert Origin.parse("agent:reviewer") == {:agent, "reviewer"}
    assert Origin.parse("process:tightbeam") == {:process, "tightbeam"}
    assert Origin.parse("remedy:review-before-merge") == {:remedy, "review-before-merge"}

    # The identifier keeps its own colons — sessionKeys are colon-shaped.
    assert Origin.parse("agent:main:clawline:flynn:main") == {:agent, "main:clawline:flynn:main"}

    assert Origin.class("user:flynn") == "user"
    assert Origin.class("remedy:r") == "remedy"

    for bad <- ["", "flynn", "user:", ":flynn", "operator:flynn", nil, 7] do
      assert Origin.parse(bad) == :malformed, inspect(bad)
      assert Origin.class(bad) == nil, inspect(bad)
    end
  end

  test "started_by collapses every class onto the wire's three-way axis" do
    assert Origin.started_by("user:flynn") == "user"
    assert Origin.started_by("agent:reviewer") == "agent"

    # Automation and rail remedies are both the substrate standing a session
    # up: nobody in the org asked for it, so the client hides it until adopted.
    assert Origin.started_by("process:tightbeam") == "substrate"
    assert Origin.started_by("remedy:review-before-merge") == "substrate"
  end

  test "an origin outside the class set classifies substrate and warns once" do
    key = {Origin, :warned_unclassified}
    previous = :persistent_term.get(key, false)
    :persistent_term.put(key, false)
    on_exit(fn -> :persistent_term.put(key, previous) end)

    log = capture_log(fn -> assert Origin.started_by("operator:flynn") == "substrate" end)
    assert log =~ "outside the closed class set"
    repeated = capture_log(fn -> assert Origin.started_by("operator:flynn") == "substrate" end)
    refute repeated =~ "outside the closed class set"

    for bad <- ["", "user:", nil, 7], do: assert(Origin.started_by(bad) == "substrate")
  end
end
