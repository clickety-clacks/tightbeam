defmodule Tightbeam.Wakes do
  @moduledoc """
  Persistent wake store + scheduler (TS reference: src/core/wakes.ts — its
  test file is the acceptance oracle). A wake is a fact-shaped, durable
  "deliver this prompt to this session at dueAt" row; delivery goes through
  the SAME turn pipeline as a user post (T8: coordination is fact-shaped).

  Process shape: ONE GenServer (`Tightbeam.WakeScheduler` in the tree) owning
  a tick timer. Every tick (and on explicit `fire_due/1`) it reads due
  pending wakes. Legacy timed wakes DELIVER and then mark fired — wakes.ts
  order, load-bearing:
  - deliver raises → wake stays pending, retried next tick (at-least-once;
    a poison wake retries visibly rather than vanishing).
  - crash between deliver and mark → redelivered after restart, deduped by
    the turns table's `wakeId` UNIQUE (enqueue is exactly-once).
  Marking fired BEFORE delivering would silently lose the wake on a crash in
  between — never reorder this legacy path. Condition/fallback wakes instead
  use a single CAS-gated transaction that atomically marks and enqueues.

  States: pending → fired | canceled. Every new cancellation is one typed,
  attributed transition. Public callers retain the scheduling-origin guard;
  the closed substrate process set uses the same mutation seam without it.
  """

  use GenServer
  require Logger

  alias Tightbeam.{
    ConditionFacts,
    DB,
    Escalation,
    EventLog,
    Gateway,
    NoticeBatcher,
    RuleRuntime
  }

  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()

  @type wake :: %{
          wake_id: String.t(),
          session_key: String.t(),
          target_role: String.t() | nil,
          origin: String.t(),
          prompt: String.t() | nil,
          consumer: String.t(),
          due_at: integer(),
          state: String.t(),
          created_at: integer(),
          fired_at: integer() | nil,
          condition_kind: String.t() | nil,
          condition_scope: String.t() | nil,
          condition_after_id: integer() | nil,
          fired_by: String.t() | nil,
          creator_session_key: String.t() | nil,
          rumination: boolean(),
          work_item_id: String.t() | nil,
          target_gate: integer(),
          reresolve: String.t() | nil,
          reresolve_seed: String.t() | nil,
          reresolve_rung: integer() | nil,
          class: String.t() | nil,
          class_election: String.t() | nil,
          delivery_rule: String.t() | nil,
          digest: boolean(),
          summon: boolean(),
          owner_user_id: String.t() | nil,
          obligation_ref: String.t() | nil,
          wait_mode: String.t() | nil,
          predicate: map() | nil,
          resolver_kind: String.t() | nil,
          resolver_id: String.t() | nil,
          resolver_holder: String.t() | nil,
          resolver_addressee: String.t() | nil,
          necessity: String.t() | nil,
          verification_assignment_id: String.t() | nil,
          verification_holder_key: String.t() | nil,
          selected_policy_name: String.t() | nil,
          verification_state: String.t() | nil,
          verification_attest_id: String.t() | nil,
          verification_notice_wake_id: String.t() | nil,
          originating_turn_seq: integer() | nil,
          recognition_at: integer() | nil,
          recognition_path: String.t() | nil,
          recognition_reason: String.t() | nil,
          recognition_evidence: map() | nil,
          recognition_disposition: String.t() | nil,
          recognition_transition: map() | nil
        }

  @typedoc "Delivery fun injected by the composition root: fires the prompt into the turn pipeline."
  @type deliver :: (wake() -> any())

  @type cancellation_result ::
          false | true | {:accepted_in_txn, pos_integer(), %{canceled: true}}

  @ddl """
  CREATE TABLE IF NOT EXISTS wakes (
    wakeId     TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL,
    targetRole TEXT,
    origin     TEXT NOT NULL,
    prompt     TEXT,
    consumer   TEXT NOT NULL DEFAULT 'prompt',
    dueAt      INTEGER NOT NULL,
    state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','fired','canceled')),
    createdAt  INTEGER NOT NULL,
    firedAt    INTEGER,
    reresolve  TEXT NULL CHECK (reresolve IN ('lineage')),
    reresolveSeed TEXT NULL,
    reresolveRung INTEGER NULL,
    conditionKind TEXT NULL,
    conditionScope TEXT NULL,
    conditionAfterId INTEGER NULL,
    firedBy TEXT NULL CHECK (firedBy IN ('condition','fallback')),
    creatorSessionKey TEXT NULL,
    rumination INTEGER NOT NULL DEFAULT 0,
    work_item_id TEXT,
    assignmentId TEXT,
    canceledAt INTEGER,
    targetGate INTEGER NOT NULL DEFAULT 1,
    -- COORDINATION CLASS (fabric §7). Deliberately UNCONSTRAINED: the five seed
    -- names are ANATOMY, and a kungfu may extend the vocabulary freely, so a
    -- CHECK here would make an org's own extension a substrate refusal — a cage.
    -- What the substrate owes is the truth of what the sender said; an extension
    -- the receiver has no mapping for is delivered as `fyi` with a named skew
    -- row (§5 policy-skew rule), never dropped and never promoted.
    class TEXT,
    -- WHO elected the class. The classifier stamps ONLY unclassified traffic
    -- (§5); this column is the proof it never overwrote a sender. A digest
    -- CARRIER is attributed 'batcher' — it was built by the batcher, not
    -- elected by any sender or the classifier, and claiming 'sender' here
    -- would be an untrue audit fact (Sol xhigh review, finding 7). Members
    -- keep their own true election; only the carrier row uses this value.
    -- `'batcher'` is a SHAPE change (schema.ex's `@shape` bumped to
    -- `coordination-fabric-classes-v2`, Sol xhigh review round 2, finding 2):
    -- `CREATE TABLE IF NOT EXISTS` cannot widen this CHECK on a table that
    -- already exists, so a database from the OLD shape is refused by name
    -- rather than dying on a raw CHECK violation at the first carrier insert.
    classElection TEXT CHECK (classElection IN ('sender','classifier','batcher')),
    -- SIGNED PROVENANCE (§8 legibility): the named rule + revision that decided
    -- THIS wake's delivery, so any agent knows which reflex to inhibit.
    deliveryRule TEXT,
    -- 1 = this wake IS a digest carrier; 0 = an ordinary wake (possibly a
    -- digest MEMBER, which the wake_cancellations replacement row records).
    digest INTEGER NOT NULL DEFAULT 0 CHECK (digest IN (0,1)),
    -- The desk's deliberate spend of its principal's turn (fabric §Terms).
    -- Sender-elected, NEVER substrate-inferred; the acceptance-№1 query (§11.1)
    -- subtracts these, and both its windows must run the SAME query, so the
    -- carrier ships in Phase 1 even though Phase 3 stands up the first desk.
    summon INTEGER NOT NULL DEFAULT 0 CHECK (summon IN (0,1)),
    ownerUserId TEXT NULL,
    obligationRef TEXT NULL,
    waitMode TEXT NULL CHECK (waitMode IN ('dependency','after-turn')),
    predicate TEXT NULL,
    resolverKind TEXT NULL CHECK (resolverKind IN ('assignment','decision_request')),
    resolverId TEXT NULL,
    resolverHolder TEXT NULL,
    resolverAddressee TEXT NULL,
    necessity TEXT NULL,
    verificationAssignmentId TEXT NULL,
    verificationHolderKey TEXT NULL,
    selectedPolicyName TEXT NULL,
    verificationState TEXT NULL CHECK (verificationState IN ('provisional','confirmed','challenged')),
    verificationAttestId TEXT NULL,
    verificationNoticeWakeId TEXT NULL REFERENCES wakes(wakeId),
    originatingTurnSeq INTEGER NULL,
    recognitionAt INTEGER NULL,
    recognitionPath TEXT NULL CHECK (recognitionPath IN ('success','reconsideration','fallback','after-turn')),
    recognitionReason TEXT NULL CHECK (recognitionReason IN ('resolver-terminal','verification-challenged','verification-terminal')),
    recognitionEvidence TEXT NULL,
    recognitionDisposition TEXT NULL,
    recognitionTransition TEXT NULL,
    CHECK (consumer != 'prompt' OR prompt IS NOT NULL),
    CHECK ((class IS NULL) = (classElection IS NULL)),
    CHECK (digest = 0 OR class IS NOT NULL)
  );
  CREATE INDEX IF NOT EXISTS wakes_due ON wakes (state, dueAt);
  CREATE INDEX IF NOT EXISTS wakes_delivery ON wakes (state, deliveryRule, sessionKey, class);
  CREATE TABLE IF NOT EXISTS scheduler_state (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    afterFact INTEGER NOT NULL DEFAULT 0
  );
  INSERT OR IGNORE INTO scheduler_state (id, afterFact) VALUES (0, 0);
  CREATE INDEX IF NOT EXISTS wakes_condition ON wakes (state, conditionKind, conditionScope);
  CREATE INDEX IF NOT EXISTS wakes_wait_recognition
    ON wakes (state, waitMode, ownerUserId, recognitionAt, dueAt);
  CREATE TABLE IF NOT EXISTS wake_retry_attempts (
    wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
    rootWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
    predecessorWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
    attempt INTEGER NOT NULL CHECK (attempt >= 0),
    sourceTurnSeq INTEGER UNIQUE REFERENCES turns(seq),
    outcome TEXT NOT NULL CHECK (outcome IN ('pending','failed','acted','canceled')),
    retryWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
    observedAt INTEGER NOT NULL,
    UNIQUE (rootWakeId, attempt)
  );
  CREATE INDEX IF NOT EXISTS wake_retry_root
    ON wake_retry_attempts (rootWakeId, attempt);
  """

  @retry_base_ms 30_000
  @retry_ceiling_ms 30 * 60_000

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    with :ok <- DB.execute(db, @ddl) do
      if RuleRuntime.loaded?(), do: activate_wait_recognition(db), else: :ok
    end
  end

  @doc false
  @spec activate_wait_recognition(db()) :: :ok
  def activate_wait_recognition(db) do
    true = RuleRuntime.loaded?()
    {:ok, :ok} = DB.transaction(db, &activate_wait_recognition_in_txn/1)
    :ok
  end

  defp activate_wait_recognition_in_txn(%Txn{conn: conn}) do
    Process.put({__MODULE__, :wait_recognition_ready, conn}, true)
    :ok
  end

  defp wait_recognition_ready?(%Txn{conn: conn}),
    do: Process.get({__MODULE__, :wait_recognition_ready, conn}, false)

  ## Delivery policy (coordination-fabric-v1 §5 `classifier` + `batcher`, §7 table)
  #
  # THE MAXIM: a wake's class decides WHEN a mind's turn is spent, never WHETHER
  # the message is recorded (Law 2). Every row below lands durably at its own
  # `schedule_in_txn`; batching only moves the moment the turn materializes, and
  # every batched delivery exits on TIME or a TURN BOUNDARY — never on anyone's
  # decision (Invariant 3).
  #
  # LAYER. The mechanism — stamp a class, look up an immediacy, enforce a
  # ceiling, sign the result — is PHYSICS. The names and the numbers are
  # ANATOMY: seed defaults, verbatim from §7's table, reshapeable by an org
  # through the identity tree. Phase 6 lifts them into policy rows; until a row
  # exists these hardcoded defaults are the fallback (§5). Nothing here judges
  # the CONTENT of a message — the sender elects, the substrate obeys.
  #
  # §7's immediacy column reads "desk exists / no desk". No desk exists on this
  # line (Phase 3 stands up the first one), so the NO-DESK column governs every
  # row below, and each is annotated with the phrase it implements.

  @doc "The class the classifier stamps on unclassified traffic (fabric §5 seed default)."
  @spec classifier_default() :: String.t()
  def classifier_default, do: "fyi"

  @doc "The five seed-shipped base classes (fabric §7). A kungfu may extend past these."
  @spec seed_classes() :: [String.t()]
  def seed_classes, do: ~w(fyi status-query input-needed blocker algedonic)

  # Rule revision. Bump when a rule's BEHAVIOUR changes, so a digest signed by
  # the old revision stays honest about which reflex produced it.
  @rules_rev "r1"

  @digest_rule "notice-batching-v1 r1"
  @legacy_digest_rule "turn-boundary-digest r1"
  @immediate_rule "immediate-delivery #{@rules_rev}"
  @bypass_rule "algedonic-bypass #{@rules_rev}"
  @inhibited_rule "batcher-inhibited #{@rules_rev}"

  @minute 60_000
  @hour 3_600_000

  @class_policy %{
    # "digest at next turn boundary / same" — ceiling 4 h.
    "fyi" => %{immediacy: :digest, ceiling_ms: 4 * @hour},
    # "rows answer (Phase 5), else parent" — no responder exists yet, so the
    # target still receives it; the 30-minute ceiling is what §7 pins.
    "status-query" => %{immediacy: :digest, ceiling_ms: 30 * @minute},
    # "principal at next turn boundary" — ceiling is the avasarala floor.
    "input-needed" => %{immediacy: :digest, ceiling_ms: 30 * @minute},
    # "principal immediately". NO CEILING (O7): `immediate`/`bypass` classes
    # never pass through the ceiling arithmetic (`apply_delivery_policy`'s
    # ceiling branch only runs for `policy.immediacy == :digest`), so `0` here
    # was inert but FALSE — a datum nobody read today that a future Phase 6
    # policy-extraction pass could still lift and publish as "blocker's
    # ceiling is zero," which is not what §7 says (no ceiling governs an
    # immediate/bypass delivery at all). `nil` is the honest value: there is
    # no ceiling to report.
    "blocker" => %{immediacy: :immediate, ceiling_ms: nil},
    # "bypasses every bone and every desk. Never batched, never digested."
    #
    # PARTIAL AGAINST §7, and named rather than papered over: the seed default
    # routes an alarm to the principal AND the org's configured human channel.
    # The bypass half ships here. The dual-routing half does NOT — there is no
    # human-channel carrier on this line to route to, and inventing one inside
    # the batching seam would be a routing decision smuggled in under a timing
    # mechanism. An alarm reaches its target and skips every bone; it does not
    # yet reach a human by a second path.
    "algedonic" => %{immediacy: :bypass, ceiling_ms: nil}
  }

  @doc """
  Stamp a class on inbound traffic (fabric §5 `classifier`).

  Returns `{class, election}`. A sender's election is returned VERBATIM and is
  NEVER overwritten — including an extended class this build has never heard of,
  which the policy below maps down to `fyi` while the row keeps what was said.
  """
  @spec classify(String.t() | nil) :: {String.t(), String.t()}
  def classify(elected) when is_binary(elected) and elected != "", do: {elected, "sender"}
  def classify(_unclassified), do: {classifier_default(), "classifier"}

  @doc """
  The delivery policy for a class (fabric §7 seed table).

  An unknown class takes `fyi`'s policy and reports `skew: true` — the §5
  policy-skew rule: never dropped (Law 2), never promoted to immediate, and the
  caller files a named skew row so the vocabulary gap is visible and repairable.
  """
  @spec delivery_policy(String.t()) :: %{
          immediacy: :digest | :immediate | :bypass,
          ceiling_ms: non_neg_integer() | nil,
          rule: String.t(),
          skew: boolean()
        }
  def delivery_policy(class) when is_binary(class) do
    case Map.fetch(@class_policy, class) do
      {:ok, policy} -> Map.merge(policy, %{rule: rule_for(policy.immediacy), skew: false})
      :error -> known_policy_for_skew()
    end
  end

  defp known_policy_for_skew do
    policy = Map.fetch!(@class_policy, classifier_default())
    Map.merge(policy, %{rule: rule_for(policy.immediacy), skew: true})
  end

  defp rule_for(:digest), do: @digest_rule
  defp rule_for(:immediate), do: @immediate_rule
  defp rule_for(:bypass), do: @bypass_rule

  @doc "The signature line a digest carries (fabric §8: every bone signs its work)."
  @spec digest_signature(non_neg_integer()) :: String.t()
  def digest_signature(count), do: digest_signature(@digest_rule, count)

  defp digest_signature(rule, count) do
    "coalesced by #{rule} (#{count} #{if count == 1, do: "notice", else: "notices"})"
  end

  @doc false
  @spec digest_rule() :: String.t()
  def digest_rule, do: @digest_rule

  @doc false
  @spec inhibited_rule() :: String.t()
  def inhibited_rule, do: @inhibited_rule

  ## Store (pure DB ops — callable without the scheduler process, e.g. by inspect)

  @doc "Persist a pending wake (id minted here, prefix `w_`). Returns the row."
  @spec schedule(db(), %{
          session_key: String.t(),
          target_role: String.t() | nil,
          origin: String.t(),
          prompt: String.t(),
          due_at: integer()
        }) :: wake()
  def schedule(db \\ Tightbeam.DB, input) do
    transaction!(db, &schedule_in_txn(&1, input))
  end

  @doc """
  Persist a pending wake inside an existing DB transaction.

  CLASSED TRAFFIC. When the input carries `:class` (or `:classify` to request the
  classifier's stamp on unclassified traffic), the delivery policy above decides
  the wake's `dueAt` and signs the row with the rule that decided it. The
  BATCHER's inhibition seam is named and small: a caller that elected its own
  delivery time (`:sender_scheduled`), a condition wake, a digest carrier, or a
  non-prompt consumer is stamped `batcher-inhibited` and keeps the `due_at` it
  was given. The class is still recorded either way — timing is shaped, truth
  is not.
  """
  @spec schedule_in_txn(Txn.t(), map()) :: wake()
  def schedule_in_txn(%Txn{} = txn, input) do
    condition_kind = Map.get(input, :condition_kind)

    owner_user_id =
      Map.get(input, :owner_user_id) || authenticated_wake_owner_in_txn(txn, input.session_key)

    condition_after_id =
      if is_binary(condition_kind) do
        [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
        cursor
      end

    created_at = now()
    {class, class_election} = elected_class(input)

    {delivery_rule, due_at} =
      apply_delivery_policy(txn, input, class, created_at, condition_kind)

    wake = %{
      wake_id: Map.get(input, :wake_id, "w_" <> Tightbeam.Id.uuid4()),
      session_key: Map.fetch!(input, :session_key),
      target_role: Map.get(input, :target_role),
      origin: Map.fetch!(input, :origin),
      prompt: Map.get(input, :prompt),
      consumer: Map.get(input, :consumer, "prompt"),
      due_at: due_at,
      state: "pending",
      created_at: created_at,
      fired_at: nil,
      condition_kind: condition_kind,
      condition_scope: Map.get(input, :condition_scope),
      condition_after_id: condition_after_id,
      fired_by: nil,
      creator_session_key: Map.get(input, :creator_session_key),
      rumination: Map.get(input, :rumination, false),
      work_item_id: Map.get(input, :work_item_id),
      assignment_id: Map.get(input, :assignment_id),
      canceled_at: nil,
      # Delivery discriminator: 1 (default) keeps the active-session gate every
      # existing nil-role prompt wake has; 0 delivers to the recorded sessionKey
      # unconditionally (decision notifications).
      target_gate: Map.get(input, :target_gate, 1),
      reresolve: Map.get(input, :reresolve),
      reresolve_seed: Map.get(input, :reresolve_seed),
      reresolve_rung: Map.get(input, :reresolve_rung),
      class: class,
      class_election: class_election,
      delivery_rule: delivery_rule,
      digest: Map.get(input, :digest, false),
      summon: Map.get(input, :summon, false),
      owner_user_id: owner_user_id,
      obligation_ref: Map.get(input, :obligation_ref),
      wait_mode: Map.get(input, :wait_mode),
      predicate: Map.get(input, :predicate),
      resolver_kind: Map.get(input, :resolver_kind),
      resolver_id: Map.get(input, :resolver_id),
      resolver_holder: Map.get(input, :resolver_holder),
      resolver_addressee: Map.get(input, :resolver_addressee),
      necessity: Map.get(input, :necessity),
      verification_assignment_id: Map.get(input, :verification_assignment_id),
      verification_holder_key: Map.get(input, :verification_holder_key),
      selected_policy_name: Map.get(input, :selected_policy_name),
      verification_state: Map.get(input, :verification_state),
      verification_attest_id: Map.get(input, :verification_attest_id),
      verification_notice_wake_id: Map.get(input, :verification_notice_wake_id),
      originating_turn_seq: Map.get(input, :originating_turn_seq),
      recognition_at: Map.get(input, :recognition_at),
      recognition_path: Map.get(input, :recognition_path),
      recognition_reason: Map.get(input, :recognition_reason),
      recognition_evidence: Map.get(input, :recognition_evidence),
      recognition_disposition: Map.get(input, :recognition_disposition),
      recognition_transition: Map.get(input, :recognition_transition)
    }

    Txn.q(
      txn,
      """
        INSERT INTO wakes
          (wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state, createdAt, firedAt,
           reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope,
           conditionAfterId, firedBy, creatorSessionKey, rumination, work_item_id, assignmentId,
           targetGate, class, classElection, deliveryRule, digest, summon,
           ownerUserId, obligationRef, waitMode, predicate, resolverKind, resolverId,
           resolverHolder, resolverAddressee, necessity, verificationAssignmentId,
           verificationHolderKey, selectedPolicyName, verificationState, verificationAttestId,
           verificationNoticeWakeId, originatingTurnSeq, recognitionAt, recognitionPath,
           recognitionReason, recognitionEvidence, recognitionDisposition, recognitionTransition)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', ?8, NULL, ?9, ?10, ?11,
                ?12, ?13, ?14, NULL, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24,
                ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32, ?33, ?34, ?35, ?36, ?37,
                ?38, ?39, ?40, ?41, ?42, ?43, ?44, ?45, ?46)
      """,
      [
        wake.wake_id,
        wake.session_key,
        wake.target_role,
        wake.origin,
        wake.prompt,
        wake.consumer,
        wake.due_at,
        wake.created_at,
        wake.reresolve,
        wake.reresolve_seed,
        wake.reresolve_rung,
        wake.condition_kind,
        wake.condition_scope,
        wake.condition_after_id,
        wake.creator_session_key,
        if(wake.rumination, do: 1, else: 0),
        wake.work_item_id,
        wake.assignment_id,
        wake.target_gate,
        wake.class,
        wake.class_election,
        wake.delivery_rule,
        if(wake.digest, do: 1, else: 0),
        if(wake.summon, do: 1, else: 0),
        wake.owner_user_id,
        wake.obligation_ref,
        wake.wait_mode,
        encode_optional(wake.predicate),
        wake.resolver_kind,
        wake.resolver_id,
        wake.resolver_holder,
        wake.resolver_addressee,
        wake.necessity,
        wake.verification_assignment_id,
        wake.verification_holder_key,
        wake.selected_policy_name,
        wake.verification_state,
        wake.verification_attest_id,
        wake.verification_notice_wake_id,
        wake.originating_turn_seq,
        wake.recognition_at,
        wake.recognition_path,
        wake.recognition_reason,
        encode_optional(wake.recognition_evidence),
        wake.recognition_disposition,
        encode_optional(wake.recognition_transition)
      ]
    )

    if is_binary(condition_kind) do
      EventLog.lifecycle_in_txn(
        txn,
        "wake_condition_scheduled",
        wake.wake_id,
        "kind=#{condition_kind} scope=#{wake.condition_scope || "nil"} fallbackAt=#{wake.due_at} origin=#{wake.origin}"
      )
    end

    file_policy_skew(txn, wake)

    if v1_batch_source?(wake) do
      policy_ref = NoticeBatcher.record_policy_in_txn(txn, wake, enabled: true)

      case NoticeBatcher.enqueue_or_recover_in_txn(txn, wake.wake_id, policy_ref) do
        %{member_id: _, batch_id: _} ->
          wake

        {:bypass, refusal} ->
          bypass_v1_batching_in_txn(txn, wake, policy_ref, refusal)

        {:error, refusal} ->
          raise "notice batching admission refused: #{inspect(refusal)}"
      end
    else
      wake
    end
  end

  @doc "Register one obligation-scoped dependency or after-turn continuation atomically."
  @spec register_wait_in_txn(Txn.t(), map()) :: wake() | {:error, map()}
  def register_wait_in_txn(%Txn{} = txn, input) do
    with :ok <- validate_wait_input(input),
         {:ok, obligation} <- wait_obligation_in_txn(txn, input),
         :ok <- wait_registrant_allowed(txn, input, obligation),
         :ok <- wait_target_allowed(input, obligation),
         :ok <- recheck_wait_admission_in_txn(txn, input) do
      if Map.get(input, :after_turn) do
        register_after_turn_in_txn(txn, input, obligation)
      else
        register_dependency_in_txn(txn, input, obligation)
      end
    end
  end

  defp recheck_wait_admission_in_txn(txn, input) do
    call = %{
      verb: "wake",
      origin: input.origin,
      principal: {:session, input.registrant_session_key},
      params: input
    }

    case RuleRuntime.recheck_admission_in_txn(txn, call) do
      :ok -> :ok
      {:deny, error} -> {:error, error}
    end
  end

  defp validate_wait_input(input) do
    predicate? = is_map(input[:predicate])
    after_turn? = input[:after_turn] == true

    valid =
      is_binary(input[:session_key]) and input.session_key != "" and
        is_binary(input[:origin]) and input.origin != "" and
        is_binary(input[:prompt]) and input.prompt != "" and
        is_binary(input[:assignment_id]) and input.assignment_id != "" and
        is_binary(input[:registrant_session_key]) and input.registrant_session_key != "" and
        is_binary(input[:owner_user_id]) and input.owner_user_id != "" and
        (is_nil(input[:target_role]) or
           (is_binary(input.target_role) and input.target_role != "")) and
        predicate? != after_turn? and (after_turn? or is_integer(input[:due_at]))

    if valid,
      do: :ok,
      else: wait_error("invalid_wait", "invalid dependency or after-turn wake registration")
  end

  defp register_after_turn_in_txn(txn, input, obligation) do
    case running_turn_seq_in_txn(txn, input.registrant_session_key) do
      nil ->
        wait_error("no_running_turn", "--after-turn requires the registrant's running turn")

      turn_seq ->
        now = now()

        wake =
          schedule_in_txn(txn, %{
            session_key: input.session_key,
            target_role: input[:target_role],
            origin: input.origin,
            prompt: input.prompt,
            due_at: now,
            creator_session_key: input.registrant_session_key,
            assignment_id: obligation.id,
            owner_user_id: obligation.owner_user_id,
            obligation_ref: obligation.id,
            wait_mode: "after-turn",
            originating_turn_seq: turn_seq,
            recognition_at: now,
            recognition_path: "after-turn",
            recognition_evidence: %{
              label: "registration-snapshot",
              observed: %{status: "running"},
              eligible_after: "originating-turn-terminal"
            },
            recognition_transition: %{
              label: "registration-snapshot",
              domain: "turn",
              row_id: turn_seq,
              observed: %{status: "running"}
            }
          })

        admit_continuation_in_txn(txn, wake)
    end
  end

  defp register_dependency_in_txn(txn, input, obligation) do
    with {:ok, declaration} <- normalize_dependency_declaration(input[:predicate]),
         {:ok, _contracts} <- dependency_contracts(declaration.conditions),
         declaration <- capture_condition_cursor_in_txn(txn, declaration),
         {:ok, resolver} <-
           resolver_in_txn(txn, declaration.resolver_ref, obligation.owner_user_id),
         {:ok, verifier} <-
           verification_assignment_in_txn(
             txn,
             declaration.verification_ref,
             obligation.owner_user_id
           ),
         {:ok, selected} <- verification_policy_in_txn(txn, obligation, verifier),
         {:ok, evaluation} <-
           RuleRuntime.evaluate_predicate_in_txn(txn, %{
             owner_user_id: obligation.owner_user_id,
             conditions: declaration.conditions,
             bindings: declaration.bindings
           }) do
      :ok = activate_wait_recognition_in_txn(txn)
      turn_seq = running_turn_seq_in_txn(txn, input.registrant_session_key)

      wake =
        schedule_in_txn(txn, %{
          session_key: input.session_key,
          target_role: input[:target_role],
          origin: input.origin,
          prompt: input.prompt,
          due_at: input.due_at,
          creator_session_key: input.registrant_session_key,
          assignment_id: obligation.id,
          owner_user_id: obligation.owner_user_id,
          obligation_ref: obligation.id,
          wait_mode: "dependency",
          predicate: evaluation.canonical,
          resolver_kind: resolver.kind,
          resolver_id: resolver.id,
          resolver_holder: resolver.holder,
          resolver_addressee: resolver.addressee,
          necessity: declaration.necessity,
          verification_assignment_id: verifier.id,
          verification_holder_key: verifier.holder_key,
          selected_policy_name: selected.name,
          verification_state: "provisional",
          originating_turn_seq: turn_seq
        })

      wake = recognize_from_snapshot_in_txn(txn, wake, evaluation, resolver, nil)
      admit_continuation_in_txn(txn, wake)
      reconcile_wait_relief_in_txn(txn, obligation.id, wake.created_at)

      if is_nil(wake.recognition_path) do
        verifier_wake = schedule_verifier_notice_in_txn(txn, wake, verifier)

        Txn.q(
          txn,
          "UPDATE wakes SET verificationNoticeWakeId=?2 WHERE wakeId=?1 AND verificationNoticeWakeId IS NULL",
          [wake.wake_id, verifier_wake.wake_id]
        )

        %{wake | verification_notice_wake_id: verifier_wake.wake_id}
      else
        wake
      end
    end
  end

  defp admit_continuation_in_txn(txn, wake) do
    Txn.q(
      txn,
      """
      INSERT INTO supervision_liveness_sidecar
        (wakeId,assignmentId,controllerOrigin,controllerState)
      VALUES (?1,?2,'holder_continuation','pending')
      """,
      [wake.wake_id, wake.assignment_id]
    )

    wake
  end

  @doc false
  def covering_continuation_in_txn?(%Txn{} = txn, assignment_id) do
    qualifying_wait_in_txn?(txn, assignment_id, "wait-prod-coverage")
  end

  defp reconcile_wait_relief_in_txn(txn, assignment_id, at) do
    case Txn.q(
           txn,
           "SELECT 1 FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed' LIMIT 1",
           [assignment_id]
         ) do
      [] ->
        :ok

      [[1]] ->
        qualifies = effort_relief_in_txn?(txn, assignment_id)
        RuleRuntime.apply_wait_relief_in_txn(txn, assignment_id, at, qualifies)
    end
  end

  @doc false
  def effort_relief_in_txn?(%Txn{} = txn, assignment_id) do
    qualifying_wait_in_txn?(txn, assignment_id, "wait-effort-relief")
  end

  # Candidate selection does not confer qualification. Both purposes use the
  # same checked snapshot, then the common Rules policy evaluator.
  defp qualifying_wait_in_txn?(txn, assignment_id, purpose) do
    Txn.q(
      txn,
      """
      SELECT w.wakeId FROM wakes w
      JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
        AND s.assignmentId=w.assignmentId AND s.controllerOrigin='holder_continuation'
      WHERE w.assignmentId=?1 AND w.obligationRef=?1
        AND ((w.state='pending' AND s.controllerState='pending') OR
             (w.state='fired' AND s.controllerState='settled'))
      """,
      [assignment_id]
    )
    |> Enum.any?(fn [wake_id] ->
      wake = wait_in_txn(txn, wake_id)
      facts = continuation_facts_in_txn(txn, wake, assignment_id)

      mechanical =
        if purpose == "wait-prod-coverage" do
          facts["wait.obligation_matches"] and facts["wait.admitted"] and
            facts["wait.after_turn_eligible"] and facts["wait.coverage_valid"] and
            facts["wait.continuation_state"] in ~w(pending queued running)
        else
          facts["wait.obligation_matches"] and facts["wait.admitted"] and
            facts["wait.continuation_state"] == "pending" and
            not facts["wait.recognized"] and facts["resolver.open"] and
            facts["wait.declaration_complete"] and facts["wait.verification_accountable"] and
            facts["wait.coverage_valid"]
        end

      mechanical and
        match?({:ok, _}, RuleRuntime.select_policy_in_txn(txn, purpose, %{wait_facts: facts}))
    end)
  end

  defp continuation_facts_in_txn(txn, wake, assignment_id) do
    obligation =
      Txn.q(
        txn,
        """
        SELECT a.holderKey FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
        WHERE a.id=?1 AND a.state='open' AND s.ownerUserId=?2
        """,
        [assignment_id, wake.owner_user_id]
      )

    matches = obligation == [[wake.session_key]] and wake.obligation_ref == assignment_id

    continuation_state =
      case Txn.q(
             txn,
             "SELECT status FROM turns WHERE wakeId=?1 AND assignmentId=?2 AND sessionKey=?3",
             [wake.wake_id, assignment_id, wake.session_key]
           ) do
        [[status]] when status in ~w(queued running) -> status
        [] when wake.state == "pending" -> "pending"
        _ -> "terminal"
      end

    dependency = wake.wait_mode == "dependency"
    resolver = if dependency, do: resolver_for_wake_in_txn(txn, wake)

    accountable =
      dependency and wake.verification_state in ~w(provisional confirmed) and
        Txn.q(
          txn,
          """
          SELECT 1 FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
          WHERE a.id=?1 AND a.holderKey=?2 AND s.ownerUserId=?3
            AND (a.state='open' OR ?4='confirmed')
          """,
          [
            wake.verification_assignment_id,
            wake.verification_holder_key,
            wake.owner_user_id,
            wake.verification_state
          ]
        ) == [[1]]

    complete =
      dependency and is_map(wake.predicate) and
        is_binary(wake.necessity) and wake.necessity != "" and
        is_binary(wake.prompt) and wake.prompt != "" and
        is_binary(wake.selected_policy_name)

    if complete, do: stored_dependency_contracts!(wake)

    %{
      "wait.obligation_matches" => matches,
      "wait.admitted" => wake.wait_mode in ~w(dependency after-turn),
      "wait.after_turn_eligible" => wait_eligible_in_txn?(txn, wake),
      "wait.coverage_valid" => not dependency or accountable,
      "wait.continuation_state" => continuation_state,
      "wait.recognized" => not is_nil(wake.recognition_at),
      "wait.declaration_complete" => complete,
      "wait.verification_accountable" => accountable,
      "wait.verification_state" => wake.verification_state,
      "resolver.open" => dependency and not resolver.terminal,
      "resolver.owed_by_other" =>
        dependency and
          resolver.holder != "session:" <> wake.session_key
    }
  end

  defp capture_condition_cursor_in_txn(txn, declaration) do
    condition_fact? =
      Enum.any?(List.wrap(declaration.conditions), fn
        condition when is_map(condition) ->
          fact = Map.get(condition, "fact") || Map.get(condition, :fact)

          match?(
            {:ok, %{kind: :condition_fact}},
            RuleRuntime.predicate_transition_contract(fact)
          )

        _ ->
          false
      end)

    if condition_fact? and is_map(declaration.bindings) do
      [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")

      bindings =
        declaration.bindings
        |> Map.drop(["conditionAfterId", :conditionAfterId, :condition_after_id])
        |> Map.put("conditionAfterId", cursor)

      %{declaration | bindings: bindings}
    else
      declaration
    end
  end

  defp wait_obligation_in_txn(txn, input) do
    case Txn.q(
           txn,
           """
           SELECT a.id,a.state,a.holderKey,s.ownerUserId
           FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
           WHERE a.id=?1
           """,
           [input[:assignment_id]]
         ) do
      [[id, "open", holder_key, owner_user_id]] ->
        if owner_user_id == input[:owner_user_id] do
          {:ok, %{id: id, holder_key: holder_key, owner_user_id: owner_user_id}}
        else
          wait_error("unknown_assignment", "unknown or inaccessible open covered assignment")
        end

      _ ->
        wait_error("unknown_assignment", "unknown or inaccessible open covered assignment")
    end
  end

  defp wait_registrant_allowed(txn, input, %{holder_key: holder_key, owner_user_id: owner}) do
    # Read lineage in the admission transaction. The creator remains the actual
    # registrant; authority never substitutes the covered holder's identity.
    authorized =
      Txn.q(
        txn,
        """
        WITH RECURSIVE lineage(sessionKey,spawnedBy) AS (
          SELECT sessionKey,spawnedBy FROM sessions WHERE sessionKey=?1 AND ownerUserId=?3
          UNION
          SELECT s.sessionKey,s.spawnedBy FROM sessions s JOIN lineage l ON s.sessionKey=l.spawnedBy
          WHERE s.ownerUserId=?3
        )
        SELECT 1 FROM lineage WHERE sessionKey=?2
        """,
        [holder_key, input[:registrant_session_key], owner]
      ) == [[1]]

    if authorized,
      do: :ok,
      else:
        wait_error("not_holder", "registrant is neither the holder nor its supervising ancestor")
  end

  defp wait_target_allowed(input, %{holder_key: holder_key}) do
    if input[:session_key] == holder_key,
      do: :ok,
      else: wait_error("invalid_target", "obligation continuation must target its holder")
  end

  defp normalize_dependency_declaration(predicate) when is_map(predicate) do
    predicate = Map.new(predicate, fn {key, value} -> {to_string(key), value} end)
    allowed = ~w(conditions bindings resolverRef necessity verificationRef)
    unknown = Map.keys(predicate) -- allowed

    cond do
      unknown != [] ->
        wait_error(
          "invalid_predicate",
          "predicate has unknown keys: #{Enum.join(Enum.sort(unknown), ", ")}"
        )

      not (is_binary(predicate["necessity"]) and String.trim(predicate["necessity"]) != "") ->
        wait_error("invalid_predicate", "predicate necessity must be nonblank")

      true ->
        with {:ok, resolver_ref} <-
               normalize_reference(
                 predicate["resolverRef"],
                 ~w(assignment decision_request),
                 "resolverRef"
               ),
             {:ok, verification_ref} <-
               normalize_reference(
                 predicate["verificationRef"],
                 ["assignment"],
                 "verificationRef"
               ) do
          {:ok,
           %{
             conditions: predicate["conditions"],
             bindings: predicate["bindings"] || %{},
             resolver_ref: resolver_ref,
             necessity: String.trim(predicate["necessity"]),
             verification_ref: verification_ref
           }}
        end
    end
  end

  defp normalize_dependency_declaration(_),
    do: wait_error("invalid_predicate", "--predicate must be a JSON object")

  defp dependency_contracts(conditions) when is_list(conditions) and conditions != [] do
    Enum.reduce_while(conditions, {:ok, []}, fn
      condition, {:ok, contracts} when is_map(condition) ->
        fact = Map.get(condition, "fact") || Map.get(condition, :fact)

        case RuleRuntime.predicate_transition_contract(fact) do
          {:ok, contract} -> {:cont, {:ok, [contract | contracts]}}
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        {:halt, wait_error("invalid_predicate", "predicate conditions must be objects")}
    end)
  end

  defp dependency_contracts(_),
    do: wait_error("invalid_predicate", "predicate conditions must be a nonempty list")

  defp stored_dependency_contracts!(wake) do
    conditions = wake.predicate["conditions"] || wake.predicate[:conditions]

    case dependency_contracts(conditions) do
      {:ok, contracts} ->
        contracts

      {:error, error} ->
        raise DB.Error, message: "stored wait #{wake.wake_id} predicate refused: #{error.message}"
    end
  end

  defp normalize_reference(reference, allowed, label) when is_map(reference) do
    reference = Map.new(reference, fn {key, value} -> {to_string(key), value} end)

    case reference do
      %{"kind" => kind, "id" => id}
      when map_size(reference) == 2 and is_binary(id) and id != "" ->
        if kind in allowed do
          {:ok, %{kind: kind, id: id}}
        else
          wait_error(
            "invalid_predicate",
            "#{label} must contain exactly a supported kind and nonblank id"
          )
        end

      _ ->
        wait_error(
          "invalid_predicate",
          "#{label} must contain exactly a supported kind and nonblank id"
        )
    end
  end

  defp normalize_reference(_reference, _allowed, label),
    do: wait_error("invalid_predicate", "#{label} must be an object")

  defp resolver_in_txn(txn, %{kind: "assignment", id: id}, owner_user_id) do
    case Txn.q(
           txn,
           """
           SELECT a.state,a.outcome,a.holderKey,s.ownerUserId
           FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
           WHERE a.id=?1
           """,
           [id]
         ) do
      [[state, outcome, holder_key, ^owner_user_id]] ->
        {:ok,
         %{
           kind: "assignment",
           id: id,
           holder: "session:" <> holder_key,
           addressee: holder_key,
           terminal: state == "closed",
           disposition: outcome
         }}

      _ ->
        wait_error("invalid_resolver", "unknown or inaccessible assignment resolver")
    end
  end

  defp resolver_in_txn(txn, %{kind: "decision_request", id: id}, owner_user_id) do
    case Txn.q(
           txn,
           """
           SELECT status,ownerUserId,expecterSessionKey,raiserSessionKey
           FROM decision_requests WHERE id=?1
           """,
           [id]
         ) do
      [[status, ^owner_user_id, expecter_session, raiser_session]] ->
        addressee =
          expecter_session || raiser_session ||
            "agent:main:clawline:#{owner_user_id}:main"

        {:ok,
         %{
           kind: "decision_request",
           id: id,
           holder: "user:" <> owner_user_id,
           addressee: addressee,
           terminal: status in ~w(ruled consumed withdrawn superseded),
           disposition: status
         }}

      _ ->
        wait_error("invalid_resolver", "unknown or inaccessible decision request resolver")
    end
  end

  defp verification_assignment_in_txn(txn, %{kind: "assignment", id: id}, owner_user_id) do
    case Txn.q(
           txn,
           """
           SELECT a.state,a.holderKey,s.ownerUserId
           FROM assignments a JOIN sessions s ON s.sessionKey=a.holderKey
           WHERE a.id=?1
           """,
           [id]
         ) do
      [["open", holder_key, ^owner_user_id]] ->
        {:ok, %{id: id, state: "open", holder_key: holder_key}}

      _ ->
        wait_error("invalid_verifier", "verificationRef must name an accessible open assignment")
    end
  end

  defp verification_policy_in_txn(txn, obligation, verifier) do
    case RuleRuntime.select_policy_in_txn(txn, "wait-verification-admission", %{
           verifier_state: verifier.state,
           verifier_holder_key: verifier.holder_key,
           obligation_holder_key: obligation.holder_key
         }) do
      {:ok, selected} -> {:ok, selected}
      :none -> wait_error("verification_not_admitted", "no verification admission policy matched")
    end
  end

  defp schedule_verifier_notice_in_txn(txn, wake, verifier) do
    schedule_in_txn(txn, %{
      session_key: verifier.holder_key,
      origin: "process:tightbeam",
      assignment_id: verifier.id,
      obligation_ref: verifier.id,
      owner_user_id: wake.owner_user_id,
      prompt:
        "Verify dependency wait #{wake.wake_id} for assignment #{wake.assignment_id}. " <>
          "Predicate: #{JSON.encode!(wake.predicate)}. Necessity: #{wake.necessity}. " <>
          "File wait-verified or wait-challenged on #{verifier.id} with --wait #{wake.wake_id}.",
      due_at: now(),
      sender_scheduled: true
    })
  end

  defp running_turn_seq_in_txn(_txn, nil), do: nil

  defp running_turn_seq_in_txn(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT seq FROM turns WHERE sessionKey=?1 AND status='running' LIMIT 1",
           [session_key]
         ) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp wait_error(code, message), do: {:error, %{code: code, message: message}}

  defp recognize_from_snapshot_in_txn(txn, wake, evaluation, resolver, transition) do
    cond do
      evaluation.matched ->
        recognize_wait_in_txn(txn, wake, "success", nil, evaluation, resolver, transition)

      resolver.terminal ->
        recognize_wait_in_txn(
          txn,
          wake,
          "reconsideration",
          "resolver-terminal",
          evaluation,
          resolver,
          transition
        )

      true ->
        wake
    end
  end

  defp recognize_wait_transitions_in_txn(txn, transitions) do
    transitions = Enum.filter(transitions, &(is_map(&1) and is_binary(&1[:owner_user_id])))

    transitions
    |> Enum.map(& &1.owner_user_id)
    |> Enum.uniq()
    |> Enum.each(fn owner_user_id ->
      Txn.q(
        txn,
        """
        SELECT wakeId FROM wakes
        WHERE state='pending' AND waitMode='dependency' AND recognitionAt IS NULL
          AND ownerUserId=?1
        ORDER BY rowid
        """,
        [owner_user_id]
      )
      |> Enum.each(fn [wake_id] ->
        case wait_in_txn(txn, wake_id) do
          nil ->
            :ok

          wake ->
            owner_transitions =
              Enum.filter(transitions, &(&1.owner_user_id == wake.owner_user_id))

            predicate_transition =
              Enum.find(owner_transitions, &predicate_transition_relevant?(txn, wake, &1))

            resolver_transition =
              Enum.find(owner_transitions, &resolver_transition_relevant?(wake, &1))

            verification_transition =
              Enum.find(owner_transitions, &verification_terminal_transition?(wake, &1))

            if predicate_transition || resolver_transition || verification_transition do
              evaluation = evaluate_wait_predicate_in_txn(txn, wake)
              resolver = resolver_for_wake_in_txn(txn, wake)

              cond do
                evaluation.matched and predicate_transition ->
                  recognize_wait_in_txn(
                    txn,
                    wake,
                    "success",
                    nil,
                    evaluation,
                    resolver,
                    predicate_transition
                  )

                resolver.terminal and resolver_transition ->
                  recognize_wait_in_txn(
                    txn,
                    wake,
                    "reconsideration",
                    "resolver-terminal",
                    evaluation,
                    resolver,
                    resolver_transition
                  )

                verification_transition ->
                  recognize_wait_in_txn(
                    txn,
                    wake,
                    "reconsideration",
                    "verification-terminal",
                    evaluation,
                    resolver,
                    verification_transition
                  )

                true ->
                  wake
              end
            end
        end
      end)
    end)

    :ok
  end

  defp resolver_transition_relevant?(wake, transition) do
    transition[:domain] == wake.resolver_kind and
      to_string(transition[:row_id]) == wake.resolver_id
  end

  defp predicate_transition_relevant?(txn, wake, transition) do
    contracts = stored_dependency_contracts!(wake)
    bindings = wake.predicate["bindings"] || wake.predicate[:bindings] || %{}
    domain = transition[:domain]

    Enum.any?(contracts, fn contract ->
      case contract do
        %{kind: :row, domains: domains, binding: binding} ->
          domain in domains and
            to_string(transition[:row_id]) == predicate_binding(bindings, binding)

        %{kind: :artifact, domains: domains, binding: binding} ->
          domain in domains and
            artifact_transition_relevant?(txn, transition, predicate_binding(bindings, binding))

        %{kind: :condition_fact, domains: domains} ->
          domain in domains and condition_fact_transition_relevant?(transition, bindings)

        contract ->
          raise "unsupported predicate transition contract: #{inspect(contract)}"
      end
    end)
  end

  defp predicate_binding(bindings, key),
    do: Map.get(bindings, key) || Map.get(bindings, String.to_atom(key))

  defp condition_fact_transition_relevant?(transition, bindings) do
    transition_bindings = transition[:bindings] || %{}
    fact_id = transition[:row_id]
    expected_fact_id = predicate_binding(bindings, "conditionFactId")
    expected_scope = predicate_binding(bindings, "conditionScope")
    actual_kind = predicate_binding(transition_bindings, "conditionKind")
    actual_scope = predicate_binding(transition_bindings, "conditionScope")
    after_id = predicate_binding(bindings, "conditionAfterId")

    is_integer(fact_id) and is_integer(after_id) and fact_id > after_id and
      actual_kind == predicate_binding(bindings, "conditionKind") and
      (is_nil(expected_scope) or actual_scope == expected_scope) and
      (is_nil(expected_fact_id) or fact_id == expected_fact_id)
  end

  defp artifact_transition_relevant?(_txn, _transition, selector) when not is_map(selector),
    do: false

  defp artifact_transition_relevant?(txn, transition, selector) do
    transition_binding = transition[:bindings] || %{}

    artifact_binding =
      Map.get(transition_binding, :artifact) || Map.get(transition_binding, "artifact") || %{}

    artifact_id =
      if transition[:domain] == "artifact",
        do: to_string(transition[:row_id]),
        else: Map.get(artifact_binding, :artifactId) || Map.get(artifact_binding, "artifactId")

    case artifact_id &&
           Txn.q(
             txn,
             "SELECT contentSha256,producedByAssignmentId FROM artifacts WHERE artifactId=?1",
             [artifact_id]
           ) do
      [[hash, producer]] -> artifact_selector_matches?(selector, artifact_id, hash, producer)
      _ -> false
    end
  end

  defp artifact_selector_matches?(selector, artifact_id, hash, producer) do
    expected_id = Map.get(selector, "artifactId") || Map.get(selector, :artifactId)

    expected_producer =
      Map.get(selector, "producedByAssignmentId") || Map.get(selector, :producedByAssignmentId)

    expected_hash = Map.get(selector, "contentSha256") || Map.get(selector, :contentSha256)

    cond do
      is_binary(expected_id) ->
        expected_id == artifact_id and expected_hash == hash

      is_binary(expected_producer) ->
        expected_producer == producer and (is_nil(expected_hash) or expected_hash == hash)

      true ->
        false
    end
  end

  defp verification_terminal_transition?(wake, transition) do
    transition[:domain] == "assignment" and
      to_string(transition[:row_id]) == wake.verification_assignment_id and
      transition_new(transition, "state") == "closed" and wake.verification_state != "confirmed"
  end

  defp transition_new(%{field: %{name: name, new: value}}, name), do: value
  defp transition_new(%{fields: fields}, name), do: get_in(fields, [String.to_atom(name), :new])
  defp transition_new(_transition, _name), do: nil

  defp evaluate_wait_predicate_in_txn(txn, wake) do
    # The deadline sweep must refuse corrupt stored vocabulary too, before it
    # can stamp a later success as a registration snapshot.
    stored_dependency_contracts!(wake)

    case RuleRuntime.evaluate_predicate_in_txn(txn, %{
           owner_user_id: wake.owner_user_id,
           conditions: wake.predicate["conditions"] || wake.predicate[:conditions],
           bindings: wake.predicate["bindings"] || wake.predicate[:bindings]
         }) do
      {:ok, evaluation} ->
        evaluation

      {:error, error} ->
        raise DB.Error, message: "stored wait predicate refused: #{error.message}"
    end
  end

  defp resolver_for_wake_in_txn(txn, %{resolver_kind: kind, resolver_id: id} = wake) do
    case resolver_in_txn(txn, %{kind: kind, id: id}, wake.owner_user_id) do
      {:ok, resolver} -> resolver
      {:error, error} -> raise DB.Error, message: "stored wait resolver refused: #{error.message}"
    end
  end

  defp recognize_wait_in_txn(txn, wake, path, reason, evaluation, resolver, transition) do
    recognized_at = now()
    facts = wait_evidence_facts(evaluation.facts)
    disposition = wait_recognition_disposition(path, evaluation.facts, resolver)

    recognition_transition =
      transition ||
        %{
          label: "registration-snapshot",
          observed: facts
        }

    evidence = %{
      label: if(is_nil(transition), do: "registration-snapshot", else: "row-transition"),
      facts: facts,
      condition_match: evaluation[:condition_match],
      artifact_revision: evaluation[:artifact_revision]
    }

    Txn.q(
      txn,
      """
      UPDATE wakes
      SET recognitionAt=?2,recognitionPath=?3,recognitionReason=?4,
          recognitionEvidence=?5,recognitionDisposition=?6,recognitionTransition=?7
      WHERE wakeId=?1 AND state='pending' AND recognitionAt IS NULL
      """,
      [
        wake.wake_id,
        recognized_at,
        path,
        reason,
        JSON.encode!(evidence),
        disposition,
        JSON.encode!(recognition_transition)
      ]
    )

    if Txn.changes(txn) == 1 do
      reconcile_wait_relief_in_txn(txn, wake.assignment_id, recognized_at)

      EventLog.lifecycle_in_txn(
        txn,
        "wake_wait_recognized",
        wake.wake_id,
        "path=#{path} reason=#{reason || "nil"} disposition=#{disposition || "nil"}"
      )

      %{
        wake
        | recognition_at: recognized_at,
          recognition_path: path,
          recognition_reason: reason,
          recognition_evidence: evidence,
          recognition_disposition: disposition,
          recognition_transition: recognition_transition
      }
    else
      wait_in_txn(txn, wake.wake_id)
    end
  end

  defp wait_evidence_facts(facts) do
    Enum.map(facts, fn
      {fact, value} -> %{fact: fact, value: value}
      fact when is_map(fact) -> fact
    end)
  end

  defp wait_recognition_disposition(_path, _facts, %{terminal: true, disposition: disposition}),
    do: disposition

  defp wait_recognition_disposition("success", facts, _resolver) do
    Enum.find_value(facts, fn
      {"assignment.outcome", value} when value in ~w(completed surrendered revoked) ->
        value

      {"work_item.state", value} when value in ~w(closed iceboxed failed) ->
        value

      {"decision_request.status", value}
      when value in ~w(ruled consumed withdrawn superseded) ->
        value

      _ ->
        nil
    end)
  end

  defp wait_recognition_disposition(_path, _facts, _resolver), do: nil

  @doc false
  @spec validate_verification_verdict_in_txn(Txn.t(), map()) :: :ok | {:error, map()}
  def validate_verification_verdict_in_txn(%Txn{} = txn, attrs) do
    verdict_kind = attrs[:verdict_kind]

    cond do
      verdict_kind in ~w(wait-verified wait-challenged) ->
        verification_verdict_binding_in_txn(txn, attrs)

      is_binary(attrs[:wait_id]) ->
        wait_error(
          "invalid_wait_verdict",
          "--wait is valid only for wait-verified and wait-challenged"
        )

      true ->
        :ok
    end
  end

  @doc false
  @spec verification_verdict_in_txn(Txn.t(), map()) :: :ok
  def verification_verdict_in_txn(%Txn{} = txn, attrs) do
    case attrs[:verdict_kind] do
      kind when kind in ~w(wait-verified wait-challenged) ->
        apply_verification_verdict_in_txn(txn, attrs)
        wake = wait_in_txn(txn, attrs.wait_id)
        reconcile_wait_relief_in_txn(txn, wake.assignment_id, now())

      _ ->
        :ok
    end
  end

  defp verification_verdict_binding_in_txn(_txn, %{wait_id: nil}),
    do: wait_error("wait_required", "wait-verified and wait-challenged require --wait")

  defp verification_verdict_binding_in_txn(txn, attrs) do
    case Txn.q(
           txn,
           """
           SELECT w.verificationState,a.state,a.holderKey
           FROM wakes w JOIN assignments a ON a.id=w.verificationAssignmentId
           WHERE w.wakeId=?1 AND w.verificationAssignmentId=?2
           """,
           [attrs.wait_id, attrs.assignment_id]
         ) do
      [[state, "open", holder_key]] when holder_key == attrs.by_session ->
        case {attrs.verdict_kind, state} do
          {"wait-verified", "provisional"} ->
            :ok

          {"wait-challenged", state} when state in ~w(provisional confirmed) ->
            :ok

          _ ->
            wait_error("invalid_wait_verdict", "wait verification transition is already terminal")
        end

      _ ->
        wait_error(
          "invalid_wait_verdict",
          "wait verdict requires the named open verifier assignment and its recorded holder"
        )
    end
  end

  defp apply_verification_verdict_in_txn(txn, %{verdict_kind: "wait-verified"} = attrs) do
    Txn.q(
      txn,
      """
      UPDATE wakes SET verificationState='confirmed',verificationAttestId=?2
      WHERE wakeId=?1 AND verificationState='provisional'
      """,
      [attrs.wait_id, attrs.attest_id]
    )

    if Txn.changes(txn) != 1,
      do: raise(DB.Error, message: "wait verification confirmation race")

    :ok
  end

  defp apply_verification_verdict_in_txn(txn, %{verdict_kind: "wait-challenged"} = attrs) do
    Txn.q(
      txn,
      """
      UPDATE wakes SET verificationState='challenged',verificationAttestId=?2
      WHERE wakeId=?1 AND verificationState IN ('provisional','confirmed')
      """,
      [attrs.wait_id, attrs.attest_id]
    )

    if Txn.changes(txn) != 1,
      do: raise(DB.Error, message: "wait verification challenge race")

    wake = wait_in_txn(txn, attrs.wait_id)

    if wake && is_nil(wake.recognition_path) do
      resolver = resolver_for_wake_in_txn(txn, wake)
      evaluation = evaluate_wait_predicate_in_txn(txn, wake)

      recognize_wait_in_txn(
        txn,
        wake,
        "reconsideration",
        "verification-challenged",
        evaluation,
        resolver,
        %{
          domain: "attest",
          row_id: attrs.attest_id,
          field: %{name: "verdictKind", old: nil, new: "wait-challenged"}
        }
      )
    end

    :ok
  end

  defp wait_in_txn(txn, wake_id) do
    case Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [wake_id]) do
      [row] -> to_wake(row)
      [] -> nil
    end
  end

  @doc "Evaluate committed business-row transitions and record matching rule notices."
  @spec row_commit_in_txn(Txn.t(), [map()] | map()) :: :ok
  def row_commit_in_txn(%Txn{} = txn, transitions) do
    transitions = List.wrap(transitions) ++ DB.take_row_commits(txn)

    if wait_recognition_ready?(txn) do
      txn
      |> RuleRuntime.row_commit_effects_in_txn(transitions)
      |> Enum.each(fn
        {:notice, rule, call, evidence} ->
          try do
            deliver_rule_notice_in_txn(txn, rule, call, evidence)
          rescue
            error ->
              EventLog.lifecycle_in_txn(
                txn,
                "rule_notice_failed",
                rule.name,
                Exception.message(error)
              )
          end

        {:error, rule, message} ->
          EventLog.lifecycle_in_txn(txn, "rule_notice_failed", rule.name, message)
      end)

      recognize_wait_transitions_in_txn(txn, transitions)
    end

    :ok
  end

  @doc "Execute an actor-owned rule notice without changing the governed decision."
  @spec deliver_rule_notice(DB.server(), map(), map(), list()) :: :ok
  def deliver_rule_notice(db, rule, call, evidence) do
    case DB.transaction(db, &deliver_rule_notice_in_txn(&1, rule, call, evidence)) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        _ = EventLog.lifecycle(db, "rule_notice_failed", rule.name, Exception.message(error))
        :ok
    end
  rescue
    _error -> :ok
  end

  defp deliver_rule_notice_in_txn(txn, rule, call, evidence) do
    case RuleRuntime.resolve_notice_in_txn(txn, rule, call) do
      {:ok, resolved} ->
        wake =
          schedule_in_txn(txn, %{
            session_key: resolved.bound_session,
            target_role: resolved.target[:target_role],
            origin: "remedy:#{rule.name}",
            prompt: resolved.params.prompt,
            due_at: System.system_time(:millisecond),
            creator_session_key: principal_session(call.principal),
            summon: true
          })

        EventLog.lifecycle_in_txn(
          txn,
          "rule_notice",
          wake.wake_id,
          JSON.encode!(%{
            rule: rule.name,
            edge: rule_edge(call),
            cause: Map.get(call, :transition),
            principal: call.origin,
            evidence: Enum.map(evidence, fn {fact, value} -> %{fact: fact, value: value} end)
          })
        )

        :ok

      {:error, reason} ->
        raise "notice #{rule.name} has unresolved target: #{inspect(reason)}"
    end
  end

  defp principal_session({:session, session_key}), do: session_key
  defp principal_session(_principal), do: nil

  defp rule_edge(call) do
    case Map.get(call, :edge, :verb) do
      :turn_end -> "turn-end"
      :row_commit -> "row-commit"
      _ -> "verb"
    end
  end

  @doc """
  Preserve a prompt wake after a rate-limit terminal by scheduling a new,
  traceable attempt. The failed turn remains terminal and every attempt keeps
  its own `wakeId`; replay returns the already-created successor.

  This deliberately admits only the existing closed `rate-limit-dead` class.
  Without a typed proof that inference did not start, retrying any other
  failure could repeat effects.
  """
  @spec preserve_failed_intent_in_txn(Txn.t(), map(), String.t() | nil) ::
          :not_wake | :not_retryable | :settled | {:retry, String.t()}
  def preserve_failed_intent_in_txn(%Txn{} = txn, turn, failure_class)
      when is_map(turn) do
    case Map.get(turn, :wake_id) do
      wake_id when is_binary(wake_id) ->
        preserve_wake_terminal_in_txn(txn, turn, wake_id, failure_class)

      _ ->
        :not_wake
    end
  end

  defp preserve_wake_terminal_in_txn(txn, turn, wake_id, failure_class) do
    case Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [wake_id]) do
      [row] ->
        wake = to_wake(row)

        cond do
          retry_attempt?(txn, wake_id) and turn.status == "delivered" ->
            settle_retry_attempt_in_txn(txn, wake_id, turn.seq, "acted", turn.ended_at)
            :settled

          retry_attempt?(txn, wake_id) and turn.status == "canceled" ->
            settle_retry_attempt_in_txn(txn, wake_id, turn.seq, "canceled", turn.ended_at)
            :settled

          turn.status == "failed" and failure_class == "rate-limit-dead" and
              retryable_prompt_wake?(wake, turn) ->
            schedule_retry_in_txn(txn, wake, turn)

          true ->
            :not_retryable
        end

      [] ->
        :not_wake
    end
  end

  defp retry_attempt?(txn, wake_id) do
    Txn.q(txn, "SELECT 1 FROM wake_retry_attempts WHERE wakeId=?1", [wake_id]) != []
  end

  defp retryable_prompt_wake?(wake, turn) do
    wake.consumer == "prompt" and not wake.digest and
      not String.starts_with?(turn.request_ref || "", "bubble:")
  end

  defp schedule_retry_in_txn(txn, wake, turn) do
    {root_wake_id, attempt} = retry_identity_in_txn(txn, wake.wake_id)
    next_attempt = attempt + 1
    retry_wake_id = retry_wake_id(root_wake_id, next_attempt)
    observed_at = turn.ended_at || now()

    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO wake_retry_attempts
        (wakeId, rootWakeId, predecessorWakeId, attempt, sourceTurnSeq,
         outcome, retryWakeId, observedAt)
      VALUES (?1, ?2, NULL, ?3, ?4, 'failed', NULL, ?5)
      """,
      [wake.wake_id, root_wake_id, attempt, turn.seq, observed_at]
    )

    Txn.q(
      txn,
      """
      UPDATE wake_retry_attempts
      SET sourceTurnSeq=COALESCE(sourceTurnSeq, ?2), outcome='failed',
          observedAt=?3
      WHERE wakeId=?1 AND outcome='pending'
      """,
      [wake.wake_id, turn.seq, observed_at]
    )

    case Txn.q(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", [retry_wake_id]) do
      [] ->
        due_at = observed_at + retry_delay_ms(next_attempt)
        insert_retry_wake_in_txn(txn, wake, turn.prompt, retry_wake_id, due_at, observed_at)

        Txn.q(
          txn,
          """
          INSERT INTO wake_retry_attempts
            (wakeId, rootWakeId, predecessorWakeId, attempt, sourceTurnSeq,
             outcome, retryWakeId, observedAt)
          VALUES (?1, ?2, ?3, ?4, NULL, 'pending', NULL, ?5)
          """,
          [retry_wake_id, root_wake_id, wake.wake_id, next_attempt, observed_at]
        )

        Txn.q(
          txn,
          "UPDATE wake_retry_attempts SET retryWakeId=?2 WHERE wakeId=?1",
          [wake.wake_id, retry_wake_id]
        )

        EventLog.lifecycle_in_txn(
          txn,
          "wake_retry_scheduled",
          root_wake_id,
          "sourceTurnSeq=#{turn.seq} failedWakeId=#{wake.wake_id} retryWakeId=#{retry_wake_id} attempt=#{next_attempt} dueAt=#{due_at} cause=rate-limit-dead principal=process:tightbeam"
        )

        {:retry, retry_wake_id}

      [[1]] ->
        {:retry, retry_wake_id}
    end
  end

  defp retry_identity_in_txn(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT rootWakeId, attempt FROM wake_retry_attempts WHERE wakeId=?1",
           [wake_id]
         ) do
      [[root_wake_id, attempt]] -> {root_wake_id, attempt}
      [] -> {wake_id, 0}
    end
  end

  defp retry_wake_id(root_wake_id, attempt) do
    digest = :crypto.hash(:sha256, "#{root_wake_id}:#{attempt}")
    "wr_" <> Base.encode16(digest, case: :lower)
  end

  defp retry_delay_ms(attempt) do
    multiplier = Integer.pow(2, min(attempt - 1, 10))
    min(@retry_base_ms * multiplier, @retry_ceiling_ms)
  end

  defp insert_retry_wake_in_txn(txn, wake, prompt, retry_wake_id, due_at, created_at) do
    Txn.q(
      txn,
      """
      INSERT INTO wakes
        (wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state,
         createdAt, firedAt, reresolve, reresolveSeed, reresolveRung,
         conditionKind, conditionScope, conditionAfterId, firedBy,
         creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt,
         targetGate, class, classElection, deliveryRule, digest, summon)
      VALUES (?1, ?2, ?3, ?4, ?5, 'prompt', ?6, 'pending', ?7, NULL,
              ?8, ?9, ?10, NULL, NULL, NULL, NULL, ?11, ?12, ?13, ?14, NULL,
              ?15, ?16, ?17, ?18, 0, ?19)
      """,
      [
        retry_wake_id,
        wake.session_key,
        wake.target_role,
        wake.origin,
        prompt,
        due_at,
        created_at,
        wake.reresolve,
        wake.reresolve_seed,
        wake.reresolve_rung,
        wake.creator_session_key,
        if(wake.rumination, do: 1, else: 0),
        wake.work_item_id,
        wake.assignment_id,
        wake.target_gate,
        wake.class,
        wake.class_election,
        wake.delivery_rule,
        if(wake.summon, do: 1, else: 0)
      ]
    )

    publish_change_in_txn(txn, "wake.scheduled", retry_wake_id)
  end

  defp settle_retry_attempt_in_txn(txn, wake_id, turn_seq, outcome, observed_at) do
    Txn.q(
      txn,
      """
      UPDATE wake_retry_attempts
      SET sourceTurnSeq=COALESCE(sourceTurnSeq, ?2), outcome=?3, observedAt=?4
      WHERE wakeId=?1 AND outcome='pending'
      """,
      [wake_id, turn_seq, outcome, observed_at || now()]
    )
  end

  defp bypass_v1_batching_in_txn(txn, wake, policy_ref, refusal) do
    Txn.q(
      txn,
      "UPDATE wakes SET deliveryRule=?2 WHERE wakeId=?1 AND state='pending'",
      [wake.wake_id, @legacy_digest_rule]
    )

    Txn.q(
      txn,
      "UPDATE notice_delivery_policies SET enabled=0 WHERE policyRef=?1 AND sourceWakeId=?2",
      [policy_ref, wake.wake_id]
    )

    EventLog.lifecycle_in_txn(
      txn,
      "notice_batching_admission_bypassed",
      wake.wake_id,
      "rule=#{@digest_rule} fallback=#{@legacy_digest_rule} code=#{refusal.code}"
    )

    %{wake | delivery_rule: @legacy_digest_rule}
  end

  # The class this wake carries, and who put it there. A caller that names
  # `:class` elects; a caller that asks to be `:classify`-ed accepts the
  # classifier's stamp; a caller that does neither gets no class at all, which
  # is how every wake predating the fabric keeps behaving exactly as it did.
  #
  # A DIGEST CARRIER is neither of those: the batcher built the row, so
  # `classify/1`'s "sender" stamp would be a false audit fact (Sol xhigh
  # review, finding 7) — checked first because `:digest` always carries
  # `:class` too and would otherwise be read as a sender election.
  defp elected_class(input) do
    cond do
      Map.get(input, :digest, false) and is_binary(Map.get(input, :class)) ->
        {Map.fetch!(input, :class), "batcher"}

      is_binary(Map.get(input, :class)) and Map.get(input, :class) != "" ->
        classify(Map.fetch!(input, :class))

      Map.get(input, :classify, false) ->
        classify(nil)

      true ->
        {nil, nil}
    end
  end

  # An unclassed wake is not fabric traffic and the policy does not touch it.
  defp apply_delivery_policy(_txn, input, nil, _created_at, _condition_kind),
    do: {nil, Map.fetch!(input, :due_at)}

  defp apply_delivery_policy(txn, input, class, created_at, condition_kind) do
    policy = delivery_policy(class)

    cond do
      # The carrier the batcher itself just built. Signed with the rule that
      # produced it, delivered at the moment that rule chose, and never a
      # member of anything: `digest = 1` is what keeps it out of its own group.
      Map.get(input, :digest, false) ->
        {Map.get(input, :delivery_rule, @digest_rule), Map.fetch!(input, :due_at)}

      # THE CLASS CHECK PRECEDES THE INHIBITION BRANCH (Sol xhigh review,
      # finding 1). `immediate` and `bypass` classes were never the batcher's
      # to hold in the first place — §7: algedonic "bypasses every bone...
      # never batched, never digested, never triaged" — so there is nothing
      # for `batcher-inhibited` to name here. A sender's own --after/--at on
      # one of these classes is not the batcher inhibiting anything; it is
      # the sender's own election, unchanged, and the row must say so: the
      # rule stays `algedonic-bypass`/`immediate-delivery`, never
      # `batcher-inhibited`. `due_at` is exactly what the caller supplied
      # either way — scheduled or not, an alarm is never delayed BY POLICY.
      policy.immediacy == :digest and class == "fyi" and
          String.starts_with?(Map.fetch!(input, :origin), "user:") ->
        due_at =
          if Map.get(input, :sender_scheduled, false) or
               String.starts_with?(Map.fetch!(input, :origin), "user:"),
             do: Map.fetch!(input, :due_at),
             else: created_at + policy.ceiling_ms

        {@inhibited_rule, due_at}

      policy.immediacy == :digest and batcher_inhibited?(input, condition_kind) ->
        {@inhibited_rule, Map.fetch!(input, :due_at)}

      policy.immediacy == :digest and not v1_batch_eligible?(input, class, condition_kind) ->
        {@legacy_digest_rule, created_at + policy.ceiling_ms}

      policy.immediacy == :digest and not NoticeBatcher.lane_enabled_in_txn(txn, input) ->
        {@legacy_digest_rule, created_at + policy.ceiling_ms}

      policy.immediacy != :digest ->
        {policy.rule, Map.fetch!(input, :due_at)}

      batcher_inhibited?(input, condition_kind) ->
        {@inhibited_rule, Map.fetch!(input, :due_at)}

      # THE CEILING IS THE EXIT (Invariant 3). The wake is due at its class
      # ceiling from the moment it is filed; the batcher may materialize the
      # digest EARLIER at a turn boundary, but nothing can make it later, and
      # an idle session's digest materializes its own turn right here.
      true ->
        {@digest_rule, created_at + policy.ceiling_ms}
    end
  end

  # THE INHIBITION SEAM, named (philosophy gate Q2). The batcher is a default,
  # not a cage: a sender that elected its own delivery moment keeps it, a
  # condition wake keeps its own firing mechanics, and an internal consumer is
  # not an agent's attention to protect. In every case the class is still
  # RECORDED — inhibiting the reflex never erases what the sender said.
  defp batcher_inhibited?(input, condition_kind) do
    Map.get(input, :sender_scheduled, false) or is_binary(condition_kind) or
      Map.get(input, :consumer, "prompt") != "prompt"
  end

  defp v1_batch_eligible?(input, class, condition_kind) do
    origin = Map.fetch!(input, :origin)

    class == "fyi" and not String.starts_with?(origin, "user:") and
      not Map.get(input, :digest, false) and not Map.get(input, :sender_scheduled, false) and
      not is_binary(condition_kind) and Map.get(input, :consumer, "prompt") == "prompt"
  end

  defp v1_batch_source?(wake) do
    wake.class == "fyi" and wake.delivery_rule == @digest_rule and not wake.digest and
      not String.starts_with?(wake.origin, "user:")
  end

  # FAIL QUIET AND VISIBLE (§5 policy-skew rule). An extended class this build
  # has no mapping for is delivered as `fyi` — never dropped, never promoted —
  # and the gap is a durable row somebody can act on, not a silent downgrade.
  #
  # THE ROW NAMES THE RULE THAT ACTUALLY DECIDED (O6 / §8 legibility): a
  # batcher-inhibited wake (a sender's own `--after`, a condition wake, an
  # internal consumer) never reaches the digest rule at all — hardcoding
  # `@digest_rule` here claimed a reflex that never fired. `wake.delivery_rule`
  # is the row's own already-computed fact, so the skew row and the wake it
  # describes can never disagree about which rule produced it.
  defp file_policy_skew(txn, %{class: class, wake_id: wake_id, delivery_rule: delivery_rule})
       when is_binary(class) do
    if delivery_policy(class).skew do
      EventLog.lifecycle_in_txn(
        txn,
        "wake_class_policy_skew",
        wake_id,
        "class=#{class} deliveredAs=#{classifier_default()} rule=#{delivery_rule}"
      )
    end

    :ok
  end

  defp file_policy_skew(_txn, _wake), do: :ok

  @doc false
  @spec retarget_in_txn(Txn.t(), String.t(), String.t()) :: wake() | :error
  def retarget_in_txn(%Txn{} = txn, wake_id, replacement_target)
      when is_binary(wake_id) and is_binary(replacement_target) do
    replacement_id = "w_" <> Tightbeam.Id.uuid4()
    created_at = now()

    with [[1]] <-
           Txn.q(
             txn,
             "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'",
             [replacement_target]
           ),
         [row] <-
           Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1 AND state='pending'", [wake_id]) do
      source = to_wake(row)
      {delivery_rule, due_at} = retarget_delivery(source, created_at)

      Txn.q(
        txn,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state,
           createdAt, firedAt, reresolve, reresolveSeed, reresolveRung,
           conditionKind, conditionScope, conditionAfterId, firedBy,
           creatorSessionKey, rumination, work_item_id, assignmentId,
           targetGate, class, classElection, deliveryRule, digest, summon)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', ?8, NULL, ?9, ?10, ?11,
                ?12, ?13, ?14, NULL, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)
        """,
        [
          replacement_id,
          replacement_target,
          source.target_role,
          source.origin,
          source.prompt,
          source.consumer,
          due_at,
          created_at,
          source.reresolve,
          source.reresolve_seed,
          source.reresolve_rung,
          source.condition_kind,
          source.condition_scope,
          source.condition_after_id,
          source.creator_session_key,
          if(source.rumination, do: 1, else: 0),
          source.work_item_id,
          source.assignment_id,
          source.target_gate,
          source.class,
          source.class_election,
          delivery_rule,
          if(source.digest, do: 1, else: 0),
          if(source.summon, do: 1, else: 0)
        ]
      )

      if Txn.changes(txn) == 1 do
        case Txn.q(
               txn,
               """
               SELECT assignmentId, controllerOrigin, wakeKind, chargedGeneration
               FROM supervision_liveness_sidecar
               WHERE wakeId=?1 AND controllerOrigin='scheduled'
                 AND controllerState='pending'
               """,
               [wake_id]
             ) do
          [[assignment_id, controller_origin, wake_kind, charged_generation]] ->
            Txn.q(
              txn,
              """
              UPDATE supervision_liveness_sidecar
              SET controllerState='settled'
              WHERE wakeId=?1 AND controllerState='pending'
              """,
              [wake_id]
            )

            Txn.q(
              txn,
              """
              INSERT INTO supervision_liveness_sidecar
                (wakeId, assignmentId, controllerOrigin, wakeKind,
                 controllerState, chargedGeneration)
              VALUES (?1, ?2, ?3, ?4, 'pending', ?5)
              """,
              [
                replacement_id,
                assignment_id,
                controller_origin,
                wake_kind,
                charged_generation
              ]
            )

          [] ->
            :ok
        end

        [row] = Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [replacement_id])
        to_wake(row)
      else
        :error
      end
    else
      _ -> :error
    end
  end

  def retarget_in_txn(%Txn{}, _wake_id, _replacement_target), do: :error

  # O1 (HIGH, Law 2): `class`/`classElection`/`digest`/`summon` are the
  # SENDER's facts, not the batcher's — retarget is org.ex:688's unroutable
  # remedy (a target session retired), and moving WHO receives a wake must
  # never destroy WHAT the sender elected or what the row IS. The INSERT
  # above now carries all five columns verbatim.
  #
  # `deliveryRule`/`dueAt` are carried VERBATIM too, and deliberately (Sol
  # xhigh review round 2, finding 1 — Invariant 3): the CEILING anchors on
  # the wake's own CREATION, never on when it happened to get retargeted.
  # `created_at + ceiling_ms`, computed against the RETARGET moment, was
  # this function's first draft and it was wrong — it RESTARTS the ceiling,
  # so an `fyi` retargeted at 3h59m could land at 7h59m, a straight §7
  # violation (a wake held longer because its target retired is a worse
  # answer than the one Law 2 already gives: the row's original `dueAt` is
  # already the correct ceiling, computed once, honestly, at filing time).
  # There is nothing to recompute here, and nothing to tighten either —
  # `source.due_at` already IS the anchor.
  #
  # The new target's own turn-boundary eligibility needs no help from this
  # function: `materialize_due/4` re-reads `group_boundary/2` FRESH every
  # materialization pass, against whatever session or role the row names
  # NOW — retargeting a digest-held member into the new target's group is
  # the whole mechanism. Nothing about WHEN it is due needs to move for that
  # to be true.
  defp retarget_delivery(source, _created_at), do: {source.delivery_rule, source.due_at}

  @requester_kinds ~w(user session process)
  @reason_kinds ~w(requester_withdrew superseded obligation_disposed routing_bracket_satisfied target_retired production_unmatched consumer_unavailable target_unresolvable)
  @source_kinds ~w(verb_call wake progress_attest condition_fact assignment_transition work_item_transition decision_request monitor_generation routing_bracket session_transition scheduler_delivery)
  @disposition_kinds ~w(assignment_transition work_item_transition decision_request_transition monitor_generation_transition)
  @liveness_kinds ~w(supervision_entitlement supervision_transfer pending_wake routing_bracket)

  @process_reasons %{
    "tightbeam:wake-scheduler" =>
      ~w(production_unmatched consumer_unavailable target_unresolvable),
    "tightbeam:work-items" => ~w(routing_bracket_satisfied),
    "tightbeam:assignments" => ~w(obligation_disposed),
    "tightbeam:effort-checkin" => ~w(superseded obligation_disposed),
    "tightbeam:supervision" => ~w(superseded),
    "tightbeam:retirement" => ~w(target_retired obligation_disposed),
    # The batcher consumes a digest MEMBER exactly one way: superseded by the
    # digest that carries it, named as the replacement. It has no other verb —
    # it cannot withdraw, dispose, or retire anyone's mail.
    "tightbeam:batcher" => ~w(superseded)
  }

  @reason_matrix %{
    "requester_withdrew" => {~w(verb_call), ~w(no_replacement)},
    "superseded" =>
      {~w(wake progress_attest monitor_generation decision_request),
       ~w(replacement no_replacement)},
    "obligation_disposed" =>
      {~w(assignment_transition work_item_transition decision_request monitor_generation),
       ~w(disposition)},
    "routing_bracket_satisfied" =>
      {~w(assignment_transition work_item_transition routing_bracket),
       ~w(replacement disposition)},
    "target_retired" => {~w(session_transition), ~w(replacement no_replacement)},
    "production_unmatched" => {~w(condition_fact), ~w(no_replacement)},
    "consumer_unavailable" => {~w(scheduler_delivery), ~w(no_replacement)},
    "target_unresolvable" => {~w(scheduler_delivery), ~w(no_replacement)}
  }

  @doc """
  Cancel one pending wake through the typed provenance seam.

  Commands use atom keys and closed string classifications. They contain
  `:wake_id`, optional `:expected_origin`, `:requester`, `:reason_kind`,
  `:causal_source`, and one tagged `:outcome`. This function derives linked
  work impact and the action-needed bit from durable rows. A successful public
  verb cancellation returns `{:accepted_in_txn, event_id, %{canceled: true}}`;
  a successful internal cancellation returns `true`, and refusal returns `false`.
  """
  @spec cancel_in_txn(Txn.t(), map()) :: cancellation_result()
  def cancel_in_txn(%Txn{} = txn, command), do: cancel_in_txn(txn, command, &now/0)

  @doc false
  @spec cancel_in_txn(Txn.t(), map(), (-> non_neg_integer())) :: cancellation_result()
  def cancel_in_txn(%Txn{} = txn, command, clock)
      when is_map(command) and is_function(clock, 0) do
    with {:ok, wake} <- pending_wake(txn, command),
         :ok <- authorize_cancel(command, wake),
         {:ok, primary} <- primary_work(txn, wake),
         {:ok, canceled_at} <- capture_clock(clock),
         {:ok, cancellation} <-
           validate_cancellation(txn, command, wake, primary, canceled_at) do
      NoticeBatcher.cancel_source_in_txn(
        txn,
        wake.wake_id,
        cancellation_reference(command, canceled_at)
      )

      commit_cancellation(txn, wake, cancellation)
    else
      _ -> false
    end
  end

  def cancel_in_txn(%Txn{}, _command, _clock), do: false

  defp cancellation_reference(command, canceled_at) do
    source = Map.get(command, :causal_source, %{})
    "#{source[:kind] || "unknown"}:#{source[:id] || "unknown"}:#{canceled_at}"
  end

  defp capture_clock(clock) do
    case clock.() do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp pending_wake(txn, %{wake_id: wake_id}) when is_binary(wake_id) do
    rows =
      Txn.q(
        txn,
        "SELECT wakeId, origin, state, conditionKind, work_item_id, assignmentId, consumer FROM wakes WHERE wakeId=?1",
        [wake_id]
      )

    rows =
      case rows do
        [[^wake_id, _origin, "pending", _condition, _work_item, _assignment, _consumer]] ->
          rows

        _ ->
          Txn.q(
            txn,
            """
            SELECT w.wakeId, w.origin, w.state, w.conditionKind, w.work_item_id,
                   w.assignmentId, w.consumer
            FROM wake_retry_attempts r
            JOIN wakes w ON w.wakeId=r.wakeId
            WHERE r.rootWakeId=?1 AND r.outcome='pending' AND w.state='pending'
            ORDER BY r.attempt DESC LIMIT 1
            """,
            [wake_id]
          )
      end

    case rows do
      [
        [
          resolved_wake_id,
          origin,
          "pending",
          condition_kind,
          work_item_id,
          assignment_id,
          consumer
        ]
      ] ->
        {:ok,
         %{
           wake_id: resolved_wake_id,
           origin: origin,
           condition_kind: condition_kind,
           work_item_id: work_item_id,
           assignment_id: assignment_id,
           consumer: consumer
         }}

      _ ->
        :error
    end
  end

  defp pending_wake(_txn, _command), do: :error

  defp authorize_cancel(
         %{expected_origin: expected, requester: %{kind: kind, id: id}, reason_kind: reason},
         %{origin: expected}
       )
       when kind in @requester_kinds and is_binary(id) and id != "" and
              reason == "requester_withdrew",
       do: :ok

  defp authorize_cancel(
         %{requester: %{kind: "process", id: id}, reason_kind: reason} = command,
         _wake
       )
       when is_binary(id) and is_binary(reason) do
    if not Map.has_key?(command, :expected_origin) and
         reason in Map.get(@process_reasons, id, []),
       do: :ok,
       else: :error
  end

  defp authorize_cancel(_command, _wake), do: :error

  defp primary_work(_txn, %{assignment_id: nil, work_item_id: nil}),
    do: {:ok, %{kind: nil, id: nil, impact: "no_linked_work"}}

  defp primary_work(txn, %{assignment_id: nil, work_item_id: work_item_id}) do
    case work_item(txn, work_item_id) do
      {:ok, state} ->
        {:ok,
         %{
           kind: "work_item",
           id: work_item_id,
           impact: if(state == "open", do: "linked_work_open", else: "linked_work_not_open")
         }}

      :error ->
        :error
    end
  end

  defp primary_work(txn, %{assignment_id: assignment_id, work_item_id: direct_work_item}) do
    case Txn.q(txn, "SELECT state, workItemId FROM assignments WHERE id=?1", [assignment_id]) do
      [[assignment_state, assignment_work_item]]
      when is_nil(direct_work_item) or direct_work_item == assignment_work_item ->
        cond do
          assignment_state == "open" ->
            with :ok <- validate_optional_work_item(txn, assignment_work_item) do
              {:ok, %{kind: "assignment", id: assignment_id, impact: "linked_work_open"}}
            end

          is_binary(assignment_work_item) ->
            case work_item(txn, assignment_work_item) do
              {:ok, state} ->
                {:ok,
                 %{
                   kind: "work_item",
                   id: assignment_work_item,
                   impact:
                     if(state == "open",
                       do: "linked_work_open",
                       else: "linked_work_not_open"
                     )
                 }}

              :error ->
                :error
            end

          true ->
            {:ok, %{kind: "assignment", id: assignment_id, impact: "linked_work_not_open"}}
        end

      _ ->
        :error
    end
  end

  defp validate_optional_work_item(_txn, nil), do: :ok

  defp validate_optional_work_item(txn, work_item_id) do
    case work_item(txn, work_item_id) do
      {:ok, _state} -> :ok
      :error -> :error
    end
  end

  defp work_item(txn, work_item_id) when is_binary(work_item_id) do
    case Txn.q(txn, "SELECT state FROM work_items WHERE id=?1", [work_item_id]) do
      [[state]] -> {:ok, state}
      _ -> :error
    end
  end

  defp work_item(_txn, _work_item_id), do: :error

  defp validate_cancellation(
         txn,
         %{
           requester: %{kind: requester_kind, id: requester_id},
           reason_kind: reason_kind,
           causal_source: %{kind: source_kind} = causal_source,
           outcome: %{kind: outcome_kind} = outcome
         } = command,
         wake,
         primary,
         canceled_at
       )
       when requester_kind in @requester_kinds and reason_kind in @reason_kinds and
              source_kind in @source_kinds and
              outcome_kind in ["replacement", "disposition", "no_replacement"] and
              is_binary(requester_id) and requester_id != "" do
    source_id = Map.get(causal_source, :id)

    with :ok <- compatible?(requester_id, reason_kind, source_kind, outcome_kind),
         {:ok, tagged} <-
           validate_outcome(txn, outcome_kind, outcome, wake, primary, requester_id, command),
         {:ok, durable_source_id, accepted_event_id} <-
           durable_source(txn, command, source_kind, source_id, wake, canceled_at) do
      {:ok,
       Map.merge(tagged, %{
         requester_kind: requester_kind,
         requester_id: requester_id,
         reason_kind: reason_kind,
         source_kind: source_kind,
         source_id: durable_source_id,
         accepted_event_id: accepted_event_id,
         canceled_at: canceled_at,
         primary_kind: primary.kind,
         primary_id: primary.id,
         work_impact: primary.impact
       })}
    end
  end

  defp validate_cancellation(_txn, _command, _wake, _primary, _canceled_at), do: :error

  defp durable_source(txn, _command, source_kind, source_id, wake, _canceled_at)
       when source_kind != "verb_call" and is_binary(source_id) and source_id != "" do
    case validate_source(txn, source_kind, source_id, wake) do
      :ok -> {:ok, source_id, nil}
      :error -> :error
    end
  end

  defp durable_source(
         txn,
         %{
           expected_origin: expected_origin,
           requester: requester,
           causal_source: %{
             kind: "verb_call",
             accepted_event:
               %{
                 origin: event_origin,
                 session_key: session_key,
                 principal: principal
               } = accepted_event
           }
         } = command,
         "verb_call",
         nil,
         wake,
         canceled_at
       ) do
    with true <- event_origin == expected_origin and event_origin == wake.origin,
         true <- map_size(command.causal_source) == 2,
         true <- map_size(accepted_event) == 3,
         true <- is_nil(session_key) or is_binary(session_key),
         true <- requester_principal?(requester, principal),
         payload = JSON.encode!(%{cancel_wake_id: wake.wake_id, canceled: true}) do
      event_id =
        EventLog.append_event_in_txn(
          txn,
          "verb",
          "wake",
          event_origin,
          session_key,
          payload,
          principal,
          canceled_at
        )

      {:ok, Integer.to_string(event_id), event_id}
    else
      _ -> :error
    end
  end

  defp durable_source(_txn, _command, _source_kind, _source_id, _wake, _canceled_at),
    do: :error

  defp requester_principal?(%{kind: "user", id: id}, {:user, id}), do: true
  defp requester_principal?(%{kind: "session", id: id}, {:session, id}), do: true
  defp requester_principal?(%{kind: "process", id: id}, {:process, id}), do: true
  defp requester_principal?(_requester, _principal), do: false

  defp compatible?(requester_id, reason, source, outcome) do
    {sources, outcomes} = Map.fetch!(@reason_matrix, reason)

    cond do
      source not in sources or outcome not in outcomes ->
        :error

      requester_id == "tightbeam:supervision" ->
        if reason == "superseded" and source == "progress_attest" and
             outcome == "no_replacement",
           do: :ok,
           else: :error

      reason == "superseded" and outcome == "no_replacement" ->
        :error

      true ->
        :ok
    end
  end

  defp validate_source(txn, "wake", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", source_id)

  defp validate_source(txn, "scheduler_delivery", source_id, wake) do
    if source_id == wake.wake_id,
      do: row_exists(txn, "SELECT 1 FROM wakes WHERE wakeId=?1", source_id),
      else: :error
  end

  defp validate_source(txn, "progress_attest", source_id, wake) do
    case Txn.q(
           txn,
           """
           SELECT 1
           FROM attests a
           JOIN supervision_entitlements e ON e.assignmentId=a.assignmentId
           WHERE a.id=?1 AND a.kind='progress' AND a.assignmentId=?2
             AND e.basisKind='progress' AND e.basisId=a.id
           """,
           [source_id, wake.assignment_id]
         ) do
      [[1]] -> :ok
      _ -> :error
    end
  end

  defp validate_source(txn, "condition_fact", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM condition_facts WHERE CAST(id AS TEXT)=?1", source_id)

  defp validate_source(txn, "assignment_transition", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM assignments WHERE id=?1", source_id)

  defp validate_source(txn, "work_item_transition", source_id, _wake),
    do:
      row_exists(
        txn,
        "SELECT 1 FROM causal_events WHERE CAST(seq AS TEXT)=?1 AND kind='disposition_transition'",
        source_id
      )

  defp validate_source(txn, "decision_request", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM decision_requests WHERE id=?1", source_id)

  defp validate_source(txn, "monitor_generation", source_id, _wake),
    do: generation_exists(txn, source_id)

  defp validate_source(txn, "routing_bracket", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM work_items WHERE id=?1", source_id)

  defp validate_source(txn, "session_transition", source_id, _wake),
    do: row_exists(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1", source_id)

  defp validate_outcome(
         txn,
         "replacement",
         outcome,
         wake,
         primary,
         requester_id,
         _command
       ) do
    replacement_id = Map.get(outcome, :replacement_wake_id)

    with true <- primary.impact != "linked_work_not_open",
         true <- is_binary(replacement_id) and replacement_id != wake.wake_id,
         :ok <- replacement_matches(txn, replacement_id, primary, requester_id),
         true <- is_nil(Map.get(outcome, :disposition_kind)),
         true <- is_nil(Map.get(outcome, :disposition_id)),
         true <- is_nil(Map.get(outcome, :liveness_trigger)) do
      {:ok,
       %{
         outcome_kind: "replacement",
         replacement_wake_id: replacement_id,
         disposition_kind: nil,
         disposition_id: nil,
         liveness_kind: nil,
         liveness_id: nil,
         action_needed: 0
       }}
    else
      _ -> :error
    end
  end

  defp validate_outcome(
         txn,
         "disposition",
         outcome,
         wake,
         primary,
         _requester_id,
         command
       ) do
    disposition_kind = Map.get(outcome, :disposition_kind)
    disposition_id = Map.get(outcome, :disposition_id)

    with true <- disposition_kind in @disposition_kinds and is_binary(disposition_id),
         :ok <- validate_disposition(txn, disposition_kind, disposition_id),
         true <- is_nil(Map.get(outcome, :replacement_wake_id)),
         {:ok, liveness} <- validate_required_liveness(txn, outcome, wake, primary, command) do
      {:ok,
       Map.merge(liveness, %{
         outcome_kind: "disposition",
         replacement_wake_id: nil,
         disposition_kind: disposition_kind,
         disposition_id: disposition_id
       })}
    else
      _ -> :error
    end
  end

  defp validate_outcome(
         txn,
         "no_replacement",
         outcome,
         wake,
         primary,
         _requester_id,
         command
       ) do
    with true <- is_nil(Map.get(outcome, :replacement_wake_id)),
         true <- is_nil(Map.get(outcome, :disposition_kind)),
         true <- is_nil(Map.get(outcome, :disposition_id)),
         {:ok, liveness} <- validate_required_liveness(txn, outcome, wake, primary, command) do
      {:ok,
       Map.merge(liveness, %{
         outcome_kind: "no_replacement",
         replacement_wake_id: nil,
         disposition_kind: nil,
         disposition_id: nil
       })}
    else
      _ -> :error
    end
  end

  defp validate_required_liveness(_txn, outcome, _wake, %{impact: impact}, _command)
       when impact != "linked_work_open" do
    if is_nil(Map.get(outcome, :liveness_trigger)) do
      {:ok, %{liveness_kind: nil, liveness_id: nil, action_needed: 0}}
    else
      :error
    end
  end

  defp validate_required_liveness(txn, outcome, wake, primary, command) do
    case Map.get(outcome, :liveness_trigger) do
      %{kind: kind, id: id} when kind in @liveness_kinds and is_binary(id) ->
        case validate_liveness(txn, kind, id, wake, primary) do
          :ok -> {:ok, %{liveness_kind: kind, liveness_id: id, action_needed: 1}}
          :error -> :error
        end

      nil ->
        if exact_terminal_effort_request?(txn, command, outcome, wake, primary),
          do: {:ok, %{liveness_kind: nil, liveness_id: nil, action_needed: 0}},
          else: :error

      _ ->
        :error
    end
  end

  # An open effort request is itself the agent's exit. Once the current
  # expecter transitions that exact request, the transition is sufficient
  # typed proof to cancel only its own deadline controller. This does not
  # stand in for liveness on any other wake: every identity and carrier field
  # is joined back to the terminal request row in this transaction.
  defp exact_terminal_effort_request?(
         txn,
         command,
         %{
           kind: "disposition",
           disposition_kind: "decision_request_transition",
           disposition_id: request_id
         },
         %{
           wake_id: wake_id,
           assignment_id: assignment_id,
           consumer: "effort_deadline"
         },
         %{kind: "assignment", id: assignment_id, impact: "linked_work_open"}
       ) do
    with %{
           requester: %{kind: "process", id: "tightbeam:effort-checkin"},
           reason_kind: "obligation_disposed",
           causal_source: %{kind: "decision_request", id: ^request_id}
         } <- command,
         %{id: ^request_id, assignment_id: ^assignment_id, deadline_wake_id: ^wake_id} <-
           Escalation.effort_terminal_in_txn(txn, request_id) do
      true
    else
      _ -> false
    end
  end

  defp exact_terminal_effort_request?(_txn, _command, _outcome, _wake, _primary), do: false

  # The plain 3-arity form is every OTHER caller of this check (today, only
  # `validate_liveness/5`'s `pending_wake` clause, which is not a batcher
  # supersession) — `requester_id: nil` never qualifies for the exemption
  # below, so those callers keep the exact same-primary-work rule they
  # always had.
  defp replacement_matches(txn, replacement_id, primary),
    do: replacement_matches(txn, replacement_id, primary, nil)

  defp replacement_matches(txn, replacement_id, primary, requester_id) do
    case Txn.q(
           txn,
           "SELECT wakeId, origin, state, conditionKind, work_item_id, assignmentId, digest FROM wakes WHERE wakeId=?1",
           [replacement_id]
         ) do
      [[^replacement_id, origin, state, condition_kind, work_item_id, assignment_id, digest]] ->
        replacement = %{
          wake_id: replacement_id,
          origin: origin,
          condition_kind: condition_kind,
          work_item_id: work_item_id,
          assignment_id: assignment_id
        }

        case {valid_replacement_state?(txn, requester_id, replacement_id, state, digest),
              primary_work(txn, replacement)} do
          {false, _} ->
            :error

          {true, {:ok, replacement_primary}} ->
            cond do
              is_nil(primary.kind) ->
                :ok

              {replacement_primary.kind, replacement_primary.id} == {primary.kind, primary.id} ->
                :ok

              digest_carrier_exemption?(requester_id, digest) ->
                :ok

              true ->
                :error
            end

          {true, :error} ->
            :error
        end

      _ ->
        :error
    end
  end

  defp valid_replacement_state?(_txn, _requester_id, _replacement_id, "pending", _digest),
    do: true

  defp valid_replacement_state?(
         txn,
         "tightbeam:batcher",
         replacement_id,
         "fired",
         1
       ) do
    row_exists(txn, "SELECT 1 FROM notice_batches WHERE deliveryWakeId=?1", replacement_id) ==
      :ok
  end

  defp valid_replacement_state?(_txn, _requester_id, _replacement_id, _state, _digest),
    do: false

  # O4 ROOT CAUSE, THE NAMED EXEMPTION — not a general bypass. A digest
  # carrier's own linked work is inherited from its group when every linked
  # member agrees on one (`shared_work/1`); this exemption is reached only
  # for a GENUINELY mixed group, where no single work item or assignment
  # could honestly describe the carrier. It is scoped as tight as the
  # mechanism it exists for: the replacement must actually BE a digest
  # carrier (`digest = 1`, not merely claimed to be one), and the requester
  # must be the batcher's own reserved process id — nobody else's
  # "replacement" outcome gets a pass on matching its primary work.
  defp digest_carrier_exemption?("tightbeam:batcher", 1), do: true
  defp digest_carrier_exemption?(_requester_id, _digest), do: false

  defp validate_disposition(txn, "assignment_transition", id),
    do: row_exists(txn, "SELECT 1 FROM assignments WHERE id=?1", id)

  defp validate_disposition(txn, "work_item_transition", id),
    do:
      row_exists(
        txn,
        "SELECT 1 FROM causal_events WHERE CAST(seq AS TEXT)=?1 AND kind='disposition_transition'",
        id
      )

  defp validate_disposition(txn, "decision_request_transition", id),
    do: row_exists(txn, "SELECT 1 FROM decision_requests WHERE id=?1", id)

  defp validate_disposition(txn, "monitor_generation_transition", id),
    do: generation_exists(txn, id)

  defp validate_liveness(txn, "supervision_entitlement", id, wake, primary) do
    with {:ok, assignment_id, generation} <- split_generation(id),
         [[work_item_id, holder_state]] <-
           Txn.q(
             txn,
             """
             SELECT a.workItemId, s.state
             FROM supervision_entitlements e
             JOIN assignments a ON a.id=e.assignmentId
             JOIN sessions s ON s.sessionKey=a.holderKey
             WHERE e.assignmentId=?1 AND e.generation=?2
               AND e.state IN ('armed','claimed') AND a.state='open'
             """,
             [assignment_id, generation]
           ),
         true <-
           holder_state == "active" or
             (holder_state == "retired" and wake.consumer == "effort_probe") or
             current_controller_carries_entitlement?(txn, wake, assignment_id, generation),
         true <-
           {primary.kind, primary.id} == {"assignment", assignment_id} or
             ({primary.kind, primary.id} == {"work_item", work_item_id} and
                is_binary(work_item_id)) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_liveness(txn, "supervision_transfer", id, _wake, primary),
    do: Tightbeam.Supervision.accepted_transfer?(txn, id, primary)

  defp validate_liveness(txn, "pending_wake", id, wake, primary) do
    with true <- id != wake.wake_id,
         :ok <- replacement_matches(txn, id, primary),
         [] <-
           Txn.q(
             txn,
             "SELECT 1 FROM work_items WHERE id=?1 AND (routingWakeId=?2 OR slateWakeId=?2)",
             [primary.id, id]
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_liveness(txn, "routing_bracket", id, _wake, %{kind: "work_item", id: id}) do
    case Txn.q(
           txn,
           """
           SELECT 1
           FROM work_items wi
           JOIN wakes w ON w.wakeId=wi.routingWakeId OR w.wakeId=wi.slateWakeId
           WHERE wi.id=?1 AND w.state='pending'
           """,
           [id]
         ) do
      [[1]] -> :ok
      _ -> :error
    end
  end

  defp validate_liveness(_txn, _kind, _id, _wake, _primary), do: :error

  # When the target disappears between scheduling and delivery, the controller
  # being canceled is itself the proof that this exact entitlement survives the
  # cancellation. This is narrower than treating every inactive holder's
  # entitlement as actionable: only its current pending controller qualifies.
  defp current_controller_carries_entitlement?(txn, wake, assignment_id, generation) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM supervision_liveness_sidecar
      WHERE wakeId=?1 AND assignmentId=?2 AND controllerOrigin='scheduled'
        AND controllerState='pending' AND chargedGeneration=?3
      """,
      [wake.wake_id, assignment_id, generation]
    ) == [[1]]
  end

  defp generation_exists(txn, id) do
    with {:ok, assignment_id, generation} <- split_generation(id) do
      row_exists(
        txn,
        "SELECT 1 FROM effort_checkin_generations WHERE assignmentId=?1 AND generation=?2",
        [assignment_id, generation]
      )
    end
  end

  defp split_generation(id) do
    case String.split(id, "#", parts: 2) do
      [assignment_id, generation] ->
        case Integer.parse(generation) do
          {value, ""} -> {:ok, assignment_id, value}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp row_exists(txn, sql, value) when not is_list(value),
    do: row_exists(txn, sql, [value])

  defp row_exists(txn, sql, params) do
    case Txn.q(txn, sql, params) do
      [[1]] -> :ok
      _ -> :error
    end
  end

  defp commit_cancellation(txn, wake, cancellation) do
    canceled_at = cancellation.canceled_at

    Txn.q(
      txn,
      """
      INSERT INTO wake_cancellations
        (wakeId, wakeState, canceledAt, requesterKind, requesterId, reasonKind,
         causalSourceKind, causalSourceId, outcomeKind, replacementWakeId,
         dispositionKind, dispositionId, primaryWorkKind, primaryWorkId,
         workImpactKind, livenessTriggerKind, livenessTriggerId, actionNeeded)
      VALUES (?1, 'canceled', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
              ?12, ?13, ?14, ?15, ?16, ?17)
      """,
      [
        wake.wake_id,
        canceled_at,
        cancellation.requester_kind,
        cancellation.requester_id,
        cancellation.reason_kind,
        cancellation.source_kind,
        cancellation.source_id,
        cancellation.outcome_kind,
        cancellation.replacement_wake_id,
        cancellation.disposition_kind,
        cancellation.disposition_id,
        cancellation.primary_kind,
        cancellation.primary_id,
        cancellation.work_impact,
        cancellation.liveness_kind,
        cancellation.liveness_id,
        cancellation.action_needed
      ]
    )

    Txn.q(
      txn,
      "UPDATE wakes SET state='canceled', canceledAt=?2 WHERE wakeId=?1 AND state='pending'",
      [wake.wake_id, canceled_at]
    )

    if Txn.changes(txn) == 1 do
      Txn.q(
        txn,
        "UPDATE wake_retry_attempts SET outcome='canceled', observedAt=?2 WHERE wakeId=?1 AND outcome='pending'",
        [wake.wake_id, canceled_at]
      )

      Txn.q(
        txn,
        """
        UPDATE supervision_liveness_sidecar
        SET controllerState='settled'
        WHERE wakeId=?1 AND controllerOrigin IN ('scheduled','holder_continuation') AND controllerState='pending'
        """,
        [wake.wake_id]
      )

      if is_binary(wake.assignment_id) do
        reconcile_wait_relief_in_txn(txn, wake.assignment_id, canceled_at)
      end

      if is_binary(wake.condition_kind) do
        EventLog.lifecycle_in_txn(
          txn,
          "wake_condition_canceled",
          wake.wake_id,
          "by=#{cancellation.requester_kind}:#{cancellation.requester_id}"
        )
      end

      cancellation_result(cancellation)
    else
      false
    end
  end

  defp cancellation_result(%{accepted_event_id: event_id})
       when is_integer(event_id) and event_id > 0,
       do: {:accepted_in_txn, event_id, %{canceled: true}}

  defp cancellation_result(_cancellation), do: true

  @spec get(db(), String.t()) :: wake() | nil
  def get(db \\ Tightbeam.DB, wake_id) do
    {:ok, rows} = DB.query(db, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id])

    case rows do
      [row] -> to_wake(row)
      [] -> nil
    end
  end

  @doc false
  @spec get_in_txn(Txn.t(), String.t()) :: wake() | nil
  def get_in_txn(%Txn{} = txn, wake_id), do: wait_in_txn(txn, wake_id)

  @doc "All pending wakes, soonest first (inspect filters to owned sessions)."
  @spec list_pending(db()) :: [wake()]
  def list_pending(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <>
          " WHERE state = 'pending' AND consumer = 'prompt' ORDER BY dueAt ASC"
      )

    Enum.map(rows, &to_wake/1)
  end

  @doc "Count pending wakes resolved to a session key."
  @spec pending_count(db(), String.t()) :: non_neg_integer()
  def pending_count(db \\ Tightbeam.DB, session_key) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM wakes WHERE state = 'pending' AND consumer = 'prompt' AND sessionKey = ?1",
        [session_key]
      )

    count
  end

  @doc """
  Count pending wakes targeting a session that were durably created by that
  same session.

  HELD CLASSED MEMBERS DO NOT COUNT (Sol xhigh review, finding 8). A row still
  waiting on the batcher (`digest = 0` under `deliveryRule = digest_rule`) is
  not a queued continuation supervision can rely on — it may not actually
  reach the session for up to a class ceiling's worth of time. Counting it
  here let an unrelated `fyi` self-wake suppress the turn-end remedy for as
  long as four hours. The materialized CARRIER (`digest = 1`) is not held —
  it is what the batcher already decided to deliver — and counts normally.
  """
  @spec self_pending_count(db(), String.t()) :: non_neg_integer()
  def self_pending_count(db \\ Tightbeam.DB, session_key) do
    {:ok, [[count]]} =
      DB.query(
        db,
        """
        SELECT count(*) FROM wakes
        WHERE state = 'pending' AND consumer = 'prompt'
          AND sessionKey = ?1 AND creatorSessionKey = ?1
          -- `IS`, not `=`: an unclassed wake's deliveryRule is NULL, and
          -- `NULL = ?2` is NULL (neither true nor false) under SQL's
          -- three-valued logic, which would silently exclude it too. `IS`
          -- compares NULL correctly and only a held digest source under one
          -- of the two mechanically distinct rule revisions matches.
          AND NOT (digest = 0 AND (deliveryRule IS ?2 OR deliveryRule IS ?3))
        """,
        [session_key, @digest_rule, @legacy_digest_rule]
      )

    count
  end

  ## The batcher (fabric §5 `batcher`; Invariant 3)

  @doc """
  Materialize every digest whose delivery moment has arrived.

  ONE TURN FOR N PAYLOADS. Members are grouped by target AND class — per-class,
  because the ceiling is per-class and mixing a four-hour `fyi` with a
  thirty-minute `input-needed` would either delay one or promote the other.
  The TARGET half of the group key is the session for a session-addressed
  member, but the ROLE itself for a role-addressed one (O2): a role's bound
  session can change between two members' filing times, and grouping by
  whatever session each one happened to resolve to at that moment would
  split one audience into several groups and leave the carrier unable to
  re-resolve at delivery. A role group's carrier carries `targetRole`
  forward so it re-resolves the SAME way any other role-addressed wake does.

  THE EXIT IS TIME OR A TURN BOUNDARY, never a decision (Invariant 3):

    * the target's next turn boundary — a turn of its own ended at or after
      THIS member was filed; a turn boundary is a turn ENDING, so queued or
      running work behind it is not a reason to hold (the wake joins the
      queue — that IS what "materializing one turn" means); or
    * the class ceiling — which is the member's own `dueAt`, so an idle session
      that never takes another turn still has its digest materialize one.

  ELIGIBILITY AND MEMBERSHIP ARE ONE TRANSACTIONALLY COHERENT SNAPSHOT (Sol
  xhigh review, finding 2). There is no outer "is this group due" query whose
  answer the transaction later trusts: each member's OWN ceiling and OWN
  filing time are re-read and re-judged from the SAME snapshot the transaction
  uses to select members, so a wake filed after another member's boundary or
  ceiling already passed waits for its own — never absorbed by somebody
  else's trigger. `due_reason` is computed exactly once, from that snapshot,
  per member (finding 4): a member with no named reason is left pending, never
  materialized under an empty `trigger=`.

  SOURCE ROWS ARE PRESERVED (Law 2, wi_1100e078's title). A member is consumed
  through the typed cancellation seam as `superseded` with the digest named as
  its REPLACEMENT — the same shape re-resolution already uses. Its prompt, its
  sender, its class and its election all stay on the row; the digest-member
  audit is one join over `wake_cancellations`. Nothing is deleted and nothing
  is summarized away.
  """
  @spec materialize_digests(db()) :: [String.t()]
  def materialize_digests(db \\ Tightbeam.DB), do: materialize_digests(db, now())

  @doc false
  @spec materialize_digests(db(), integer()) :: [String.t()]
  def materialize_digests(db, at) do
    NoticeBatcher.recover(db, at) ++ legacy_materialize_digests(db, at)
  end

  # Compatibility path: rows stamped by the Phase-1 digest rule, including
  # default-off and rollback admission, keep that versioned rule through the
  # carrier and every provenance row.
  defp legacy_materialize_digests(db, at) do
    {:ok, groups} =
      DB.query(
        db,
        """
        SELECT DISTINCT targetRole, sessionKey, class
        FROM wakes
        WHERE state = 'pending' AND consumer = 'prompt' AND digest = 0
          AND deliveryRule = ?1
        """,
        [@legacy_digest_rule]
      )

    groups
    |> Enum.map(fn
      [role, _session_key, class] when is_binary(role) -> {:role, role, class}
      [nil, session_key, class] -> {:session, session_key, class}
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn group_key ->
      case safe_materialize_digest(db, group_key, at) do
        nil -> []
        wake_id -> [wake_id]
      end
    end)
  end

  # PER-GROUP ISOLATION (O4; philosophy gate Q3/Q7). A raise inside
  # `materialize_members/4` still rolls back atomically for ITS OWN group —
  # Law 2 holds, nothing is half-consumed — but letting it escape this far
  # would crash the scheduler's GenServer on every tick until an operator
  # intervened at a console, which is exactly the repair-requires-an-admin
  # shape the gate forbids. Catching it HERE, one group at a time, makes the
  # repair agent-reachable: the named row below is the visible, actionable
  # failure; the group's own members stay genuinely pending, not silently
  # dropped, and the SAME group is retried next tick — bounded by the
  # avasarala floor on whichever member's obligation is oldest.
  defp safe_materialize_digest(db, group_key, at) do
    materialize_digest(db, group_key, at)
  rescue
    error -> file_materialization_failure(db, group_key, Exception.message(error))
  catch
    kind, reason -> file_materialization_failure(db, group_key, inspect({kind, reason}))
  end

  # SIGNED LIKE THE SUCCESS PATH (Sol xhigh review, finding 3 — §8
  # legibility): `wake_digest_materialized` names `rule=` alongside its
  # target/class/trigger, and a FAILURE is exactly the row an agent most
  # needs to know which reflex to inhibit — `@digest_rule` names the batcher
  # revision that was attempting this materialization when it failed, not
  # just where and why.
  defp file_materialization_failure(db, group_key, detail) do
    label = group_label(group_key)
    record = "rule=#{@legacy_digest_rule} target=#{label} reason=#{detail}"
    Logger.error("wake digest materialization failed for #{label}: #{detail}")
    best_effort_lifecycle(db, "wake_digest_materialization_failed", label, record)
    nil
  end

  defp group_label({:session, session_key, class}), do: "#{session_key}/#{class}"
  defp group_label({:role, role, class}), do: "role:#{role}/#{class}"

  defp materialize_digest(db, group_key, at) do
    transaction!(db, fn txn ->
      members = group_members(txn, group_key)
      materialize_due(txn, group_key, at, members)
    end)
  end

  # Filing order. `createdAt` ties inside a millisecond, and the tie must not
  # be broken by an id, which is random: rowid IS the order the org filed
  # them in, and a digest that reordered its members would misreport the
  # sequence a reader is trying to reconstruct. `work_item_id`/`assignmentId`
  # ride along for `shared_work/1` (O4) — the carrier's own linked-work
  # inheritance, decided once membership is known.
  defp group_members(txn, {:role, role, class}) do
    Txn.q(
      txn,
      """
      SELECT wakeId, prompt, origin, creatorSessionKey, createdAt, dueAt,
             work_item_id, assignmentId
      FROM wakes
      WHERE state = 'pending' AND consumer = 'prompt' AND digest = 0
        AND deliveryRule = ?1 AND targetRole = ?2 AND class = ?3
      ORDER BY createdAt ASC, rowid ASC
      """,
      [@legacy_digest_rule, role, class]
    )
  end

  defp group_members(txn, {:session, session_key, class}) do
    Txn.q(
      txn,
      """
      SELECT wakeId, prompt, origin, creatorSessionKey, createdAt, dueAt,
             work_item_id, assignmentId
      FROM wakes
      WHERE state = 'pending' AND consumer = 'prompt' AND digest = 0
        AND deliveryRule = ?1 AND targetRole IS NULL AND sessionKey = ?2 AND class = ?3
      ORDER BY createdAt ASC, rowid ASC
      """,
      [@legacy_digest_rule, session_key, class]
    )
  end

  # Nothing pending for this group in THIS snapshot — a race with another
  # materialization, not an error: nothing to carry, nothing to sign.
  defp materialize_due(_txn, _group_key, _at, []), do: nil

  defp materialize_due(txn, group_key, at, members) do
    boundary = group_boundary(txn, group_key)

    due =
      members
      |> Enum.map(fn [
                       wake_id,
                       prompt,
                       origin,
                       creator,
                       created_at,
                       due_at,
                       work_item_id,
                       assignment_id
                     ] ->
        {[wake_id, prompt, origin, creator, created_at, work_item_id, assignment_id],
         member_due_reason(at, due_at, boundary, created_at)}
      end)
      |> Enum.filter(fn {_row, reason} -> reason != nil end)

    case due do
      # Candidate group, but not ONE of its current members has reached its
      # own ceiling or seen a boundary since it was filed. Nothing is due —
      # refuse silently rather than materialize under a reason nobody can
      # name (finding 4): every member simply waits for its own trigger.
      [] ->
        nil

      _ ->
        # Ceiling wins the tie: a digest whose members are due by both
        # guarantees reports the one that bounds it.
        reason =
          if Enum.any?(due, fn {_row, r} -> r == "ceiling" end),
            do: "ceiling",
            else: "turn-boundary"

        rows = Enum.map(due, fn {row, _reason} -> row end)
        materialize_members(txn, group_key, reason, at, rows)
    end
  end

  # THE TARGET WHOSE BOUNDARY GOVERNS THIS GROUP (O2). A session-addressed
  # group's target is fixed. A role-addressed group's target is whoever the
  # role resolves to RIGHT NOW, re-read every materialization pass through
  # the SAME txn-safe resolution `Gateway.delivery_target/3` already uses for
  # an ordinary role-addressed wake at fire time — so a rebind between ticks
  # changes whose turns release the digest early, exactly as it changes who
  # receives it. An unresolvable role reports no boundary; the ceiling still
  # governs, and delivery-time resolution (or its `wake_unresolved` row) is
  # what actually happens when the carrier fires.
  defp group_boundary(txn, {:session, session_key, _class}), do: latest_turn_end(txn, session_key)

  defp group_boundary(txn, {:role, role, _class}) do
    case Gateway.delivery_target(txn, nil, %{target_role: role}) do
      {session_key, _role, _fallback} -> latest_turn_end(txn, session_key)
      nil -> nil
    end
  end

  # A member's OWN eligibility (Sol xhigh review, finding 2): its own class
  # ceiling, or a turn of the target's own that ended STRICTLY AFTER THIS
  # member's own filing time — never another member's ceiling or another
  # member's boundary.
  #
  # STRICT `>`, not `>=` (Sol xhigh review round 2, finding 1): timestamps
  # here are millisecond-resolution wall-clock reads. A wake filed in the
  # SAME millisecond a turn ended is not provably filed BEFORE that turn's
  # end — the ordering is ambiguous, and ambiguous is not "the boundary
  # happened after this member was filed." An equal timestamp waits for the
  # member's own NEXT boundary or its ceiling, same as a wake filed a moment
  # later would.
  defp member_due_reason(at, due_at, boundary, created_at) do
    cond do
      at >= due_at -> "ceiling"
      is_integer(boundary) and boundary > created_at -> "turn-boundary"
      true -> nil
    end
  end

  # THE LATEST turn end for this session, or nil if none has ever ended. A
  # turn boundary is the moment an in-flight turn ENDS (finding 3) — nothing
  # here judges whether the session is otherwise busy; queued or running work
  # behind the boundary is not a reason to hold what already crossed it.
  defp latest_turn_end(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT MAX(endedAt) FROM turns WHERE sessionKey = ?1 AND endedAt IS NOT NULL",
           [session_key]
         ) do
      [[nil]] -> nil
      [[ended]] -> ended
    end
  end

  defp materialize_members(txn, group_key, reason, at, members) do
    {class, target_label, carrier_fields, pinned_owner} = carrier_shape(txn, group_key)
    {work_item_id, assignment_id} = shared_work(members)

    # MINTED HERE, not left to `schedule_in_txn`'s default (O5 follow-up: Sol
    # xhigh review, finding 2 — `digest-members` needs a wake id no agent
    # could otherwise discover). Minting it before the prompt is built is
    # what lets the delivered digest sign itself with its OWN id.
    carrier_wake_id = "w_" <> Tightbeam.Id.uuid4()

    digest =
      schedule_in_txn(
        txn,
        Map.merge(
          %{
            wake_id: carrier_wake_id,
            origin: "process:tightbeam",
            prompt: digest_prompt(class, members, carrier_wake_id, @legacy_digest_rule),
            due_at: at,
            class: class,
            digest: true,
            delivery_rule: @legacy_digest_rule,
            target_gate: 0,
            work_item_id: work_item_id,
            assignment_id: assignment_id
          },
          carrier_fields
        )
      )

    carried =
      Enum.count(members, fn [wake_id | _rest] ->
        cancel_in_txn(txn, %{
          wake_id: wake_id,
          requester: %{kind: "process", id: "tightbeam:batcher"},
          reason_kind: "superseded",
          causal_source: %{kind: "wake", id: digest.wake_id},
          outcome: %{kind: "replacement", replacement_wake_id: digest.wake_id}
        }) == true
      end)

    # ALL OR NOTHING. A member the batcher could not consume is a member whose
    # own wake is still pending WHILE a digest carrying its payload is about to
    # fire — the one failure worse than not batching at all, because the payload
    # lands twice and the record says once. There is nothing to accommodate
    # here: roll the whole materialization back and name what refused. (O4:
    # the caller — `safe_materialize_digest/3` — is what keeps this raise
    # scoped to ITS OWN group instead of taking the whole tick loop down.)
    if carried != length(members) do
      raise "incompatible_delivery_policy_v1: batcher consumed #{carried} of " <>
              "#{length(members)} digest members for #{target_label}/#{class}"
    end

    EventLog.lifecycle_in_txn(
      txn,
      "wake_digest_materialized",
      digest.wake_id,
      "rule=#{@legacy_digest_rule} target=#{target_label} class=#{class} members=#{carried} " <>
        "trigger=#{reason}" <> pinned_owner_field(pinned_owner)
    )

    digest.wake_id
  end

  # PIN THE PAST (specs roles-registry-v1.md:31 — Sol xhigh review round 2):
  # a role carrier's authority fact is decided HERE, once, in the SAME
  # transaction as the carrier itself, and never re-derived from a live role
  # lookup later. `nil` for a session group (there is no role to pin; the
  # carrier's own `sessionKey` already IS the pinned fact, durably, since
  # sessions are never hard-deleted).
  defp pinned_owner_field(nil), do: ""
  defp pinned_owner_field(owner), do: " ownerUserId=#{owner}"

  # THE CARRIER'S OWN TARGET (O2). A session group's carrier addresses that
  # session directly, exactly as before. A role group's carrier carries
  # `targetRole` forward so it re-resolves at delivery the SAME way any other
  # role-addressed wake does (gateway.ex's composition-root `deliver` fn) —
  # a rebind inside the ceiling window reaches the role's new holder, not
  # whoever held it when the members were filed. `sessionKey` still needs a
  # value (the column is NOT NULL) but delivery never reads it once
  # `targetRole` is set; it names the role's CURRENT resolution, audit-only,
  # never a fallback if that resolution later fails.
  #
  # THE FOURTH ELEMENT is the role's owner AT THIS MOMENT — read directly
  # off the `roles` table, once, here — for `materialize_members/4` to pin
  # into the SAME transaction's `wake_digest_materialized` lifecycle event.
  # A session group has no role, so it pins nothing (gateway.ex's read path
  # never needs it: `Org.get/2` on a real, permanently-resolvable session
  # already answers the ownership question for that case).
  defp carrier_shape(_txn, {:session, session_key, class}),
    do: {class, session_key, %{session_key: session_key}, nil}

  defp carrier_shape(txn, {:role, role, class}) do
    session_key =
      case Gateway.delivery_target(txn, nil, %{target_role: role}) do
        {resolved, _role, _fallback} -> resolved
        nil -> "role:#{role}"
      end

    {class, "role:#{role}", %{session_key: session_key, target_role: role}, role_owner(txn, role)}
  end

  defp role_owner(txn, role) do
    case Txn.q(txn, "SELECT ownerUserId FROM roles WHERE name=?1", [role]) do
      [[owner]] -> owner
      [] -> nil
    end
  end

  # O4 ROOT CAUSE: the carrier inherits the group's linked work WHEN EVERY
  # member that has one agrees on the SAME one — so `replacement_matches/4`'s
  # ordinary same-primary-work check passes genuinely, not through a bypass.
  # A member with no linked work never needed the carrier to match anything
  # (`validate_outcome`'s `is_nil(primary.kind)` clause already lets it
  # through unconditionally), so it is excluded from the agreement check
  # entirely — only a GENUINE conflict between two linked members leaves the
  # carrier unlinked, and that narrower case is what
  # `digest_carrier_exemption?/2` names honestly, below.
  defp shared_work(members) do
    linked =
      members
      |> Enum.map(fn [_wid, _prompt, _origin, _creator, _created_at, work_item_id, assignment_id] ->
        {work_item_id, assignment_id}
      end)
      |> Enum.reject(&(&1 == {nil, nil}))
      |> Enum.uniq()

    case linked do
      [one] -> one
      _ -> {nil, nil}
    end
  end

  # THE BRIEF. Every payload appears in full and in filing order; the digest
  # summarizes nothing, because an optimization that loses rows is wrong. The
  # signature names the rule and its revision so a reader knows which reflex to
  # inhibit (§8 legibility) — and now names the carrier's OWN wake id (O5
  # follow-up), so the recipient can ask `digest-members <id>` about the
  # payload it just received without any surface but the message itself.
  defp digest_prompt(class, members, wake_id, rule) do
    body =
      members
      |> Enum.with_index(1)
      |> Enum.map(fn {[
                        _wake_id,
                        prompt,
                        origin,
                        creator,
                        _created_at,
                        _work_item_id,
                        _assignment_id
                      ], index} ->
        "#{index}. [#{class} from #{creator || origin}] #{prompt}"
      end)
      |> Enum.join("\n")

    "[digest] #{digest_signature(rule, length(members))} wake #{wake_id}\n\n#{body}"
  end

  @doc """
  Every source wake a digest carries, oldest first (fabric §11 acceptance 2).

  The audit that proves zero information loss: a digest that named a member it
  did not carry, or carried one it did not name, is visible here as a mismatch.

  PROVENANCE-TOTAL (Sol xhigh review, finding 6). Matching only
  `replacementWakeId`/`reasonKind`/`outcomeKind` proves a row was superseded
  BY SOMETHING naming this carrier as its replacement — not that the BATCHER
  carried it. The join also binds `requesterId` to the batcher and
  `causalSourceKind`/`causalSourceId` to THIS digest wake, so a non-batcher
  supersession that happens to point at the carrier (or a malformed
  cancellation whose causal wake differs from its replacement) cannot be
  reported as a member Law 2 never actually carried.
  """
  @spec digest_members(db(), String.t()) :: [map()]
  def digest_members(db \\ Tightbeam.DB, digest_wake_id) do
    current = NoticeBatcher.carrier_members(db, digest_wake_id)

    if current != [] do
      current
    else
      {:ok, rows} =
        DB.query(
          db,
          """
          SELECT w.wakeId, w.prompt, w.class, w.classElection, w.createdAt
          FROM wake_cancellations c
          JOIN wakes w ON w.wakeId = c.wakeId
          WHERE c.replacementWakeId = ?1 AND c.reasonKind = 'superseded'
            AND c.outcomeKind = 'replacement'
            AND c.requesterId = 'tightbeam:batcher'
            AND c.causalSourceKind = 'wake'
            AND c.causalSourceId = ?1
          ORDER BY w.createdAt ASC, w.rowid ASC
          """,
          [digest_wake_id]
        )

      Enum.map(rows, fn [wake_id, prompt, class, election, created_at] ->
        %{
          wake_id: wake_id,
          prompt: prompt,
          class: class,
          class_election: election,
          created_at: created_at
        }
      end)
    end
  end

  ## The classed-row read (fabric §12 Q5; §11 acceptance 1)

  @doc """
  A session's coordination share over a window: turns materialized by
  non-summon, non-algedonic wakes, against all its turns.

  §11's acceptance 1 measures the pilot with THIS query on both sides of desk
  stand-up, so it ships in Phase 1 — the before-window opens the moment classed
  rows exist. Its two exclusions are the two ways spending a mind's turn is the
  POINT rather than the waste: an `algedonic` alarm, which bypasses every bone
  by design, and a `summon`, which is a desk deliberately buying its principal's
  attention.

  A window with no turns reports `share: nil`, not `0.0`. Zero would be a claim
  about a session that did nothing, and the rows do not support it.

  This is a READ. It counts rows and files none; it makes no judgment about
  whether a share is good, and it names no threshold — the ruling on §11's
  acceptance is a mind's (Phase 3 exit), never this function's.
  """
  @spec coordination_share(db(), String.t(), integer(), integer()) :: map()
  def coordination_share(db \\ Tightbeam.DB, session_key, from, to) do
    {:ok, [[turns, wake_turns, classed, coordination, summons, algedonic]]} =
      DB.query(
        db,
        """
        SELECT
          COUNT(*),
          COALESCE(SUM(CASE WHEN t.wakeId IS NOT NULL THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN w.class IS NOT NULL THEN 1 ELSE 0 END), 0),
          -- §11.1's numerator: ALL non-summon, non-algedonic wake-materialized
          -- turns, CLASSED OR NOT (Sol xhigh review, finding 5). `w.class IS
          -- NOT NULL` excluded legacy unclassed wake turns entirely, undercounting
          -- the share this query exists to measure — a wake-materialized turn
          -- counts here whether or not the fabric ever stamped it.
          --
          -- `w.wakeId IS NOT NULL` — not `t.wakeId IS NOT NULL` (Sol xhigh
          -- review round 2, finding 3): the LEFT JOIN's `w.*` columns are also
          -- NULL when `t.wakeId` names a wake that does not exist (a dangling
          -- reference), and a naive `COALESCE(w.class, '') <> 'algedonic'`
          -- treats a JOIN MISS exactly like a real unclassed wake — counting
          -- a dangling reference as coordination traffic that was never
          -- actually materialized by any wake. Requiring the joined row
          -- excludes that case while still allowing a real wake's NULL class
          -- through: `w.class IS NOT 'algedonic'` is NULL-safe (`IS`/`IS NOT`
          -- never themselves evaluate to NULL), so it is true for a real
          -- unclassed wake and false only for an actual `algedonic` class —
          -- and once `w.wakeId IS NOT NULL` holds, `w.summon` is a real,
          -- NOT NULL column, so a plain `= 0` is safe without COALESCE.
          COALESCE(SUM(CASE WHEN w.wakeId IS NOT NULL
                             AND w.summon = 0
                             AND w.class IS NOT 'algedonic' THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN w.summon = 1 THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN w.class = 'algedonic' THEN 1 ELSE 0 END), 0)
        FROM turns AS t
        LEFT JOIN wakes AS w ON w.wakeId = t.wakeId
        WHERE t.sessionKey = ?1 AND t.createdAt >= ?2 AND t.createdAt < ?3
        """,
        [session_key, from, to]
      )

    {:ok, by_class} =
      DB.query(
        db,
        """
        SELECT w.class, COUNT(*)
        FROM turns AS t
        JOIN wakes AS w ON w.wakeId = t.wakeId
        WHERE t.sessionKey = ?1 AND t.createdAt >= ?2 AND t.createdAt < ?3
          AND w.class IS NOT NULL
        GROUP BY w.class
        """,
        [session_key, from, to]
      )

    %{
      session_key: session_key,
      from: from,
      to: to,
      turns: turns,
      wake_turns: wake_turns,
      classed_turns: classed,
      coordination_turns: coordination,
      summon_turns: summons,
      algedonic_turns: algedonic,
      share: if(turns > 0, do: coordination / turns),
      by_class: Map.new(by_class, fn [class, count] -> {class, count} end)
    }
  end

  @doc "Whether a delivered rumination wake exists for this work-item and caller session."
  @spec rumination_exists?(db(), String.t(), String.t()) :: boolean()
  def rumination_exists?(db \\ Tightbeam.DB, work_item_id, caller_session) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT 1 FROM wakes
        WHERE rumination = 1 AND work_item_id = ?1 AND creatorSessionKey = ?2
          AND state = 'fired'
        LIMIT 1
        """,
        [work_item_id, caller_session]
      )

    rows != []
  end

  ## Scheduler process

  @doc """
  Start the scheduler. Opts: `:deliver` (required — see `t:deliver/0`),
  `:db`, `:tick_ms` (default 1000), `:name` (default `Tightbeam.WakeScheduler`
  — the registered name the wake verb handler calls).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: Keyword.get(opts, :name, Tightbeam.WakeScheduler)
    )
  end

  @doc """
  Claim + deliver every due pending wake NOW (synchronous). The wake verb
  calls this after scheduling an immediate DM so delivery never waits a tick.
  """
  @spec fire_due(GenServer.server()) :: :ok
  def fire_due(server \\ Tightbeam.WakeScheduler) do
    if GenServer.whereis(server) == self() do
      send(self(), :fire_due)
      :ok
    else
      GenServer.call(server, :fire_due)
    end
  end

  @doc """
  Eagerly evaluate condition wakes for the fact(s) that just committed.

  A caller that filed SEVERAL facts in one transaction passes them as one
  ordered list: the scheduler drains them sequentially, and a saturation
  continuation carries the whole remaining list — so a later fact's fan-out
  never overtakes an unserved earlier fact's (§4.3/7g).
  """
  @spec fire_matching(GenServer.server(), pos_integer() | [pos_integer()]) :: :ok
  def fire_matching(_server, []), do: :ok

  def fire_matching(server, [fact_id]), do: fire_matching(server, fact_id)

  def fire_matching(server, fact_ids) when is_list(fact_ids) do
    GenServer.call(server, {:fire_matching_seq, fact_ids})
  end

  def fire_matching(server, fact_id) do
    GenServer.call(server, {:fire_matching, fact_id})
  end

  @doc false
  @spec recognize_condition_fact_in_txn(Txn.t(), pos_integer()) :: [term()]
  def recognize_condition_fact_in_txn(%Txn{} = txn, fact_id) do
    Txn.q(
      txn,
      """
      SELECT w.wakeId
      FROM condition_facts f
      JOIN wakes w INDEXED BY wakes_condition ON w.conditionKind=f.kind
      WHERE f.id=?1 AND w.state='pending' AND f.id>w.conditionAfterId
      ORDER BY w.rowid
      """,
      [fact_id]
    )
    |> Enum.flat_map(fn [wake_id] ->
      case Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [wake_id]) do
        [row] ->
          case fire_in_txn(txn, to_wake(row), fact_id) do
            {:fired, delivery} -> [delivery]
            :noop -> []
          end

        [] ->
          []
      end
    end)
  end

  @impl true
  def init(opts) do
    state = %{
      deliver: Keyword.fetch!(opts, :deliver),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      tick_ms: Keyword.get(opts, :tick_ms, 1_000),
      batch: Keyword.get(opts, :batch, 100),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      internal_consumers: Keyword.get(opts, :internal_consumers, %{})
    }

    schedule_tick(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:fire_due, _from, state) do
    deliver_due(state)
    {:reply, :ok, state}
  end

  def handle_call({:fire_matching, fact_id}, _from, state) do
    eager_step(state, fact_id)
    {:reply, :ok, state}
  end

  def handle_call({:fire_matching_seq, fact_ids}, _from, state) do
    drain_seq(state, fact_ids)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:fire_due, state) do
    deliver_due(state)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    deliver_due(state)
    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  def handle_info(:fire_matching, state) do
    if evaluate_conditions(state, :tick) == :saturated, do: send(self(), :fire_matching)
    {:noreply, state}
  end

  def handle_info({:fire_matching, fact_id}, state) do
    eager_step(state, fact_id)
    {:noreply, state}
  end

  def handle_info({:fire_matching_seq, fact_ids}, state) do
    drain_seq(state, fact_ids)
    {:noreply, state}
  end

  # One eager batch for one fact; saturation re-queues the same fact.
  defp eager_step(state, fact_id) do
    if evaluate_conditions(state, {:eager, fact_id}) == :saturated do
      send(self(), {:fire_matching, fact_id})
    end

    :ok
  end

  # Ordered multi-fact drain: the head fact must be fully served before any
  # later fact's fan-out starts; saturation carries the WHOLE remaining list
  # into the continuation so mailbox interleaving cannot reorder facts.
  defp drain_seq(_state, []), do: :ok

  defp drain_seq(state, [head | rest] = all) do
    case evaluate_conditions(state, {:eager, head}) do
      :saturated -> send(self(), {:fire_matching_seq, all})
      :done -> drain_seq(state, rest)
    end
  end

  # Deliver-then-mark (see moduledoc — never reorder): a raising deliver
  # leaves its wake pending for the next tick; a crash between deliver and
  # mark redelivers, deduped by turns.wakeId.
  defp deliver_due(%{db: db, deliver: deliver, internal_consumers: consumers} = state) do
    recognize_due_dependency_waits(db)
    deliver_eligible_waits(db, state.delivery_opts)

    # THE BATCHER RUNS FIRST, so a digest that just came due is delivered in
    # this same pass rather than waiting a tick. Held members are consumed here
    # and never reach the loop below as individual deliveries.
    materialize_digests(db)

    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <>
          " WHERE state = 'pending' AND dueAt <= ?1 AND conditionKind IS NULL AND waitMode IS NULL" <>
          " AND NOT (digest = 0 AND (deliveryRule IS ?2 OR deliveryRule IS ?3))" <>
          " ORDER BY dueAt ASC",
        [now(), @digest_rule, @legacy_digest_rule]
      )

    for row <- rows do
      wake = to_wake(row)

      if wake.digest, do: NoticeBatcher.delivery_attempted(db, wake.wake_id)

      delivery =
        case wake.consumer do
          "prompt" ->
            if suppressed_by_recognition?(db, wake) do
              :retry
            else
              attempt_delivery(fn -> deliver.(wake) end)
            end

          consumer ->
            case Map.fetch(consumers, consumer) do
              {:ok, internal_consumer} ->
                attempt_internal_delivery(db, wake, internal_consumer)

              :error ->
                undeliverable(db, wake, "unknown internal consumer #{inspect(consumer)}")
                false
            end
        end

      case {wake.consumer, delivery} do
        {"prompt", {:ok, :skipped}} when wake.digest ->
          NoticeBatcher.delivery_terminal_failure(db, wake.wake_id, :skipped)

        {"prompt", {:ok, _result}} ->
          mark_fired(db, wake.wake_id)
          if wake.digest, do: NoticeBatcher.delivery_delivered(db, wake.wake_id)

        _ ->
          if wake.digest,
            do: NoticeBatcher.delivery_failed_attempt(db, wake.wake_id, :not_committed)
      end
    end

    evaluate_conditions(state, :tick)
    :ok
  end

  defp recognize_due_dependency_waits(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM wakes
        WHERE state='pending' AND waitMode='dependency' AND recognitionAt IS NULL AND dueAt<=?1
        ORDER BY dueAt,wakeId
        """,
        [now()]
      )

    Enum.each(rows, fn [wake_id] ->
      case DB.transaction(db, fn txn -> recognize_due_dependency_in_txn(txn, wake_id) end) do
        {:ok, _} -> :ok
        {:error, error} -> raise error
      end
    end)
  end

  defp recognize_due_dependency_in_txn(txn, wake_id) do
    case wait_in_txn(txn, wake_id) do
      %{state: "pending", wait_mode: "dependency", recognition_at: nil} = wake ->
        evaluation = evaluate_wait_predicate_in_txn(txn, wake)
        resolver = resolver_for_wake_in_txn(txn, wake)
        recognized = recognize_from_snapshot_in_txn(txn, wake, evaluation, resolver, nil)

        if is_nil(recognized.recognition_path) and wake.due_at <= now() do
          recognize_wait_in_txn(
            txn,
            wake,
            "fallback",
            nil,
            %{matched: false, facts: [%{resolver_silent_through: wake.due_at}]},
            %{resolver | disposition: nil, terminal: false},
            %{label: "fallback-silence", due_at: wake.due_at}
          )
        else
          recognized
        end

      _ ->
        :noop
    end
  end

  defp deliver_eligible_waits(db, delivery_opts) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM wakes
        WHERE state='pending' AND waitMode IS NOT NULL AND recognitionAt IS NOT NULL
        ORDER BY recognitionAt,wakeId
        """
      )

    Enum.each(rows, fn [wake_id] ->
      case DB.transaction(db, fn txn -> deliver_wait_in_txn(txn, wake_id, delivery_opts) end) do
        {:ok, {:delivery, delivery}} -> Gateway.complete_delivery(db, delivery)
        {:ok, _} -> :ok
        {:error, error} -> raise error
      end
    end)
  end

  defp deliver_wait_in_txn(txn, wake_id, delivery_opts) do
    case wait_in_txn(txn, wake_id) do
      %{state: "pending", recognition_path: path} = wake when is_binary(path) ->
        if wait_eligible_in_txn?(txn, wake) do
          fired_at = now()

          Txn.q(
            txn,
            "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending'",
            [wake.wake_id, fired_at]
          )

          if Txn.changes(txn) == 1 do
            Txn.q(
              txn,
              "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1 AND controllerOrigin='holder_continuation' AND controllerState='pending'",
              [wake.wake_id]
            )

            delivery =
              Gateway.deliver_prompt_in_txn(
                txn,
                wake.session_key,
                wake.origin,
                wait_stamp(wake) <> "\n\n" <> wake.prompt,
                [
                  wake_id: wake.wake_id,
                  sender: wake.origin,
                  target_gate: wake,
                  role_ref: wake.target_role
                ] ++ delivery_opts
              )

            EventLog.lifecycle_in_txn(
              txn,
              "wake_wait_delivered",
              wake.wake_id,
              "path=#{wake.recognition_path} assignment=#{wake.assignment_id}"
            )

            {:delivery, delivery}
          else
            :noop
          end
        else
          :ineligible
        end

      _ ->
        :noop
    end
  end

  defp wait_eligible_in_txn?(_txn, %{originating_turn_seq: nil}), do: true

  defp wait_eligible_in_txn?(txn, wake) do
    case Txn.q(txn, "SELECT status FROM turns WHERE seq=?1", [wake.originating_turn_seq]) do
      [[status]] -> status in ~w(delivered canceled failed failed_unknown)
      [] -> false
    end
  end

  defp wait_stamp(wake) do
    resolver =
      if wake.resolver_kind,
        do:
          "resolver #{wake.resolver_kind}:#{wake.resolver_id} holder=#{wake.resolver_holder} " <>
            "addressee=#{wake.resolver_addressee}",
        else: "resolver none"

    transition = wait_transition_stamp(wake.recognition_transition)
    predicate = JSON.encode!(wake.predicate || %{})
    evidence = JSON.encode!(wake.recognition_evidence || %{})

    "[woke: wait #{wake.wake_id}; assignment #{wake.assignment_id}; " <>
      "path #{wake.recognition_path}; #{resolver}; " <>
      "disposition #{wake.recognition_disposition || "none"}; #{transition}; " <>
      "predicate #{predicate}; evidence #{evidence}]"
  end

  defp wait_transition_stamp(%{"label" => "registration-snapshot"}),
    do: "registration-snapshot"

  defp wait_transition_stamp(%{"label" => "fallback-silence", "due_at" => due_at}),
    do: "resolver-silent-through=#{due_at}"

  defp wait_transition_stamp(%{"domain" => domain, "row_id" => row_id, "field" => field}) do
    "#{domain}:#{row_id} #{field["name"]} #{inspect(field["old"])}→#{inspect(field["new"])}"
  end

  defp wait_transition_stamp(%{"domain" => domain, "row_id" => row_id, "fields" => fields}) do
    changes =
      Enum.map_join(fields, ",", fn {name, change} ->
        "#{name} #{inspect(change["old"])}→#{inspect(change["new"])}"
      end)

    "#{domain}:#{row_id} #{changes}"
  end

  defp wait_transition_stamp(_transition), do: "transition unavailable"

  # THE PRODDER'S TRUE ACT TIME (spec production-machine-v1 §The prod
  # production). The prodder is three-phase on the ground: match records a
  # pending branch, drain SCHEDULES a wake, and this sweep FIRES it — so a
  # work-blocked fact asserted after the drain's recheck but before the fire
  # still has one effectful edge left to recognize at. Only supervision's own
  # pending controllers are eligible. Assignment attribution is shared by
  # ordinary process notices, so the sidecar is the durable discriminator: its
  # schema requires the same wake/assignment, process origin, prompt consumer,
  # pending state, and prod/escalation shape. The holder is `reresolveSeed` for
  # an escalation wake (its TARGET is the ancestor being told) and the target
  # itself for a prod. Nothing here gates the turn queue: a suppressed
  # controller is withdrawn by recognition, consumed as `canceled` with the
  # reason named — never a turn.
  defp suppressed_by_recognition?(db, wake) do
    holder = wake.reresolve_seed || wake.session_key

    if pending_supervision_controller?(db, wake) and
         ConditionFacts.standing?(db, "work-blocked", holder) do
      Logger.info(
        "supervision wake #{wake.wake_id} suppressed: work-blocked stands for #{holder}"
      )

      canceled =
        transaction!(db, fn txn ->
          with [[fact_id]] <- standing_block(txn, holder),
               [[generation]] <-
                 Txn.q(
                   txn,
                   "SELECT generation FROM supervision_entitlements WHERE assignmentId=?1 AND state IN ('armed','claimed')",
                   [wake.assignment_id]
                 ),
               true <-
                 cancel_in_txn(txn, %{
                   wake_id: wake.wake_id,
                   requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
                   reason_kind: "production_unmatched",
                   causal_source: %{kind: "condition_fact", id: to_string(fact_id)},
                   outcome: %{
                     kind: "no_replacement",
                     liveness_trigger: %{
                       kind: "supervision_entitlement",
                       id: "#{wake.assignment_id}##{generation}"
                     }
                   }
                 }) do
            # REFUND THE RUNG. The prodder's bookkeeping increments prodCount
            # when the wake is scheduled, but suppression voids that act.
            Txn.q(
              txn,
              "UPDATE assignment_prods SET prodCount = MAX(prodCount - 1, 0) WHERE assignmentId = ?1",
              [wake.assignment_id]
            )

            true
          else
            _ -> false
          end
        end)

      if canceled do
        best_effort_lifecycle(
          db,
          "supervision_wake_suppressed",
          wake.wake_id,
          "holder=#{holder}"
        )
      end

      canceled
    else
      false
    end
  end

  defp pending_supervision_controller?(db, wake) do
    DB.query(
      db,
      """
      SELECT 1 FROM supervision_liveness_sidecar
      WHERE wakeId=?1 AND assignmentId=?2 AND controllerOrigin='scheduled'
        AND controllerState='pending'
      """,
      [wake.wake_id, wake.assignment_id]
    ) == {:ok, [[1]]}
  end

  defp standing_block(txn, holder) do
    Txn.q(
      txn,
      """
      SELECT blocked.id
      FROM condition_facts blocked
      WHERE blocked.kind='work-blocked' AND blocked.scope=?1
        AND blocked.id > COALESCE((
          SELECT MAX(cleared.id)
          FROM condition_facts cleared
          WHERE cleared.kind='work-unblocked' AND cleared.scope=?1
        ), 0)
      ORDER BY blocked.id DESC
      LIMIT 1
      """,
      [holder]
    )
  end

  # A wake nobody can deliver is still CONSUMED — leaving it pending would spin the
  # sweep forever on what is necessarily a code bug — but it is recorded as
  # `canceled`, NEVER as `fired`. `fired` is this substrate's word for delivered,
  # and claiming it for a delivery that never happened makes the durable row lie:
  # this path carries owner decision notifications, so a consumer-name typo would
  # silently eat a decision request while the record showed it delivered.
  #
  # No new state value: `canceled` already means "will not be delivered", and the
  # named lifecycle row carries WHY. Recording is best-effort so an unavailable
  # sink cannot fail the sweep, matching the swallow-but-write idiom in
  # `Supervision.safe_evaluate/3`.
  defp undeliverable(db, wake, reason) do
    Logger.error("wake #{wake.wake_id} undeliverable: #{reason}")

    canceled =
      transaction!(db, fn txn ->
        cancel_in_txn(txn, %{
          wake_id: wake.wake_id,
          requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
          reason_kind: "consumer_unavailable",
          causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
          outcome: %{kind: "no_replacement"}
        })
      end)

    if canceled, do: best_effort_lifecycle(db, "wake_undeliverable", wake.wake_id, reason)
  end

  # An internal consumer that RAISES keeps its wake pending, so the next tick
  # retries it — correct, because a consumer can fail transiently and succeed
  # later. What was wrong is that it retried in total silence: the `false` an
  # internal delivery returns is discarded by the prompt-only `mark_fired` guard
  # below, so a consumer raising on every tick was indistinguishable from an idle
  # scheduler. One row per failed attempt, so the repetition is itself visible.
  defp attempt_internal_delivery(db, wake, internal_consumer) do
    internal_consumer.(wake)
    true
  rescue
    error -> internal_delivery_failed(db, wake, Exception.message(error))
  catch
    kind, reason -> internal_delivery_failed(db, wake, inspect({kind, reason}))
  end

  defp internal_delivery_failed(db, wake, detail) do
    Logger.error(
      "internal wake consumer #{inspect(wake.consumer)} failed for #{wake.wake_id}: #{detail}"
    )

    best_effort_lifecycle(db, "wake_delivery_failed", wake.wake_id, detail)
    false
  end

  defp best_effort_lifecycle(db, kind, subject, detail) do
    EventLog.lifecycle(db, kind, subject, detail)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp attempt_delivery(delivery) do
    try do
      {:ok, delivery.()}
    rescue
      _ -> :retry
    catch
      :exit, _ -> :retry
    end
  end

  defp mark_fired(db, wake_id) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
        [wake_id, now()]
      )

      :ok
    end)
  end

  defp evaluate_conditions(%{db: db, batch: batch}, mode) do
    {rows, watermark, condition_saturated?} = select_candidates(db, batch, mode)

    rows
    |> Enum.sort_by(fn
      ["C", _wake_id, fact_id, _scope, rid] ->
        {0, fact_id, rid}

      [_branch, _wake_id, _fact_id, _scope, rid] ->
        {1, rid, rid}
    end)
    |> Enum.each(fn [_branch, wake_id, fact_id, _scope, _rid] ->
      fire_candidate(db, wake_id, fact_id)
    end)

    if mode == :tick do
      advance_watermark(db, rows, batch, watermark)
    end

    saturated? = condition_saturated? or Enum.count(rows, &(hd(&1) == "F")) == batch

    if saturated?, do: :saturated, else: :done
  end

  defp select_candidates(db, batch, :tick) do
    transaction!(db, fn txn ->
      [[after_fact]] = Txn.q(txn, "SELECT afterFact FROM scheduler_state WHERE id = 0")
      [[ceil]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")

      fact_ids =
        Txn.q(
          txn,
          "SELECT id FROM condition_facts WHERE id>?1 AND id<=?2 ORDER BY id LIMIT ?3",
          [after_fact, ceil, batch]
        )
        |> Enum.map(&hd/1)

      processed_fact = List.last(fact_ids) || ceil

      condition_rows =
        if fact_ids == [] do
          []
        else
          Txn.q(
            txn,
            """
            SELECT 'C' AS branch, w.wakeId, f.id AS factId, f.scope, w.rowid AS rid
            FROM condition_facts f
            JOIN wakes w INDEXED BY wakes_condition ON w.conditionKind=f.kind
            WHERE f.id>?1 AND f.id<=?2 AND w.state='pending' AND f.id>w.conditionAfterId
            ORDER BY f.id, w.rowid
            """,
            [after_fact, processed_fact]
          )
        end

      fallback_rows =
        Txn.q(
          txn,
          """
          SELECT 'F' AS branch, w.wakeId, NULL AS factId, NULL AS scope, w.rowid AS rid
          FROM wakes w INDEXED BY wakes_due
          WHERE w.state='pending' AND w.dueAt<=?1 AND w.conditionKind IS NOT NULL
          ORDER BY w.rowid LIMIT ?2
          """,
          [now(), batch]
        )

      condition_saturated? = length(fact_ids) == batch and processed_fact < ceil
      {condition_rows ++ fallback_rows, processed_fact, condition_saturated?}
    end)
  end

  defp select_candidates(db, batch, {:eager, fact_id}) do
    transaction!(db, fn txn ->
      condition_rows =
        Txn.q(
          txn,
          """
          SELECT 'C' AS branch, w.wakeId, f.id AS factId, f.scope, w.rowid AS rid
          FROM condition_facts f
          JOIN wakes w INDEXED BY wakes_condition ON w.conditionKind=f.kind
          WHERE f.id=?1 AND w.state='pending' AND f.id>w.conditionAfterId
          ORDER BY w.rowid
          """,
          [fact_id]
        )

      fallback_rows =
        Txn.q(
          txn,
          """
          SELECT 'F' AS branch, w.wakeId, NULL AS factId, NULL AS scope, w.rowid AS rid
          FROM wakes w INDEXED BY wakes_due
          WHERE w.state='pending' AND w.dueAt<=?1 AND w.conditionKind IS NOT NULL
          ORDER BY w.rowid LIMIT ?2
          """,
          [now(), batch]
        )

      {condition_rows ++ fallback_rows, nil, false}
    end)
  end

  defp advance_watermark(db, _rows, _batch, after_fact_new) do
    {:ok, _} =
      DB.query(db, "UPDATE scheduler_state SET afterFact = ?1 WHERE id = 0", [after_fact_new])

    :ok
  end

  defp fire_candidate(db, wake_id, fact_id) do
    result =
      DB.transaction(db, fn txn ->
        case Txn.q(txn, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id]) do
          [row] -> fire_in_txn(txn, to_wake(row), fact_id)
          [] -> :noop
        end
      end)

    case result do
      {:ok, {:fired, delivery}} -> Gateway.complete_delivery(db, delivery)
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  defp fire_in_txn(txn, %{state: "pending", condition_kind: kind} = wake, fact_id)
       when is_binary(kind) do
    # Owner provenance moves onto condition facts in G-B. Until that migration,
    # unresolved legacy targets still need the common evaluator to preserve their
    # existing fire-and-record behavior.
    owner_user_id = wake_owner_in_txn(txn, wake) || "legacy-unscoped"

    bindings = %{
      condition_kind: kind,
      condition_scope: wake.condition_scope,
      condition_after_id: wake.condition_after_id
    }

    bindings =
      if is_integer(fact_id), do: Map.put(bindings, :condition_fact_id, fact_id), else: bindings

    predicate = %{
      owner_user_id: owner_user_id,
      conditions: [%{fact: "condition_fact.matches", op: "eq", value: true}],
      bindings: bindings
    }

    match =
      case RuleRuntime.evaluate_predicate_in_txn(txn, predicate) do
        {:ok, %{matched: true, condition_match: matched}} ->
          matched

        {:ok, %{matched: false}} ->
          nil

        {:error, error} ->
          raise DB.Error, message: "legacy wake predicate refused: #{error.message}"
      end

    cause =
      cond do
        match -> "condition"
        wake.due_at <= now() -> "fallback"
        true -> nil
      end

    if cause do
      fired_at = now()

      Txn.q(
        txn,
        "UPDATE wakes SET state = 'fired', firedAt = ?2, firedBy = ?3 WHERE wakeId = ?1 AND state = 'pending'",
        [wake.wake_id, fired_at, cause]
      )

      if Txn.changes(txn) == 1 do
        stamp =
          if cause == "condition",
            do: "[woke: fact #{kind}/#{match.scope || "nil"}]",
            else: "[woke: fallback deadline]"

        delivery =
          Gateway.deliver_prompt_in_txn(
            txn,
            wake.session_key,
            wake.origin,
            stamp <> "\n\n" <> wake.prompt,
            wake_id: wake.wake_id,
            sender: wake.origin,
            target_gate: wake,
            role_ref: wake.target_role
          )

        lifecycle_for_fire(txn, wake, cause, match, delivery)
        {:fired, delivery}
      else
        :noop
      end
    else
      :noop
    end
  end

  defp fire_in_txn(_txn, _wake, _fact_id), do: :noop

  defp wake_owner_in_txn(txn, wake) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [wake.session_key]) do
      [[owner_user_id]] -> owner_user_id
      [] -> nil
    end
  end

  defp authenticated_wake_owner_in_txn(txn, session_key) do
    case Txn.q(
           txn,
           "SELECT s.ownerUserId FROM sessions s JOIN users u ON u.userId=s.ownerUserId WHERE s.sessionKey=?1",
           [session_key]
         ) do
      [[owner_user_id]] -> owner_user_id
      [] -> nil
    end
  end

  # The 0.1.9 line has no firehose publisher. The ordinary wake row and its
  # lifecycle event remain the durable observation seams on this branch.
  @doc false
  def publish_change_in_txn(%Txn{}, _class, _wake_id), do: :ok

  defp lifecycle_for_fire(txn, wake, cause, match, :skipped) do
    matched =
      if match,
        do: " matchedFactId=#{match.id} scope=#{match.scope || "nil"}",
        else: ""

    target = wake.target_role || wake.session_key

    EventLog.lifecycle_in_txn(
      txn,
      "wake_unresolved",
      wake.wake_id,
      "firedBy=#{cause}#{matched} target=#{target} reason=unresolvable"
    )
  end

  defp lifecycle_for_fire(txn, wake, "condition", match, _delivery) do
    EventLog.lifecycle_in_txn(
      txn,
      "wake_condition_fired",
      wake.wake_id,
      "firedBy=condition matchedFactId=#{match.id} kind=#{wake.condition_kind} scope=#{match.scope || "nil"}"
    )
  end

  defp lifecycle_for_fire(txn, wake, "fallback", _match, _delivery) do
    EventLog.lifecycle_in_txn(
      txn,
      "wake_fallback_fired",
      wake.wake_id,
      "firedBy=fallback fallbackAt=#{wake.due_at}"
    )
  end

  defp select_wake_sql do
    "SELECT wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state, createdAt, firedAt, reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope, conditionAfterId, firedBy, creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt, targetGate, class, classElection, deliveryRule, digest, summon, ownerUserId, obligationRef, waitMode, predicate, resolverKind, resolverId, resolverHolder, resolverAddressee, necessity, verificationAssignmentId, verificationHolderKey, selectedPolicyName, verificationState, verificationAttestId, verificationNoticeWakeId, originatingTurnSeq, recognitionAt, recognitionPath, recognitionReason, recognitionEvidence, recognitionDisposition, recognitionTransition FROM wakes"
  end

  defp to_wake([
         wake_id,
         session_key,
         target_role,
         origin,
         prompt,
         consumer,
         due_at,
         state,
         created_at,
         fired_at,
         reresolve,
         reresolve_seed,
         reresolve_rung,
         condition_kind,
         condition_scope,
         condition_after_id,
         fired_by,
         creator_session_key,
         rumination,
         work_item_id,
         assignment_id,
         canceled_at,
         target_gate,
         class,
         class_election,
         delivery_rule,
         digest,
         summon,
         owner_user_id,
         obligation_ref,
         wait_mode,
         predicate,
         resolver_kind,
         resolver_id,
         resolver_holder,
         resolver_addressee,
         necessity,
         verification_assignment_id,
         verification_holder_key,
         selected_policy_name,
         verification_state,
         verification_attest_id,
         verification_notice_wake_id,
         originating_turn_seq,
         recognition_at,
         recognition_path,
         recognition_reason,
         recognition_evidence,
         recognition_disposition,
         recognition_transition
       ]) do
    %{
      wake_id: wake_id,
      session_key: session_key,
      target_role: target_role,
      origin: origin,
      prompt: prompt,
      consumer: consumer,
      due_at: due_at,
      state: state,
      created_at: created_at,
      fired_at: fired_at,
      reresolve: reresolve,
      reresolve_seed: reresolve_seed,
      reresolve_rung: reresolve_rung,
      condition_kind: condition_kind,
      condition_scope: condition_scope,
      condition_after_id: condition_after_id,
      fired_by: fired_by,
      creator_session_key: creator_session_key,
      rumination: rumination == 1,
      work_item_id: work_item_id,
      assignment_id: assignment_id,
      canceled_at: canceled_at,
      target_gate: target_gate,
      class: class,
      class_election: class_election,
      delivery_rule: delivery_rule,
      digest: digest == 1,
      summon: summon == 1,
      owner_user_id: owner_user_id,
      obligation_ref: obligation_ref,
      wait_mode: wait_mode,
      predicate: decode_optional(predicate),
      resolver_kind: resolver_kind,
      resolver_id: resolver_id,
      resolver_holder: resolver_holder,
      resolver_addressee: resolver_addressee,
      necessity: necessity,
      verification_assignment_id: verification_assignment_id,
      verification_holder_key: verification_holder_key,
      selected_policy_name: selected_policy_name,
      verification_state: verification_state,
      verification_attest_id: verification_attest_id,
      verification_notice_wake_id: verification_notice_wake_id,
      originating_turn_seq: originating_turn_seq,
      recognition_at: recognition_at,
      recognition_path: recognition_path,
      recognition_reason: recognition_reason,
      recognition_evidence: decode_optional(recognition_evidence),
      recognition_disposition: recognition_disposition,
      recognition_transition: decode_optional(recognition_transition)
    }
  end

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JSON.encode!(value)

  defp decode_optional(nil), do: nil
  defp decode_optional(value), do: JSON.decode!(value)

  defp schedule_tick(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
