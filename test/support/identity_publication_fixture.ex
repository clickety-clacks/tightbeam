defmodule Tightbeam.IdentityPublicationFixture.Diagnostics do
  @moduledoc false

  @path_env "DD36_IDENTITY_PUBLICATION_DIAGNOSTIC_PATH"
  @max_bytes 24 * 1024
  @max_events 8
  @max_stack_frames 16
  @max_string_bytes 128

  @phases [
    :child_started,
    :runtime_ready,
    :scenario_9_entered,
    :scenario_9_completed,
    :controlled_child_stalled,
    :controlled_child_released
  ]

  def record(phase) when phase in @phases do
    case System.get_env(@path_env) do
      path when is_binary(path) and path != "" ->
        event = %{
          "schema" => "identity-publication-child-diagnostic/v1",
          "phase" => Atom.to_string(phase),
          "output" => "identity-publication-child: #{phase}",
          "timestamp_ms" => System.system_time(:millisecond),
          "stack" => current_stack()
        }

        line = JSON.encode!(event) <> "\n"
        existing = read_existing(path)

        event_count =
          if existing == "", do: 0, else: length(String.split(existing, "\n", trim: true))

        if event_count >= @max_events or byte_size(existing) + byte_size(line) > @max_bytes do
          raise "identity publication child diagnostics exceeded their fixed bound"
        end

        File.write!(path, line, [:append, :sync])

      _ ->
        :ok
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
      {:error, reason} -> raise "cannot read identity publication diagnostics: #{inspect(reason)}"
    end
  end

  defp current_stack do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, stack} ->
        stack
        |> Enum.take(@max_stack_frames)
        |> Enum.map(&safe_frame/1)

      _ ->
        []
    end
  end

  defp safe_frame({module, function, arity, location}) do
    location = if is_list(location), do: location, else: []
    file = Keyword.get(location, :file)

    file =
      case file do
        value when is_binary(value) -> value
        value when is_list(value) -> List.to_string(value)
        _ -> nil
      end

    %{
      "module" => short(inspect(module)),
      "function" => short(Atom.to_string(function)),
      "arity" => safe_arity(arity),
      "file" => if(file, do: file |> Path.basename() |> short(), else: nil),
      "line" => Keyword.get(location, :line)
    }
  end

  defp safe_frame(_), do: %{"frame" => "unavailable"}

  defp safe_arity(arity) when is_integer(arity), do: arity
  defp safe_arity(arity) when is_list(arity), do: length(arity)
  defp safe_arity(_), do: nil

  defp short(value), do: String.slice(value, 0, @max_string_bytes)
end

defmodule Tightbeam.IdentityPublicationFixture.ReconcileOnceFailure do
  @moduledoc false
  use GenServer

  def start_link(parent) do
    GenServer.start_link(__MODULE__, parent, name: Tightbeam.SentinelSupervisor)
  end

  @impl true
  def init(parent), do: {:ok, %{parent: parent, attempts: 0}}

  @impl true
  def handle_call({:reconcile, restart}, _from, state) do
    attempt = state.attempts + 1
    send(state.parent, {:identity_publication_reconcile, attempt, restart})

    reply = if attempt == 1, do: {:error, :synthetic_reconcile_failure}, else: :ok
    {:reply, reply, %{state | attempts: attempt}}
  end
end

