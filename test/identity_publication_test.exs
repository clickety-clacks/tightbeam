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

  test "public dispatch JSON returns the redacted persisted identity denial", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 10)
  end
end
