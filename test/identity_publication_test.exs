defmodule Tightbeam.IdentityPublicationTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true
  test "pending markers recover on either side of the live-ref move", %{tmp_dir: tmp} do
    Tightbeam.IdentityPublicationFixture.run!(tmp, 0)
  end

  test "invalid include denial is fingerprinted, immutable, and commit-free", %{tmp_dir: tmp} do
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
end
