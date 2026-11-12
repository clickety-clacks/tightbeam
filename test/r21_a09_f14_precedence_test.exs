defmodule Tightbeam.R21A09F14PrecedenceTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Artifacts, Assignments, DB, Dispatch, Gateway, Model, Org, Rules, WorkItems}

  @good_ref %{"repo" => "testhost:/tmp/r21-a09", "commit" => String.duplicate("a", 40)}
  @bad_ref %{"repo" => "testhost:/tmp/r21-a09", "commit" => "abc"}

  test "F14 malformed refs precede clean-review coverage and corrected refs pass" do
    db = String.to_atom("r21_a09_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})

    base = Path.join(System.tmp_dir!(), "r21-a09-#{System.unique_integer([:positive])}")
    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    for source <-
          Path.wildcard("priv/kungfu/agentic-engineering/rules/*.toml") ++
            Path.wildcard("priv/seed/rules/*.toml") do
      File.cp!(source, Path.join(rules_dir, Path.basename(source)))
    end

    on_exit(fn -> File.rm_rf!(base) end)
    loaded = Rules.load!(base, Map.keys(handlers))
    assert Enum.any?(loaded, &(&1.name == "clean-review-covers-verified-commits"))

    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('a09_owner',0,1)")
    item = "wi_a09_precedence"

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt) " <>
          "VALUES(?1,'A09','a09_owner','open','a09_owner',1)",
        [item]
      )

    holder =
      Org.create(db, %{
        session_key: "a09_holder",
        display_name: "A09 holder",
        kind: "custom",
        owner_user_id: "a09_owner",
        origin: "user:a09_owner",
        archetype: "coder",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    assert %{deliveryOwnerSessionKey: "a09_holder"} =
             WorkItems.__handle__(db, "work-item-update", %{
               origin: "user:a09_owner",
               principal: {:user, "a09_owner"},
               params: %{work_item_id: item, delivery_owner_session_key: holder.session_key}
             })

    previous_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:tightbeam, :commit_ref_command, previous_runner),
        else: Application.delete_env(:tightbeam, :commit_ref_command)
    end)

    Application.put_env(:tightbeam, :commit_ref_command, fn _cmd, _args, _opts -> {"", 0} end)

    producer = assign(db, holder.session_key, item, nil, "code", "source code")
    bytes = "A09 captured code result\n"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    artifact =
      Artifacts.record(db, %{
        principal: {:session, holder.session_key},
        session_key: holder.session_key,
        params: %{
          kind: "report",
          title: "A09 source report",
          origin_path: "descriptive/a09-source",
          work_item_id: item,
          produced_by_assignment_id: producer.id,
          content_base64: Base.encode64(bytes),
          content_sha256: digest
        }
      })

    source_result =
      Dispatch.dispatch(
        db,
        handlers,
        call("attest", {:session, holder.session_key}, %{
          assignment_id: producer.id,
          kind: "verdict",
          verdict_kind: "verified",
          artifact_id: artifact.artifact_id,
          content_sha256: digest,
          commit_refs: [@good_ref]
        })
      )

    assert {:ok, %{attest: %{verdictKind: "verified"}}} = source_result

    review = assign(db, holder.session_key, item, producer.id, "review", "clean review")

    common = %{
      assignment_id: review.id,
      kind: "verdict",
      verdict_kind: "reviewed-clean",
      artifact_id: artifact.artifact_id,
      content_sha256: digest
    }

    malformed =
      call("attest", {:session, holder.session_key}, Map.put(common, :commit_refs, [@bad_ref]))

    corrected =
      call("attest", {:session, holder.session_key}, Map.put(common, :commit_refs, [@good_ref]))

    assert {:deny, %{rule: "clean-review-covers-verified-commits"}} =
             Rules.evaluate(db, malformed)

    assert {:error,
            %{
              code: "invalid_commit_refs",
              message: "commitRefs must be unique full immutable commit refs"
            }} = Dispatch.dispatch(db, handlers, malformed)

    assert count(db, review.id) == 0

    assert {:ok, %{attest: %{verdictKind: "reviewed-clean"}}} =
             Dispatch.dispatch(db, handlers, corrected)

    assert count(db, review.id) == 1
  end

  defp count(db, assignment) do
    {:ok, [[n]]} =
      DB.query(db, "SELECT COUNT(*) FROM attests WHERE assignmentId=?1", [assignment])

    n
  end

  defp assign(db, holder, item, reviews, effect, subject) do
    call =
      call("assign", {:user, "a09_owner"}, %{
        subject: subject,
        idempotency_key: nil,
        work_item_id: item,
        reviews_assignment_id: reviews,
        effect_kind: effect,
        files: nil
      })
      |> Map.put(:session_key, holder)

    Assignments.__handle__(db, "assign", call)
  end

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
