defmodule Tightbeam.Identity.TomlEditTest do
  use ExUnit.Case, async: true
  alias Tightbeam.Identity.TomlEdit

  test "qualification leaves CRLF, comments, nested tables and multiline prose intact" do
    bytes =
      """
      # author introduction
      [[rule]] # rule rationale
      name = 'sample'
      text = '''
      A prose example: [[rule]], # not a comment, { untouched = true }.
      '''
      deny_when = [
        { fact = "target.archetype", op = "eq", value = 'coder' }, # why coder
      ]
      [rule.notice]
      prompt = "Keep this prompt exactly."
      """
      |> String.replace("\n", "\r\n")

    data = Toml.decode!(bytes)
    [rule] = data["rule"]
    [condition] = rule["deny_when"]

    desired =
      put_in(data["rule"], [
        rule
        |> Map.put("archetypes", ["engineering.coder"])
        |> Map.put("deny_when", [Map.put(condition, "value", "engineering.coder")])
      ])

    expected =
      bytes
      |> String.replace(
        "[[rule]] # rule rationale\r\n",
        "[[rule]] # rule rationale\r\narchetypes = [\"engineering.coder\"]\r\n"
      )
      |> String.replace("value = 'coder'", "value = 'engineering.coder'")

    assert TomlEdit.update!(bytes, desired) == expected
  end

  test "removing a foreign comparison retains comments and the remaining authored condition" do
    bytes = """
    [[rule]]
    name = "sample"
    deny_when = [
      # explanation of the foreign comparison
      { fact = 'target.archetype', op = 'ne', value = 'outsider' }, # kept note
      { fact = 'caller.is_admin', op = 'eq', value = false }, # unchanged
    ]
    """

    data = Toml.decode!(bytes)
    [rule] = data["rule"]
    [_removed, retained] = rule["deny_when"]
    desired = put_in(data["rule"], [Map.put(rule, "deny_when", [retained])])
    result = TomlEdit.update!(bytes, desired)
    assert Toml.decode!(result) == desired
    assert result =~ "# explanation of the foreign comparison"
    assert result =~ "# kept note"
    assert result =~ "{ fact = 'caller.is_admin', op = 'eq', value = false }, # unchanged"
  end

  test "manifest and receipt edits preserve unrelated fields and list comments" do
    bytes = """
    name  = 'engineering' # provenance
    root_archetype = 'coder'
    paths = [
      'archetypes/coder.toml', # authored path note
      'rules/old-reaction.toml', # migration note
    ]
    purpose = '''Keep the multiline
    offer, its spacing, and its punctuation.'''
    """

    desired =
      Toml.decode!(bytes)
      |> Map.put("root_archetype", "engineering.coder")
      |> Map.put("paths", ["kungfu/engineering/archetypes/coder.toml"])

    result = TomlEdit.update!(bytes, desired)
    assert result =~ "name  = 'engineering' # provenance\n"
    assert result =~ "# authored path note"
    assert result =~ "# migration note"

    assert result =~
             "purpose = '''Keep the multiline\noffer, its spacing, and its punctuation.'''"
  end

  test "array-of-table comparisons keep subsequent rule sections independent" do
    bytes = """
    [[rule]]
    name = 'first'
    [[rule.deny_when]]
    # foreign comparison note
    fact = 'target.archetype'
    op = 'ne'
    value = 'outsider'
    [[rule.deny_when]]
    fact = 'caller.is_admin'
    op = 'eq'
    value = false # retained condition
    [[rule]]
    name = 'second'
    deny_when = [{ fact = 'target.archetype', op = 'eq', value = 'coder' }]
    """

    data = Toml.decode!(bytes)
    [first, second] = data["rule"]
    [_foreign, retained] = first["deny_when"]
    desired = Map.put(data, "rule", [Map.put(first, "deny_when", [retained]), second])
    result = TomlEdit.update!(bytes, desired)
    assert result =~ "# foreign comparison note"
    assert result =~ "value = false # retained condition"

    assert result =~
             "name = 'second'\ndeny_when = [{ fact = 'target.archetype', op = 'eq', value = 'coder' }]"
  end

  test "removing a comparison does not rewrite a retained comparison with the same fact and operator" do
    bytes = """
    [[rule]]
    deny_when = [
      { fact = 'target.archetype', op = 'ne', value = 'outsider' },
      { fact = 'target.archetype', op = 'ne', value = 'engineering.coder' }, # retained bytes
    ]
    """

    data = Toml.decode!(bytes)
    [rule] = data["rule"]
    [_foreign, retained] = rule["deny_when"]
    desired = Map.put(data, "rule", [Map.put(rule, "deny_when", [retained])])
    result = TomlEdit.update!(bytes, desired)

    assert result =~
             "{ fact = 'target.archetype', op = 'ne', value = 'engineering.coder' }, # retained bytes"
  end

  test "an inserted field after a final table header preserves its comment" do
    bytes = "[rule] # no final newline"

    assert TomlEdit.update!(bytes, %{"rule" => %{"archetypes" => ["*"]}}) ==
             bytes <> "\narchetypes = [\"*\"]\n"
  end

  test "inline and dotted rail forms retain their original bytes around the added scope" do
    inline = "rule = [{ name = 'one', text = 'unchanged' }] # comment\n"
    original = Toml.decode!(inline)
    [rule] = original["rule"]
    desired = Map.put(original, "rule", [Map.put(rule, "archetypes", ["*"])])

    assert TomlEdit.update!(inline, desired) ==
             "rule = [{ name = 'one', text = 'unchanged' , archetypes = [\"*\"]}] # comment\n"

    dotted = "rule.name = 'one' # explanation\nrule.text = 'unchanged'\n"
    desired = put_in(Toml.decode!(dotted)["rule"]["archetypes"], ["*"])

    assert TomlEdit.update!(dotted, desired) ==
             "\"rule\".\"archetypes\" = [\"*\"]\n" <> dotted
  end

  test "a singleton table stays a table and unchanged input is byte-identical" do
    bytes = "# retained\n[rule]\nname = 'one'\ntext = '''keep this'''\n"
    data = Toml.decode!(bytes)
    assert TomlEdit.update!(bytes, data) == bytes

    assert TomlEdit.update!(bytes, put_in(data["rule"]["archetypes"], ["*"])) ==
             "# retained\n[rule]\narchetypes = [\"*\"]\nname = 'one'\ntext = '''keep this'''\n"
  end
end