defmodule Tightbeam.IdentityPublicationFixture do
  import ExUnit.Assertions

  alias Tightbeam.{
    AdminProjection,
    Archetypes,
    DB,
    Devices,
    Dispatch,
    ErrorDiagnostic,
    Gateway,
    Identity,
    Model,
    Org,
    Schema
  }

  def run_case!(scenario, base) do
    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

    try do
      assert :ok = Schema.ensure_all(db)
      assert :ok = DB.assert_base_admitted!(db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))
      assert :initialized = Identity.init!(base)
      Archetypes.load!(base)
      Devices.add_user(db, "flynn", true)
      scenario(scenario, %{base_dir: base, db: db})

      if scenario == 9,
        do: Tightbeam.IdentityPublicationFixture.Diagnostics.record(:scenario_9_completed)

      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(db), do: GenServer.stop(db)
    end

    IO.puts("identity_publication-case: #{scenario}: ok")
  end

  defp scenario(0, ctx) do
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

  defp scenario(1, ctx) do
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

    # The first answer carries the refusal's location as fields, not only as text.
    assert %{"kind" => "denial", "details" => %{"cause" => "missing_fragment"} = details} =
             denial.diagnostic

    assert details["treeFingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
    assert details["expectedPrior"] == live
    assert %{"origin" => origin, "path" => path, "line" => 1, "paths" => ["missing.md"]} = details
    assert is_binary(origin) and is_binary(path)

    assert %{
             state: "denied",
             cause: "missing_fragment",
             denial_code: "identity_include_invalid",
             denial_message: ^message,
             candidate_revision: nil,
             tree_fingerprint: fingerprint
           } = AdminProjection.identity_publication_marker(ctx.db, invocation, live)

    assert byte_size(fingerprint) == 64
    # A replay answers from the marker: the same code and message, and the
    # fields the marker stores.
    replay = handler.(call)
    assert Map.delete(replay, :diagnostic) == Map.delete(denial, :diagnostic)

    assert replay.diagnostic == denial.diagnostic

    assert git!(identity_dir, ["rev-parse", "main"]) == main
    assert git!(identity_dir, ["rev-parse", "tightbeam/live"]) == live
  end

  defp scenario(2, ctx) do
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

  defp scenario(3, ctx) do
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

  defp scenario(4, ctx) do
    prepare_learned_unlearn_bundle!(ctx)
    seed_unlearn_sentinel_rows!(ctx)
    key = "unlearn-pending-cleanup"
    {candidate, invocation} = begin_pending_unlearn!(ctx, key)
    before_refs = identity_ref_snapshot(ctx.base_dir)
    before_history = identity_history_snapshot(ctx.base_dir)
    call = unlearn_call(key)

    assert {:ok, %{state: "published", live_revision: revision}} =
             Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

    assert revision == candidate.candidate_revision

    assert %{state: "accepted"} =
             AdminProjection.identity_publication_marker(
               ctx.db,
               invocation,
               candidate.expected_prior
             )

    assert sentinel_state_rows(ctx) == [["agentic-engineering-extra/runner", "disabled"]]
    assert sentinel_env_rows(ctx) == [["sentinel:agentic-engineering-extra/runner", "FOREIGN"]]
    assert identity_ref_snapshot(ctx.base_dir) == before_refs
    assert identity_history_snapshot(ctx.base_dir) == before_history
    assert Identity.live_revision!(ctx.base_dir) == revision
    assert call == unlearn_call(key)
  end

  defp scenario(5, ctx) do
    prepare_learned_unlearn_bundle!(ctx)
    seed_unlearn_sentinel_rows!(ctx)
    key = "unlearn-accepted-after-delete-failure"
    call = unlearn_call(key)
    invocation = keyed_invocation(call.origin, call.verb, key)
    trigger = "identity_publication_fail_sentinel_delete"

    assert :ok =
             DB.execute(
               ctx.db,
               """
               CREATE TRIGGER #{trigger} BEFORE DELETE ON sentinel_states
               BEGIN SELECT RAISE(ABORT, 'synthetic sentinel delete failure'); END
               """
             )

    assert {:error, %{code: "server_error"}} =
             Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

    marker = AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation)
    assert %{state: "accepted", candidate_revision: revision} = marker

    assert sentinel_state_rows(ctx) == [
             ["agentic-engineering-extra/runner", "disabled"],
             ["agentic-engineering/runner", "disabled"]
           ]

    assert sentinel_env_rows(ctx) == [
             ["sentinel:agentic-engineering-extra/runner", "FOREIGN"],
             ["sentinel:agentic-engineering/runner", "TARGET"]
           ]

    before_refs = identity_ref_snapshot(ctx.base_dir)
    before_history = identity_history_snapshot(ctx.base_dir)
    before_projection = identity_projection_snapshot(ctx.db)
    assert call.params == %{name: "agentic-engineering", idempotency_key: key}
    assert invocation == keyed_invocation(call.origin, call.verb, call.params.idempotency_key)

    assert :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")

    assert {:ok, %{state: "published", live_revision: ^revision}} =
             Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

    assert AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation) ==
             marker

    assert sentinel_state_rows(ctx) == [["agentic-engineering-extra/runner", "disabled"]]
    assert sentinel_env_rows(ctx) == [["sentinel:agentic-engineering-extra/runner", "FOREIGN"]]
    assert identity_ref_snapshot(ctx.base_dir) == before_refs
    assert identity_history_snapshot(ctx.base_dir) == before_history
    assert identity_projection_snapshot(ctx.db) == before_projection
    assert Identity.live_revision!(ctx.base_dir) == revision
    assert call == unlearn_call(key)
  end

  defp scenario(6, ctx) do
    prepare_learned_unlearn_bundle!(ctx)
    seed_unlearn_sentinel_rows!(ctx)
    key = "unlearn-accepted-after-reconcile-failure"
    call = unlearn_call(key)
    invocation = keyed_invocation(call.origin, call.verb, key)
    assert is_nil(Process.whereis(Tightbeam.SentinelSupervisor))

    {:ok, supervisor} =
      Tightbeam.IdentityPublicationFixture.ReconcileOnceFailure.start_link(self())

    try do
      assert {:error, %{code: "server_error"}} =
               Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

      assert_receive {:identity_publication_reconcile, 1, []}
      marker = AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation)
      assert %{state: "accepted", candidate_revision: revision} = marker
      assert sentinel_state_rows(ctx) == [["agentic-engineering-extra/runner", "disabled"]]
      assert sentinel_env_rows(ctx) == [["sentinel:agentic-engineering-extra/runner", "FOREIGN"]]

      before_refs = identity_ref_snapshot(ctx.base_dir)
      before_history = identity_history_snapshot(ctx.base_dir)
      before_projection = identity_projection_snapshot(ctx.db)
      assert call.params == %{name: "agentic-engineering", idempotency_key: key}
      assert invocation == keyed_invocation(call.origin, call.verb, call.params.idempotency_key)

      assert {:ok, %{state: "published", live_revision: ^revision}} =
               Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

      assert_receive {:identity_publication_reconcile, 2, []}

      assert AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation) ==
               marker

      assert sentinel_state_rows(ctx) == [["agentic-engineering-extra/runner", "disabled"]]
      assert sentinel_env_rows(ctx) == [["sentinel:agentic-engineering-extra/runner", "FOREIGN"]]
      assert identity_ref_snapshot(ctx.base_dir) == before_refs
      assert identity_history_snapshot(ctx.base_dir) == before_history
      assert identity_projection_snapshot(ctx.db) == before_projection
      assert Identity.live_revision!(ctx.base_dir) == revision
      assert call == unlearn_call(key)
    after
      if Process.alive?(supervisor), do: GenServer.stop(supervisor)
    end
  end

  defp scenario(7, ctx) do
    prepare_learned_unlearn_bundle!(ctx)
    seed_unlearn_sentinel_rows!(ctx)
    key = "unlearn-initial-cleanup"
    call = unlearn_call(key)
    invocation = keyed_invocation(call.origin, call.verb, key)

    assert {:ok, %{state: "published", live_revision: revision}} =
             Dispatch.dispatch(ctx.db, identity_handlers(ctx), call)

    assert %{state: "accepted", candidate_revision: ^revision} =
             AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation)

    assert sentinel_state_rows(ctx) == [["agentic-engineering-extra/runner", "disabled"]]
    assert sentinel_env_rows(ctx) == [["sentinel:agentic-engineering-extra/runner", "FOREIGN"]]
    assert Identity.live_revision!(ctx.base_dir) == revision
  end

  defp prepare_learned_unlearn_bundle!(ctx) do
    assert {:ok, learned} = Identity.learn!(ctx.base_dir, "agentic-engineering", "user:flynn")
    assert {:ok, _revision} = Identity.publish_live!(ctx.base_dir, learned)
    Archetypes.load!(ctx.base_dir)
  end

  defp identity_handlers(ctx),
    do: Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})

  defp begin_pending_unlearn!(ctx, key) do
    candidate = Identity.unlearn!(ctx.base_dir, "agentic-engineering", "user:flynn")
    invocation = keyed_invocation("user:flynn", "unlearn", key)

    assert {:ok, %{state: "pending"}} =
             AdminProjection.begin_identity_publication(
               ctx.db,
               invocation,
               candidate,
               "user:flynn"
             )

    assert {:ok, _revision} = Identity.publish_live!(ctx.base_dir, candidate)
    {candidate, invocation}
  end

  defp seed_unlearn_sentinel_rows!(ctx) do
    now = System.system_time(:millisecond)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO sentinel_states (host, sentinel, state, updatedAt)
                 VALUES
                   ('testhost', 'agentic-engineering/runner', 'disabled', ?1),
                   ('testhost', 'agentic-engineering-extra/runner', 'disabled', ?1)
                 """,
                 [now]
               )

               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO harness_env_overlays
                   (host, harness, name, value, setBy, setAt)
                 VALUES
                   ('testhost', 'sentinel:agentic-engineering/runner', 'TOKEN',
                    'TARGET', 'user:flynn', ?1),
                   ('testhost', 'sentinel:agentic-engineering-extra/runner', 'TOKEN',
                    'FOREIGN', 'user:flynn', ?1)
                 """,
                 [now]
               )

               :ok
             end)
  end

  defp unlearn_call(key) do
    %{
      verb: "unlearn",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{name: "agentic-engineering", idempotency_key: key}
    }
  end

  defp sentinel_state_rows(ctx) do
    assert {:ok, rows} =
             DB.query(
               ctx.db,
               """
               SELECT sentinel, state
               FROM sentinel_states
               WHERE host = 'testhost'
               ORDER BY sentinel
               """
             )

    rows
  end

  defp sentinel_env_rows(ctx) do
    assert {:ok, rows} =
             DB.query(
               ctx.db,
               """
               SELECT harness, value
               FROM harness_env_overlays
               WHERE host = 'testhost' AND harness LIKE 'sentinel:%'
               ORDER BY harness
               """
             )

    rows
  end

  defp identity_ref_snapshot(base_dir) do
    identity_dir = Path.join(base_dir, "identity")

    ["main", "tightbeam/live", "tightbeam/upstream"]
    |> Enum.map(&git!(identity_dir, ["rev-parse", &1]))
  end

  defp identity_history_snapshot(base_dir) do
    base_dir
    |> Path.join("identity")
    |> git!(["rev-list", "--all", "--format=%H%x00%P%x00%s"])
  end

  defp identity_projection_snapshot(db) do
    assert {:ok, rows} =
             DB.query(
               db,
               """
               SELECT resource, primaryKey, rowVersion, fingerprint, item
               FROM admin_projection_versions
               WHERE resource IN ('identity', 'kungfu')
               ORDER BY resource, primaryKey
               """
             )

    rows
  end

  defp scenario(8, ctx) do
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    live = git!(Path.join(ctx.base_dir, "identity"), ["rev-parse", "tightbeam/live"])

    include_invocation = "identity-include-secret-redaction"
    secret_include = "api_key=synthetic-include-secret.md"

    include_call =
      identity_call(
        %{
          archetype: "operating-model",
          content: "#include \"#{secret_include}\"\n"
        },
        include_invocation
      )

    assert {:error, include_denial} = Dispatch.dispatch(ctx.db, handlers, include_call)

    refute include_denial.message =~ "synthetic-include-secret"
    assert %{"kind" => "denial", "details" => include_details} = include_denial.diagnostic
    assert include_details["cause"] == "missing_fragment"
    assert include_details["line"] == 1
    assert include_details["treeFingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
    assert hd(include_details["paths"]) =~ "[REDACTED:secret_field]"

    include_marker = AdminProjection.identity_publication_marker(ctx.db, include_invocation, live)
    assert include_marker.denial_message == include_denial.message
    assert include_marker.denial_diagnostic == include_denial.diagnostic

    include_replay_call =
      identity_call(
        %{archetype: "default", content: "# valid now\n"},
        include_invocation
      )

    assert {:error, ^include_denial} =
             Dispatch.dispatch(ctx.db, handlers, include_replay_call)

    invocation = "identity-denial-secret-field-redaction"

    diagnostic =
      ErrorDiagnostic.new("denial",
        details: %{
          "path" => "includes/api_key=synthetic-secret.md",
          "apiKey" => "synthetic-field-secret",
          "safeSibling" => "preserve-this-value",
          "longValue" => String.duplicate("x", 9_000)
        }
      )

    {:ok, marker} =
      AdminProjection.deny_identity_validation(
        ctx.db,
        invocation,
        live,
        String.duplicate("a", 64),
        "user:flynn",
        "missing_fragment",
        %{
          code: "identity_include_invalid",
          message:
            "identity_include_invalid token=synthetic-message-secret safeSibling=preserve-this-value",
          diagnostic: diagnostic
        }
      )

    assert marker.denial_message =~ "safeSibling=preserve-this-value"
    refute marker.denial_message =~ "synthetic-message-secret"

    assert %{"kind" => "denial", "details" => details} = marker.denial_diagnostic
    assert marker.denial_diagnostic == diagnostic
    assert details["path"] == "includes/api_key=[REDACTED:secret_field]"
    assert details["apiKey"] == "[REDACTED:secret_field]"
    assert details["safeSibling"] == "preserve-this-value"
    assert %{"$type" => "truncated_string", "bytes" => 9_000} = details["longValue"]
    refute JSON.encode!(marker.denial_diagnostic) =~ "synthetic-secret"
    refute JSON.encode!(marker.denial_diagnostic) =~ "synthetic-field-secret"

    field_replay_call =
      identity_call(
        %{archetype: "default", content: "# this request would validate\n"},
        invocation
      )

    assert {:error, replay} = Dispatch.dispatch(ctx.db, handlers, field_replay_call)

    assert replay.code == "identity_include_invalid"
    assert replay.message == marker.denial_message
    assert replay.diagnostic == marker.denial_diagnostic
  end

  defp scenario(9, ctx) do
    Tightbeam.IdentityPublicationFixture.Diagnostics.record(:scenario_9_entered)
    invocation = "identity-denial-first-writer-race"
    live = git!(Path.join(ctx.base_dir, "identity"), ["rev-parse", "tightbeam/live"])
    fingerprint = String.duplicate("b", 64)

    diagnostics =
      ["first", "second"]
      |> Enum.map(fn path ->
        ErrorDiagnostic.new("denial", details: %{"path" => "#{path}.md", "safeSibling" => path})
      end)

    tasks =
      Enum.map(diagnostics, fn diagnostic ->
        Task.async(fn ->
          AdminProjection.deny_identity_validation(
            ctx.db,
            invocation,
            live,
            fingerprint,
            "user:flynn",
            "missing_fragment",
            %{
              code: "identity_include_invalid",
              message: "same first-writer message",
              diagnostic: diagnostic
            }
          )
        end)
      end)

    [{:ok, left}, {:ok, right}] = Enum.map(tasks, &Task.await(&1, 5_000))
    assert left.denial_code == right.denial_code
    assert left.denial_message == right.denial_message
    assert left.denial_diagnostic == right.denial_diagnostic
    assert left.denial_diagnostic in diagnostics

    assert %{denial_diagnostic: winner} =
             AdminProjection.identity_publication_marker(ctx.db, invocation, live)

    assert winner == left.denial_diagnostic
  end

  defp scenario(10, ctx) do
    handlers = Gateway.handlers(%{db: ctx.db, base_dir: ctx.base_dir})
    cli_token = "tbc_identity_publication_transport"

    router =
      Tightbeam.Wire.Router.init(
        db: ctx.db,
        base_dir: ctx.base_dir,
        handlers: handlers,
        cli_token: cli_token,
        session_status: fn _ -> nil end
      )

    key = "identity-public-denial-redaction"
    invocation = keyed_invocation("user:flynn", "identity-edit", key)
    secret_path = "api_key=synthetic-public-secret.md"

    first =
      post_identity_dispatch(router, cli_token, "flynn", %{
        "archetype" => "operating-model",
        "content" => "#include \"#{secret_path}\"\n",
        "idempotencyKey" => key
      })

    assert first.status == 400, first.resp_body

    assert %{
             "error" => %{
               "code" => "identity_include_invalid",
               "message" => message,
               "diagnostic" => %{"kind" => "denial", "details" => details} = diagnostic
             }
           } = first_body = JSON.decode!(first.resp_body)

    assert details["cause"] == "missing_fragment"
    assert details["line"] == 1
    assert is_binary(details["path"])
    refute first.resp_body =~ "synthetic-public-secret"

    marker = AdminProjection.identity_publication_marker_by_invocation(ctx.db, invocation)
    assert marker.denial_message == message
    assert marker.denial_diagnostic == diagnostic
    refute marker.denial_message =~ "synthetic-public-secret"
    refute JSON.encode!(marker.denial_diagnostic) =~ "synthetic-public-secret"

    replay =
      post_identity_dispatch(router, cli_token, "flynn", %{
        "archetype" => "default",
        "content" => "# valid after denial\n",
        "idempotencyKey" => key
      })

    assert replay.status == 400, replay.resp_body
    assert JSON.decode!(replay.resp_body) == first_body
  end

  defp post_identity_dispatch(router, cli_token, user_id, params) do
    Plug.Test.conn(
      :post,
      "/agent/dispatch",
      JSON.encode!(%{"verb" => "identity-edit", "asUser" => user_id, "params" => params})
    )
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> cli_token)
    |> Plug.Conn.put_req_header(
      "x-tightbeam-cli-version",
      Tightbeam.CliCompatibility.required_version()
    )
    |> Tightbeam.Wire.Router.call(router)
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

  def run!(tmp, scenario) do
    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "identity_publication_runtime.exs")

    diagnostic_path =
      if scenario == 9 do
        suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)
        path = Path.join(suite_tmp, "identity-publication-child-diagnostic.jsonl")
        _ = File.rm(path)
        requested = Path.join(suite_tmp, "identity-publication-diagnostic-requested")
        _ = File.rm(requested)
        File.write!(requested, "scenario_9\n")
        path
      end

    diagnostic_env =
      if diagnostic_path,
        do: [{"DD36_IDENTITY_PUBLICATION_DIAGNOSTIC_PATH", diagnostic_path}],
        else: []

    child_env = [{"DD36_SCENARIO", Integer.to_string(scenario)}] ++ diagnostic_env ++ env

    {output, status} =
      System.cmd(executable, args,
        env: child_env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)

    if scenario == 9 and status == 0 do
      assert_scenario_9_diagnostics!(diagnostic_path)
    end

    assert status == 0, output
    assert output =~ "identity_publication-case: #{scenario}: ok"
  end

  def run_controlled_stall!(tmp) do
    diagnostic_path = Path.join(tmp, "controlled-child-diagnostic.jsonl")

    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "identity_publication_runtime.exs")

    child_env =
      [
        {"DD36_IDENTITY_PUBLICATION_CONTROLLED_STALL", "1"},
        {"DD36_IDENTITY_PUBLICATION_DIAGNOSTIC_PATH", diagnostic_path}
      ] ++ env

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:env, Enum.map(child_env, &port_env/1)}
        ]
      )

    try do
      waiting_output =
        receive_until(port, "identity-publication-child: waiting for release", 15_000)

      assert waiting_output =~ "identity-publication-child: waiting for release"

      stalled_events = read_diagnostic_events(diagnostic_path)

      assert Enum.map(stalled_events, & &1["phase"]) == [
               "child_started",
               "runtime_ready",
               "controlled_child_stalled"
             ]

      stalled = List.last(stalled_events)
      assert stalled["output"] == "identity-publication-child: controlled_child_stalled"
      assert is_integer(stalled["timestamp_ms"])
      assert is_list(stalled["stack"]) and length(stalled["stack"]) <= 16
      assert File.stat!(diagnostic_path).size <= 24 * 1024

      true = Port.command(port, "release\n")
      released_output = receive_until(port, "identity-publication-child: released", 15_000)
      assert released_output =~ "identity-publication-child: released"
      assert_receive {^port, {:exit_status, 0}}, 15_000

      released_events = read_diagnostic_events(diagnostic_path)

      assert Enum.map(released_events, & &1["phase"]) == [
               "child_started",
               "runtime_ready",
               "controlled_child_stalled",
               "controlled_child_released"
             ]
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp port_env({name, nil}), do: {String.to_charlist(name), false}
  defp port_env({name, value}), do: {String.to_charlist(name), String.to_charlist(value)}

  defp read_diagnostic_events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp assert_scenario_9_diagnostics!(path) do
    events = read_diagnostic_events(path)

    assert Enum.map(events, & &1["phase"]) == [
             "child_started",
             "runtime_ready",
             "scenario_9_entered",
             "scenario_9_completed"
           ]

    assert Enum.all?(events, fn event ->
             is_binary(event["output"]) and is_integer(event["timestamp_ms"]) and
               is_list(event["stack"]) and length(event["stack"]) <= 16
           end)

    assert File.stat!(path).size <= 24 * 1024
  end

  defp receive_until(port, marker, timeout) do
    started = System.monotonic_time(:millisecond)
    receive_until(port, marker, timeout, started, "")
  end

  defp receive_until(port, marker, timeout, started, received) do
    remaining = max(timeout - (System.monotonic_time(:millisecond) - started), 0)

    receive do
      {^port, {:data, data}} ->
        combined = received <> data

        if String.contains?(combined, marker),
          do: combined,
          else: receive_until(port, marker, timeout, started, combined)

      {^port, {:exit_status, status}} ->
        flunk("identity publication child exited #{status} before output #{inspect(marker)}")
    after
      remaining -> flunk("identity publication child did not emit #{inspect(marker)}")
    end
  end

  defp start_supervised!(child, opts \\ []) do
    spec = Supervisor.child_spec(child, opts)
    {:ok, pid} = Supervisor.start_child(Process.get({__MODULE__, :supervisor}), spec)
    pid
  end

  defp stop_supervised!(id) do
    sup = Process.get({__MODULE__, :supervisor})
    :ok = Supervisor.terminate_child(sup, id)
    :ok = Supervisor.delete_child(sup, id)
  end
end
