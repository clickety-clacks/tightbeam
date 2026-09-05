defmodule Tightbeam.Premises do
  @moduledoc """
  Typed premise claims, their observed checks, and the park links that depend
  on them.

  A park is any mechanism that can stop advancement. Before this module a park
  could rest on a free-text factual assertion — the specimen was a surrender
  note naming a path that a stale clone lacked, which the decision chain then
  quoted as proof and converted into a durable hold. Nothing in the schema
  carried the difference between "a mind asserted this" and "a verifier
  observed this."

  THIS MODULE RECORDS OBSERVATIONS AND DERIVES STATE. IT RUNS NO VERIFIER.
  The substrate never judges (CLAUDE.md philosophy gate 1): a verifier owned by
  the source's host records what it saw with `record_check/2`, and
  `park_admission/4` derives admissibility from those rows. There is no shell
  execution, no network call, and no prose parsing here, and there must never
  be one — the stored `predicate` and `canonicalSource` are typed data rendered
  for humans, never an executable authority.

  Three shapes, and the reason each is separate:

    * `premise_claims` — IMMUTABLE. What a mind declared, and against which
      canonical source it may be checked. Enforced by trigger, not by prose.
    * `premise_checks` — APPEND-ONLY. What a verifier observed, once, at a
      version. A ruling records what a user CHOSE; a check records what a
      verifier SAW. A ruling never converts `refuted` or `unknown` into
      `passed`, which is why the two never share a row.
    * `park_premises` — which park-effect row depends on which claims, under a
      Boolean policy (`all` only, initially).

  `premiseState` is DERIVED from the newest admissible check every time it is
  asked (`premise_state/3`). It is never stored, because a stored verdict is a
  cache that outlives the observation it summarizes — exactly the failure this
  mechanism exists to stop.

  ## Legacy parks

  A park with no `park_premises` rows is `:legacy_untyped`. It is admitted
  unchanged. Pre-feature parks are not reclassified, their prose is not parsed,
  and closed historical rows are never touched. A caller authoring a NEW
  premise-bearing park passes `typed_premise_required?: true` and receives
  `{:refused, :premise_required}` instead — the substrate names the class, the
  client owns the policy of when to demand one.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Id

  @claim_prefix "pc_"
  @check_prefix "pck_"

  # The owned objects of this shape, in creation order. One list serves both
  # paths a table can arrive by: a fresh database creates them through
  # `ensure_schema/1`, and an existing one activates the SAME text through the
  # additive migration in `Tightbeam.Schema`, which validates each object's
  # stored DDL against this list. Two hand-kept copies of a CREATE statement
  # drift, and the drift only shows up as a refusal on somebody else's boot.
  @objects [
    %{
      type: "table",
      name: "premise_claims",
      sql: """
      CREATE TABLE IF NOT EXISTS premise_claims (
        claimId         TEXT PRIMARY KEY,
        declaredBy      TEXT NOT NULL,
        subjectKind     TEXT NOT NULL CHECK (subjectKind IN (
          'attest','decision_request','assignment','wake','condition_fact','work_item'
        )),
        subjectId       TEXT NOT NULL,
        verifierType    TEXT NOT NULL CHECK (verifierType IN (
          'git-ref-path','git-ref-contains','content-sha256','substrate-row',
          'http-versioned','capability-probe','judgment'
        )),
        verifierVersion TEXT NOT NULL,
        canonicalSource TEXT NOT NULL,
        predicate       TEXT NOT NULL,
        expectedResult  TEXT NOT NULL CHECK (expectedResult IN ('passed','refuted')),
        sensitivity     TEXT NOT NULL CHECK (sensitivity IN ('public','restricted','secret')),
        createdAt       INTEGER NOT NULL CHECK (createdAt >= 0)
      )
      """
    },
    %{
      type: "index",
      name: "premise_claims_subject",
      sql: """
      CREATE INDEX IF NOT EXISTS premise_claims_subject
        ON premise_claims (subjectKind, subjectId)
      """
    },
    %{
      type: "table",
      name: "premise_checks",
      sql: """
      CREATE TABLE IF NOT EXISTS premise_checks (
        checkId               TEXT PRIMARY KEY,
        claimId               TEXT NOT NULL REFERENCES premise_claims(claimId),
        purpose               TEXT NOT NULL CHECK (purpose IN (
          'attest','dr-raise','ruling','park-effect','patrol'
        )),
        result                TEXT NOT NULL CHECK (result IN ('passed','refuted','unknown')),
        observedSourceVersion TEXT,
        checkedAt             INTEGER NOT NULL CHECK (checkedAt >= 0),
        durationMs            INTEGER CHECK (durationMs IS NULL OR durationMs >= 0),
        runner                TEXT NOT NULL,
        verifierVersion       TEXT NOT NULL,
        summary               TEXT,
        rawOutputDigest       TEXT,
        errorClass            TEXT,
        expiresAt             INTEGER CHECK (expiresAt IS NULL OR expiresAt >= 0),
        CHECK (
          (result = 'unknown' AND errorClass IS NOT NULL AND observedSourceVersion IS NULL)
          OR
          (result IN ('passed','refuted') AND errorClass IS NULL
           AND observedSourceVersion IS NOT NULL)
        )
      )
      """
    },
    %{
      type: "index",
      name: "premise_checks_newest",
      sql: """
      CREATE INDEX IF NOT EXISTS premise_checks_newest
        ON premise_checks (claimId, checkedAt, checkId)
      """
    },
    %{
      type: "index",
      name: "premise_checks_idempotency",
      sql: """
      CREATE UNIQUE INDEX IF NOT EXISTS premise_checks_idempotency
        ON premise_checks (claimId, verifierVersion, observedSourceVersion, purpose)
      """
    },
    %{
      type: "table",
      name: "park_premises",
      sql: """
      CREATE TABLE IF NOT EXISTS park_premises (
        parkKind TEXT NOT NULL CHECK (parkKind IN (
          'surrender_dependent','operator_dr','operator_ruling','statute_escalation_dr',
          'effort_dr','condition_wake','work_blocked_fact','patrol_hold'
        )),
        parkId   TEXT NOT NULL,
        claimId  TEXT NOT NULL REFERENCES premise_claims(claimId),
        policy   TEXT NOT NULL CHECK (policy = 'all'),
        linkedBy TEXT NOT NULL,
        linkedAt INTEGER NOT NULL CHECK (linkedAt >= 0),
        PRIMARY KEY (parkKind, parkId, claimId)
      )
      """
    },
    %{
      type: "index",
      name: "park_premises_claim",
      sql: """
      CREATE INDEX IF NOT EXISTS park_premises_claim
        ON park_premises (claimId)
      """
    },
    %{
      type: "trigger",
      name: "premise_claims_immutable_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS premise_claims_immutable_update
      BEFORE UPDATE ON premise_claims
      BEGIN
        SELECT RAISE(ABORT, 'premise_claims_immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "premise_claims_immutable_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS premise_claims_immutable_delete
      BEFORE DELETE ON premise_claims
      BEGIN
        SELECT RAISE(ABORT, 'premise_claims_immutable');
      END
      """
    },
    %{
      type: "trigger",
      name: "premise_checks_append_only_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS premise_checks_append_only_update
      BEFORE UPDATE ON premise_checks
      BEGIN
        SELECT RAISE(ABORT, 'premise_checks_append_only');
      END
      """
    },
    %{
      type: "trigger",
      name: "premise_checks_append_only_delete",
      sql: """
      CREATE TRIGGER IF NOT EXISTS premise_checks_append_only_delete
      BEFORE DELETE ON premise_checks
      BEGIN
        SELECT RAISE(ABORT, 'premise_checks_append_only');
      END
      """
    },
    %{
      type: "trigger",
      name: "park_premises_immutable_update",
      sql: """
      CREATE TRIGGER IF NOT EXISTS park_premises_immutable_update
      BEFORE UPDATE ON park_premises
      BEGIN
        SELECT RAISE(ABORT, 'park_premises_immutable');
      END
      """
    }
  ]

  @ddl Enum.map_join(@objects, ";\n", & &1.sql) <> ";\n"

  @doc """
  The owned objects of this shape, in creation order, for the additive
  migration in `Tightbeam.Schema`.
  """
  @spec owned_objects() :: [%{type: String.t(), name: String.t(), sql: String.t()}]
  def owned_objects, do: @objects

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    DB.execute(db, @ddl)
  end

  @doc """
  Declare one immutable premise claim.

  The declaring mind identifies the load-bearing claim and its canonical
  source. Declaration alone parks nothing and proves nothing.
  """
  @spec declare_claim(DB.server(), map()) :: {:ok, String.t()}
  def declare_claim(db, attrs) do
    claim_id = @claim_prefix <> Id.uuid4()

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO premise_claims
          (claimId, declaredBy, subjectKind, subjectId, verifierType, verifierVersion,
           canonicalSource, predicate, expectedResult, sensitivity, createdAt)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
        """,
        [
          claim_id,
          Map.fetch!(attrs, :declared_by),
          Map.fetch!(attrs, :subject_kind),
          Map.fetch!(attrs, :subject_id),
          Map.fetch!(attrs, :verifier_type),
          Map.fetch!(attrs, :verifier_version),
          Map.fetch!(attrs, :canonical_source),
          Map.fetch!(attrs, :predicate),
          Map.fetch!(attrs, :expected_result),
          Map.fetch!(attrs, :sensitivity),
          Map.fetch!(attrs, :created_at)
        ]
      )

    {:ok, claim_id}
  end

  @doc """
  Record one observation against a claim.

  Idempotent on `(claimId, verifierVersion, observedSourceVersion, purpose)`:
  a replay of the same observation returns `{:ok, :reused, checkId}` and writes
  nothing. `unknown` results carry no observed source version by construction,
  so SQLite's NULL-distinct index never collapses two of them — an outage
  observed twice IS two observations, and pretending otherwise would let one
  stale error class stand in for a source that has since come back.
  """
  @spec record_check(DB.server(), map()) :: {:ok, String.t()} | {:ok, :reused, String.t()}
  def record_check(db, attrs) do
    claim_id = Map.fetch!(attrs, :claim_id)
    verifier_version = Map.fetch!(attrs, :verifier_version)
    observed = Map.get(attrs, :observed_source_version)
    purpose = Map.fetch!(attrs, :purpose)

    case existing_check(db, claim_id, verifier_version, observed, purpose) do
      nil ->
        check_id = @check_prefix <> Id.uuid4()

        {:ok, _} =
          DB.query(
            db,
            """
            INSERT INTO premise_checks
              (checkId, claimId, purpose, result, observedSourceVersion, checkedAt,
               durationMs, runner, verifierVersion, summary, rawOutputDigest,
               errorClass, expiresAt)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
            """,
            [
              check_id,
              claim_id,
              purpose,
              Map.fetch!(attrs, :result),
              observed,
              Map.fetch!(attrs, :checked_at),
              Map.get(attrs, :duration_ms),
              Map.fetch!(attrs, :runner),
              verifier_version,
              Map.get(attrs, :summary),
              Map.get(attrs, :raw_output_digest),
              Map.get(attrs, :error_class),
              Map.get(attrs, :expires_at)
            ]
          )

        {:ok, check_id}

      check_id ->
        {:ok, :reused, check_id}
    end
  end

  defp existing_check(_db, _claim_id, _verifier_version, nil, _purpose), do: nil

  defp existing_check(db, claim_id, verifier_version, observed, purpose) do
    case rows(
           db,
           """
           SELECT checkId FROM premise_checks
           WHERE claimId = ?1 AND verifierVersion = ?2
             AND observedSourceVersion = ?3 AND purpose = ?4
           """,
           [claim_id, verifier_version, observed, purpose]
         ) do
      [[check_id]] -> check_id
      [] -> nil
    end
  end

  @doc """
  Link a park-effect row to the claims it depends on, under policy `all`.

  Linking is what makes a park premise-bearing. A superseding request does not
  inherit evidence by prose similarity: it links the exact claim id again only
  when predicate, canonical source, and verifier version still match, and
  otherwise declares a new claim.
  """
  @spec link_park(DB.server(), String.t(), String.t(), [String.t()], map()) :: :ok
  def link_park(db, park_kind, park_id, claim_ids, attrs) do
    linked_by = Map.fetch!(attrs, :linked_by)
    linked_at = Map.fetch!(attrs, :linked_at)
    policy = Map.get(attrs, :policy, "all")

    Enum.each(claim_ids, fn claim_id ->
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT OR IGNORE INTO park_premises
            (parkKind, parkId, claimId, policy, linkedBy, linkedAt)
          VALUES (?1,?2,?3,?4,?5,?6)
          """,
          [park_kind, park_id, claim_id, policy, linked_by, linked_at]
        )
    end)

    :ok
  end

  @doc """
  Derive one claim's state from its newest admissible check.

  Returns `{state, detail}` where state is one of `:unchecked`, `:passed`,
  `:refuted`, `:unknown`, `:expired`, or `:unverified`, and detail carries the
  observed source version and error class the caller must show.

  `:passed` means the newest check's result MATCHES what the claim expected —
  a claim that expects `refuted` (an absence claim) is satisfied by a refuting
  observation, and a passing one refutes it.
  """
  @spec premise_state(DB.server() | Txn.t(), String.t(), integer()) :: {atom(), map()}
  def premise_state(db, claim_id, now) do
    case rows(
           db,
           "SELECT verifierType, expectedResult FROM premise_claims WHERE claimId = ?1",
           [claim_id]
         ) do
      [] ->
        {:unchecked, %{}}

      [["judgment", _expected]] ->
        # Not mechanically checkable, and deliberately so. It stays explicit and
        # under human policy authority; it can never be machine-passed.
        {:unverified, %{verifier_type: "judgment"}}

      [[_verifier_type, expected]] ->
        newest_check_state(db, claim_id, expected, now)
    end
  end

  defp newest_check_state(db, claim_id, expected, now) do
    case rows(
           db,
           """
           SELECT result, observedSourceVersion, errorClass, expiresAt
           FROM premise_checks INDEXED BY premise_checks_newest
           WHERE claimId = ?1
           ORDER BY checkedAt DESC, checkId DESC LIMIT 1
           """,
           [claim_id]
         ) do
      [] ->
        {:unchecked, %{ever_passed: ever_passed?(db, claim_id, expected)}}

      [["unknown", _observed, error_class, _expires_at]] ->
        {:unknown, %{error_class: error_class, ever_passed: ever_passed?(db, claim_id, expected)}}

      [[result, observed, _error_class, expires_at]] when result == expected ->
        if is_integer(expires_at) and expires_at <= now do
          {:expired, %{observed_source_version: observed, expired_at: expires_at}}
        else
          {:passed, %{observed_source_version: observed}}
        end

      [[_result, observed, _error_class, _expires_at]] ->
        {:refuted, %{observed_source_version: observed}}
    end
  end

  defp ever_passed?(db, claim_id, expected) do
    rows(
      db,
      "SELECT 1 FROM premise_checks WHERE claimId = ?1 AND result = ?2 LIMIT 1",
      [claim_id, expected]
    ) != []
  end

  # Worst-first. The shape a caller reports is the most severe one present, so
  # a park holding one refuted claim and one merely stale claim reads as
  # refuted, not as a retryable staleness.
  @refusal_precedence [
    :refuted,
    :unverified,
    :premise_stale,
    :verification_required,
    :verification_degraded
  ]

  @doc """
  Derive whether a park effect may land.

  Options:

    * `:now` — required, epoch ms, the instant expiry is judged against.
    * `:typed_premise_required?` — the caller is authoring a NEW
      premise-bearing park, so an unlinked park is `:premise_required` rather
      than `:legacy_untyped`. Defaults to `false`.
    * `:observed_source_versions` — a `claimId => version` map of what the
      caller observes RIGHT NOW at the effect boundary. Any claim whose passing
      check was taken at a different version is `:premise_stale`: the check is
      rejected, one idempotent recheck is owed, and nothing is applied. This is
      the CAS that closes the check-to-effect race, and it is the caller's job
      to read the version inside the same transaction as the effect.

  Returns `{:ok, :legacy_untyped}`, `{:ok, :passed}`, or `{:refused, shape,
  detail}` where shape is one of `:premise_required`, `:refuted`,
  `:unverified`, `:premise_stale`, `:verification_required`, or
  `:verification_degraded`.
  """
  @spec park_admission(DB.server() | Txn.t(), String.t(), String.t(), keyword()) ::
          {:ok, :legacy_untyped | :passed} | {:refused, atom(), map()}
  def park_admission(db, park_kind, park_id, opts) do
    now = Keyword.fetch!(opts, :now)
    observed = Keyword.get(opts, :observed_source_versions, %{})

    links =
      rows(
        db,
        "SELECT claimId FROM park_premises WHERE parkKind = ?1 AND parkId = ?2 ORDER BY claimId",
        [park_kind, park_id]
      )

    case links do
      [] ->
        if Keyword.get(opts, :typed_premise_required?, false) do
          {:refused, :premise_required, %{}}
        else
          {:ok, :legacy_untyped}
        end

      links ->
        links
        |> Enum.map(fn [claim_id] -> {claim_id, premise_state(db, claim_id, now)} end)
        |> Enum.map(fn {claim_id, state} -> refusal(claim_id, state, observed) end)
        |> Enum.reject(&is_nil/1)
        |> worst()
    end
  end

  defp refusal(claim_id, {:passed, detail}, observed) do
    case Map.fetch(observed, claim_id) do
      {:ok, current} ->
        if current == detail.observed_source_version do
          nil
        else
          {:premise_stale,
           %{
             claim_id: claim_id,
             checked_source_version: detail.observed_source_version,
             observed_source_version: current
           }}
        end

      :error ->
        nil
    end
  end

  defp refusal(claim_id, {:refuted, detail}, _observed),
    do: {:refuted, Map.put(detail, :claim_id, claim_id)}

  defp refusal(claim_id, {:unverified, detail}, _observed),
    do: {:unverified, Map.put(detail, :claim_id, claim_id)}

  # An outage on a claim that has never passed is a park that was never
  # justified: `verification_required`, with an owner and a deadline the caller
  # sets. An outage on one that HAS passed is a previously justified safety
  # hold going dark: `verification_degraded`, which keeps the hold and demands
  # a bounded owner path rather than silently resuming hazardous work.
  defp refusal(claim_id, {:unknown, detail}, _observed) do
    shape = if detail.ever_passed, do: :verification_degraded, else: :verification_required
    {shape, Map.put(detail, :claim_id, claim_id)}
  end

  defp refusal(claim_id, {:expired, detail}, _observed),
    do: {:verification_degraded, Map.put(detail, :claim_id, claim_id)}

  defp refusal(claim_id, {:unchecked, detail}, _observed),
    do: {:verification_required, Map.put(detail, :claim_id, claim_id)}

  defp worst([]), do: {:ok, :passed}

  defp worst(refusals) do
    {shape, detail} =
      Enum.min_by(refusals, fn {shape, _detail} ->
        Enum.find_index(@refusal_precedence, &(&1 == shape))
      end)

    {:refused, shape, detail}
  end

  # One read path, two callers: an ordinary server read, and the act-time read
  # inside the transaction that lands the effect. The effect boundary MUST use
  # the transaction form — a version read outside the effect's transaction is
  # a value that can change before it is used, which is the race this gate
  # exists to close.
  defp rows(%Txn{} = txn, sql, params), do: Txn.q(txn, sql, params)

  defp rows(db, sql, params) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end
end
