defmodule Tightbeam.OriginTest do
  # The warning flag is node-wide, so this module must not overlap async tests.
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
    warning_key = {Origin, :warned_unclassified}
    previous_warning = :persistent_term.get(warning_key, :unset)

    on_exit(fn ->
      case previous_warning do
        :unset -> :persistent_term.erase(warning_key)
        value -> :persistent_term.put(warning_key, value)
      end
    end)

    :persistent_term.erase(warning_key)

    origin = "unknown:origin-warning-test"

    log =
      capture_log([colors: [enabled: false]], fn ->
        for bad <- [origin, origin, "", "user:", nil, 7] do
          assert Origin.started_by(bad) == "substrate"
        end
      end)

    assert length(Regex.scan(~r/session origin .* is outside the closed class set;/, log)) == 1
    assert log =~ "session origin #{inspect(origin)} is outside the closed class set;"
  end
end
