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

  test "every review checks unasked additions and unasked machinery is never light" do
    text = File.read!(Path.join(@guidance, "review.md"))

    assert text =~ """
           schema change, or a new dependency; without one of those it is light unless it
           adds unasked machinery. Every review, light or heavy and whatever the size, checks
           the work for additions the ask did not require. Unasked machinery is never light.
           When the work disagrees with the verdict, review at the weight the work warrants
           and say so in the report.
           """

    refute text =~ "light however large"
    refute text =~ "an order of magnitude larger"
  end

  test "spec writers cite the ask or a ruling for every addition" do
    text = File.read!(Path.join(@guidance, "spec-writer.md"))

    assert text =~ """
           - Every requirement, mechanism, component, table, process and setting cites what it
             serves: a quote from the ask or a ruling. Anything that cannot cite one is cut,
             or raised to the PO as a question; never write it in on spec.
           """
  end

  test "spec review blocks uncited requirements unless the PO accepts them" do
    text = File.read!(Path.join(@guidance, "reviewer-spec.md"))

    assert text =~ """
           simpler adequate alternative when useful. Check every requirement and mechanism
           against the ask: each must cite the ask or a ruling it serves. An uncited one is a
           blocker unless the PO accepts it. Do not cut what the ask needs to save lines.
           """

    refute text =~ "Future flexibility or a smaller line"
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
