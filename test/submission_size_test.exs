defmodule Tightbeam.SubmissionSizeTest do
  use ExUnit.Case, async: true
  alias Tightbeam.SubmissionSize

  test "Codex counts Unicode scalar values across all text parts, not graphemes or bytes" do
    text = "e\u0301🙂"
    assert SubmissionSize.text_chars(text) == 3
    assert String.length(text) == 2
    assert byte_size(text) == 7
    limit = SubmissionSize.codex_text_limit()
    parts = [%{type: "text", text: String.duplicate("🙂", limit - 3)},
      %{"type" => "text", "text" => text}, %{type: "image", data: "not text"}]
    assert SubmissionSize.check_codex(parts) == :ok
    assert {:error, {:submission_text_limit_exceeded, actual, ^limit}} =
      SubmissionSize.check_codex(parts ++ [%{type: "text", text: "x"}])
    assert actual == limit + 1
  end

  test "small ready notices have no fifty-member or 65536-byte split" do
    notices = for n <- 1..101, do: {n, String.duplicate("🙂", 1_000)}
    assert {:ok, [^notices]} = SubmissionSize.pack_codex(notices, &elem(&1, 1),
      fn _, count -> 100 + 2 * (count - 1) end)
    assert Enum.sum(Enum.map(notices, fn {_, text} -> byte_size(text) end)) > 65_536
  end

  test "largest ordered fitting prefix includes envelope and separators at the exact boundary" do
    limit = SubmissionSize.codex_text_limit()
    overhead = fn _, count -> 100 + 2 * (count - 1) end
    first = {1, String.duplicate("a", limit - 103)}
    second = {2, "b"}
    third = {3, "c"}
    assert {:ok, [[^first, ^second], [^third]]} =
      SubmissionSize.pack_codex([first, second, third], &elem(&1, 1), overhead)
    assert SubmissionSize.text_chars(elem(first, 1)) + 1 + overhead.(first, 2) == limit
    assert SubmissionSize.text_chars(elem(first, 1)) + 2 + overhead.(first, 3) > limit
  end

  test "single-source oversize is explicit and cannot silently drop a sibling" do
    limit = SubmissionSize.codex_text_limit()
    huge = {:huge, String.duplicate("x", limit)}
    assert {:error, {:source_submission_too_large, ^huge, actual, ^limit}} =
      SubmissionSize.pack_codex([{:before, "a"}, huge, {:after, "b"}], &elem(&1, 1),
        fn _, _ -> 1 end)
    assert actual == limit + 1
  end
end
