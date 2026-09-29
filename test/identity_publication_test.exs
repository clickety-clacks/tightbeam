defmodule Tightbeam.IdentityPublicationTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  test "pending markers recover on either side of the live-ref move", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 0)
  end

  test "invalid include denial persists diagnostics, replays after restart, and stays commit-free",
       %{
         tmp_dir: tmp
       } do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 1)
  end

  test "pending replay denies an unrelated live ref and preserves the exact denial", %{
    tmp_dir: tmp
  } do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 2)
  end

  test "pending unlearn replay keeps a late durable reference behind the writer fence", %{
    tmp_dir: tmp
  } do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 3)
  end

  test "pending unlearn replay removes sentinel state without republishing", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 4)
  end

  test "accepted unlearn replay completes cleanup after a failed delete", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 5)
  end

  test "accepted unlearn replay completes cleanup after supervisor reconciliation fails", %{
    tmp_dir: tmp
  } do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 6)
  end

  test "initial unlearn removes only the target bundle sentinel state", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 7)
  end

  test "identity denial redacts secrets before persistence and replay", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 8)
  end

  test "same-key racing denials return the first persisted diagnostic", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 9)
  end

  test "child diagnostics persist across a controlled stall and the child exits cleanly", %{
    tmp_dir: tmp
  } do
    Tightbeam.IdentityPublicationFixture.run_controlled_stall!(tmp)
  end

  test "public dispatch JSON returns the redacted persisted identity denial", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 10)
  end
end

ExUnit.after_suite(fn _result ->
  suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)
  requested = Path.join(suite_tmp, "identity-publication-diagnostic-requested")
  diagnostic = Path.join(suite_tmp, "identity-publication-child-diagnostic.jsonl")

  if File.exists?(requested) do
    IO.puts(:stderr, "identity-publication-child-diagnostic-begin")

    case File.read(diagnostic) do
      {:ok, contents} when byte_size(contents) <= 24 * 1024 ->
        IO.write(:stderr, contents)

      {:ok, _oversized} ->
        IO.puts(:stderr, "identity-publication-child-diagnostic exceeded its fixed output bound")

      {:error, :enoent} ->
        IO.puts(:stderr, "no child phase was persisted before the parent test ended")

      {:error, reason} ->
        IO.puts(:stderr, "child diagnostic unavailable: #{inspect(reason)}")
    end

    IO.puts(:stderr, "identity-publication-child-diagnostic-end")
    IO.puts(:stderr, "stack entries are phase-time snapshots; no live timeout stack is captured")
  end
end)
