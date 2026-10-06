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
  alias Tightbeam.Model

  import Plug.Test
  import Plug.Conn

  alias Tightbeam.{
    DB,
    Gateway,
    Org,
    Roles,
    Rules,
    Wakes
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
    Tightbeam.Archetypes.load!(base_dir)

    handlers = Gateway.handlers(%{db: db, base_dir: base_dir, wake_tick_ms: 1_000})
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

  test "authenticated wake cancellation crosses the wire with exact envelopes", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: "wire-cancel",
        origin: "user:flynn",
        prompt: "cancel through the wire",
        due_at: 1_000
      })

    wrong_origin =
      Wakes.schedule(ctx.db, %{
        session_key: "wire-cancel",
        origin: "user:other",
        prompt: "do not cancel through the wire",
        due_at: 2_000
      })

    assert ok!(
             dispatch_cli(ctx, "tbc_wire_seam", %{
               verb: "wake",
               asUser: "flynn",
               params: %{"cancelWakeId" => wake.wake_id}
             })
           ) == %{"canceled" => true}

    assert {:ok, [[event_id, causal_source_id]]} =
             DB.query(
               ctx.db,
               """
               SELECT e.id, c.causalSourceId
               FROM events e
               JOIN wake_cancellations c ON c.causalSourceId=CAST(e.id AS TEXT)
               WHERE c.wakeId=?1 AND e.kind='verb' AND e.verb='wake'
               """,
               [wake.wake_id]
             )

    assert event_id > 0
    assert causal_source_id == Integer.to_string(event_id)

    assert ok!(
             dispatch_cli(ctx, "tbc_wire_seam", %{
               verb: "wake",
               asUser: "flynn",
               params: %{"cancelWakeId" => wrong_origin.wake_id}
             })
           ) == %{"canceled" => false}

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [wrong_origin.wake_id]
             )

    assert Wakes.get(ctx.db, wake.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, wrong_origin.wake_id).state == "pending"
  end

  test "a holder cancels a dependency wake through the wire with liveness provenance", ctx do
    holder = create_session(ctx.db, "g23-holder", "flynn")
    resolver = create_session(ctx.db, "g23-resolver", "flynn")
    verifier = create_session(ctx.db, "g23-verifier", "flynn")
    stranger = create_session(ctx.db, "g23-stranger", "flynn")

    Roles.create!(ctx.db, "g23-holder-role", "flynn", holder.session_key)
    Roles.create!(ctx.db, "g23-stranger-role", "flynn", stranger.session_key)

    rules_dir = Path.join(ctx.opts[:base_dir], "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "verification.toml"), """
    [[policy]]
    name = "accountable-dependency-verifier"
    purpose = "wait-verification-admission"
    when = [
      { fact = "verifier.open", op = "eq", value = true },
      { fact = "verifier.holder_is_other", op = "eq", value = true },
    ]
    verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }
    """)

    Rules.load!(ctx.opts[:base_dir], Map.keys(ctx.opts[:handlers]))

    for {session, subject} <- [
          {holder, "g23 holder assignment"},
          {resolver, "g23 resolver assignment"},
          {verifier, "g23 verifier assignment"}
        ] do
      assert is_map(
               ok!(
                 dispatch_cli(ctx, holder.cli_token, %{
                   verb: "assign",
                   as: "g23-holder-role",
                   sessionKey: session.session_key,
                   params: %{subject: subject}
                 })
               )
             )
    end

    holder_assignment = assignment_id(ctx.db, "g23 holder assignment")
    resolver_assignment = assignment_id(ctx.db, "g23 resolver assignment")
    verifier_assignment = assignment_id(ctx.db, "g23 verifier assignment")

    assert {:ok, [["open"], ["open"], ["open"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM assignments WHERE id IN (?1, ?2, ?3) ORDER BY id",
               [holder_assignment, resolver_assignment, verifier_assignment]
             )

    predicate = %{
      "conditions" => [
        %{"fact" => "assignment.state", "op" => "eq", "value" => "completed"}
      ],
      "bindings" => %{"assignmentId" => resolver_assignment},
      "resolverRef" => %{"kind" => "assignment", "id" => resolver_assignment},
      "necessity" => "The named resolver owns the prerequisite output.",
      "verificationRef" => %{"kind" => "assignment", "id" => verifier_assignment}
    }

    assert is_map(
             ok!(
               dispatch_cli(ctx, holder.cli_token, %{
                 verb: "wake",
                 as: "g23-holder-role",
                 sessionKey: holder.session_key,
                 params: %{
                   prompt: "wait for the resolver",
                   afterMs: 60_000,
                   assignmentId: holder_assignment,
                   predicate: predicate,
                   nudge: false
                 }
               })
             )
           )

    assert {:ok, [[wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND waitMode='dependency'",
               [holder_assignment]
             )

    assert Wakes.get(ctx.db, wake_id).state == "pending"

    # A different session principal cannot cancel the holder's origin, and the
    # refusal must not consume the pending wake or write provenance.
    assert ok!(
             dispatch_cli(ctx, stranger.cli_token, %{
               verb: "wake",
               as: "g23-stranger-role",
               sessionKey: holder.session_key,
               params: %{"cancelWakeId" => wake_id}
             })
           ) == %{"canceled" => false}

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [wake_id])

    assert Wakes.get(ctx.db, wake_id).state == "pending"

    assert ok!(
             dispatch_cli(ctx, holder.cli_token, %{
               verb: "wake",
               as: "g23-holder-role",
               sessionKey: holder.session_key,
               params: %{"cancelWakeId" => wake_id}
             })
           ) == %{"canceled" => true}

    assert Wakes.get(ctx.db, wake_id).state == "canceled"
    assert assignment_state(ctx.db, holder_assignment) == "open"
    assert assignment_state(ctx.db, resolver_assignment) == "open"

    assert {:ok,
            [
              [
                "session",
                holder_session_key,
                "requester_withdrew",
                "verb_call",
                causal_source_id,
                "no_replacement",
                "assignment",
                ^holder_assignment,
                "linked_work_open",
                "supervision_entitlement",
                liveness_trigger_id,
                1
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT requesterKind, requesterId, reasonKind, causalSourceKind, causalSourceId,
                      outcomeKind, primaryWorkKind, primaryWorkId, workImpactKind,
                      livenessTriggerKind, livenessTriggerId, actionNeeded
               FROM wake_cancellations WHERE wakeId=?1
               """,
               [wake_id]
             )

    assert holder_session_key == holder.session_key
    assert is_binary(causal_source_id) and causal_source_id != ""
    assert String.starts_with?(liveness_trigger_id, holder_assignment <> "#")

    # Replay is a refusal, not a second cancellation or a second liveness action.
    assert ok!(
             dispatch_cli(ctx, holder.cli_token, %{
               verb: "wake",
               as: "g23-holder-role",
               sessionKey: holder.session_key,
               params: %{"cancelWakeId" => wake_id}
             })
           ) == %{"canceled" => false}

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [wake_id])

    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake_id])
  end

  test "authenticated session-po-set dispatch returns and inspects the exact association", ctx do
    target = create_session(ctx.db, "po-target", "flynn")
    po = create_session(ctx.db, "po-reader", "flynn")
    Roles.create!(ctx.db, "product-owner:wire", "flynn", po.session_key)

    result =
      ok!(
        dispatch_cli(ctx, "tbc_wire_seam", %{
          verb: "session-po-set",
          asUser: "flynn",
          params: %{
            sessionKey: target.session_key,
            poRole: "product-owner:wire",
            idempotencyKey: "wire-association"
          }
        })
      )

    assert result["changed"]
    assert result["association"]["sessionKey"] == target.session_key
    assert result["association"]["poRole"] == "product-owner:wire"

    inspected =
      ok!(
        dispatch_cli(ctx, "tbc_wire_seam", %{
          verb: "inspect",
          asUser: "flynn"
        })
      )

    target_readback =
      Enum.find(inspected["sessions"], &(&1["sessionKey"] == target.session_key))

    assert target_readback["poAssociation"] == result["association"]
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

  test "assignment-stop-turn crosses dispatch and refuses a non-opener", ctx do
    holder = create_session(ctx.db, "stop-holder", "flynn")

    ok!(
      dispatch_cli(ctx, "tbc_wire_seam", %{
        verb: "assign",
        asUser: "flynn",
        sessionKey: holder.session_key,
        params: %{subject: "stop only by the opener"}
      })
    )

    assignment = assignment_id(ctx.db, "stop only by the opener")

    response =
      dispatch_cli(ctx, "tbc_wire_seam", %{
        verb: "cancel",
        asUser: "other",
        params: %{
          assignmentId: assignment,
          reason: "replacement is waiting"
        }
      })

    assert response.status == 403
    assert JSON.decode!(response.resp_body)["error"]["code"] == "not_authorized"
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
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp assignment_id(db, subject) do
    case DB.query(db, "SELECT id FROM assignments WHERE subject = ?1", [subject]) do
      {:ok, [[id]]} -> id
      {:ok, []} -> nil
    end
  end

  defp assignment_state(db, assignment_id) do
    case DB.query(db, "SELECT state FROM assignments WHERE id=?1", [assignment_id]) do
      {:ok, [[state]]} -> state
      {:ok, []} -> nil
    end
  end
end
