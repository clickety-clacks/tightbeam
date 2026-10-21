defmodule Tightbeam.TestCase do
  @moduledoc false

  # WAITING ON THINGS — read this before adding a sleep or a refute.
  #
  # `start_supervised!` is NOT a boot barrier for an adapter. `Acp.Adapter.init/1`
  # returns `{:ok, nil, {:continue, {:boot, opts}}}`, so it returns before `node`
  # is spawned and before the `initialize` round trip; anything sent to a fresh
  # adapter queues behind that boot.
  #
  # The sanctioned barriers, in order of preference. `assert_ready/2` (an
  # unbounded receive plus a death monitor, acp_adapter_test.exs) for adapter
  # boot. A `GenServer.call` into the target — including `:sys.get_state/1` —
  # when the thing you are waiting on is a `cast`: both are answered in mailbox
  # order, so the cast has RUN when the call returns.
  #
  # A fixed sleep before a `refute_receive`/`refute_received` is a false-pass
  # generator, not a budget: if the work has not started yet, the absence you
  # assert is the absence of a beginning. Make the racing side signal before it
  # acts, `assert_receive` that signal, then refute.
  #
  # A predicate-poll helper that returns `false` on exhaustion must be called
  # under `assert` — in statement position its timeout is silent, and the test
  # passes having proven nothing.
  #
  # Which SIDE the budget sits on decides how it fails, and the two are not
  # symmetric. A CHECK-side wait — how long you will watch for an effect —
  # under-detects: for effect time T and window W, T<W is observed and T>W is
  # missed, and load only raises T, so a longer check-side wait is never worse
  # (neither a written file nor a received message is reversible once it lands).
  # A SETUP-side budget is the dangerous one: it is the window the effect must
  # land INSIDE, so load closes it and the test suppresses nothing while still
  # going green. The case that established this: a kill test whose fixture slept
  # 2s, which at load 97 finished on its own before the kill arrived, so the test
  # passed having killed nothing. Give such a fixture a window load cannot close.
  # Do not "simplify" a widened check-side wait back down on a symmetry that does
  # not hold.

  use ExUnit.CaseTemplate

  @persistent_keys [
    Tightbeam.Rules,
    {Tightbeam.Rules, :policies},
    Tightbeam.RuleRuntime,
    Tightbeam.Rails,
    Tightbeam.Archetypes,
    {Tightbeam.Application, :draining}
  ]

  using do
    quote do
      import Tightbeam.TestCase,
        only: [
          register_hosts: 2,
          catalog_reply: 1,
          catalog_reply: 2,
          catalog_probe_harness: 1,
          ensure_all_schemas: 1,
          ensure_main_session: 2,
          stage_review_verdict: 2,
          stage_review_verdict: 3
        ]
    end
  end

  setup do
    assert_hermetic_tmp!()
    snapshot = snapshot()
    on_exit(fn -> restore(snapshot) end)

    Tightbeam.Rules.load!(
      Path.join(System.tmp_dir!(), "tightbeam-empty-rules-#{System.unique_integer([:positive])}"),
      []
    )

    # The ONE place the episode writer starts for tests. Not per-suite ceremony and
    # deliberately not lazy: call sites use the named process and a missing one is loud,
    # so a suite that evaluates a check-tier statute must find a real writer here rather
    # than silently conjuring one. Fresh per test, so ordering state never leaks between
    # them; suites that never touch rails just have an idle process.
    start_supervised!({Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes})

    # Same contract as the episode writer above: `Artifacts.record/2` reads the
    # named process, and an absent one degrades to a weaker evidence class rather
    # than failing loudly — so a suite that asserts `tool-call-observed` must find
    # a real writer here or it would silently be asserting the fallback.
    start_supervised!({Tightbeam.TurnObservations, name: Tightbeam.TurnObservations})

    :ok
  end

  @doc "Create the complete production schema for a unit-test database."
  def ensure_all_schemas(db) do
    :ok = Tightbeam.Schema.ensure_all(db)

    # The reviewed batching acceptance fixture was captured on main after the
    # users provenance column landed. The 0.1.9 product schema does not own that
    # unrelated feature, so expose only its harmless fixture column in tests.
    {:ok, columns} = Tightbeam.DB.query(db, "PRAGMA table_info(users)")

    if Enum.any?(columns, fn [_cid, name | _rest] -> name == "creationKind" end) do
      :ok
    else
      Tightbeam.DB.execute(
        db,
        "ALTER TABLE users ADD COLUMN creationKind TEXT NOT NULL DEFAULT 'legacy'"
      )
    end
  end

  @doc "Create the canonical self-parented Main fixture for an owner when absent."
  def ensure_main_session(db, owner) do
    key = Tightbeam.Org.personal_session_key(owner)

    case Tightbeam.Org.get(db, key) do
      nil ->
        Tightbeam.Org.create(db, %{
          session_key: key,
          display_name: "Main",
          kind: "main",
          is_built_in: true,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          harness: "claude",
          provider: "anthropic",
          model: Tightbeam.Model.new("fable"),
          host: "testhost"
        })

      %{kind: "main"} = session ->
        session

      session ->
        raise "invalid Main fixture for #{owner}: #{inspect(session)}"
    end
  end

  @doc """
  Register satellite hosts the way the product does.

  `assimilate` records a host through `Placement.register_host/3`, a row in the
  org DB's `hosts` table — the one host store. Tests used to inject
  `Application.put_env(:tightbeam, :hosts, …)`, a SECOND store that existed only
  because `TIGHTBEAM_HOSTS` did; both are gone. Beyond removing the duplication,
  this scopes host config to the test's own DB instead of global app env, so
  two tests can no longer see each other's hosts.

  This is assimilate's recording step, not the whole verb: the rest of it probes
  ssh and installs adapters on a real machine, which a test naming a fictional
  host cannot do.
  """
  def register_hosts(db, hosts) do
    # The registry is a table; a suite that registers hosts declares it.
    :ok = Tightbeam.Placement.ensure_schema(db)

    Enum.each(hosts, fn {name, config} ->
      {:ok, _entry} = Tightbeam.Placement.register_host(db, name, config)
    end)
  end

  @doc "Stage the production bindings required by a linked review conclusion fixture."
  def stage_review_verdict(db, call, opts \\ []) do
    params = call.params

    if params[:kind] == "verdict" and
         params[:verdict_kind] in ["reviewed-clean", "changes-requested"] do
      stage_linked_review_verdict(db, call, opts)
    else
      call
    end
  end

  defp stage_linked_review_verdict(db, call, opts) do
    assignment_id = call.params[:assignment_id]

    case Tightbeam.DB.query(
           db,
           """
           SELECT review.holderKey, review.reviewsAssignmentId,
                  rs.ownerUserId, ps.ownerUserId, review.workItemId, producer.workItemId
           FROM assignments review
           JOIN assignments producer ON producer.id=review.reviewsAssignmentId
           JOIN sessions rs ON rs.sessionKey=review.holderKey
           JOIN sessions ps ON ps.sessionKey=producer.holderKey
           WHERE review.id=?1
           """,
           [assignment_id]
         ) do
      {:ok, [[holder, producer_id, owner, owner, review_item, producer_item]]}
      when call.principal == {:session, holder} ->
        work_item_id = review_item || producer_item || "wi_#{Tightbeam.Id.uuid4()}"

        if is_nil(review_item) and is_nil(producer_item) do
          {:ok, _} =
            Tightbeam.DB.query(
              db,
              "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt) VALUES (?1,'review binding fixture',?2,'open',?2,1)",
              [work_item_id, owner]
            )
        end

        {:ok, _} =
          Tightbeam.DB.query(
            db,
            "UPDATE assignments SET workItemId=?1 WHERE id IN (?2,?3) AND workItemId IS NULL",
            [work_item_id, assignment_id, producer_id]
          )

        if (is_nil(review_item) or review_item == work_item_id) and
             (is_nil(producer_item) or producer_item == work_item_id) and
             work_item_owned_by?(db, work_item_id, owner) do
          bind_review_verdict(db, call, opts, holder, producer_id, owner, work_item_id)
        else
          call
        end

      _ ->
        call
    end
  end

  defp bind_review_verdict(db, call, opts, holder, producer_id, owner, work_item_id) do
    refs =
      case Tightbeam.DB.query(
             db,
             "SELECT commitRefs FROM assignment_commit_ref_corrections WHERE assignmentId=?1",
             [producer_id]
           ) do
        {:ok, [[encoded]]} ->
          JSON.decode!(encoded)

        {:ok, []} ->
          refs = call.params[:commit_refs] || opts[:commit_refs] || fixture_review_refs()
          refs = native_fixture_refs(refs)
          artifact_id = "art_#{System.unique_integer([:positive])}"

          {:ok, _} =
            Tightbeam.DB.query(
              db,
              """
              INSERT INTO artifacts
                (artifactId,kind,title,createdBySession,workItemId,producedByAssignmentId,
                 originPath,contentSha256,state,createdAt,updatedAt)
              VALUES (?1,'report','review binding evidence',?2,?3,?4,?1,?5,'in-workspace',1,1)
              """,
              [
                artifact_id,
                holder,
                work_item_id,
                call.params.assignment_id,
                fixture_hash(artifact_id)
              ]
            )

          {:ok, _} =
            Tightbeam.DB.query(
              db,
              """
              INSERT INTO assignment_commit_ref_corrections
                (id,assignmentId,commitRefs,reason,evidenceArtifactId,actorKind,actorRef,cause,
                 idempotencyKey,requestFingerprint,verifiedAt,createdAt)
              VALUES (?1,?2,?3,'review binding fixture',?4,'user',?5,
                      'historical_canonical_commitref_correction',?1,?6,1,1)
              """,
              [
                "crc_#{Tightbeam.Id.uuid4()}",
                producer_id,
                JSON.encode!(refs),
                artifact_id,
                owner,
                String.duplicate("a", 64)
              ]
            )

          refs
      end

    report_id = "art_#{System.unique_integer([:positive])}"
    hash = fixture_hash(report_id)

    {:ok, _} =
      Tightbeam.DB.query(
        db,
        """
        INSERT INTO artifacts
          (artifactId,kind,title,createdBySession,workItemId,producedByAssignmentId,
           originPath,contentSha256,state,createdAt,updatedAt)
        VALUES (?1,'report','review report fixture',?2,?3,?4,?1,?5,'in-workspace',1,1)
        """,
        [report_id, holder, work_item_id, call.params.assignment_id, hash]
      )

    %{
      call
      | params:
          call.params
          |> Map.put(:artifact_id, report_id)
          |> Map.put(:content_sha256, hash)
          |> Map.put(:commit_refs, refs)
    }
  end

  defp work_item_owned_by?(db, work_item_id, owner) do
    match?(
      {:ok, [[1]]},
      Tightbeam.DB.query(
        db,
        "SELECT 1 FROM work_items WHERE id=?1 AND ownerUserId=?2",
        [work_item_id, owner]
      )
    )
  end

  defp native_fixture_refs(refs) do
    Enum.map(refs, fn ref ->
      ref = Map.new(ref, fn {key, value} -> {to_string(key), value} end)

      ref
      |> Map.put_new("remote", "test://#{ref["repo"]}")
      |> Map.put_new("ref", "refs/heads/main")
    end)
  end

  defp fixture_review_refs do
    [
      %{
        "repo" => "#{Tightbeam.Placement.local_host_name()}:#{File.cwd!()}",
        "commit" => String.duplicate("a", 40)
      }
    ]
  end

  defp fixture_hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc """
  Wrap a catalog body the way the probe's shell hands it back.

  Both harness catalogs are now one HTTPS call made BY the host that owns the
  credential, so a test supplies a RESPONSE, not a file. curl cannot return a
  status any other way than printing it, so it rides on a trailing line, with
  whatever the probe learned on that host after it — for codex, the `codex
  --version` that decided which models the server would even list.
  """
  def catalog_reply(body, status \\ 200)
  def catalog_reply(body, status), do: {body <> "\n#{status} 0.145.0", 0}

  @doc "Which harness a captured catalog-probe argv belongs to."
  def catalog_probe_harness(argv) do
    if argv |> List.last() |> String.contains?("api.anthropic.com"),
      do: :claude,
      else: :codex
  end

  # Per-test scratch dirs are named with System.unique_integer/1, which is unique
  # only within one BEAM. They stay collision-free because config/test.exs points
  # TMPDIR at a per-BEAM root. If that root goes missing, System.tmp_dir!/0 falls
  # back to the shared /tmp, concurrent `mix test` processes mint the same scratch
  # names, and each one's rm_rf cleanup deletes fixtures another is still using —
  # which reads as a passing assertion over an absent file, not as a failure.
  defp assert_hermetic_tmp! do
    suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)
    actual = System.tmp_dir!()

    if actual != suite_tmp do
      raise "test tmp root is not hermetic: expected #{suite_tmp}, got #{actual}"
    end
  end

  @doc false
  def snapshot do
    %{
      application: Map.new(Application.get_all_env(:tightbeam)),
      persistent: Map.new(@persistent_keys, &{&1, persistent_value(&1)}),
      system: System.get_env()
    }
  end

  @doc false
  def restore(snapshot) do
    restore_application(snapshot.application)
    restore_persistent(snapshot.persistent)
    restore_system(snapshot.system)
  end

  defp persistent_value(key) do
    sentinel = make_ref()

    case :persistent_term.get(key, sentinel) do
      ^sentinel -> :absent
      value -> {:present, value}
    end
  end

  defp restore_application(expected) do
    current = Map.new(Application.get_all_env(:tightbeam))

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> Application.put_env(:tightbeam, key, value)
        {:error, {:ok, _value}} -> Application.delete_env(:tightbeam, key)
        {:error, :error} -> :ok
      end
    end)
  end

  defp restore_persistent(expected) do
    Enum.each(expected, fn {key, expected_value} ->
      case {expected_value, persistent_value(key)} do
        {value, value} -> :ok
        {:absent, _current} -> :persistent_term.erase(key)
        {{:present, value}, _current} -> :persistent_term.put(key, value)
      end
    end)
  end

  defp restore_system(expected) do
    current = System.get_env()

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> System.put_env(key, value)
        {:error, {:ok, _value}} -> System.delete_env(key)
        {:error, :error} -> :ok
      end
    end)
  end
end
