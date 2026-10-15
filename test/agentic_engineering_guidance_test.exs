defmodule Tightbeam.AgenticEngineeringGuidanceTest do
  use ExUnit.Case, async: true

  @guidance Path.expand("../priv/kungfu/agentic-engineering/guidance", __DIR__)

  test "code review names unasked additions and requires delivery owner acceptance" do
    text = File.read!(Path.join(@guidance, "reviewer-code.md"))

    assert text =~ """
           Name everything the change adds that the ask did not require: a new module,
           table, process, setting, dependency, generalization, or hardening or defense
           beyond the ask. For each, say who asked for it, quoting the ask or a ruling, or
           mark it unasked. Unasked machinery is a blocker unless the delivery owner accepts
           it. A diff far larger than its ask is a reason to look for it.
           """
  end

  test "light review checks disproportionate changes for unasked additions" do
    text = File.read!(Path.join(@guidance, "review.md"))

    assert text =~ """
           schema change, or a new dependency; without one of those it is light. Check a
           change an order of magnitude larger than its ask for unasked additions before it
           passes. When the work disagrees with the verdict, review at the weight the work
           warrants and say so in the report.
           """

    refute text =~ "light however large"
  end

  test "coders ask before building beyond the ask" do
    text = File.read!(Path.join(@guidance, "coder.md"))

    assert text =~ """
           Build what the ask requires. If you believe more is needed (a guard, a
           generalization, a new mechanism), say so and ask; do not build it on spec.
           """
  end

  test "coders and code reviewers require base failure evidence and every caller check" do
    for role <- ["coder", "reviewer-code"] do
      text = File.read!(Path.join(@guidance, role <> ".md"))

      assert text =~ """
             A failure called pre-existing counts only when shown failing on the base branch.
             A removal is safe only after every caller of the removed code is checked.
             """
    end
  end
end
