defmodule Tightbeam.IdentityPublicationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    AdminProjection,
    Archetypes,
    DB,
    Devices,
    Dispatch,
    Gateway,
    Identity,
    Model,
    Org,
    Schema
  }

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tb-identity-publication-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    assert :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"identity_publication_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: Path.join(base_dir, "state.db"), name: db})
    assert :ok = Schema.ensure_all(db)
    Devices.add_user(db, "flynn", true)

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir, db: db}
  end

  test "pending markers recover on either side of the live-ref move", ctx do
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})

    for {suffix, move_first?} <- [{"before", false}, {"after", true}] do
      key = "identity-crash-#{suffix}"
      invocation = keyed_invocation("user:flynn", "identity-edit", key)

      candidate =
        Identity.edit!(
          ctx.base_dir,
          "default",
          :guidance,
          "# recovered #{suffix}\n",
          "user:flynn"
        )

      assert {:ok, %{state: "pending"}} =
               AdminProjection.begin_identity_publication(
                 ctx.db,
                 invocation,
                 candidate,
                 "user:flynn"
               )

      if move_first?,
        do: assert({:ok, _revision} = Identity.publish_live!(ctx.base_dir, candidate))

      call = %{
        verb: "identity-edit",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{
          archetype: "default",
          content: "ignored on replay",
          idempotency_key: key
        }
      }

      assert {:ok, %{live_revision: revision}} = Dispatch.dispatch(ctx.db, handlers, call)
      assert revision == candidate.candidate_revision

      assert %{state: "accepted", candidate_revision: ^revision} =
               AdminProjection.identity_publication_marker(
                 ctx.db,
                 invocation,
                 candidate.expected_prior
               )
    end
  end

  test "invalid include denial is fingerprinted, immutable, and commit-free", ctx do
    handler = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["identity-edit"]
    invocation = "identity-invalid-replay"
    identity_dir = Path.join(ctx.base_dir, "identity")
    main = git!(identity_dir, ["rev-parse", "main"])
    live = git!(identity_dir, ["rev-parse", "tightbeam/live"])

    call =
      identity_call(
        %{archetype: "operating-model", content: "#include \"missing.md\"\n"},
        invocation
      )

    assert %{code: "identity_include_invalid", message: message} = denial = handler.(call)
    assert message =~ "missing.md"

    assert %{
             state: "denied",
             cause: "missing_fragment",
             denial_code: "identity_include_invalid",
             denial_message: ^message,
             candidate_revision: nil,
             tree_fingerprint: fingerprint
           } = AdminProjection.identity_publication_marker(ctx.db, invocation, live)

    assert byte_size(fingerprint) == 64
    assert handler.(call) == denial
    assert git!(identity_dir, ["rev-parse", "main"]) == main
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == live
  end

  test "pending replay denies an unrelated live ref and preserves the exact denial", ctx do
    handler = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})["identity-edit"]
    invocation = "identity-pending-conflict"
    identity_dir = Path.join(ctx.base_dir, "identity")
    candidate = Identity.edit!(ctx.base_dir, "default", :guidance, "candidate\n", "user:flynn")

    assert {:ok, %{state: "pending"}} =
             AdminProjection.begin_identity_publication(
               ctx.db,
               invocation,
               candidate,
               "user:flynn"
             )

    divergent =
      git!(identity_dir, [
        "-c",
        "user.name=publication-test",
        "-c",
        "user.email=publication@test.invalid",
        "commit-tree",
        "#{candidate.expected_prior}^{tree}",
        "-m",
        "unrelated publication"
      ])

    git!(identity_dir, [
      "update-ref",
      "refs/heads/tightbeam/live",
      divergent,
      candidate.expected_prior
    ])

    call = identity_call(%{archetype: "default", content: "ignored"}, invocation)
    expected = candidate.expected_prior

    assert %{code: "identity_publication_conflict", expected: ^expected, actual: ^divergent} =
             denial = handler.(call)

    assert %{
             state: "denied",
             cause: "identity_publication_conflict",
             denial_code: "identity_publication_conflict",
             denial_expected: ^expected,
             denial_actual: ^divergent
           } =
             AdminProjection.identity_publication_marker(
               ctx.db,
               invocation,
               candidate.expected_prior
             )

    assert handler.(call) == denial
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == divergent
  end

  test "pending unlearn replay keeps a late durable reference behind the writer fence", ctx do
    assert {:ok, learned} = Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")
    assert {:ok, _revision} = Identity.publish_live!(ctx.base_dir, learned)
    Archetypes.load!(ctx.base_dir)

    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    key = "unlearn-late-reference"
    invocation = keyed_invocation("user:flynn", "unlearn", key)
    candidate = Identity.unlearn!(ctx.base_dir, "agentic-engineering", "user:flynn")

    assert {:ok, %{state: "pending"}} =
             AdminProjection.begin_identity_publication(
               ctx.db,
               invocation,
               candidate,
               "user:flynn"
             )

    session =
      Org.create(ctx.db, %{
        session_key: "agent:late-coder",
        display_name: "Late coder",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "coder",
        host: "testhost",
        harness: "codex",
        provider: "openai",
        model: Model.new("gpt-5.6-sol")
      })

    call = %{
      verb: "unlearn",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{name: "agentic-engineering", idempotency_key: key}
    }

    assert {:error,
            %{
              state: "referenced",
              code: "kungfu_referenced",
              sessions: [%{session_key: session_key}]
            }} = Dispatch.dispatch(ctx.db, handlers, call)

    assert session_key == session.session_key
    assert Identity.live_revision!(ctx.base_dir) == candidate.expected_prior
    assert Archetypes.get("coder").name == "coder"

    assert %{state: "pending", candidate_revision: candidate_revision} =
             AdminProjection.identity_publication_marker(
               ctx.db,
               invocation,
               candidate.expected_prior
             )

    assert candidate_revision == candidate.candidate_revision
  end

  defp identity_call(params, invocation_id) do
    %{
      verb: "identity-edit",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: params,
      invocation_id: invocation_id
    }
  end

  defp keyed_invocation(origin, verb, key) do
    digest = :crypto.hash(:sha256, [origin, 0, verb, 0, key]) |> Base.encode16(case: :lower)
    "identity-" <> digest
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed #{status}: #{output}"
    end
  end
end
