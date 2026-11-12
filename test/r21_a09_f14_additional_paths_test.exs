defmodule Tightbeam.R21A09F14AdditionalPathsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Artifacts,
    Assignments,
    DB,
    Dispatch,
    Gateway,
    Model,
    Org,
    RailRemedy,
    Rules,
    WorkItems
  }

  alias Tightbeam.Firehose.Hub

  @good_ref %{"repo" => "testhost:/tmp/r21-a09-five", "commit" => String.duplicate("a", 40)}
  @bad_ref %{"repo" => "testhost:/tmp/r21-a09-five", "commit" => "abc"}
  @overlap_rules ~w(
    document-verification-cites-copy
    verified-copy-is-saved
    clean-review-cites-verified-copy
    linked-review-verification-cites-own-report
    linked-review-verification-by-holder
  )

  test "five malformed-ref overlaps use each side's shipped rules" do
    for case_name <- @overlap_rules do
      {db, handlers, ctx} = setup_case(case_name)
      call = case_call(db, handlers, ctx, case_name)

      assert {:deny, %{rule: ^case_name}} = Rules.evaluate(db, call)

      before_count = count(db, call.params.assignment_id)
      result = Dispatch.dispatch(db, handlers, call)
      after_count = count(db, call.params.assignment_id)

      IO.puts(
        "A09_F14 case=#{case_name} result=#{inspect(result, limit: :infinity)} before=#{before_count} after=#{after_count}"
      )

      assert {:error,
              %{
                code: "invalid_commit_refs",
                message: "commitRefs must be unique full immutable commit refs"
              }} = result

      assert after_count == before_count
    end
  end

  test "F14 refusal closes later remedy and publishes original call refs" do
    {db, handlers, ctx} = setup_case("f14-remedy-closure")
    producer = assign(db, ctx.holder.session_key, ctx.item, nil, "evidence", "document proof")

    completion =
      call("attest", {:session, ctx.holder.session_key}, %{
        assignment_id: producer.id,
        work_item_id: ctx.item,
        kind: "completion"
      })

    assert {:error, %{reason: "remedy_fired", rule: "completion-requires-results-artifact"}} =
             Dispatch.dispatch(db, handlers, completion)

    assert %{status: "live"} =
             RailRemedy.episode(db, "completion-requires-results-artifact", producer.id)

    hub = String.to_atom("r21_a09_f14_hub_#{System.unique_integer([:positive])}")
    start_supervised!(Supervisor.child_spec({Hub, name: hub}, id: hub))

    :ok =
      Hub.register(hub, self(), %{
        mode: :all,
        db: db,
        user_id: "a09_five_owner",
        is_admin: false
      })

    malformed =
      call("attest", {:session, ctx.holder.session_key}, %{
        assignment_id: producer.id,
        work_item_id: ctx.item,
        kind: "verdict",
        verdict_kind: "verified",
        commit_refs: [@bad_ref]
      })
      |> Map.put(:firehose_hub, hub)

    assert {:deny, %{rule: "document-verification-cites-copy"}} = Rules.evaluate(db, malformed)

    assert {:error,
            %{
              code: "invalid_commit_refs",
              message: "commitRefs must be unique full immutable commit refs"
            }} = Dispatch.dispatch(db, handlers, malformed)

    assert %{status: "closed"} =
             RailRemedy.episode(db, "completion-requires-results-artifact", producer.id)

    assert count(db, producer.id) == 0

    assert_receive {:firehose_notice, %{"class" => "verb.denied", "refs" => refs}}

    assert refs["assignmentId"] == producer.id
    assert refs["workItemId"] == ctx.item
  end

  test "F14 preflight preserves principal and placement refusals after rule allow" do
    {db, handlers, ctx} = setup_case("admission-refusals")
    producer = assign(db, ctx.holder.session_key, ctx.item, nil, "code", "source")

    params = %{
      assignment_id: producer.id,
      kind: "verdict",
      verdict_kind: "verified",
      commit_refs: [@bad_ref]
    }

    for {principal, expected_code} <- [
          {nil, "principal_required"},
          {{:user, "a09_five_owner"}, "not_holder"}
        ] do
      request =
        call("attest", {:session, ctx.holder.session_key}, params)
        |> Map.put(:principal, principal)

      assert :ok = Rules.evaluate(db, request)
      assert {:error, %{code: ^expected_code}} = Dispatch.dispatch(db, handlers, request)
      assert count(db, producer.id) == 0
    end
  end

  defp setup_case(case_name) do
    db = :"r21_a09_five_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))
    :ok = Tightbeam.Schema.ensure_all(db)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    base = Path.join(System.tmp_dir!(), "r21-a09-five-#{System.unique_integer([:positive])}")
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    for source <-
          Path.wildcard("priv/kungfu/agentic-engineering/rules/*.toml") ++
            Path.wildcard("priv/seed/rules/*.toml") do
      File.cp!(source, Path.join(rules_dir, Path.basename(source)))
    end

    on_exit(fn -> File.rm_rf!(base) end)
    loaded = Rules.load!(base, Map.keys(handlers))
    IO.puts("A09_F14_RULES case=#{case_name} count=#{length(loaded)}")

    :ok =
      DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('a09_five_owner',0,1)")

    item = "wi_a09_five_#{System.unique_integer([:positive])}"

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt) VALUES(?1,'A09 five','a09_five_owner','open','a09_five_owner',1)",
        [item]
      )

    holder = session(db, "a09_five_holder", "coder")
    reviewer = session(db, "a09_five_reviewer", "reviewer-code")
    outsider = session(db, "a09_five_outsider", "reviewer-code")

    assert %{deliveryOwnerSessionKey: owner_key} =
             WorkItems.__handle__(db, "work-item-update", %{
               origin: "user:a09_five_owner",
               principal: {:user, "a09_five_owner"},
               params: %{work_item_id: item, delivery_owner_session_key: holder.session_key}
             })

    assert owner_key == holder.session_key
    previous_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:tightbeam, :commit_ref_command, previous_runner),
        else: Application.delete_env(:tightbeam, :commit_ref_command)
    end)

    Application.put_env(:tightbeam, :commit_ref_command, fn _cmd, _args, _opts -> {"", 0} end)

    {db, handlers, %{item: item, holder: holder, reviewer: reviewer, outsider: outsider}}
  end

  defp case_call(db, handlers, ctx, "document-verification-cites-copy") do
    producer = assign(db, ctx.holder.session_key, ctx.item, nil, "evidence", "document proof")

    call("attest", {:session, ctx.holder.session_key}, %{
      assignment_id: producer.id,
      kind: "verdict",
      verdict_kind: "verified",
      commit_refs: [@bad_ref]
    })
  end

  defp case_call(db, _handlers, ctx, "verified-copy-is-saved") do
    producer = assign(db, ctx.holder.session_key, ctx.item, nil, "policy", "uncaptured proof")
    digest = sha("metadata-only copy")

    artifact =
      Artifacts.record(db, %{
        principal: {:session, ctx.holder.session_key},
        session_key: ctx.holder.session_key,
        params: %{
          kind: "report",
          title: "uncaptured",
          origin_path: "descriptive/uncaptured",
          work_item_id: ctx.item,
          produced_by_assignment_id: producer.id,
          content_sha256: digest
        }
      })

    call("attest", {:session, ctx.holder.session_key}, %{
      assignment_id: producer.id,
      kind: "verdict",
      verdict_kind: "verified",
      artifact_id: artifact.artifact_id,
      content_sha256: digest,
      commit_refs: [@bad_ref]
    })
  end

  defp case_call(db, handlers, ctx, "clean-review-cites-verified-copy") do
    {producer, _source_artifact, _digest} = verified_producer(db, handlers, ctx, "live_mutation")

    review =
      assign(db, ctx.reviewer.session_key, ctx.item, producer.id, "review", "review wrong copy")

    call("attest", {:session, ctx.reviewer.session_key}, %{
      assignment_id: review.id,
      kind: "verdict",
      verdict_kind: "reviewed-clean",
      commit_refs: [@good_ref, @bad_ref]
    })
  end

  defp case_call(db, handlers, ctx, "linked-review-verification-cites-own-report") do
    {producer, source_artifact, digest} = verified_producer(db, handlers, ctx, "code")

    review =
      assign(db, ctx.reviewer.session_key, ctx.item, producer.id, "review", "review wrong report")

    call("attest", {:session, ctx.reviewer.session_key}, %{
      assignment_id: review.id,
      kind: "verdict",
      verdict_kind: "verified",
      artifact_id: source_artifact.artifact_id,
      content_sha256: digest,
      commit_refs: [@bad_ref]
    })
  end

  defp case_call(db, handlers, ctx, "linked-review-verification-by-holder") do
    {producer, _source_artifact, _digest} = verified_producer(db, handlers, ctx, "code")

    review =
      assign(db, ctx.reviewer.session_key, ctx.item, producer.id, "review", "review nonholder")

    {own_artifact, digest} =
      captured(db, ctx.reviewer.session_key, ctx.item, review.id, "own review report")

    call("attest", {:session, ctx.outsider.session_key}, %{
      assignment_id: review.id,
      kind: "verdict",
      verdict_kind: "verified",
      artifact_id: own_artifact.artifact_id,
      content_sha256: digest,
      commit_refs: [@bad_ref]
    })
  end

  defp verified_producer(db, handlers, ctx, effect) do
    producer = assign(db, ctx.holder.session_key, ctx.item, nil, effect, "source #{effect}")

    {artifact, digest} =
      captured(db, ctx.holder.session_key, ctx.item, producer.id, "source report")

    result =
      Dispatch.dispatch(
        db,
        handlers,
        call("attest", {:session, ctx.holder.session_key}, %{
          assignment_id: producer.id,
          kind: "verdict",
          verdict_kind: "verified",
          artifact_id: artifact.artifact_id,
          content_sha256: digest,
          commit_refs: [@good_ref]
        })
      )

    assert {:ok, %{attest: %{verdictKind: "verified"}}} = result
    {producer, artifact, digest}
  end

  defp captured(db, holder, item, assignment, title) do
    bytes = "A09 five #{title}\n"
    digest = sha(bytes)

    artifact =
      Artifacts.record(db, %{
        principal: {:session, holder},
        session_key: holder,
        params: %{
          kind: "report",
          title: title,
          origin_path: "descriptive/#{assignment}",
          work_item_id: item,
          produced_by_assignment_id: assignment,
          content_base64: Base.encode64(bytes),
          content_sha256: digest
        }
      })

    {artifact, digest}
  end

  defp count(db, assignment) do
    {:ok, [[n]]} =
      DB.query(db, "SELECT COUNT(*) FROM attests WHERE assignmentId=?1", [assignment])

    n
  end

  defp session(db, key, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: "a09_five_owner",
      origin: "user:a09_five_owner",
      archetype: archetype,
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp assign(db, holder, item, reviews, effect, subject) do
    Assignments.__handle__(db, "assign", %{
      call("assign", {:user, "a09_five_owner"}, %{
        subject: subject,
        idempotency_key: nil,
        work_item_id: item,
        reviews_assignment_id: reviews,
        effect_kind: effect,
        files: nil
      })
      | session_key: holder
    })
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp call(verb, principal, params) do
    origin =
      case principal do
        {:session, key} -> "agent:#{key}"
        {:user, user} -> "user:#{user}"
      end

    %{
      verb: verb,
      origin: origin,
      principal: principal,
      session_key: nil,
      params: params,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000
    }
  end
end
