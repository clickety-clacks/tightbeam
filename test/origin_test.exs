defmodule Tightbeam.OriginTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tightbeam.Origin

  test "parse and class read the closed class set structurally" do
    assert Origin.parse("user:flynn") == {:user, "flynn"}
    assert Origin.parse("agent:reviewer") == {:agent, "reviewer"}
    assert Origin.parse("process:tightbeam") == {:process, "tightbeam"}
    assert Origin.parse("remedy:review-before-merge") == {:remedy, "review-before-merge"}
    assert Origin.parse("bootstrap:first-user") == {:bootstrap, "first-user"}

    # The identifier keeps its own colons — sessionKeys are colon-shaped.
    assert Origin.parse("agent:main:clawline:flynn:main") == {:agent, "main:clawline:flynn:main"}

    assert Origin.class("user:flynn") == "user"
    assert Origin.class("remedy:r") == "remedy"
    assert Origin.class("bootstrap:first-user") == "bootstrap"

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
    assert Origin.started_by("bootstrap:first-user") == "substrate"
  end

  test "an origin outside the class set classifies substrate and warns once" do
    log = capture_log(fn -> assert Origin.started_by("operator:flynn") == "substrate" end)

    # The warning is per-node, so this file may or may not be the one that
    # spends it. What is total is the classification: never nil, never a raise.
    assert log == "" or log =~ "outside the closed class set"

    for bad <- ["", "user:", nil, 7], do: assert(Origin.started_by(bad) == "substrate")
  end
end
