defmodule Tightbeam.IdentityPublicationFixture do
  import ExUnit.Assertions

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

  def run_case!(scenario, base, locks) do
    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

    try do
      assert :ok = Schema.ensure_all(db)
      assert :ok = DB.assert_base_admitted!(db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))
      assert :initialized = Identity.init!(base)
      Archetypes.load!(base)
      Devices.add_user(db, "flynn", true)
      scenario(scenario, %{base_dir: base, db: db})
      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(db), do: GenServer.stop(db)
    end

    await_lock!(base, locks)
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

    {output, status} =
      System.cmd(executable, args,
        env: [{"DD36_SCENARIO", Integer.to_string(scenario)} | env],
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "identity_publication-case: #{scenario}: ok"
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

  defp await_lock!(base, locks, remaining \\ 100) do
    path = Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

    case Tightbeam.LiveBaseLock.acquire(path) do
      {:ok, lock} ->
        :ok = Tightbeam.LiveBaseLock.release(lock)

      {:error, :lock_busy} when remaining > 0 ->
        Process.sleep(10)
        await_lock!(base, locks, remaining - 1)

      other ->
        raise "fixture lock did not release: #{inspect(other)}"
    end
  end
end
