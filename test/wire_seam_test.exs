defmodule Tightbeam.Wire.SeamTest do
  @moduledoc """
  A param the CLI puts on the wire must reach the handler that acts on it.

  `assign --reviews` was underscored to `:reviews`, which no handler reads, so
  every review link silently landed NULL and the unknown-target check that
  guards it never ran.

  Proven from the wire shape through the real router and the real handler to the
  persisted row. The bodies here are written by hand to match what the CLI emits
  — `cli/src/dispatch.rs`'s own tests pin those bytes, and this file's business
  is what the substrate does with them. Asserting at `atomize_params/2` alone
  would not have caught the defect, because a name can translate correctly and
  still be read under a different one downstream.
  """

  use Tightbeam.TestCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{
    DB,
    Gateway,
    Org,
    Rules
  }

  alias Tightbeam.Wire.Router

  setup do
    db = :"wire_seam_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-wire-seam-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base_dir) end)

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir})
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))

    %{
      db: db,
      opts: [
        db: db,
        base_dir: base_dir,
        handlers: handlers,
        cli_token: "tbc_wire_seam",
        session_status: fn _ -> nil end
      ]
    }
  end

  test "the assign wire word `reviews` normalizes to the edge it sets" do
    # The spec pins both spellings — wire `reviews`, atomized
    # `:reviews_assignment_id` (p3-observables-producers-v1 §Review-of relation) —
    # because the word the caller says names the REVIEWED assignment while the
    # column it sets names the link.
    assert Router.atomize_params_for_test("assign", %{
             "subject" => "review the fix",
             "reviews" => "asg_reviewed"
           }) == %{subject: "review the fix", reviews_assignment_id: "asg_reviewed"}
  end

  test "assign --reviews lands the review link on the row", ctx do
    producer = create_session(ctx.db, "producer", "flynn")
    reviewer = create_session(ctx.db, "reviewer", "flynn")

    ok!(
      dispatch_cli(ctx, "tbc_wire_seam", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: producer.session_key,
        params: %{subject: "fix the seam"}
      })
    )

    produced = assignment_id(ctx.db, "fix the seam")

    ok!(
      dispatch_cli(ctx, "tbc_wire_seam", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: reviewer.session_key,
        params: %{subject: "review the fix", reviews: produced}
      })
    )

    {:ok, [[link]]} =
      DB.query(
        ctx.db,
        "SELECT reviewsAssignmentId FROM assignments WHERE subject = ?1",
        ["review the fix"]
      )

    assert link == produced
  end

  test "assign --reviews on an unknown assignment is refused, not ignored", ctx do
    # The handler's existing UnknownReviewTarget check is unreachable while the
    # param is dropped, so a typo'd id used to open an ordinary unlinked
    # assignment. Reaching the refusal is itself proof the id arrives.
    reviewer = create_session(ctx.db, "reviewer", "flynn")

    response =
      dispatch_cli(ctx, "tbc_wire_seam", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: reviewer.session_key,
        params: %{subject: "review a ghost", reviews: "asg_never_existed"}
      })

    assert JSON.decode!(response.resp_body)["error"]["code"] == "unknown_review_target"
    assert assignment_id(ctx.db, "review a ghost") == nil
  end

  # A refusal here is the interesting failure, and the raw Plug.Conn dump buries
  # it, so the body rides on the assertion message.
  defp ok!(response) do
    assert response.status == 200, "dispatch refused: #{response.resp_body}"
    JSON.decode!(response.resp_body)["result"]
  end

  defp dispatch_cli(ctx, bearer, body) do
    conn(:post, "/agent/dispatch", JSON.encode!(Map.put_new(body, :params, %{})))
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("x-tightbeam-cli-version", Tightbeam.CliCompatibility.required_version())
    |> Router.call(Router.init(ctx.opts))
  end

  defp create_session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    })
  end

  defp assignment_id(db, subject) do
    case DB.query(db, "SELECT id FROM assignments WHERE subject = ?1", [subject]) do
      {:ok, [[id]]} -> id
      {:ok, []} -> nil
    end
  end
end
