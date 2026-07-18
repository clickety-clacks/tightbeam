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

  test "reserved gate mode fails closed", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\nmode = "gate"\ntext = "law"|)

    assert_raise ArgumentError, ~r/mode "gate" is reserved for a later stage/, fn ->
      Rails.load!(ctx.base_dir)
    end
  end

  test "reserved block mode fails closed", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\nmode = "block"\ntext = "law"|)

    assert_raise ArgumentError, ~r/mode "block" is reserved for a later stage/, fn ->
      Rails.load!(ctx.base_dir)
    end
  end

  test "predicate statute check fails closed", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\ntext = "law"\ncheck = "curl example"|)

    assert_raise ArgumentError,
                 ~r/"check" \(predicate statutes\) is reserved for a later stage/,
                 fn -> Rails.load!(ctx.base_dir) end
  end

  test "unknown mode is rejected", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\nmode = "nonsense"\ntext = "law"|)

    assert_raise ArgumentError, ~r/unknown statute mode/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "unknown event is rejected", ctx do
    write_statute(ctx, ~s|name = "x"\non = "tool-call"\ntext = "law"|)

    assert_raise ArgumentError, ~r/unknown statute event/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "event is required and never defaulted", ctx do
    write_statute(ctx, ~s|name = "announce-new-work"\ntext = "law"|)

    assert_raise ArgumentError, ~r/statute announce-new-work is missing "on"/, fn ->
      Rails.load!(ctx.base_dir)
    end
  end

  test "text is required", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"|)

    assert_raise ArgumentError, ~r/is missing "text"/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "blank text is rejected", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\ntext = "   "|)

    assert_raise ArgumentError, ~r/is missing "text"/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "name is required", ctx do
    write_statute(ctx, ~s|on = "turn-end"\ntext = "law"|)

    assert_raise ArgumentError, ~r/statute is missing "name"/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "name must use statute segments", ctx do
    write_statute(ctx, ~s|name = "Bad_Name"\non = "turn-end"\ntext = "law"|)

    assert_raise ArgumentError, ~r/invalid statute name/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "names are unique across files", ctx do
    write_statute(ctx, ~s|name = "x"\non = "work-received"\ntext = "first"|, "a.toml")
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\ntext = "second"|, "b.toml")

    assert_raise ArgumentError, ~r/duplicate statute name: x/, fn -> Rails.load!(ctx.base_dir) end
  end

  test "unknown statute keys name the typo", ctx do
    write_statute(ctx, ~s|name = "x"\non = "turn-end"\ntext = "law"\nsevrity = 1|)

    assert_raise ArgumentError, ~r/unknown statute keys.*sevrity/, fn ->
      Rails.load!(ctx.base_dir)
    end
  end

  test "missing directory and zero statute files load as an empty set", ctx do
    File.rm_rf!(ctx.rails_dir)

    assert Rails.load!(ctx.base_dir) == []
    assert Rails.standing_law() == nil
    assert Rails.claude_settings() == nil
  end

  test "files and tables retain deterministic load order", ctx do
    write_statute(ctx, ~s|name = "second"\non = "turn-end"\ntext = "second"|, "b.toml")

    File.write!(Path.join(ctx.rails_dir, "a.toml"), """
    [[statute]]
    name = "first"
    on = "work-received"
    text = "first"

    [[statute]]
    name = "first-next"
    on = "turn-end"
    text = "next"
    """)

    assert Enum.map(Rails.load!(ctx.base_dir), & &1.name) == ["first", "first-next", "second"]
  end

  test "standing law is byte-pinned", ctx do
    write_examples(ctx)
    Rails.load!(ctx.base_dir)

    assert Rails.standing_law() ==
             """
             ## Standing law

             Deterministic law of this org, delivered by rail. Each statute is also
             re-presented at its moment; these are the same obligations, standing.

             - announce-new-work (on work-received): If this message assigns you new
               work, wake your coordinator session to acknowledge it before starting.
             - ticket-on-done (on turn-end): If this turn completed coding work tied to
               a tracked ticket, update the ticket state before ending.
             """
             |> String.trim_trailing()
  end

  test "Claude hook settings and example commands are byte-pinned", ctx do
    write_examples(ctx)
    Rails.load!(ctx.base_dir)

    assert Rails.claude_settings() == %{
             "hooks" => %{
               "UserPromptSubmit" => [
                 %{
                   "hooks" => [
                     %{
                       "type" => "command",
                       "command" =>
                         "echo '[standing law: announce-new-work] If this message assigns you new work, wake your coordinator session to acknowledge it before starting.'"
                     }
                   ]
                 }
               ],
               "Stop" => [
                 %{
                   "hooks" => [
                     %{
                       "type" => "command",
                       "command" =>
                         "sh -c 'if grep -q \"\\\"stop_hook_active\\\"[[:space:]]*:[[:space:]]*true\" -; then exit 0; fi; echo \"[standing law: ticket-on-done] If this turn completed coding work tied to a tracked ticket, update the ticket state before ending.\" >&2; exit 2'"
                     }
                   ]
                 }
               ]
             }
           }
  end

  test "Claude command quoting is byte-pinned for single and double quotes", ctx do
    File.write!(Path.join(ctx.rails_dir, "quotes.toml"), """
    [[statute]]
    name = "quote-work"
    on = "work-received"
    text = "Don't say \\\"done\\\" without proof."

    [[statute]]
    name = "quote-stop"
    on = "turn-end"
    text = "Don't say \\\"done\\\" without proof."
    """)

    settings = Rails.load!(ctx.base_dir) && Rails.claude_settings()

    assert get_in(settings, [
             "hooks",
             "UserPromptSubmit",
             Access.at(0),
             "hooks",
             Access.at(0),
             "command"
           ]) ==
             "echo '[standing law: quote-work] Don'\\''t say \"done\" without proof.'"

    assert get_in(settings, ["hooks", "Stop", Access.at(0), "hooks", Access.at(0), "command"]) ==
             "sh -c 'if grep -q \"\\\"stop_hook_active\\\"[[:space:]]*:[[:space:]]*true\" -; then exit 0; fi; echo \"[standing law: quote-stop] Don'\\''t say \\\"done\\\" without proof.\" >&2; exit 2'"
  end

  defp write_statute(ctx, body, filename \\ "statute.toml") do
    File.write!(Path.join(ctx.rails_dir, filename), "[[statute]]\n#{body}\n")
  end

  defp write_examples(ctx) do
    File.write!(Path.join(ctx.rails_dir, "examples.toml"), """
    [[statute]]
    name = "announce-new-work"
    on = "work-received"
    mode = "remind"
    text = \"""
    If this message assigns you new work, wake your coordinator session to
    acknowledge it before starting.\"""

    [[statute]]
    name = "ticket-on-done"
    on = "turn-end"
    text = "If this turn completed coding work tied to a tracked ticket, update the ticket state before ending."
    """)
  end
end
