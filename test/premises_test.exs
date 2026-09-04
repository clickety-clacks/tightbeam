defmodule Tightbeam.PremisesTest do
  @moduledoc """
  The specimen these tests reproduce: a surrender note asserted that a path did
  not exist, the assertion was true only of a stale clone, and the decision
  chain quoted the prose as proof and converted it into a durable hold.

  Every test below is deterministic — no clock, no network, no shell. That is
  the point: this module records what a verifier observed and derives state
  from those rows, so its whole behaviour is a function of its inputs.
  """

  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Premises, Schema}

  @now 1_000_000

  setup do
    name = :"premises_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Schema.ensure_all(name)
    %{db: name}
  end

  test "a claim is immutable and its checks are append only", %{db: db} do
    claim = declare(db)
    {:ok, check} = record(db, claim, result: "passed", observed_source_version: "sha-a")

    assert {:error, %DB.Error{message: message}} =
             DB.query(db, "UPDATE premise_claims SET predicate='other' WHERE claimId=?1", [claim])

    assert message =~ "premise_claims_immutable"

    assert {:error, %DB.Error{message: message}} =
             DB.query(db, "DELETE FROM premise_claims WHERE claimId=?1", [claim])

    assert message =~ "premise_claims_immutable"

    assert {:error, %DB.Error{message: message}} =
             DB.query(db, "UPDATE premise_checks SET result='refuted' WHERE checkId=?1", [check])

    assert message =~ "premise_checks_append_only"

    assert {:error, %DB.Error{message: message}} =
             DB.query(db, "DELETE FROM premise_checks WHERE checkId=?1", [check])

    assert message =~ "premise_checks_append_only"

    assert {:ok, [["passed", "sha-a"]]} =
             DB.query(
               db,
               "SELECT result, observedSourceVersion FROM premise_checks WHERE checkId=?1",
               [check]
             )
  end

  test "an incoherent check and an off-census park kind are unrepresentable", %{db: db} do
    claim = declare(db)

    # `unknown` never carries an observed version, and never omits its error
    # class: the spec's "do not call the premise false" is a column constraint
    # here, not a convention a later caller can forget.
    assert {:error, %DB.Error{}} =
             raw_check(db, claim, result: "unknown", observed: "sha-a", error_class: "timeout")

    assert {:error, %DB.Error{}} =
             raw_check(db, claim, result: "unknown", observed: nil, error_class: nil)

    # A terminal result never omits the version it was taken at, because the
    # effect boundary compares against exactly that value.
    assert {:error, %DB.Error{}} =
             raw_check(db, claim, result: "passed", observed: nil, error_class: nil)

    assert {:error, %DB.Error{}} =
             raw_check(db, claim, result: "passed", observed: "sha-a", error_class: "timeout")

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM premise_checks")

    assert {:error, %DB.Error{}} =
             DB.query(
               db,
               """
               INSERT INTO park_premises (parkKind,parkId,claimId,policy,linkedBy,linkedAt)
               VALUES ('work_item_icebox','wi_1',?1,'all','agent:x',1)
               """,
               [claim]
             )

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM park_premises")
  end

  test "a replayed observation is reused and an outage observed twice is two observations",
       %{db: db} do
    claim = declare(db)

    {:ok, first} = record(db, claim, result: "passed", observed_source_version: "sha-a")

    assert {:ok, :reused, ^first} =
             record(db, claim, result: "passed", observed_source_version: "sha-a")

    # Same immutable source, different purpose: a distinct observation, because
    # the idempotency key names the purpose it was taken for.
    {:ok, second} =
      record(db, claim,
        result: "passed",
        observed_source_version: "sha-a",
        purpose: "park-effect"
      )

    assert second != first

    {:ok, outage_one} = record(db, claim, result: "unknown", error_class: "timeout")
    {:ok, outage_two} = record(db, claim, result: "unknown", error_class: "timeout")
    assert outage_one != outage_two

    assert {:ok, [[4]]} = DB.query(db, "SELECT COUNT(*) FROM premise_checks")
  end

  test "state is derived from the newest check against what the claim expected", %{db: db} do
    claim = declare(db)
    assert {:unchecked, _} = Premises.premise_state(db, claim, @now)

    {:ok, _} =
      record(db, claim, result: "refuted", observed_source_version: "sha-a", checked_at: @now - 1)

    assert {:refuted, %{observed_source_version: "sha-a"}} =
             Premises.premise_state(db, claim, @now)

    # The source moved and the claim now holds. Every checkedAt below is
    # explicit: two observations sharing a millisecond would order on an
    # opaque id, and a test whose answer depends on that is not deterministic.
    {:ok, _} = record(db, claim, result: "passed", observed_source_version: "sha-b")

    assert {:passed, %{observed_source_version: "sha-b"}} =
             Premises.premise_state(db, claim, @now)

    # An absence claim expects a refuting observation. `passed` is the claim
    # holding, never the verifier's raw exit status.
    absence = declare(db, expected_result: "refuted", predicate: "path is absent at HEAD")

    {:ok, _} =
      record(db, absence,
        result: "refuted",
        observed_source_version: "sha-a",
        checked_at: @now - 1
      )

    assert {:passed, %{observed_source_version: "sha-a"}} =
             Premises.premise_state(db, absence, @now)

    {:ok, _} = record(db, absence, result: "passed", observed_source_version: "sha-b")

    assert {:refuted, %{observed_source_version: "sha-b"}} =
             Premises.premise_state(db, absence, @now)
  end

  test "a passing check past its expiry degrades and never passes", %{db: db} do
    claim = declare(db)

    {:ok, _} =
      record(db, claim,
        result: "passed",
        observed_source_version: "sha-a",
        checked_at: @now - 10,
        expires_at: @now - 1
      )

    assert {:expired, %{expired_at: expiry}} = Premises.premise_state(db, claim, @now)
    assert expiry == @now - 1
    assert {:passed, _} = Premises.premise_state(db, claim, @now - 5)

    link(db, "operator_dr", "dr_expiring", [claim])

    assert {:refused, :verification_degraded, %{claim_id: ^claim}} =
             Premises.park_admission(db, "operator_dr", "dr_expiring", now: @now)
  end

  test "an unlinked park is legacy untyped, and a new typed park refuses without a premise",
       %{db: db} do
    # A pre-feature park carries prose and no link. Nothing reads the prose,
    # nothing classifies it, and its admission is exactly what it was before.
    assert {:ok, :legacy_untyped} =
             Premises.park_admission(db, "surrender_dependent", "att_historical", now: @now)

    assert {:refused, :premise_required, %{}} =
             Premises.park_admission(db, "surrender_dependent", "att_new",
               now: @now,
               typed_premise_required?: true
             )

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM premise_claims")
  end

  test "a refuted premise cannot park, and the reported shape is the worst one present",
       %{db: db} do
    refuted = declare(db, predicate: "path exists at HEAD")
    unchecked = declare(db, predicate: "row is in the terminal state")

    {:ok, _} = record(db, refuted, result: "refuted", observed_source_version: "sha-a")
    link(db, "statute_escalation_dr", "dr_specimen", [refuted, unchecked])

    assert {:refused, :refuted, %{claim_id: ^refuted, observed_source_version: "sha-a"}} =
             Premises.park_admission(db, "statute_escalation_dr", "dr_specimen", now: @now)

    # The refutation stays durable. It is recorded, the park is inert, and no
    # row is rewritten to make the history read differently.
    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM premise_checks WHERE claimId=?1", [refuted])
  end

  test "an outage before a first pass is required, and after one is degraded", %{db: db} do
    fresh = declare(db)
    proven = declare(db)

    {:ok, _} = record(db, fresh, result: "unknown", error_class: "dns_failure")
    link(db, "condition_wake", "w_fresh", [fresh])

    assert {:refused, :verification_required, %{error_class: "dns_failure"}} =
             Premises.park_admission(db, "condition_wake", "w_fresh", now: @now)

    {:ok, _} =
      record(db, proven,
        result: "passed",
        observed_source_version: "sha-a",
        checked_at: @now - 10
      )

    {:ok, _} = record(db, proven, result: "unknown", error_class: "auth_failure")
    link(db, "condition_wake", "w_proven", [proven])

    assert {:refused, :verification_degraded, %{error_class: "auth_failure"}} =
             Premises.park_admission(db, "condition_wake", "w_proven", now: @now)
  end

  test "a non-checkable judgment claim stays explicit and is never machine passed", %{db: db} do
    claim = declare(db, verifier_type: "judgment", predicate: "this approach is unsound")
    assert {:unverified, %{verifier_type: "judgment"}} = Premises.premise_state(db, claim, @now)

    # Even a recorded passing observation cannot promote it. Whoever wrote that
    # row was not a mechanical verifier of this predicate.
    {:ok, _} = record(db, claim, result: "passed", observed_source_version: "sha-a")
    assert {:unverified, _} = Premises.premise_state(db, claim, @now)

    link(db, "operator_ruling", "dr_judgment", [claim])

    assert {:refused, :unverified, %{claim_id: ^claim}} =
             Premises.park_admission(db, "operator_ruling", "dr_judgment", now: @now)
  end

  test "the source version read at the effect boundary refuses a stale check", %{db: db} do
    claim = declare(db)
    {:ok, _} = record(db, claim, result: "passed", observed_source_version: "sha-a")
    link(db, "effort_dr", "dr_race", [claim])

    assert {:ok, :passed} =
             Premises.park_admission(db, "effort_dr", "dr_race",
               now: @now,
               observed_source_versions: %{claim => "sha-a"}
             )

    # The source moved between the check and the effect. The check is rejected,
    # one idempotent recheck is owed, and nothing is applied.
    assert {:refused, :premise_stale, detail} =
             Premises.park_admission(db, "effort_dr", "dr_race",
               now: @now,
               observed_source_versions: %{claim => "sha-b"}
             )

    assert detail.checked_source_version == "sha-a"
    assert detail.observed_source_version == "sha-b"

    # The recheck at the new version is one new observation, and the replay of
    # it writes nothing.
    {:ok, recheck} =
      record(db, claim, result: "passed", observed_source_version: "sha-b", checked_at: @now + 1)

    assert {:ok, :reused, ^recheck} =
             record(db, claim,
               result: "passed",
               observed_source_version: "sha-b",
               checked_at: @now + 1
             )

    assert {:ok, :passed} =
             Premises.park_admission(db, "effort_dr", "dr_race",
               now: @now,
               observed_source_versions: %{claim => "sha-b"}
             )
  end

  test "admission reads inside the effect transaction, and survives a restart unchanged",
       %{db: db} do
    claim = declare(db)
    {:ok, _} = record(db, claim, result: "passed", observed_source_version: "sha-a")
    link(db, "work_blocked_fact", "fact_boundary", [claim])

    # The effect boundary must read the links, the checks, and the version in
    # the same transaction that lands the effect.
    assert {:ok, {:refused, :premise_stale, _}} =
             DB.transaction(db, fn txn ->
               Premises.park_admission(txn, "work_blocked_fact", "fact_boundary",
                 now: @now,
                 observed_source_versions: %{claim => "sha-b"}
               )
             end)

    assert {:ok, {:ok, :passed}} =
             DB.transaction(db, fn txn ->
               Premises.park_admission(txn, "work_blocked_fact", "fact_boundary",
                 now: @now,
                 observed_source_versions: %{claim => "sha-a"}
               )
             end)

    # Nothing about the verdict is cached, so a fresh reader of the same rows
    # derives the same answer. This is the restart case: state is a function of
    # the rows, and the rows are all that survive.
    assert {:ok, :passed} =
             Premises.park_admission(db, "work_blocked_fact", "fact_boundary",
               now: @now,
               observed_source_versions: %{claim => "sha-a"}
             )
  end

  test "linking the same claim twice is one link, and a park needs every claim", %{db: db} do
    first = declare(db)
    second = declare(db)

    link(db, "operator_dr", "dr_all", [first, second])
    link(db, "operator_dr", "dr_all", [first])

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT COUNT(*) FROM park_premises WHERE parkId='dr_all'")

    {:ok, _} = record(db, first, result: "passed", observed_source_version: "sha-a")

    assert {:refused, :verification_required, %{claim_id: ^second}} =
             Premises.park_admission(db, "operator_dr", "dr_all", now: @now)

    {:ok, _} = record(db, second, result: "passed", observed_source_version: "sha-b")

    assert {:ok, :passed} = Premises.park_admission(db, "operator_dr", "dr_all", now: @now)
  end

  defp declare(db, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          declared_by: "agent:coder",
          subject_kind: "attest",
          subject_id: "att_specimen",
          verifier_type: "git-ref-path",
          verifier_version: "gitref-1",
          canonical_source: "github:clickety-clacks/tightbeam#main",
          predicate: "lib/tightbeam/premises.ex exists at HEAD",
          expected_result: "passed",
          sensitivity: "public",
          created_at: 1
        },
        Map.new(overrides)
      )

    {:ok, claim_id} = Premises.declare_claim(db, attrs)
    claim_id
  end

  defp record(db, claim_id, overrides) do
    attrs =
      Map.merge(
        %{
          claim_id: claim_id,
          purpose: "dr-raise",
          checked_at: @now,
          runner: "host:eezo",
          verifier_version: "gitref-1"
        },
        Map.new(overrides)
      )

    Premises.record_check(db, attrs)
  end

  defp raw_check(db, claim_id, opts) do
    DB.query(
      db,
      """
      INSERT INTO premise_checks
        (checkId, claimId, purpose, result, observedSourceVersion, checkedAt,
         runner, verifierVersion, errorClass)
      VALUES (?1,?2,'dr-raise',?3,?4,1,'host:eezo','gitref-1',?5)
      """,
      [
        "pck_raw_#{System.unique_integer([:positive])}",
        claim_id,
        Keyword.fetch!(opts, :result),
        Keyword.fetch!(opts, :observed),
        Keyword.fetch!(opts, :error_class)
      ]
    )
  end

  defp link(db, park_kind, park_id, claim_ids) do
    :ok =
      Premises.link_park(db, park_kind, park_id, claim_ids, %{
        linked_by: "agent:coder",
        linked_at: 1
      })
  end
end
