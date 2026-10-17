defmodule Tightbeam.Wakes do
  @moduledoc """
  Persistent wake store + scheduler (TS reference: src/core/wakes.ts — its
  test file is the acceptance oracle). A wake is a fact-shaped, durable
  "deliver this prompt to this session at dueAt" row; delivery goes through
  the SAME turn pipeline as a user post (T8: coordination is fact-shaped).

  Process shape: ONE GenServer (`Tightbeam.WakeScheduler` in the tree) owning
  one due-time timer. At that deadline (and on explicit `fire_due/1`) it reads due
  pending wakes. Legacy timed wakes DELIVER and then mark fired — wakes.ts
  order, load-bearing:
  - deliver raises → wake stays pending, retried with backoff (at-least-once;
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
    DeliveryResponsibilities,
    Escalation,
    EventLog,
    Gateway,
    Keyset,
    Ledger,
    NoticeBatcher,
    RuleRuntime,
    Supervision,
    WorkItems
  }

  alias Tightbeam.DB.Txn

  @miss_detector_ms 180_000
  @miss_lateness_ms 60_000

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

  # AC4's retry guard is current-build storage. Do not install it during the
  # historical bootstrap pass: a later predecessor migration may refuse, and
  # that refusal must leave the predecessor's object set intact.
  @health_redelivery_ddl """
  CREATE TABLE IF NOT EXISTS health_redelivery_attempts (
    idempotencyKey TEXT PRIMARY KEY CHECK(length(trim(idempotencyKey)) > 0),
    sessionKey TEXT NOT NULL CHECK(length(trim(sessionKey)) > 0),
    sourceHarness TEXT NOT NULL CHECK(length(trim(sourceHarness)) > 0),
    sourceHost TEXT NOT NULL CHECK(length(trim(sourceHost)) > 0),
    sourceMessageId TEXT NOT NULL CHECK(length(trim(sourceMessageId)) > 0),
    sourceTurnSeq INTEGER NOT NULL REFERENCES turns(seq),
    sourceWakeId TEXT,
    origin TEXT NOT NULL CHECK(length(trim(origin)) > 0),
    prompt TEXT NOT NULL,
    roleRef TEXT,
    roleFallback INTEGER NOT NULL CHECK(roleFallback IN (0,1)),
    assignmentId TEXT,
    jobRef TEXT,
    requestRef TEXT,
    failureClass TEXT NOT NULL CHECK(failureClass IN (
      'auth-dead','rate-limit-dead','adapter_unavailable','model_unavailable','task_crash',
      'interrupted-outcome-unknown','unclassified'
    )),
    parentSessionKey TEXT REFERENCES sessions(sessionKey),
    restorationTurnSeq INTEGER REFERENCES turns(seq),
    redeliveryTurnSeq INTEGER UNIQUE REFERENCES turns(seq),
    createdAt INTEGER NOT NULL CHECK(createdAt >= 0),
    UNIQUE(sessionKey, sourceTurnSeq),
    UNIQUE(sessionKey, sourceMessageId),
    CHECK((restorationTurnSeq IS NULL) = (redeliveryTurnSeq IS NULL))
  );
  CREATE INDEX IF NOT EXISTS health_redelivery_pending
    ON health_redelivery_attempts (sourceHarness, sourceHost, sourceTurnSeq)
    WHERE redeliveryTurnSeq IS NULL;
  """

  @retry_base_ms 30_000
  @retry_ceiling_ms 30 * 60_000

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    with :ok <- ensure_historical_schema(db),
         :ok <- DB.execute(db, @health_redelivery_ddl) do
      :ok
    end
  end

  @doc false
  @spec ensure_historical_schema(db()) :: :ok | {:error, term()}
  def ensure_historical_schema(db \\ Tightbeam.DB) do
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
  # Every source wake lands durably at its own `schedule_in_txn`. Ordinary
  # prompt wakes batch by default regardless of origin or class election. The
  # class remains on the source and controls only in-batch priority and its
  # visible marker. Scheduled, conditioned, and internal wakes keep their own
  # trigger mechanics.
  #
  # LAYER. The mechanism — stamp a class, look up special-trigger timing, and
  # sign a batch result — is PHYSICS. The names and the numbers are
  # ANATOMY: seed defaults, verbatim from §7's table, reshapeable by an org
  # through the identity tree. Phase 6 lifts them into policy rows; until a row
  # exists these hardcoded defaults are the fallback (§5). Nothing here judges
  # the CONTENT of a message — the sender elects, the substrate obeys.
  #
  # The legacy immediacy table remains for scheduled, conditioned, and
  # internal traffic. Default prompt batching does not consult it.

  @doc "The class the classifier stamps on unclassified traffic (fabric §5 seed default)."
  @spec classifier_default() :: String.t()
  def classifier_default, do: "fyi"

  @doc "The five seed-shipped base classes (fabric §7). A kungfu may extend past these."
  @spec seed_classes() :: [String.t()]
  def seed_classes, do: ~w(fyi status-query input-needed blocker algedonic)

  # Rule revision. Bump when a rule's BEHAVIOUR changes, so a digest signed by
  # the old revision stays honest about which reflex produced it.
  @rules_rev "r1"

  @digest_rule "notice-batching-v1 r2"
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

  @terminal_notice_purpose "terminal-child-owner-notification"
  @terminal_notice_marker @terminal_notice_purpose <> ":"

  @doc false
  # A terminal notice re-resolves its recipient when it is prepared.
  def terminal_notice?(%{obligation_ref: @terminal_notice_marker <> _}), do: true
  def terminal_notice?(_wake), do: false
  @terminal_action_purpose "terminal-child-owner-action-reminder"
  @terminal_action_marker @terminal_action_purpose <> ":"
  @terminal_action_condition_kind "terminal-child-owner-action"
  @terminal_action_fallback_ms 2 * 60 * 60 * 1_000
  @terminal_notice_fields ~w(source_kind source_token assignment_id work_item_id child_session_key owner_user_id opened_by_kind opened_by_id outcome terminal_at)a

  @doc """
  Build a terminal-event identity and payload without admitting or delivering a wake.

  The caller must derive the event from durable rows in its owning transaction.
  `opened_by_*` records the assignment's durable relation, not the current recipient.
  Recipient resolution and authorization are deliberately outside this pure helper.
  The returned `wake_id` and `prompt` can feed `schedule_in_txn/2`; this function
  neither calls that seam nor proves that the terminal event committed.

  Pass the existing wake on replay to refuse a conflicting immutable payload.
  Mutable delivery fields (including the recipient) do not participate in identity
  or replay comparison. A later admission caller must perform this comparison in
  the same transaction as its lookup and insert.
  """
  @spec terminal_notification(map(), map() | nil) :: {:ok, map()} | {:error, map()}
  def terminal_notification(event, existing_wake \\ nil)

  def terminal_notification(event, existing_wake) when is_map(event) do
    event = Map.take(event, @terminal_notice_fields)

    strings = ~w(source_token assignment_id child_session_key owner_user_id opened_by_id)a

    valid? =
      Enum.all?(strings, fn key ->
        value = event[key]
        is_binary(value) and String.valid?(value) and String.trim(value) != ""
      end) and
        Map.has_key?(event, :work_item_id) and
        (is_nil(event.work_item_id) or
           (is_binary(event.work_item_id) and String.valid?(event.work_item_id) and
              String.trim(event.work_item_id) != "")) and
        event[:opened_by_kind] in ["user", "session"] and
        is_integer(event[:terminal_at]) and event.terminal_at >= 0 and
        ((event[:source_kind] == "attest" and event[:outcome] in ["completed", "surrendered"]) or
           (event[:source_kind] == "assignment_revocation" and event[:outcome] == "revoked" and
              event.source_token != event.assignment_id))

    if valid? do
      # A JSON array is ordered and unambiguous even when tokens contain delimiters.
      identity = JSON.encode!([@terminal_notice_purpose, event.source_kind, event.source_token])
      digest = :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)

      prompt =
        Enum.map_join(@terminal_notice_fields, "\n", fn key ->
          "#{key}=#{JSON.encode!(Map.fetch!(event, key))}"
        end)

      notice = %{
        wake_id: "w_terminal_" <> digest,
        prompt: @terminal_notice_purpose <> "\n" <> prompt
      }

      case existing_wake do
        nil ->
          {:ok, notice}

        %{wake_id: wake_id, prompt: prompt}
        when wake_id == notice.wake_id and prompt == notice.prompt ->
          {:ok, notice}

        _ ->
          {:error,
           %{
             code: "terminal_notification_conflict",
             message: "existing wake does not match the immutable terminal event"
           }}
      end
    else
      {:error,
       %{
         code: "invalid_terminal_notification",
         message: "terminal event identity is incomplete or invalid"
       }}
    end
  end

  def terminal_notification(_event, _existing_wake),
    do:
      {:error,
       %{
         code: "invalid_terminal_notification",
         message: "terminal event identity is incomplete or invalid"
       }}

  @doc """
  Admit the current terminal notice in the terminal owner's transaction.

  All event fields come from the closed assignment and its matching closing source.
  This is admission only: replay never resets delivery state or changes the recipient.
  The caller must roll back its terminal transition on an error result.
  """
  def admit_terminal_notification_in_txn(%Txn{} = txn, assignment_id) do
    with {:ok, event} <- terminal_event_in_txn(txn, assignment_id) do
      admit_terminal_event_in_txn(txn, event)
    end
  end

  @doc "Admit or replay the exact immutable revocation event, including after reopening."
  def admit_terminal_revocation_in_txn(%Txn{} = txn, assignment_id, revocation_id)
      when is_binary(revocation_id) do
    with {:ok, event} <- terminal_revocation_event_in_txn(txn, assignment_id, revocation_id) do
      admit_terminal_event_in_txn(txn, event)
    end
  end

  defp admit_terminal_event_in_txn(txn, event) do
    with {:ok, notice} <- terminal_notification(event),
         existing = get_in_txn(txn, notice.wake_id),
         {:ok, ^notice} <- terminal_notification(event, existing) do
      relation = terminal_notice_relation(event)

      case existing do
        nil ->
          case terminal_notice_recipient_in_txn(txn, event) do
            {:ok, recipient} ->
              {:ok, schedule_terminal_notice_in_txn(txn, event, notice, relation, recipient)}

            {:error, %{code: "terminal_notification_recipient_unavailable"}} ->
              # Keep the event report as an ordinary stored notice. The scheduler
              # owns recipient existence/readiness and records an ordinary
              # undeliverable outcome if Main is unavailable too.
              address = Tightbeam.Org.personal_session_key(event.owner_user_id)
              {:ok, schedule_terminal_notice_in_txn(txn, event, notice, relation, address)}

            {:error, _} = refusal ->
              refusal
          end

        wake ->
          if Map.take(wake, Map.keys(relation)) == relation do
            {:ok, wake}
          else
            wait_error(
              "terminal_notification_conflict",
              "existing wake does not match the durable terminal relation"
            )
          end
      end
    end
  end

  @doc false
  def readdress_terminal_notices_for_work_item_in_txn(%Txn{} = txn, work_item_id)
      when is_binary(work_item_id) do
    wake_ids =
      Txn.q(
        txn,
        """
        SELECT wakeId FROM wakes
        WHERE work_item_id=?1 AND state='pending' AND deliveredTurnSeq IS NULL
          AND substr(obligationRef,1,length(?2))=?2
        ORDER BY createdAt,wakeId
        """,
        [work_item_id, @terminal_notice_marker]
      )
      |> Enum.map(&hd/1)

    Enum.each(wake_ids, fn wake_id ->
      case get_in_txn(txn, wake_id) do
        %{obligation_ref: @terminal_notice_marker <> _} = wake ->
          with {:ok, identity_wake} <- terminal_notice_identity_in_txn(txn, wake),
               {:ok, event} <- terminal_event_for_wake_in_txn(txn, identity_wake),
               true <- event.work_item_id == work_item_id,
               {:ok, recipient} <- terminal_notice_recipient_in_txn(txn, event),
               {:ok, _updated} <- readdress_pending_in_txn(txn, wake_id, recipient) do
            :ok
          else
            _ ->
              # The source remains durable and pending. A later owner update or
              # explicit source recovery can reconcile it without making
              # ordinary delivery inspect the terminal event.
              :ok
          end

        _ ->
          :ok
      end
    end)

    :ok
  end

  def readdress_terminal_notices_for_work_item_in_txn(%Txn{}, _work_item_id), do: :ok

  defp schedule_terminal_notice_in_txn(txn, event, notice, relation, address) do
    schedule_in_txn(
      txn,
      relation
      |> Map.merge(notice)
      |> Map.merge(%{session_key: address, due_at: event.terminal_at})
    )
  end

  defp terminal_notice_relation(event) do
    %{
      origin: "process:tightbeam",
      consumer: "prompt",
      creator_session_key: event.child_session_key,
      assignment_id: event.assignment_id,
      work_item_id: event.work_item_id,
      owner_user_id: event.owner_user_id,
      obligation_ref: @terminal_notice_marker <> event.assignment_id
    }
  end

  @doc false
  @spec reconcile_delivered_sources(DB.server(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def reconcile_delivered_sources(db \\ DB, recipient_session_key \\ nil, delivered_wake_id \\ nil) do
    case DB.transaction(db, fn txn ->
           delivered_turn_seq =
             if is_binary(delivered_wake_id) do
               case Txn.q(txn, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [delivered_wake_id]) do
                 [[seq]] when is_integer(seq) -> seq
                 _ -> nil
               end
             end

           delivered =
             Txn.q(
               txn,
               """
               SELECT wakeId FROM wakes
               WHERE deliveredTurnSeq IS NOT NULL
                 AND (?1 IS NULL OR sessionKey=?1)
                 AND (?2 IS NULL OR deliveredTurnSeq=?2)
                 AND (waitMode IS NOT NULL
                   OR substr(obligationRef,1,length(?3))=?3
                   OR substr(obligationRef,1,length(?4))=?4)
               ORDER BY deliveredTurnSeq,wakeId
               """,
               [recipient_session_key, delivered_turn_seq, @terminal_notice_marker, @terminal_action_marker]
             )

           delivery_failed =
             Txn.q(
               txn,
               """
               SELECT w.wakeId FROM wakes w
               JOIN wake_cancellations c ON c.wakeId=w.wakeId
               WHERE w.waitMode IS NOT NULL
                 AND c.causalSourceKind='scheduler_delivery'
                 AND c.reasonKind IN ('target_unresolvable','consumer_unavailable')
                 AND (?1 IS NULL OR w.sessionKey=?1)
                 AND (?2 IS NULL OR w.wakeId=?2)
               ORDER BY c.canceledAt,w.wakeId
               """,
               [recipient_session_key, delivered_wake_id]
             )

           Enum.each(delivered, fn [wake_id] ->
             reconcile_source_delivery_in_savepoint(txn, wake_id, "delivered")
           end)

           Enum.each(delivery_failed, fn [wake_id] ->
             reconcile_source_delivery_in_savepoint(txn, wake_id, "delivery-failed")
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, error} ->
        Logger.warning("delivered notice source reconciliation deferred: #{Exception.message(error)}")
        {:error, error}
    end
  end

  defp reconcile_source_delivery_in_savepoint(txn, wake_id, wait_outcome) do
    :ok = Txn.exec(txn, "SAVEPOINT reconcile_notice_source")

    try do
      case get_in_txn(txn, wake_id) do
        nil ->
          :ok

        wake ->
          if wake.wait_mode do
            settle_wait_continuation_in_txn(
              txn,
              wake.wake_id,
              wake.recognition_path,
              wake.assignment_id,
              wait_outcome
            )
          end

          case wake.obligation_ref do
            @terminal_notice_marker <> _ ->
              if wait_outcome == "delivered" do
                terminal_notice_delivered_in_txn(txn, wake.wake_id, wake.session_key)
              end

            @terminal_action_marker <> _ ->
              if wait_outcome == "delivered" do
                reconcile_terminal_action_delivery_in_txn(txn, wake)
              end

            _ ->
              :ok
          end
      end

      :ok = Txn.exec(txn, "RELEASE reconcile_notice_source")
    rescue
      error ->
        :ok = Txn.exec(txn, "ROLLBACK TO reconcile_notice_source")
        :ok = Txn.exec(txn, "RELEASE reconcile_notice_source")
        Logger.warning("notice source action deferred for #{wake_id}: #{Exception.message(error)}")
    catch
      kind, reason ->
        :ok = Txn.exec(txn, "ROLLBACK TO reconcile_notice_source")
        :ok = Txn.exec(txn, "RELEASE reconcile_notice_source")
        Logger.warning("notice source action deferred for #{wake_id}: #{inspect({kind, reason})}")
    end
  end

  defp reconcile_terminal_action_delivery_in_txn(txn, wake) do
    with {:ok, root, event} <- terminal_action_root_event_in_txn(txn, wake),
         [[delivered_at]] <-
           Txn.q(txn, "SELECT firedAt FROM wakes WHERE wakeId=?1", [wake.wake_id]),
         true <- is_integer(delivered_at) do
      schedule_terminal_action_reminder_in_txn(
        txn,
        root,
        event,
        wake.session_key,
        wake.wake_id,
        delivered_at
      )
    else
      _ -> :ok
    end
  end

  @doc false
  def terminal_notice_delivered_in_txn(%Txn{} = txn, wake_id, delivered_to)
      when is_binary(wake_id) and is_binary(delivered_to) do
    case get_in_txn(txn, wake_id) do
      %{obligation_ref: @terminal_notice_marker <> _} = wake
      when wake.session_key == delivered_to ->
        case terminal_notice_identity_in_txn(txn, wake) do
          {:ok, identity_wake} ->
            case terminal_event_for_wake_in_txn(txn, identity_wake) do
              {:ok, event}
              when event.source_kind == "attest" and event.outcome in ["completed", "surrendered"] ->
                [[delivered_at]] =
                  Txn.q(txn, "SELECT firedAt FROM wakes WHERE wakeId=?1", [wake_id])

                if is_integer(delivered_at) do
                  schedule_terminal_action_reminder_in_txn(
                    txn,
                    wake,
                    event,
                    delivered_to,
                    nil,
                    delivered_at
                  )
                end

              {:ok, _event} ->
                :ok

              {:error, %{message: message}} ->
                raise DB.Error, message: message
            end

          {:error, %{message: message}} ->
            raise DB.Error, message: message
        end

      _ ->
        :ok
    end
  end

  def terminal_notice_delivered_in_txn(%Txn{}, _wake_id, _delivered_to), do: :ok

  @doc false
  def delivery_prompt_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    case get_in_txn(txn, wake_id) do
      nil -> nil
      wake -> render_delivery_prompt(wake)
    end
  end

  defp render_delivery_prompt(%{wait_mode: mode, recognition_path: path} = wake)
       when is_binary(mode) and is_binary(path),
       do: wait_stamp(wake) <> "\n\n" <> wake.prompt

  defp render_delivery_prompt(%{condition_kind: kind, fired_by: "condition"} = wake)
       when is_binary(kind) do
    # Recognition keeps the exact matched fact, including a wildcard wait's
    # actual scope. Presentation never alters the authored queue row.
    %{"condition_fact" => %{"kind" => ^kind, "scope" => scope}} = wake.recognition_evidence
    "[woke: fact #{kind}/#{scope || "nil"}]\n\n" <> wake.prompt
  end

  defp render_delivery_prompt(%{condition_kind: kind, fired_by: "fallback"} = wake)
       when is_binary(kind),
       do: "[woke: fallback deadline]\n\n" <> wake.prompt

  defp render_delivery_prompt(wake), do: wake.prompt

  @doc false
  @spec prepare_prompt_source_for_batch_in_txn(Txn.t(), String.t(), String.t(), String.t()) ::
          {:ok, wake()} | :not_found
  def prepare_prompt_source_for_batch_in_txn(%Txn{} = txn, wake_id, session_key, prompt)
      when is_binary(wake_id) and is_binary(session_key) and is_binary(prompt) do
    case get_in_txn(txn, wake_id) do
      %{
        wake_id: ^wake_id,
        session_key: ^session_key,
        consumer: "prompt",
        digest: false,
        state: state
      } = wake
      when state in ["pending", "fired"] ->
        fired_at = wake.fired_at || now()

        Txn.q(
          txn,
          "UPDATE wakes SET state='pending',firedAt=COALESCE(firedAt,?2) WHERE wakeId=?1 AND state IN ('pending','fired')",
          [wake_id, fired_at]
        )

        if Txn.changes(txn) == 1 do
          source = %{wake | state: "pending", fired_at: fired_at}
          NoticeBatcher.record_policy_in_txn(txn, source)
          if state == "fired", do: schedule_changed_in_txn(txn, :wake_ready)

          {:ok, source}
        else
          :not_found
        end

      _ ->
        :not_found
    end
  end

  def prepare_prompt_source_for_batch_in_txn(%Txn{}, _wake_id, _session_key, _prompt),
    do: :not_found

  @doc false
  def record_terminal_handoff_action_in_txn(%Txn{} = txn, holder, attest)
      when is_binary(holder) and is_map(attest) do
    if attest.kind == "progress" and attest.bySession == holder do
      txn
      |> pending_terminal_action_reminders_for(holder)
      |> Enum.each(fn wake ->
        case terminal_action_attest_for_wake_in_txn(txn, wake, attest.id) do
          {:ok, _event} ->
            unless cancel_terminal_action_reminder_in_txn(txn, wake, attest.id) do
              raise DB.Error,
                message: "matching parent action could not stop its pending reminder"
            end

          :error ->
            :ok
        end
      end)
    end

    :ok
  end

  def record_terminal_handoff_action_in_txn(%Txn{}, _holder, _attest), do: :ok

  defp schedule_terminal_action_reminder_in_txn(
         txn,
         root,
         event,
         recipient,
         predecessor_id,
         delivered_at
       ) do
    if terminal_action_event?(event) and
         is_nil(terminal_action_attest_for_event_in_txn(txn, event, recipient)) and
         terminal_action_destination_available_in_txn?(txn, recipient) do
      wake_id = terminal_action_wake_id(root.wake_id, predecessor_id)
      prompt = terminal_action_prompt(event, root.wake_id)
      condition_kind = terminal_action_condition_kind(root.wake_id)

      reminder = %{
        wake_id: wake_id,
        session_key: recipient,
        origin: "process:tightbeam",
        prompt: prompt,
        due_at: delivered_at + @terminal_action_fallback_ms,
        condition_kind: condition_kind,
        condition_scope: root.wake_id,
        creator_session_key: event.child_session_key,
        owner_user_id: event.owner_user_id,
        obligation_ref: @terminal_action_marker <> root.wake_id
      }

      case get_in_txn(txn, wake_id) do
        nil ->
          schedule_in_txn(txn, reminder)
          :ok

        existing ->
          if terminal_action_reminder_matches?(existing, reminder),
            do: :ok,
            else: raise(DB.Error, message: "terminal action reminder identity conflict")
      end
    else
      :ok
    end
  end

  defp terminal_action_wake_id(root_wake_id, predecessor_id) do
    identity = JSON.encode!([@terminal_action_purpose, root_wake_id, predecessor_id || "initial"])
    digest = :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
    "w_terminal_action_" <> digest
  end

  defp terminal_action_condition_kind(root_wake_id) do
    digest = :crypto.hash(:sha256, root_wake_id) |> Base.encode16(case: :lower)
    @terminal_action_condition_kind <> "-" <> digest
  end

  defp terminal_action_prompt(event, root_wake_id) do
    "A parent action is still due for child assignment #{event.assignment_id} " <>
      "(finish occurrence #{event.source_kind}/#{event.source_token}). Choose keep, park, or retire " <>
      "based on current purpose and obligations, act within your existing authority, then record " <>
      "what you did on an open assignment with a progress attest naming this child and occurrence. " <>
      "Use note: completion-handoff-action #{event.assignment_id} #{event.source_kind} " <>
      "#{event.source_token} kept|parked|retired: <what you did>. " <>
      "A refusal or failed action must be reported truthfully. Notice #{root_wake_id}."
  end

  defp terminal_action_prompt_matches?(wake, event, root_wake_id),
    do: wake.prompt == terminal_action_prompt(event, root_wake_id)

  defp terminal_action_reminder_matches?(wake, expected) do
    fields =
      ~w(wake_id session_key origin prompt condition_kind condition_scope creator_session_key owner_user_id obligation_ref)a

    Enum.all?(fields, &(Map.get(wake, &1) == Map.get(expected, &1))) and
      is_integer(wake.condition_after_id)
  end

  defp terminal_action_event?(%{source_kind: "attest", outcome: outcome}),
    do: outcome in ["completed", "surrendered"]

  defp terminal_action_event?(_), do: false

  defp terminal_action_attest_for_event_in_txn(txn, event, parent) do
    Txn.q(
      txn,
      "SELECT id,note FROM attests WHERE kind='progress' AND bySession=?1 ORDER BY ts DESC,id DESC",
      [parent]
    )
    |> Enum.find_value(fn [attest_id, note] ->
      if terminal_action_note_matches?(note, event), do: attest_id
    end)
  end

  defp terminal_action_destination_available_in_txn?(txn, parent) do
    Txn.q(
      txn,
      "SELECT 1 FROM assignments WHERE holderKey=?1 AND state='open' LIMIT 1",
      [parent]
    ) == [[1]]
  end

  defp terminal_action_attest_for_wake_in_txn(txn, wake, attest_id) do
    with {:ok, root, event} <- terminal_action_root_event_in_txn(txn, wake),
         [[^attest_id, "progress", note, parent]] <-
           Txn.q(
             txn,
             "SELECT id,kind,note,bySession FROM attests WHERE id=?1",
             [attest_id]
           ),
         true <- parent == wake.session_key,
         true <- terminal_action_note_matches?(note, event) do
      {:ok, %{root: root, event: event}}
    else
      _ -> :error
    end
  end

  defp terminal_action_root_event_in_txn(
         txn,
         %{obligation_ref: @terminal_action_marker <> root_id} = wake
       ) do
    with %{obligation_ref: @terminal_notice_marker <> _} = root <- get_in_txn(txn, root_id),
         {:ok, identity_wake} <- terminal_notice_identity_in_txn(txn, root),
         {:ok, event} <- terminal_event_for_wake_in_txn(txn, identity_wake),
         true <- terminal_action_event?(event),
         {:ok, %{prompt: root_prompt}} <- terminal_notification(event, identity_wake),
         true <- root.prompt == root_prompt,
         relation = terminal_notice_relation(event),
         true <- Map.take(root, Map.keys(relation)) == relation,
         true <- root.session_key == wake.session_key,
         true <- root.owner_user_id == wake.owner_user_id,
         true <- wake.condition_scope == root.wake_id,
         true <- wake.condition_kind == terminal_action_condition_kind(root.wake_id),
         true <- terminal_action_prompt_matches?(wake, event, root.wake_id),
         true <- wake.origin == "process:tightbeam",
         true <- wake.creator_session_key == event.child_session_key,
         true <- is_nil(wake.assignment_id) and is_nil(wake.work_item_id),
         true <- wake.consumer == "prompt",
         true <-
           Txn.q(
             txn,
             "SELECT sessionKey FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
             [wake.session_key, event.owner_user_id]
           ) == [[wake.session_key]],
         true <- terminal_notice_has_delivery_turn_in_txn?(txn, root.wake_id, root.session_key) do
      {:ok, root, event}
    else
      _ -> :error
    end
  end

  defp terminal_action_root_event_in_txn(_txn, _wake), do: :error

  defp terminal_notice_has_delivery_turn_in_txn?(txn, source_wake_id, session_key) do
    Txn.q(
      txn,
      """
      SELECT 1 FROM wakes w JOIN turns t ON t.seq=w.deliveredTurnSeq
      WHERE w.wakeId=?1 AND t.sessionKey=?2
      """,
      [source_wake_id, session_key]
    ) == [[1]]
  end

  defp terminal_action_note_matches?(note, event) when is_binary(note) do
    case Regex.run(
           ~r/\Acompletion-handoff-action ([^\s]+) ([^\s]+) ([^\s]+) (kept|parked|retired): (.+)\z/u,
           note,
           capture: :all_but_first
         ) do
      [assignment_id, source_kind, source_token, _action, detail] ->
        terminal_action_event?(event) and assignment_id == event.assignment_id and
          source_kind == event.source_kind and source_token == event.source_token and
          String.trim(detail) != ""

      _ ->
        false
    end
  end

  defp terminal_action_note_matches?(_, _), do: false

  defp pending_terminal_action_reminders_for(txn, holder) do
    Txn.q(
      txn,
      "SELECT wakeId FROM wakes WHERE state='pending' AND sessionKey=?1 AND substr(obligationRef,1,length(?2))=?2 ORDER BY rowid",
      [holder, @terminal_action_marker]
    )
    |> Enum.map(fn [wake_id] -> get_in_txn(txn, wake_id) end)
  end

  defp cancel_terminal_action_reminder_in_txn(txn, wake, attest_id) do
    cancel_in_txn(txn, %{
      wake_id: wake.wake_id,
      requester: %{kind: "process", id: "tightbeam:supervision"},
      reason_kind: "superseded",
      causal_source: %{kind: "progress_attest", id: attest_id},
      outcome: %{kind: "no_replacement"}
    })
  end

  defp cancel_unresolvable_terminal_action_reminder_in_txn(txn, wake) do
    # The session may still be active, but without an open holder assignment it
    # has no lawful destination for the progress attest this reminder requires.
    # The existing target-unresolvable cancellation records that limit without
    # claiming the parent completed the action.
    cancel_in_txn(txn, %{
      wake_id: wake.wake_id,
      requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
      reason_kind: "target_unresolvable",
      causal_source: %{kind: "scheduler_delivery", id: wake.wake_id},
      outcome: %{kind: "no_replacement"}
    })
  end

  # A run-boundary retry keeps a distinct transport wakeId; the retry row
  # identifies the original immutable semantic notification for source-owned
  # follow-through outside delivery.
  defp terminal_notice_identity_in_txn(txn, wake) do
    case Txn.q(txn, "SELECT rootWakeId FROM wake_retry_attempts WHERE wakeId=?1", [wake.wake_id]) do
      [] ->
        {:ok, wake}

      [[root]] when root == wake.wake_id ->
        {:ok, wake}

      [[root]] ->
        case get_in_txn(txn, root) do
          %{obligation_ref: ref} = identity when ref == wake.obligation_ref ->
            {:ok, identity}

          _ ->
            wait_error("wake_retry_identity_inconsistent", "retry lacks its exact notice root")
        end

      _ ->
        wait_error("wake_retry_identity_inconsistent", "retry has an ambiguous notice root")
    end
  end

  defp terminal_event_in_txn(txn, assignment_id) do
    case terminal_attest_event_in_txn(txn, assignment_id) do
      {:ok, _} = event ->
        event

      {:error, _} = refusal ->
        case terminal_revocation_event_in_txn(txn, assignment_id, nil) do
          {:ok, _} = event -> event
          {:error, _} -> refusal
        end
    end
  end

  # Match the deterministic identity against durable source rows, never prompt
  # text. An earlier revocation keeps its identity after revoke/reopen/revoke.
  # Attest delivery retains its existing current-close validation.
  defp terminal_event_for_wake_in_txn(txn, wake) do
    case terminal_attest_event_in_txn(txn, wake.assignment_id) do
      {:ok, event} ->
        case terminal_notification(event) do
          {:ok, %{wake_id: id}} when id == wake.wake_id ->
            {:ok, event}

          _ ->
            case terminal_revocation_for_wake_in_txn(txn, wake) do
              {:ok, _} = revocation -> revocation
              {:error, _} -> {:ok, event}
            end
        end

      {:error, _} = refusal ->
        case terminal_revocation_for_wake_in_txn(txn, wake) do
          {:ok, _} = revocation -> revocation
          {:error, _} -> refusal
        end
    end
  end

  defp terminal_revocation_for_wake_in_txn(txn, wake) do
    terminal_revocation_events_in_txn(txn, wake.assignment_id)
    |> Enum.find(fn event ->
      case terminal_notification(event) do
        {:ok, %{wake_id: id}} -> id == wake.wake_id
        _ -> false
      end
    end)
    |> terminal_event_result()
  end

  defp terminal_revocation_event_in_txn(txn, assignment_id, token) do
    events = terminal_revocation_events_in_txn(txn, assignment_id)

    event =
      if token do
        Enum.find(events, &(&1.source_token == token))
      else
        # Only the current closed generation is an implicit admission request.
        case Txn.q(
               txn,
               """
               SELECT g.revocationId FROM assignments a
               JOIN assignment_revocation_generations g ON g.assignmentId=a.id
               WHERE a.id=?1 AND a.state='closed' AND a.outcome='revoked'
                 AND g.reopeningId IS (SELECT MAX(id) FROM assignment_reopenings WHERE assignmentId=a.id)
               """,
               [assignment_id]
             ) do
          [[current]] -> Enum.find(events, &(&1.source_token == current))
          _ -> nil
        end
      end

    terminal_event_result(event)
  end

  defp terminal_event_result(nil),
    do:
      wait_error(
        "invalid_terminal_notification_relation",
        "terminal source lacks exact closing evidence and authorized owner relation"
      )

  defp terminal_event_result(event), do: {:ok, event}

  defp terminal_revocation_events_in_txn(txn, assignment_id) do
    Txn.q(
      txn,
      """
      SELECT a.id,a.workItemId,a.holderKey,owner.userId,a.openedByUser,a.openedBySession,
             r.id,r.revokedAt
      FROM assignments a
      JOIN sessions h ON h.sessionKey=a.holderKey
      JOIN assignment_revocation_generations g ON g.assignmentId=a.id
      JOIN assignment_revocations r ON r.id=g.revocationId AND r.assignmentId=a.id
      LEFT JOIN work_items w ON w.id=a.workItemId
      LEFT JOIN sessions parent ON parent.sessionKey=a.openedBySession
      JOIN users owner ON owner.userId=CASE
        WHEN a.openedBySession IS NULL THEN a.openedByUser ELSE parent.ownerUserId END
      WHERE a.id=?1
        AND (a.workItemId IS NULL OR w.ownerUserId=owner.userId)
        AND ((a.openedBySession IS NULL AND a.openedByUser IS NOT NULL)
          OR (a.openedByUser IS NULL AND a.openedBySession IS NOT NULL))
        AND (
          (a.state='closed' AND a.outcome='revoked' AND a.closingAttestId IS NULL
           AND a.closedAt=r.revokedAt AND a.closedByUser IS r.revokedByUser
           AND a.closedBySession IS r.revokedBySession AND a.closedByProcess IS r.revokedByProcess
           AND g.reopeningId IS (SELECT MAX(id) FROM assignment_reopenings WHERE assignmentId=a.id))
          OR EXISTS (
            SELECT 1 FROM assignment_reopenings next
            WHERE next.assignmentId=a.id AND next.id=(
              SELECT MIN(id) FROM assignment_reopenings
              WHERE assignmentId=a.id AND (g.reopeningId IS NULL OR id>g.reopeningId))
              AND next.priorOutcome='revoked' AND next.priorClosingAttestId IS NULL
              AND next.priorClosedAt=r.revokedAt AND next.priorClosedByUser IS r.revokedByUser
              AND next.priorClosedBySession IS r.revokedBySession
              AND next.priorClosedByProcess IS r.revokedByProcess))
      ORDER BY r.id
      """,
      [assignment_id]
    )
    |> Enum.map(fn [id, item, child, owner, opened_user, opened_session, token, ts] ->
      %{
        source_kind: "assignment_revocation",
        source_token: token,
        assignment_id: id,
        work_item_id: item,
        child_session_key: child,
        owner_user_id: owner,
        opened_by_kind: if(opened_session, do: "session", else: "user"),
        opened_by_id: opened_session || opened_user,
        outcome: "revoked",
        terminal_at: ts
      }
    end)
  end

  defp terminal_attest_event_in_txn(txn, assignment_id) do
    # The durable opener owns the accountable parent relation. A lawfully
    # assigned independent holder may have another owner; closer provenance
    # remains exact and does not elect the notification recipient.
    rows =
      Txn.q(
        txn,
        """
        SELECT a.id,a.workItemId,a.holderKey,owner.userId,a.openedByUser,a.openedBySession,
               a.outcome,a.closedAt,a.closingAttestId
        FROM assignments a
        JOIN sessions h ON h.sessionKey=a.holderKey
        JOIN attests t ON t.id=a.closingAttestId AND t.assignmentId=a.id
        LEFT JOIN work_items w ON w.id=a.workItemId
        LEFT JOIN sessions parent ON parent.sessionKey=a.openedBySession
        JOIN users owner ON owner.userId=CASE
          WHEN a.openedBySession IS NULL THEN a.openedByUser ELSE parent.ownerUserId END
        WHERE a.id=?1 AND a.state='closed' AND a.closedBySession=a.holderKey
          AND a.closedByUser IS NULL AND t.bySession=a.holderKey AND t.byUser IS NULL
          AND t.ts=a.closedAt
          AND ((a.outcome='completed' AND t.kind='completion')
            OR (a.outcome='surrendered' AND t.kind='surrender'))
          AND (a.workItemId IS NULL OR w.ownerUserId=owner.userId)
          AND ((a.openedBySession IS NULL AND a.openedByUser IS NOT NULL)
            OR (a.openedByUser IS NULL AND a.openedBySession IS NOT NULL))
        """,
        [assignment_id]
      )

    case rows do
      [[id, work_item, child, owner, opened_user, opened_session, outcome, closed_at, token]] ->
        {:ok,
         %{
           source_kind: "attest",
           source_token: token,
           assignment_id: id,
           work_item_id: work_item,
           child_session_key: child,
           owner_user_id: owner,
           opened_by_kind: if(opened_session, do: "session", else: "user"),
           opened_by_id: opened_session || opened_user,
           outcome: outcome,
           terminal_at: closed_at
         }}

      _ ->
        wait_error(
          "invalid_terminal_notification_relation",
          "assignment lacks an exact completion/surrender attest and authorized owner relation"
        )
    end
  end

  defp terminal_notice_recipient_in_txn(txn, event) do
    personal = Tightbeam.Org.personal_session_key(event.owner_user_id)

    current =
      case DeliveryResponsibilities.current_owner_in_txn(txn, event.work_item_id) do
        %{
          "ownerUserId" => owner_user_id,
          "accountableSessionKey" => session_key,
          "deliveryState" => "current"
        }
        when owner_user_id == event.owner_user_id ->
          session_key

        _ ->
          nil
      end

    delegated_opener =
      if event.opened_by_kind == "session" and
           DeliveryResponsibilities.responsibility_in_txn(
             txn,
             event.opened_by_id,
             event.work_item_id
           ) == "delegated",
         do: event.opened_by_id,
         else: nil

    candidates =
      if event.opened_by_kind == "session",
        do: [delegated_opener, current, event.opened_by_id, personal],
        else: [current, personal]

    recipient =
      candidates
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.find(fn key ->
        Txn.q(
          txn,
          "SELECT 1 FROM sessions WHERE sessionKey=?1 AND ownerUserId=?2 AND state='active'",
          [key, event.owner_user_id]
        ) == [[1]]
      end)

    if recipient do
      {:ok, recipient}
    else
      wait_error(
        "terminal_notification_recipient_unavailable",
        "no active accountable recipient for the durable terminal relation"
      )
    end
  end

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
  the wake's `dueAt` and signs the row with the rule that decided it. Ordinary
  prompt wakes use the batch route across origins and class elections; an
  explicit time or condition still controls when its source becomes ready.
  Dispatch rumination is also a prompt wake and joins that recipient's next-turn
  batch. Non-prompt consumers remain outside recipient batching.
  """
  @spec schedule_in_txn(Txn.t(), map()) :: wake()
  def schedule_in_txn(%Txn{} = txn, input) do
    input =
      case Map.get(input, :cron) do
        nil ->
          input

        schedule ->
          if Enum.any?([:condition_kind, :wait_mode], &Map.get(input, &1)),
            do: raise(ArgumentError, "cron cannot be combined with another trigger")

          Map.merge(input, %{
            consumer: "cron",
            classify: true,
            due_at: Tightbeam.CronWake.next_at(schedule, now())
          })
      end

    condition_kind = Map.get(input, :condition_kind)

    input =
      if is_binary(Map.get(input, :replacement_assignment_id)),
        do: Map.put(input, :sender_scheduled, true),
        else: input

    owner_user_id =
      Map.get(input, :owner_user_id) || authenticated_wake_owner_in_txn(txn, input.session_key)

    condition_after_id =
      if is_binary(condition_kind) do
        [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
        cursor
      end

    created_at = now()
    {class, class_election} = elected_class(input)

    {delivery_rule, due_at} = apply_delivery_policy(txn, input, class, created_at, condition_kind)

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

    # Only typed user targets carry this transient address. Existing wake result
    # maps retain their shape; sourceAddress preserves user:<id> on the wake.
    wake =
      case Map.get(input, :target_user_id) do
        user_id when is_binary(user_id) and user_id != "" ->
          Map.put(wake, :target_user_id, user_id)

        _ ->
          wake
      end

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

    if schedule = Map.get(input, :cron) do
      Txn.q(txn, "INSERT INTO cron_wake_schedules(wakeId,schedule) VALUES(?1,?2)", [
        wake.wake_id,
        schedule
      ])
    end

    if is_binary(Map.get(input, :replacement_assignment_id)) do
      Tightbeam.QueuedMessageSuppression.record_replacement_request_in_txn(
        txn,
        wake.wake_id,
        input.replacement_assignment_id
      )

      Tightbeam.QueuedMessageSuppression.replace_pending_wakes_in_txn(
        txn,
        wake,
        input.replacement_assignment_id
      )
    end

    if is_binary(condition_kind) do
      EventLog.lifecycle_in_txn(
        txn,
        "wake_condition_scheduled",
        wake.wake_id,
        "kind=#{condition_kind} scope=#{wake.condition_scope || "nil"} fallbackAt=#{wake.due_at} origin=#{wake.origin}"
      )
    end

    file_policy_skew(txn, wake)

    if batch_source?(wake) do
      policy_opts =
        case Map.get(input, :visibility_scope) do
          scope when is_binary(scope) and scope != "" ->
            [enabled: true, visibility_scope: scope]

          _ ->
            [enabled: true]
        end

      NoticeBatcher.record_policy_in_txn(txn, wake, policy_opts)
    end

    if is_binary(wake.assignment_id) and is_binary(wake.creator_session_key) do
      Tightbeam.Supervision.activity_in_txn(
        txn,
        wake.assignment_id,
        wake.creator_session_key,
        wake.created_at
      )
    end

    schedule_changed_in_txn(txn, {:schedule_changed, wake.due_at})
    wake
  end

  # A carrier turn serves several independently owned sources. Preserve each
  # source's assignment identity when recognizing its delivery or recovery,
  # rather than treating the carrier's transport wake as the semantic notice.
  defp source_delivery_turns_in_txn(txn, wake_id),
    do: NoticeBatcher.source_delivery_turns_in_txn(txn, wake_id)

  @doc false
  def consume_internal_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    Txn.q(
      txn,
      "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending' AND consumer!='prompt'",
      [wake_id, now()]
    )

    if Txn.changes(txn) == 1 do
      publish_change_in_txn(txn, "wake.fired", wake_id)
      :ok
    else
      raise ArgumentError, "internal wake is not pending"
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
            replacement_assignment_id: input[:replacement_assignment_id],
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
          replacement_assignment_id: input[:replacement_assignment_id],
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
    Tightbeam.Assignments.cannot_proceed_standing_in_txn?(txn, assignment_id) or
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
        facts["wait.obligation_matches"] and facts["wait.admitted"] and
          facts["wait.continuation_state"] == "pending" and
          not facts["wait.recognized"] and facts["resolver.open"] and
          facts["wait.declaration_complete"] and facts["wait.verification_accountable"] and
          facts["wait.coverage_valid"]

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
             """
             WITH deliveries AS (#{Tightbeam.NoticeBatcher.recorded_deliveries_sql()})
             SELECT t.status FROM deliveries d JOIN turns t ON t.seq=d.turnSeq
             WHERE d.sourceWakeId=?1 AND d.assignmentId=?2 AND t.sessionKey=?3
             ORDER BY t.seq DESC
             LIMIT 1
             """,
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

  @doc false
  def rebind_not_dispatched_continuation_in_txn(%Txn{} = txn, source, successor, turn) do
    old = wait_in_txn(txn, source)
    next = wait_in_txn(txn, successor)
    facts = continuation_facts_in_txn(txn, old, old.assignment_id)
    mutable = [:wake_id, :state, :due_at, :canceled_at]

    recognition_valid =
      case old.wait_mode do
        "after-turn" ->
          old.recognition_path == "after-turn" and is_integer(old.originating_turn_seq) and
            match?(
              %{"domain" => "turn", "row_id" => seq} when seq == old.originating_turn_seq,
              old.recognition_transition
            )

        "dependency" ->
          old.recognition_path in ~w(success reconsideration fallback) and
            facts["wait.declaration_complete"]

        _ ->
          false
      end

    originating_valid =
      is_nil(old.originating_turn_seq) or
        Txn.q(
          txn,
          "SELECT 1 FROM turns WHERE seq=?1 AND sessionKey=?2 AND status IN ('delivered','canceled','failed','failed_unknown')",
          [old.originating_turn_seq, old.creator_session_key]
        ) == [[1]]

    # The retry delegates an admitted declaration, never a new controller or
    # recognition. Recheck live obligation/verification and originating-turn
    # eligibility while preserving the entire stored declaration and evidence.
    qualified =
      old.state == "fired" and next.state == "pending" and
        Map.drop(old, mutable) == Map.drop(next, mutable) and
        facts["wait.obligation_matches"] and facts["wait.admitted"] and
        facts["wait.after_turn_eligible"] and facts["wait.coverage_valid"] and
        facts["wait.recognized"] and is_binary(old.recognition_path) and
        is_map(old.recognition_evidence) and is_map(old.recognition_transition) and
        recognition_valid and originating_valid and
        Txn.q(
          txn,
          """
          WITH deliveries AS (#{Tightbeam.NoticeBatcher.recorded_deliveries_sql()})
          SELECT 1 FROM deliveries d JOIN turns t ON t.seq=d.turnSeq
          JOIN sessions holder ON holder.sessionKey=t.sessionKey
          JOIN supervision_liveness_sidecar sidecar ON sidecar.wakeId=d.sourceWakeId
            AND sidecar.assignmentId=d.assignmentId AND sidecar.controllerOrigin='holder_continuation'
            AND sidecar.controllerState='settled' AND sidecar.wakeKind IS NULL
            AND sidecar.chargedGeneration IS NULL AND sidecar.transferEvidenceId IS NULL
          JOIN wake_retry_attempts previous ON previous.wakeId=d.sourceWakeId
          JOIN wake_retry_attempts retry ON retry.wakeId=?2
          WHERE d.sourceWakeId=?1 AND d.assignmentId=?3 AND d.turnSeq=?4
            AND t.sessionKey=?5 AND holder.state='active' AND holder.ownerUserId=?6
            AND previous.sourceTurnSeq=t.seq AND previous.outcome='failed'
            AND previous.retryWakeId=retry.wakeId AND retry.predecessorWakeId=previous.wakeId
            AND retry.rootWakeId=previous.rootWakeId AND retry.attempt=previous.attempt+1
            AND retry.outcome='pending'
            AND NOT EXISTS (SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=retry.wakeId)
          """,
          [source, successor, old.assignment_id, turn.seq, old.session_key, old.owner_user_id]
        ) == [[1]]

    unless qualified,
      do:
        raise(DB.Error,
          message: "notice_prewrite_restoration_refused: continuation authority changed"
        )

    admit_continuation_in_txn(txn, next)
    :ok
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
          SELECT sessionKey,#{Tightbeam.Org.current_parent_sql("sessions")} FROM sessions WHERE sessionKey=?1 AND ownerUserId=?3
          UNION
          SELECT s.sessionKey,#{Tightbeam.Org.current_parent_sql("s")} FROM sessions s JOIN lineage l ON s.sessionKey=l.spawnedBy
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
           "SELECT seq FROM turns WHERE sessionKey=?1 AND status='running' " <>
             "AND status IN ('queued','running') LIMIT 1",
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

  defp log_wake_deferral(wake_id, operation, error) do
    key = {__MODULE__, :deferred_wake_ids}
    logged = Process.get(key, MapSet.new())

    unless MapSet.member?(logged, wake_id) do
      Process.put(key, MapSet.put(logged, wake_id))
      Logger.warning("wake #{wake_id} #{operation} deferred: #{Exception.message(error)}")
    end
  end

  defp recognize_wake_in_savepoint(txn, wake_id, recognize) do
    :ok = Txn.exec(txn, "SAVEPOINT wake_recognition")

    try do
      result = recognize.()
      :ok = Txn.exec(txn, "RELEASE wake_recognition")
      result
    rescue
      error ->
        :ok = Txn.exec(txn, "ROLLBACK TO wake_recognition")
        :ok = Txn.exec(txn, "RELEASE wake_recognition")
        log_wake_deferral(wake_id, "recognition", error)
        []
    end
  end

  defp recognize_wait_transitions_in_txn(txn, transitions) do
    unowned_fact? = fn transition ->
      is_map(transition) and transition[:domain] == "condition_fact" and
        is_nil(transition[:owner_user_id])
    end

    transitions =
      Enum.filter(
        transitions,
        &(is_map(&1) and (is_binary(&1[:owner_user_id]) or unowned_fact?.(&1)))
      )

    owners =
      if Enum.any?(transitions, unowned_fact?) do
        Txn.q(
          txn,
          "SELECT DISTINCT ownerUserId FROM wakes WHERE state='pending' AND waitMode='dependency' AND recognitionAt IS NULL"
        )
        |> Enum.map(fn [owner] -> owner end)
      else
        Enum.map(transitions, & &1.owner_user_id)
      end

    owners
    |> Enum.uniq()
    |> Enum.each(fn owner_user_id ->
      Txn.q(
        txn,
        """
        SELECT wakeId,predicate,resolverKind,resolverId,verificationAssignmentId,verificationState FROM wakes
        WHERE state='pending' AND waitMode='dependency' AND recognitionAt IS NULL
          AND ownerUserId=?1
        ORDER BY rowid
        """,
        [owner_user_id]
      )
      |> Enum.each(fn [
                        wake_id,
                        predicate,
                        resolver_kind,
                        resolver_id,
                        verifier,
                        verification_state
                      ] ->
        recognize_wake_in_savepoint(txn, wake_id, fn ->
          wake = %{
            wake_id: wake_id,
            owner_user_id: owner_user_id,
            predicate: decode_optional(predicate),
            resolver_kind: resolver_kind,
            resolver_id: resolver_id,
            verification_assignment_id: verifier,
            verification_state: verification_state
          }

          owner_transitions =
            Enum.filter(transitions, &(&1.owner_user_id == wake.owner_user_id))

          predicate_transition =
            Enum.find(transitions, fn transition ->
              (transition.owner_user_id == wake.owner_user_id or unowned_fact?.(transition)) and
                predicate_transition_relevant?(txn, wake, transition)
            end)

          resolver_transition =
            Enum.find(owner_transitions, &resolver_transition_relevant?(wake, &1))

          verification_transition =
            Enum.find(owner_transitions, &verification_terminal_transition?(wake, &1))

          if predicate_transition || resolver_transition || verification_transition do
            wake = wait_in_txn(txn, wake_id)
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
        end)
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
      schedule_changed_in_txn(txn, :wake_ready)

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
        wake_id = rule_notice_wake_id(rule, resolved)

        if is_binary(wake_id) and
             Txn.q(
               txn,
               "SELECT 1 FROM wakes WHERE wakeId=?1 AND origin=?2",
               [wake_id, "remedy:#{rule.name}"]
             ) != [] do
          :ok
        else
          input = %{
            session_key: resolved.bound_session,
            target_role: resolved.target[:target_role],
            origin: "remedy:#{rule.name}",
            prompt: resolved.params.prompt,
            due_at: System.system_time(:millisecond),
            creator_session_key: principal_session(call.principal),
            assignment_id: resolved[:assignment_id] || Map.get(call.params, :assignment_id),
            work_item_id: resolved[:work_item_id] || Map.get(call.params, :work_item_id),
            summon: true
          }

          input = if is_binary(wake_id), do: Map.put(input, :wake_id, wake_id), else: input
          wake = schedule_in_txn(txn, input)

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
        end

        :ok

      {:error, reason} ->
        case request_unowned_agent_stretch_decision_in_txn(txn, rule, call, evidence) do
          :handled ->
            :ok

          :not_applicable ->
            raise "notice #{rule.name} has unresolved target: #{inspect(reason)}"
        end
    end
  end

  defp request_unowned_agent_stretch_decision_in_txn(
         txn,
         %{name: "ac6a-unassigned-agent-turn"},
         call,
         evidence
       ) do
    session_key = Map.get(call.params, :session_key)
    caller_origin = Map.get(call.params, :caller_origin)

    stretch_id =
      case List.keyfind(evidence, "session.unassigned_stretch_id", 0) do
        {"session.unassigned_stretch_id", value} -> value
        nil -> nil
      end

    if is_binary(session_key) and is_binary(caller_origin) and is_binary(stretch_id) and
         stretch_id != "" do
      case Escalation.request_unowned_agent_stretch_in_txn(
             txn,
             session_key,
             caller_origin,
             stretch_id
           ) do
        %{code: code, message: message} ->
          EventLog.lifecycle_in_txn(
            txn,
            "rule_notice_failed",
            "ac6a-unassigned-agent-turn",
            "operator decision request failed (#{code}): #{message}"
          )

        _request ->
          :ok
      end

      :handled
    else
      :not_applicable
    end
  end

  defp request_unowned_agent_stretch_decision_in_txn(_txn, _rule, _call, _evidence),
    do: :not_applicable

  defp rule_notice_wake_id(_rule, %{idempotency_key: nil}), do: nil

  defp rule_notice_wake_id(rule, %{bound_session: session_key, idempotency_key: key})
       when is_binary(session_key) and is_binary(key) do
    digest =
      :crypto.hash(:sha256, rule.name <> "\0" <> session_key <> "\0" <> key)
      |> Base.encode16(case: :lower)

    "w_rule_" <> digest
  end

  defp rule_notice_wake_id(_rule, _resolved), do: nil

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

  @doc false
  def preserve_failed_intent_for_terminal_in_txn(%Txn{} = txn, turn_seq)
      when is_integer(turn_seq) and turn_seq > 0 do
    case Txn.q(
           txn,
           "SELECT seq,status,error,wakeId,requestRef,prompt,endedAt FROM turns WHERE seq=?1",
           [turn_seq]
         ) do
      [[^turn_seq, "failed", error, wake_id, request_ref, prompt, ended_at]] ->
        failure_class = Tightbeam.HarnessHealth.classify_turn_failure(error)

        preserve_failed_intent_in_txn(
          txn,
          %{
            seq: turn_seq,
            status: "failed",
            error: error,
            wake_id: wake_id,
            request_ref: request_ref,
            prompt: prompt,
            ended_at: ended_at
          },
          failure_class
        )

      [[^turn_seq, _status, _error, _wake_id, _request_ref, _prompt, _ended_at]] ->
        :not_retryable

      _ ->
        :settled
    end
  end

  def preserve_failed_intent_for_terminal_in_txn(%Txn{}, _turn_seq), do: :not_retryable

  @doc false
  @spec record_health_redelivery_source_in_txn(Txn.t(), integer(), String.t()) :: :ok
  def record_health_redelivery_source_in_txn(%Txn{} = txn, source_turn_seq, failure_class)
      when is_integer(source_turn_seq) and
             failure_class in [
               "auth-dead",
               "rate-limit-dead",
               "adapter_unavailable",
               "model_unavailable",
               "task_crash",
               "interrupted-outcome-unknown",
               "unclassified"
             ] do
    case Txn.q(
           txn,
           """
           SELECT t.sessionKey,t.messageId,t.wakeId,t.origin,t.prompt,t.roleRef,t.roleFallback,
                  t.assignmentId,t.jobRef,t.requestRef,s.harness,s.host
           FROM turns t JOIN sessions s ON s.sessionKey=t.sessionKey
           WHERE t.seq=?1 AND t.messageId IS NOT NULL
             AND (t.status='failed' OR
                  (t.status='failed_unknown' AND ?2='interrupted-outcome-unknown'))
           """,
           [source_turn_seq, failure_class]
         ) do
      [
        [
          session_key,
          message_id,
          wake_id,
          origin,
          prompt,
          role_ref,
          role_fallback,
          assignment_id,
          job_ref,
          request_ref,
          source_harness,
          source_host
        ]
      ]
      when is_binary(source_harness) and is_binary(source_host) ->
        idempotency_key = health_redelivery_key(session_key, source_turn_seq)

        parent_session_key =
          if failure_class == "interrupted-outcome-unknown" do
            interrupted_redelivery_parent_in_txn(txn, session_key, assignment_id)
          end

        Txn.q(
          txn,
          """
          INSERT OR IGNORE INTO health_redelivery_attempts
            (idempotencyKey,sessionKey,sourceHarness,sourceHost,sourceMessageId,sourceTurnSeq,
             sourceWakeId,origin,prompt,roleRef,roleFallback,assignmentId,jobRef,requestRef,
             failureClass,parentSessionKey,createdAt)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
          """,
          [
            idempotency_key,
            session_key,
            source_harness,
            source_host,
            message_id,
            source_turn_seq,
            wake_id,
            origin,
            prompt,
            role_ref,
            role_fallback,
            assignment_id,
            job_ref,
            request_ref,
            failure_class,
            parent_session_key,
            now()
          ]
        )

        if Txn.changes(txn) == 1 and is_binary(parent_session_key) do
          ask_interrupted_redelivery_parent_in_txn(
            txn,
            parent_session_key,
            session_key,
            source_turn_seq,
            message_id,
            origin,
            prompt
          )
        end

        :ok

      [] ->
        :ok

      [_] ->
        :ok
    end
  end

  defp interrupted_redelivery_parent_in_txn(txn, source_session_key, assignment_id) do
    assignment_parent =
      if is_binary(assignment_id) do
        case Txn.q(
               txn,
               """
               SELECT parent.sessionKey
               FROM assignments assignment
               JOIN sessions parent ON parent.sessionKey=assignment.openedBySession
               WHERE assignment.id=?1 AND parent.state='active'
                 AND parent.sessionKey!=?2
               """,
               [assignment_id, source_session_key]
             ) do
          [[parent_session_key]] -> parent_session_key
          _ -> nil
        end
      end

    assignment_parent ||
      case Txn.q(
             txn,
             """
             SELECT parent.sessionKey
             FROM sessions source
             JOIN sessions parent
               ON parent.sessionKey=#{Tightbeam.Org.current_parent_sql("source")}
             WHERE source.sessionKey=?1 AND parent.state='active'
               AND parent.sessionKey!=source.sessionKey
             """,
             [source_session_key]
           ) do
        [[parent_session_key]] -> parent_session_key
        _ -> nil
      end
  end

  defp ask_interrupted_redelivery_parent_in_txn(
         txn,
         parent_session_key,
         source_session_key,
         source_turn_seq,
         message_id,
         origin,
         original_prompt
       ) do
    wake_id = "w_health_redelivery_parent_#{source_turn_seq}"

    prompt =
      "A turn in session #{source_session_key} ended with typed " <>
        "interrupted-outcome-unknown. No automatic retry was queued. " <>
        "Should the original message be redelivered?\n" <>
        "Source turn: #{source_turn_seq}; message: #{message_id}; sender: #{origin}.\n" <>
        "Original message:\n#{original_prompt}\n" <>
        "If you want it retried, use the ordinary dispatch path for that session; " <>
        "otherwise leave the failed turn unchanged."

    schedule_in_txn(txn, %{
      wake_id: wake_id,
      session_key: parent_session_key,
      origin: "health-redelivery-parent",
      prompt: prompt,
      due_at: now(),
      summon: true
    })
  end

  @doc false
  @spec redeliver_pending_health_intents_in_txn(Txn.t(), map(), map()) :: non_neg_integer()
  def redeliver_pending_health_intents_in_txn(%Txn{} = txn, session, turn)
      when is_map(session) and is_map(turn) do
    harness = to_string(session.harness)
    host = session.host
    restoration_turn_seq = Map.fetch!(turn, :seq)

    if is_binary(host) and String.trim(host) != "" do
      Txn.q(
        txn,
        """
        SELECT a.idempotencyKey,a.sessionKey,a.sourceMessageId,a.sourceTurnSeq,
               a.sourceWakeId,a.origin,a.prompt,a.roleRef,a.roleFallback,a.assignmentId,
               a.jobRef,a.requestRef
        FROM health_redelivery_attempts a
        WHERE a.sourceHarness=?1
          AND a.sourceHost=?2
          AND a.redeliveryTurnSeq IS NULL
          AND a.parentSessionKey IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM harness_health_observations observation
            JOIN harness_health_incidents incident ON incident.id=observation.incidentId
            WHERE observation.correlationId =
              'harness-turn:' || a.sourceTurnSeq || ':' || a.failureClass
              AND observation.evidenceKind='terminal-failure'
              AND incident.state='open'
          )
          AND NOT EXISTS (
            SELECT 1 FROM wake_retry_attempts retry
            WHERE retry.sourceTurnSeq=a.sourceTurnSeq AND retry.retryWakeId IS NOT NULL
          )
        ORDER BY a.sourceTurnSeq
        """,
        [harness, host]
      )
      |> Enum.reduce(0, fn source, count ->
        count + redeliver_health_source_in_txn(txn, source, restoration_turn_seq)
      end)
    else
      0
    end
  end

  @doc false
  @spec redeliver_failed_intent_in_txn(Txn.t(), String.t(), String.t(), map()) ::
          non_neg_integer()
  def redeliver_failed_intent_in_txn(
        %Txn{} = txn,
        incident_id,
        failure_class,
        restoration_turn
      )
      when is_binary(incident_id) and
             failure_class in [
               "auth-dead",
               "rate-limit-dead",
               "adapter_unavailable",
               "model_unavailable",
               "task_crash",
               "interrupted-outcome-unknown"
             ] and is_map(restoration_turn) do
    restoration_turn_seq = Map.fetch!(restoration_turn, :seq)

    restoration_correlation =
      "harness-turn:#{restoration_turn_seq}:normal-success:#{failure_class}"

    case Txn.q(
           txn,
           """
           SELECT i.state,r.correlationId,r.evidenceKind
           FROM harness_health_incidents i
           JOIN harness_health_observations r ON r.id=i.resolutionObservationId
           WHERE i.id=?1 AND i.failureClass=?2
           """,
           [incident_id, failure_class]
         ) do
      [["resolved", ^restoration_correlation, "normal-turn-success"]] ->
        health_redelivery_sources_in_txn(txn, incident_id, failure_class)
        |> Enum.reduce(0, fn source, count ->
          count + redeliver_health_source_in_txn(txn, source, restoration_turn_seq)
        end)

      _ ->
        0
    end
  end

  defp health_redelivery_sources_in_txn(txn, incident_id, failure_class) do
    Txn.q(
      txn,
      """
      SELECT DISTINCT a.idempotencyKey,a.sessionKey,a.sourceMessageId,a.sourceTurnSeq,
             a.sourceWakeId,a.origin,a.prompt,a.roleRef,a.roleFallback,a.assignmentId,
             a.jobRef,a.requestRef
      FROM harness_health_observations observation
      JOIN turns observed
        ON observation.correlationId =
           'harness-turn:' || observed.seq || ':' || observation.failureClass
      JOIN health_redelivery_attempts a
        ON a.sessionKey=observed.sessionKey AND a.sourceMessageId=observed.messageId
      WHERE observation.incidentId=?1
        AND observation.failureClass=?2
        AND observation.evidenceKind='terminal-failure'
        AND observed.status='failed'
        AND observed.messageId IS NOT NULL
        AND a.failureClass=?2
        AND a.redeliveryTurnSeq IS NULL
        AND a.parentSessionKey IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM wake_retry_attempts retry
          WHERE retry.sourceTurnSeq=observed.seq AND retry.retryWakeId IS NOT NULL
        )
      ORDER BY a.sourceTurnSeq
      """,
      [incident_id, failure_class]
    )
  end

  defp redeliver_health_source_in_txn(
         txn,
         [
           idempotency_key,
           session_key,
           message_id,
           source_turn_seq,
           _source_wake_id,
           origin,
           prompt,
           role_ref,
           role_fallback,
           assignment_id,
           job_ref,
           request_ref
         ],
         restoration_turn_seq
       ) do
    if Ledger.enqueueable_in_txn?(txn, session_key) do
      case Ledger.enqueue_in_txn(txn, %{
             session_key: session_key,
             message_id: message_id,
             origin: origin,
             prompt: prompt,
             role_ref: role_ref,
             role_fallback: role_fallback == 1,
             assignment_id: assignment_id,
             job_ref: job_ref,
             request_ref: request_ref
           }) do
        {:ok, redelivery_turn_seq} ->
          Txn.q(
            txn,
            """
            UPDATE health_redelivery_attempts
            SET restorationTurnSeq=?2,redeliveryTurnSeq=?3
            WHERE idempotencyKey=?1 AND redeliveryTurnSeq IS NULL
            """,
            [idempotency_key, restoration_turn_seq, redelivery_turn_seq]
          )

          if Txn.changes(txn) != 1,
            do: raise("health redelivery attempt lost its enqueue")

          Txn.handoff(txn, Tightbeam.LaneManager, {:ensure_lane, session_key})
          1

        {:error, :no_session} ->
          0
      end
    else
      0
    end
  end

  defp health_redelivery_key(session_key, source_turn_seq) do
    "health-redelivery:" <> JSON.encode!([session_key, source_turn_seq])
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

        Tightbeam.ReminderDelivery.rebind_wake_in_txn(
          txn,
          wake.assignment_id,
          turn.seq,
          wake.wake_id,
          retry_wake_id
        )

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

    Tightbeam.QueuedMessageSuppression.copy_replacement_request_in_txn(
      txn,
      wake.wake_id,
      retry_wake_id
    )

    publish_change_in_txn(txn, "wake.scheduled", retry_wake_id)
    schedule_changed_in_txn(txn, {:schedule_changed, due_at})
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

  @doc false
  def bypass_batching_in_txn(%Txn{} = txn, wake_id, policy_ref, refusal)
      when is_binary(wake_id) and is_binary(policy_ref) and is_map(refusal) do
    fallback_rule =
      if Map.get(refusal, :direct_delivery, false),
        do: @inhibited_rule,
        else: @legacy_digest_rule

    Txn.q(
      txn,
      "UPDATE wakes SET deliveryRule=?2 WHERE wakeId=?1 AND state='pending'",
      [wake_id, fallback_rule]
    )

    EventLog.lifecycle_in_txn(
      txn,
      "notice_batching_admission_bypassed",
      wake_id,
      "rule=#{@digest_rule} fallback=#{fallback_rule} code=#{refusal.code}"
    )

    :ok
  end

  # The class this wake carries, and who put it there. A caller that names
  # `:class` elects; a caller that asks to be `:classify`-ed accepts the
  # classifier's stamp. An ordinary unclassed prompt receives the classifier's
  # default so it can share the recipient's next-turn batch.
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

      Map.get(input, :consumer, "prompt") == "prompt" ->
        classify(nil)

      true ->
        {nil, nil}
    end
  end

  defp apply_delivery_policy(txn, input, class, created_at, condition_kind) do
    if is_binary(class) and not Map.get(input, :digest, false) and
         not batcher_inhibited?(input, condition_kind) do
      {@digest_rule, Map.fetch!(input, :due_at)}
    else
      apply_class_delivery_policy(txn, input, class, created_at, condition_kind)
    end
  end

  defp apply_class_delivery_policy(_txn, input, nil, _created_at, _condition_kind),
    do: {nil, Map.fetch!(input, :due_at)}

  defp apply_class_delivery_policy(txn, input, class, created_at, condition_kind) do
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
      policy.immediacy == :digest and batcher_inhibited?(input, condition_kind) ->
        {@inhibited_rule, Map.fetch!(input, :due_at)}

      policy.immediacy == :digest and not batch_eligible?(input, class, condition_kind) ->
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

  # Trigger mechanics decide when a source becomes ready. They do not grant it
  # a separate recipient turn: timed, condition, dependency, replacement,
  # rumination, and typed terminal prompt sources join the same ordered batch.
  # Internal consumers are not agent attention and remain outside this lane.
  defp batcher_inhibited?(input, _condition_kind) do
    Map.get(input, :consumer, "prompt") != "prompt"
  end

  defp batch_eligible?(input, class, _condition_kind) do
    is_binary(class) and not Map.get(input, :digest, false) and
      Map.get(input, :consumer, "prompt") == "prompt"
  end

  defp batch_source?(wake), do: v1_batch_source?(wake) or v2_batch_source?(wake)

  defp batchable_delivery?(wake) do
    wake.delivery_rule in [@digest_rule, @legacy_digest_rule] and
      is_binary(wake.class) and wake.consumer == "prompt" and not wake.digest
  end

  defp batchable_for_recipient?(txn, wake) do
    if batchable_delivery?(wake) do
      target_gate = if wake.target_gate == 0, do: nil, else: wake

      case Gateway.delivery_target(txn, wake.session_key, target_gate) do
        {target, _role_ref, _role_fallback} -> Ledger.enqueueable_in_txn?(txn, target)
        nil -> false
      end
    else
      false
    end
  end

  defp v1_batch_source?(wake) do
    wake.delivery_rule == @digest_rule and not wake.digest and wake.consumer == "prompt" and
      is_binary(wake.class)
  end

  defp v2_batch_source?(_wake), do: false

  # FAIL QUIET AND VISIBLE (§5 policy-skew rule). An extended class this build
  # has no mapping for is delivered as `fyi` — never dropped, never promoted —
  # and the gap is a durable row somebody can act on, not a silent downgrade.
  #
  # THE ROW NAMES THE RULE THAT ACTUALLY DECIDED (O6 / §8 legibility): an
  # ordinary notice records the batch rule, while a source may use a direct
  # route — hardcoding `@digest_rule` here could claim a reflex that never
  # fired. `wake.delivery_rule` is the row's own already-computed fact, so the
  # skew row and the wake it describes cannot disagree about its rule.
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
  @spec readdress_pending_in_txn(Txn.t(), String.t(), String.t()) :: {:ok, wake()} | {:error, term()}
  def readdress_pending_in_txn(%Txn{} = txn, wake_id, replacement_target)
      when is_binary(wake_id) and is_binary(replacement_target) do
    case Txn.q(
           txn,
           "SELECT sessionKey,targetRole,consumer,state,deliveredTurnSeq,reresolve FROM wakes WHERE wakeId=?1",
           [wake_id]
         ) do
      [[session_key, nil, "prompt", "pending", nil, nil]] ->
        if session_key == replacement_target do
          {:ok, get_in_txn(txn, wake_id)}
        else
          with [[1]] <-
                 Txn.q(
                   txn,
                   "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'",
                   [replacement_target]
                 ),
               :ok <- Tightbeam.NoticeBatcher.readdress_source_in_txn(txn, wake_id) do
            Txn.q(
              txn,
              "UPDATE wakes SET sessionKey=?2 WHERE wakeId=?1 AND state='pending' AND deliveredTurnSeq IS NULL",
              [wake_id, replacement_target]
            )

            if Txn.changes(txn) == 1 do
              case get_in_txn(txn, wake_id) do
                %{due_at: due_at} = wake ->
                  schedule_changed_in_txn(txn, {:schedule_changed, due_at})
                  {:ok, wake}

                other ->
                  {:error, {:readdressed_wake_unreadable, other}}
              end
            else
              {:error, :wake_no_longer_pending}
            end
          else
            [] -> {:error, :target_unavailable}
            {:error, reason} -> {:error, reason}
            other -> {:error, {:source_not_readdressable, other}}
          end
        end

      [[_session_key, _target_role, _consumer, "fired", delivered_turn_seq, _reresolve]]
      when is_integer(delivered_turn_seq) ->
        {:error, :wake_already_delivered}

      [] ->
        {:error, :wake_missing}

      other ->
        {:error, {:wake_not_pending_plain_notice, other}}
    end
  end

  def readdress_pending_in_txn(%Txn{}, _wake_id, _replacement_target),
    do: {:error, :invalid_readdress_input}

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
        # Retarget preserves the source payload and authored provenance. Client
        # identity stays bound to the original source, reserving its dedupe key.
        Txn.q(
          txn,
          """
          UPDATE wakes SET
            sourceAttachments=(SELECT sourceAttachments FROM wakes WHERE wakeId=?2),
            sourceVisibilityScope=(SELECT sourceVisibilityScope FROM wakes WHERE wakeId=?2),
          sourceAddress=(SELECT sourceAddress FROM wakes WHERE wakeId=?2),
          ownerUserId=(SELECT ownerUserId FROM wakes WHERE wakeId=?2),
          obligationRef=(SELECT obligationRef FROM wakes WHERE wakeId=?2)
          WHERE wakeId=?1
          """,
          [replacement_id, wake_id]
        )

        Tightbeam.QueuedMessageSuppression.copy_replacement_request_in_txn(
          txn,
          wake_id,
          replacement_id
        )

        [row] = Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [replacement_id])
        wake = to_wake(row)
        schedule_changed_in_txn(txn, {:schedule_changed, wake.due_at})
        wake
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
  # Recipient readiness re-resolves the source at the concrete-session snapshot.
  # A retargeted source joins that same queue with its original due time.
  defp retarget_delivery(source, _created_at), do: {source.delivery_rule, source.due_at}

  @requester_kinds ~w(user session process)
  @reason_kinds ~w(requester_withdrew superseded obligation_disposed cannot_proceed_released routing_bracket_satisfied target_retired production_unmatched consumer_unavailable target_unresolvable)
  @source_kinds ~w(verb_call wake progress_attest condition_fact assignment_transition work_item_transition decision_request monitor_generation routing_bracket session_transition scheduler_delivery)
  @disposition_kinds ~w(assignment_transition work_item_transition decision_request_transition monitor_generation_transition)
  @liveness_kinds ~w(pending_wake routing_bracket)

  @process_reasons %{
    "tightbeam:wake-scheduler" =>
      ~w(production_unmatched consumer_unavailable target_unresolvable),
    "tightbeam:work-items" => ~w(routing_bracket_satisfied),
    "tightbeam:assignments" => ~w(obligation_disposed cannot_proceed_released superseded),
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
      {~w(wake progress_attest monitor_generation decision_request), ~w(replacement no_replacement)},
    "obligation_disposed" =>
      {~w(assignment_transition work_item_transition decision_request monitor_generation),
       ~w(disposition)},
    "cannot_proceed_released" => {~w(condition_fact), ~w(no_replacement)},
    "routing_bracket_satisfied" =>
      {~w(assignment_transition work_item_transition routing_bracket),
       ~w(replacement disposition)},
    "target_retired" => {~w(session_transition), ~w(replacement no_replacement)},
    "production_unmatched" => {~w(condition_fact), ~w(no_replacement)},
    "consumer_unavailable" => {~w(scheduler_delivery), ~w(no_replacement)},
    "target_unresolvable" => {~w(scheduler_delivery), ~w(replacement no_replacement)}
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

  @doc """
  Derive the liveness outcome for a public requester cancellation in `txn`.

  This is deliberately read-only and repeats the cancellation's pending-wake,
  origin and primary-work checks. `cancel_in_txn/2` performs those checks again
  before committing, so the trigger and the cancellation remain one transaction
  and the central no-stranding validator remains authoritative.
  """
  @spec public_cancellation_outcome_in_txn(Txn.t(), map()) :: {:ok, map()} | :error
  def public_cancellation_outcome_in_txn(%Txn{} = txn, command) when is_map(command) do
    with {:ok, wake} <- pending_wake(txn, command),
         :ok <- authorize_cancel(command, wake),
         {:ok, primary} <- primary_work(txn, wake) do
      {:ok, public_cancellation_outcome(txn, primary)}
    else
      _ -> :error
    end
  end

  def public_cancellation_outcome_in_txn(%Txn{}, _command), do: :error

  defp public_cancellation_outcome(txn, %{impact: "linked_work_open"} = primary) do
    kind = if primary.kind == "assignment", do: :assignment, else: :work_item

    case Supervision.inactivity_deadline_trigger_in_txn(txn, {kind, primary.id}) do
      {:ok, trigger} -> %{kind: "no_replacement", liveness_trigger: trigger}
      :none -> %{kind: "no_replacement"}
      {:error, _reason} -> %{kind: "no_replacement"}
    end
  end

  defp public_cancellation_outcome(_txn, _primary), do: %{kind: "no_replacement"}

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
        "SELECT wakeId, origin, state, conditionKind, work_item_id, assignmentId, consumer, obligationRef FROM wakes WHERE wakeId=?1",
        [wake_id]
      )

    rows =
      case rows do
        [
          [
            ^wake_id,
            _origin,
            "pending",
            _condition,
            _work_item,
            _assignment,
            _consumer,
            _obligation
          ]
        ] ->
          rows

        _ ->
          Txn.q(
            txn,
            """
            SELECT w.wakeId, w.origin, w.state, w.conditionKind, w.work_item_id,
                   w.assignmentId, w.consumer, w.obligationRef
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
          consumer,
          obligation_ref
        ]
      ] ->
        {:ok,
         %{
           wake_id: resolved_wake_id,
           origin: origin,
           condition_kind: condition_kind,
           work_item_id: work_item_id,
           assignment_id: assignment_id,
           consumer: consumer,
           obligation_ref: obligation_ref
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

  defp durable_source(
         txn,
         %{
           requester: %{kind: "process", id: requester_id},
           reason_kind: "superseded"
         },
         "progress_attest",
         source_id,
         %{obligation_ref: @terminal_action_marker <> _} = wake,
         _canceled_at
       )
       when requester_id in ["tightbeam:assignments", "tightbeam:supervision"] and
              is_binary(source_id) and source_id != "" do
    case get_in_txn(txn, wake.wake_id) do
      %{obligation_ref: @terminal_action_marker <> _} = full_wake ->
        case terminal_action_attest_for_wake_in_txn(txn, full_wake, source_id) do
          {:ok, _} -> {:ok, source_id, nil}
          :error -> :error
        end

      _ ->
        :error
    end
  end

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
        if reason == "superseded" and source == "wake" and outcome == "replacement",
           do: :ok,
           else: :error

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

              requester_id == "tightbeam:assignments" and primary.kind == "assignment" and
                  Tightbeam.QueuedMessageSuppression.replacement_assignment_id_in_txn(
                    txn,
                    replacement_id
                  ) == primary.id ->
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
        WHERE wakeId=?1 AND controllerOrigin='holder_continuation' AND controllerState='pending'
        """,
        [wake.wake_id]
      )

      if is_binary(wake.assignment_id) do
        Tightbeam.ReminderDelivery.canceled_in_txn(txn, wake.assignment_id, wake.wake_id)
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

      publish_change_in_txn(txn, "wake.canceled", wake.wake_id)
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

  @doc "Project the carrier's recorded delivery status without changing wake admission state."
  def delivery_projection_in_txn(%Txn{} = txn, wake_id) when is_binary(wake_id) do
    # One fixed selection for both absent and hidden wakes: a second lookup
    # conditional on finding the wake would disclose its existence in the trace.
    carrier_columns =
      ", (SELECT status FROM turns WHERE turns.wakeId=wakes.wakeId)" <>
        ", (SELECT createdAt FROM turns WHERE turns.wakeId=wakes.wakeId)" <>
        ", (SELECT startedAt FROM turns WHERE turns.wakeId=wakes.wakeId)" <>
        ", (SELECT endedAt FROM turns WHERE turns.wakeId=wakes.wakeId)"

    case Txn.q(txn, select_wake_sql(carrier_columns) <> " WHERE wakeId=?1", [wake_id]) do
      [] ->
        nil

      [row] ->
        {wake_columns, [status, created_at, started_at, ended_at]} = Enum.split(row, -4)
        wake = to_wake(wake_columns)

        # Keep the existing maximum-durable-timestamp version convention, now
        # including the row from which this additive projection is derived.
        version =
          [wake.created_at, wake.fired_at, wake.canceled_at, created_at, started_at, ended_at]
          |> Enum.filter(&is_integer/1)
          |> Enum.max()

        wake |> Map.put(:delivery_status, status) |> Map.put(:row_version, version)
    end
  end

  @doc "Record a failed carrier's outcome in its sender's existing transcript, without a turn."
  def report_failed_delivery(db, seq) do
    result =
      transaction!(db, fn txn ->
        case Txn.q(
               txn,
               """
               SELECT w.wakeId,w.creatorSessionKey,w.origin,t.status,t.error,w.digest
               FROM turns t JOIN wakes w ON w.wakeId=t.wakeId
               WHERE t.seq=?1 AND t.status IN ('failed','failed_unknown')
                 AND w.consumer='prompt' AND COALESCE(w.targetGate,1)!=0
               """,
               [seq]
             ) do
          [[wake_id, creator, origin, status, error, digest]] ->
            # This is the same closed classification used by supervision. Its
            # rate-limit retry may not yet have run: the two recognizers are async.
            retry_safe? =
              status == "failed" and
                Tightbeam.HarnessHealth.classify_turn_failure(error) == "rate-limit-dead"

            carrier? =
              Txn.q(txn, "SELECT 1 FROM notice_batches WHERE deliveryWakeId=?1", [wake_id]) != []

            cond do
              retry_safe? ->
                :retry_owned

              carrier? ->
                sources = carrier_failure_sources_in_txn(txn, wake_id)
                record_sender_failure_in_txn(txn, seq, sources, status)

              digest == 0 ->
                record_sender_failure_in_txn(
                  txn,
                  seq,
                  [[wake_id, creator, origin]],
                  status
                )

              true ->
                :not_applicable
            end

          [] ->
            :not_applicable
        end
      end)

    case result do
      {:notices, notices} ->
        Enum.each(notices, fn {recipient, owner, marker} ->
          Tightbeam.ConnRegistry.publish_message(
            Tightbeam.ConnRegistry,
            recipient,
            owner,
            marker.seq,
            Tightbeam.Wire.Payloads.server_message(marker),
            fn pid, payload -> send(pid, {:push_message, recipient, marker.seq, payload}) end
          )
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp carrier_failure_sources_in_txn(txn, carrier_wake_id) do
    Txn.q(
      txn,
      """
      SELECT source.wakeId,source.creatorSessionKey,source.origin
      FROM notice_batches batch
      JOIN notice_batch_members member
        ON member.batchId=batch.batchId AND member.state='included'
      JOIN wakes source ON source.wakeId=member.sourceWakeId
      WHERE batch.deliveryWakeId=?1
        AND source.consumer='prompt' AND source.digest=0
        AND COALESCE(source.targetGate,1)!=0
      ORDER BY member.publicationSeq
      """,
      [carrier_wake_id]
    )
  end

  defp record_sender_failure_in_txn(txn, seq, sources, status) do
    notices =
      sources
      |> Enum.reduce(%{}, fn [wake_id, creator, origin], recipients ->
        # Stored creator identity is the sender, not the receiver's ancestry.
        # A substrate marker is readable even if that sender session retired.
        recipient = sender_failure_recipient(creator, origin)

        if is_binary(recipient) do
          Map.update(recipients, recipient, [wake_id], &[wake_id | &1])
        else
          recipients
        end
      end)
      |> Enum.flat_map(fn {recipient, wake_ids} ->
        case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey=?1", [recipient]) do
          [[owner]] when is_binary(owner) ->
            uncertainty =
              if status == "failed_unknown",
                do:
                  " Delivery outcome is unknown; prior effects must be reconciled before retry.",
                else: " The delivery carrier failed; this notice does not authorize a retry."

            source_names = wake_ids |> Enum.reverse() |> Enum.join(", ")

            # Use the existing transcript dedupe key. No new wake, obligation,
            # notification registry, or second failure-prone inference is admitted.
            {disposition, marker} =
              Tightbeam.Projection.append_in_txn(txn, %{
                session_key: recipient,
                role: "assistant",
                content:
                  "Wake #{source_names} undelivered: delivery turn #{seq} is #{status}." <>
                    uncertainty,
                sender: "process:tightbeam",
                message_type: "substrate",
                attention_tier: Tightbeam.Projection.attention_tier(:high),
                device_id: "process:tightbeam",
                client_message_id: "wake-undelivered:#{seq}"
              })

            if disposition in [:appended, :duplicate],
              do: [{recipient, owner, marker}],
              else: raise("wake undelivered notice conflicts with delivery turn #{seq}")

          _ ->
            # There is no lawful transcript to write. The durable carrier and
            # authorized source projection still expose the incomplete outcome.
            []
        end
      end)

    {:notices, notices}
  end

  defp sender_failure_recipient(creator, _origin) when is_binary(creator), do: creator

  defp sender_failure_recipient(nil, "user:" <> user),
    do: Tightbeam.Org.personal_session_key(user)

  defp sender_failure_recipient(_creator, _origin), do: nil

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

  @doc "All wakes targeting one session, in stable creation order."
  @spec list_for_session(db(), String.t()) :: [wake()]
  def list_for_session(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <> " WHERE sessionKey = ?1 ORDER BY createdAt ASC, wakeId ASC",
        [session_key]
      )

    Enum.map(rows, &to_wake/1)
  end

  @doc "Return one bounded page of wakes targeting a session in stable creation order."
  def list_for_session_page(db, session_key, boundary, limit) do
    select_from = select_wake_sql()

    case DB.transaction(db, fn txn ->
           query = fn sql, params -> Txn.q(txn, sql, params) end

           Keyset.page(
             query,
             select_from,
             "wakes",
             "sessionKey = ?",
             [session_key],
             ["createdAt", "wakeId"],
             boundary,
             limit,
             fn row -> [Enum.at(row, 8), hd(row)] end
           )
         end) do
      {:ok, page} -> %{rows: Enum.map(page.rows, &to_wake/1), flags: page}
      {:error, error} -> raise error
    end
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
  Count pending prompt wakes targeting a session that were durably created by
  that same session. A held self-created continuation still suppresses the
  turn-end remedy: its source row remains pending until the recipient is ready.
  Process-origin notices do not count as session-created continuations even if
  a caller supplied a creator key while constructing a fixture or system notice.
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
          AND origin NOT LIKE 'process:%'
        """,
        [session_key]
      )

    count
  end

  ## The batcher (fabric §5 `batcher`; Invariant 3)

  @doc """
  Materialize each default-on batch from the recipient's due prompt queue only
  when that recipient is ready to take a turn. While a turn is running, source
  wakes have no batch membership and remain individually editable. Readiness,
  enrollment, sealing, and carrier creation happen in one transaction so a
  cancellation or retarget cannot race into a frozen envelope.

  Every due prompt class shares the recipient batch. Class controls only member
  priority and stays visible in each source mark. Session, user, and role
  addresses remain separate groups; role carriers preserve `targetRole` so
  delivery resolves the same audience again.

  Batch and rendered-payload limits split the ready queue into bounded
  carriers. A source too large to fit by itself is moved to the compatibility
  digest path without truncating or rewriting its payload. Source rows remain
  durable and are never deleted by materialization.
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

  @doc "Whether a rumination wake is staged for, or has reached, this caller's next turn."
  @spec rumination_exists?(db(), String.t(), String.t()) :: boolean()
  def rumination_exists?(db \\ Tightbeam.DB, work_item_id, caller_session) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT 1 FROM wakes
        WHERE rumination = 1 AND work_item_id = ?1 AND creatorSessionKey = ?2
          AND (state = 'fired' OR (state = 'pending' AND (
            firedAt IS NOT NULL OR EXISTS (
              SELECT 1 FROM notice_batch_members m
              JOIN notice_batches b ON b.batchId=m.batchId
              WHERE m.sourceWakeId=wakes.wakeId
                AND m.state IN ('active','included')
                AND b.state IN ('open','sealed','delivery_pending')
            )
          )))
        LIMIT 1
        """,
        [work_item_id, caller_session]
      )

    rows != []
  end

  @doc false
  @spec rumination_status_in_txn(Txn.t(), String.t(), String.t()) ::
          :delivered | :staged | :pending | :none
  def rumination_status_in_txn(%Txn{} = txn, work_item_id, caller_session) do
    case Txn.q(
           txn,
           """
           SELECT state, firedAt,
             EXISTS (
               SELECT 1 FROM notice_batch_members m
               JOIN notice_batches b ON b.batchId=m.batchId
               WHERE m.sourceWakeId=wakes.wakeId
                 AND m.state IN ('active','included')
                 AND b.state IN ('open','sealed','delivery_pending')
             )
           FROM wakes
           WHERE rumination=1 AND work_item_id=?1 AND creatorSessionKey=?2
             AND state IN ('pending','fired')
           ORDER BY CASE state WHEN 'fired' THEN 0 ELSE 1 END, createdAt, wakeId
           LIMIT 1
           """,
           [work_item_id, caller_session]
         ) do
      [["fired", _fired_at, _member]] -> :delivered
      [["pending", fired_at, member]] when not is_nil(fired_at) or member == 1 -> :staged
      [["pending", nil, 0]] -> :pending
      [] -> :none
    end
  end

  ## Scheduler process

  @doc """
  Start the scheduler. Opts: `:deliver` (required — see `t:deliver/0`),
  `:db`, `:name` (default `Tightbeam.WakeScheduler`
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
      GenServer.cast(self(), :wake_ready)
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

  @doc """
  Post-commit `fire_matching/2` for request paths. The fact has already
  committed: an absent scheduler is ignored, and a timeout or crash only logs,
  so the caller still gets its success response. Matching condition wakes are
  evaluated again on the next scheduler event.
  """
  @spec nudge_matching(GenServer.server(), pos_integer() | [pos_integer()]) :: :ok
  def nudge_matching(server, fact_ids) do
    fire_matching(server, fact_ids)
  catch
    :exit, {:noproc, _call} ->
      :ok

    :exit, reason ->
      Logger.warning(
        "wake scheduler condition nudge after a committed fact did not complete; " <>
          "matching wakes are evaluated on the next scheduler event: #{inspect(reason)}"
      )

      :ok
  end

  @doc false
  # The existing outbox sends to the registered scheduler only after commit.
  def schedule_changed_in_txn(%Txn{} = txn, message) do
    Txn.handoff(txn, Tightbeam.WakeScheduler, message)
  end

  @doc false
  def recipient_ready(server \\ Tightbeam.WakeScheduler, session_key) do
    GenServer.cast(server, {:recipient_ready, session_key})
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
      WHERE f.id=?1 AND w.state='pending' AND w.firedAt IS NULL
        AND f.id>w.conditionAfterId
      ORDER BY w.rowid
      """,
      [fact_id]
    )
    |> Enum.flat_map(fn [wake_id] ->
      recognize_wake_in_savepoint(txn, wake_id, fn ->
        case Txn.q(txn, select_wake_sql() <> " WHERE wakeId=?1", [wake_id]) do
          [row] ->
            case fire_in_txn(txn, to_wake(row), fact_id) do
              {:fired, :staged} -> [{:condition_batch_ready, wake_id}]
              {:fired, delivery} -> [delivery]
              :noop -> []
            end

          [] ->
            []
        end
      end)
    end)
  end

  @impl true
  def init(opts) do
    state = %{
      deliver: Keyword.fetch!(opts, :deliver),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      timer: nil,
      deadline: nil,
      fire_pending: false,
      retries: %{},
      retry_attempts: %{},
      detected_misses: MapSet.new(),
      scanned_through: -1,
      batch: Keyword.get(opts, :batch, 100),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      internal_consumers: Keyword.get(opts, :internal_consumers, %{})
    }

    Process.send_after(self(), :detect_misses, @miss_detector_ms)
    send(self(), :recover_notices)
    Process.send_after(self(), :backfill_wake_delivery, 100)

    {:ok, invalid} =
      DB.query(
        state.db,
        "SELECT wakeId, dueAt FROM wakes WHERE state='pending' AND dueAt IS NOT NULL AND typeof(dueAt)<>'integer'"
      )

    Enum.each(invalid, fn [id, due] ->
      Logger.warning("wake #{id} unavailable: invalid deadline #{inspect(due)}")
    end)

    {:ok, arm_due_timer(state)}
  end

  @impl true
  def handle_call(:fire_due, _from, state) do
    {:reply, :ok, run_due(state)}
  end

  # Evaluate the committed fact(s) eagerly, then reply. The delivery pass runs
  # as the next message, so a fact filer never waits on a full scheduler pass.
  def handle_call({:fire_matching, fact_id}, _from, state) do
    eager_step(state, fact_id)
    {:reply, :ok, queue_due(state)}
  end

  def handle_call({:fire_matching_seq, fact_ids}, _from, state) do
    drain_seq(state, fact_ids)
    {:reply, :ok, queue_due(state)}
  end

  @impl true
  def handle_cast(:wake_ready, state) do
    {:noreply, queue_due(state)}
  end

  def handle_cast({:schedule_changed, due_at}, state) do
    cond do
      is_nil(due_at) or due_at >= 253_402_300_799_000 ->
        {:noreply, state}

      due_at <= now() ->
        {:noreply, queue_due(state)}

      is_nil(state.deadline) or due_at < state.deadline ->
        {:noreply, set_due_timer(state, due_at)}

      true ->
        {:noreply, state}
    end
  end

  def handle_cast({:recipient_ready, session_key}, state) do
    DB.background_pass(fn ->
      deliver_eligible_waits(state.db, state.delivery_opts, session_key)
      NoticeBatcher.recover(state.db, now(), state.delivery_opts, session_key)
    end)

    {:noreply, arm_due_timer(state)}
  end

  @impl true
  def handle_info(:recover_notices, state) do
    # Recognize overdue conditions before recovery forms a carrier. Otherwise
    # a timed source can occupy the recipient ahead of its due condition peers.
    DB.background_pass(fn -> evaluate_conditions(state, :tick) end)
    # Release pre-crash, unclaimed memberships once. Later drains are driven
    # only by recipient readiness and due events.
    NoticeBatcher.recover(state.db, now(), state.delivery_opts)
    {:noreply, state}
  end

  def handle_info(:backfill_wake_delivery, state) do
    result =
      DB.background_pass(fn -> Tightbeam.Schema.backfill_wake_delivery(state.db) end, :overloaded)

    case result do
      :overloaded -> Process.send_after(self(), :backfill_wake_delivery, 5_000)
      :more -> Process.send_after(self(), :backfill_wake_delivery, 100)
      {:error, _error} -> Process.send_after(self(), :backfill_wake_delivery, 5_000)
      :done -> :ok
    end

    {:noreply, state}
  end

  def handle_info(:fire_due, state) do
    {:noreply, run_due(%{state | fire_pending: false})}
  end

  def handle_info({:timeout, timer, :due}, %{timer: timer} = state) do
    {:noreply, run_due(%{state | timer: nil, deadline: nil})}
  end

  def handle_info({:timeout, _stale_timer, :due}, state), do: {:noreply, state}

  def handle_info(:detect_misses, state) do
    state = DB.background_pass(fn -> detect_misses(state) end, state)
    Process.send_after(self(), :detect_misses, @miss_detector_ms)
    {:noreply, arm_due_timer(state)}
  end

  def handle_info(:fire_matching, state) do
    DB.background_pass(fn ->
      if evaluate_conditions(state, :tick) == :saturated, do: send(self(), :fire_matching)
    end)

    {:noreply, state}
  end

  def handle_info({:fire_matching, fact_id}, state) do
    DB.background_pass(fn -> eager_step(state, fact_id) end)
    {:noreply, state}
  end

  def handle_info({:fire_matching_seq, fact_ids}, state) do
    DB.background_pass(fn -> drain_seq(state, fact_ids) end)
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
  # leaves its wake pending for recovery; a crash between deliver and
  # mark redelivers, deduped by turns.wakeId.
  defp deliver_due(state) do
    # R1/B1: one real scheduler entry owns the context of all DB calls in this
    # scan. The bind restores even when delivery raises; the next scan gets a
    # fresh ID. No context is implicitly inherited by a spawned process.
    Tightbeam.RequestContext.bind_internal("wake_scheduler", fn ->
      DB.background_pass(fn -> deliver_due_in_context(state) end, :overloaded)
    end)
  end

  defp prompt_eligibility_sql do
    """
    digest=0 AND COALESCE(deliveryRule,'')<>'turn-boundary-digest r1'
    AND (conditionKind IS NULL OR firedAt IS NOT NULL)
    AND (waitMode IS NULL OR recognitionAt IS NOT NULL)
    AND (originatingTurnSeq IS NULL OR EXISTS (
      SELECT 1 FROM turns origin_turn WHERE origin_turn.seq=wakes.originatingTurnSeq
        AND origin_turn.status IN ('delivered','canceled','failed','failed_unknown')
    ))
    """
  end

  # Group only due routing destinations before resolving them. Busy recipients
  # wait for their lane's readiness signal without preparing their sources.
  defp due_prompt_recipients(db) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
        SELECT DISTINCT sessionKey,targetRole,targetGate,reresolve,reresolveSeed,reresolveRung
        FROM wakes INDEXED BY wakes_due
        WHERE state='pending' AND consumer='prompt'
          AND (dueAt<=?1 OR firedAt IS NOT NULL OR recognitionAt IS NOT NULL)
          AND #{prompt_eligibility_sql()}
        """,
        [now()]
      )
      |> Enum.flat_map(fn [key, role, gate, resolve, seed, rung] ->
        target_gate =
          cond do
            is_binary(role) -> %{target_role: role}
            gate == 0 -> nil
            true -> %{reresolve: resolve, reresolve_seed: seed, reresolve_rung: rung}
          end

        case Gateway.delivery_target(txn, key, target_gate) do
          {recipient, _, _} ->
            if Txn.q(
                 txn,
                 "SELECT 1 FROM turns WHERE sessionKey=?1 AND status IN ('running','queued') LIMIT 1",
                 [recipient]
               ) == [], do: [recipient], else: []

          # An unresolved role must be disposed visibly even when its former
          # recipient is busy. There is no recipient whose readiness can unblock it.
          nil ->
            [key]
        end
      end)
      |> Enum.uniq()
    end)
  end

  defp deliver_due_in_context(%{db: db, deliver: deliver, internal_consumers: consumers} = state) do
    state =
      Enum.reduce(Map.keys(state.retries), state, fn id, acc ->
        if is_binary(id) and
             transaction!(db, fn txn ->
               Txn.q(
                 txn,
                 "SELECT 1 FROM wakes WHERE wakeId=?1 AND state='pending' AND dueAt<=?2",
                 [id, now()]
               ) == []
             end), do: clear_retry(acc, id), else: acc
      end)

    Tightbeam.CronWake.fire_due(db, now())
    recognize_due_dependency_waits(db)
    evaluate_conditions(state, :tick)

    (deliver_eligible_waits(db, state.delivery_opts) ++ due_prompt_recipients(db))
    |> Enum.uniq()
    |> Enum.each(&NoticeBatcher.recover(db, now(), state.delivery_opts, &1))

    legacy_materialize_digests(db, now())

    {:ok, rows} =
      DB.query_for(
        db,
        "wake.due_scan",
        select_wake_sql(
          ", (SELECT routingWakeId FROM work_items WHERE id=wakes.work_item_id), (SELECT slateWakeId FROM work_items WHERE id=wakes.work_item_id)"
        ) <>
          " INDEXED BY wakes_due WHERE state = 'pending' AND dueAt <= ?1 AND conditionKind IS NULL AND waitMode IS NULL AND consumer<>'cron'" <>
          " AND NOT (consumer='prompt' AND digest=0 AND COALESCE(deliveryRule,'')<>'turn-boundary-digest r1')" <>
          " ORDER BY dueAt ASC",
        [now()]
      )

    # Keep the exact carrier references from this due snapshot. A failed
    # recognition rolls back only its notice, and holds that notice plus its
    # linked carriers for this pass, never the unrelated due batch. Consumed
    # carriers are not reset; absent liveness remains a visible pending notice.
    entries =
      Enum.flat_map(rows, fn row ->
        try do
          {wake_row, carriers} = Enum.split(row, -2)
          [{to_wake(wake_row), Enum.reject(carriers, &is_nil/1)}]
        rescue
          error ->
            log_wake_deferral(hd(row), "due delivery", error)
            []
        end
      end)

    Enum.reduce(entries, state, fn {wake, _carriers}, state ->
      if Map.get(state.retries, wake.wake_id, 0) > now() do
        state
      else
        if wake.digest, do: NoticeBatcher.delivery_attempted(db, wake.wake_id)

        delivery =
          case wake.consumer do
            "prompt" ->
              attempt_delivery(fn -> deliver.(wake) end)

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
          {_consumer, :deferred} ->
            :ok

          # Gateway returns :queued only when it staged the same pending source
          # into the recipient's editable next-turn queue. Leave that source
          # pending for NoticeBatcher recovery; marking it fired here would erase
          # the very row the carrier must preserve.
          {"prompt", {:ok, :queued}} ->
            :ok

          {"prompt", {:ok, :retry}} ->
            :ok

          {"prompt", {:ok, :skipped}} when wake.digest ->
            NoticeBatcher.delivery_terminal_failure(db, wake.wake_id, :skipped)

          {"prompt", {:ok, _result}} ->
            mark_fired(db, wake.wake_id)
            if wake.digest, do: NoticeBatcher.delivery_delivered(db, wake.wake_id)

          _ ->
            if wake.digest,
              do: NoticeBatcher.delivery_failed_attempt(db, wake.wake_id, :not_committed)
        end

        if delivery in [false, :retry] or delivery == {:ok, :retry} do
          retry_later(state, wake.wake_id)
        else
          clear_retry(state, wake.wake_id)
        end
      end
    end)
  end

  defp recognize_due_dependency_waits(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM wakes INDEXED BY wakes_due
        WHERE state='pending' AND waitMode='dependency' AND recognitionAt IS NULL AND dueAt<=?1
        ORDER BY dueAt,wakeId
        """,
        [now()]
      )

    Enum.each(rows, fn [wake_id] ->
      case DB.transaction(db, fn txn -> recognize_due_dependency_in_txn(txn, wake_id) end) do
        {:ok, _} ->
          :ok

        {:error, %DB.Overloaded{} = error} ->
          raise error

        {:error, error} ->
          log_wake_deferral(wake_id, "dependency recognition", error)
      end
    end)

    rows
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

  defp deliver_eligible_waits(db, delivery_opts, recipient \\ nil) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT wakeId FROM wakes
        WHERE state='pending' AND waitMode IS NOT NULL AND recognitionAt IS NOT NULL
          AND firedAt IS NULL AND (?1 IS NULL OR sessionKey=?1 OR targetRole IS NOT NULL OR targetGate<>0)
        ORDER BY recognitionAt,wakeId
        """,
        [recipient]
      )

    deliver_wait_ids(db, rows, delivery_opts, recipient)
  end

  defp deliver_wait_ids(db, rows, delivery_opts, recipient) do
    Enum.flat_map(rows, fn [wake_id] ->
      case DB.transaction_then(
             db,
             fn txn ->
               wake = get_in_txn(txn, wake_id)

               if is_nil(recipient) or match?({^recipient, _, _}, resolved_recipient(txn, wake)),
                 do: deliver_wait_in_txn(txn, wake_id, delivery_opts),
                 else: :noop
             end,
             fn txn, result ->
               row_commit_in_txn(txn, [])
               result
             end
           ) do
        {:ok, {:delivery, delivery}} ->
          Gateway.complete_delivery(db, delivery)
          []

        {:ok, {:staged, target}} ->
          [target]

        {:ok, _} ->
          []

        {:error, %DB.Overloaded{} = error} ->
          raise error

        {:error, error} ->
          log_wake_deferral(wake_id, "wait delivery", error)
          []
      end
    end)
  end

  defp deliver_wait_in_txn(txn, wake_id, delivery_opts) do
    case wait_in_txn(txn, wake_id) do
      %{state: "pending", recognition_path: path} = wake when is_binary(path) ->
        if wait_eligible_in_txn?(txn, wake) do
          batchable? = batchable_for_recipient?(txn, wake)
          fired_at = now()
          stamped_prompt = wait_stamp(wake) <> "\n\n" <> wake.prompt

          Txn.q(
            txn,
            if(batchable?,
              do:
                "UPDATE wakes SET firedAt=?2 WHERE wakeId=?1 AND state='pending' AND firedAt IS NULL",
              else:
                "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1 AND state='pending' AND firedAt IS NULL"
            ),
            [wake.wake_id, fired_at]
          )

          updated? = Txn.changes(txn) == 1

          if updated? do
            delivery =
              if batchable? do
                :staged
              else
                Gateway.deliver_prompt_in_txn(
                  txn,
                  wake.session_key,
                  wake.origin,
                  stamped_prompt,
                  [
                    wake_id: wake.wake_id,
                    sender: wake.origin,
                    target_gate: wake,
                    role_ref: wake.target_role
                  ] ++ delivery_opts
                )
              end

            if delivery == :staged do
              EventLog.lifecycle_in_txn(
                txn,
                "wake_wait_staged",
                wake.wake_id,
                "path=#{wake.recognition_path} assignment=#{wake.assignment_id}"
              )
            end

            publish_change_in_txn(txn, "wake.fired", wake.wake_id)

            if delivery == :staged do
              target_gate = if wake.target_gate == 0, do: nil, else: wake
              {recipient, _, _} = Gateway.delivery_target(txn, wake.session_key, target_gate)
              {:staged, recipient}
            else
              {:delivery, delivery}
            end
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

  defp settle_wait_continuation_in_txn(txn, wake_id, path, assignment_id, outcome) do
    Txn.q(
      txn,
      "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1 AND controllerOrigin='holder_continuation' AND controllerState='pending'",
      [wake_id]
    )

    if Txn.changes(txn) == 1 do
      lifecycle_kind =
        if outcome == "delivered", do: "wake_wait_delivered", else: "wake_wait_delivery_failed"

      EventLog.lifecycle_in_txn(
        txn,
        lifecycle_kind,
        wake_id,
        "path=#{path} assignment=#{assignment_id} outcome=#{outcome}"
      )
    end

    :ok
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

  @doc false
  def undeliverable_delivery_in_txn(%Txn{} = txn, wake_id, reason, at)
      when is_binary(wake_id) and is_binary(reason) and is_integer(at) and at >= 0 do
    case get_in_txn(txn, wake_id) do
      %{state: "pending"} = wake ->
        with {:ok, primary} <- primary_work(txn, wake),
             outcome <- delivery_failure_outcome(txn, wake, primary),
             true <- is_map(outcome),
             true <-
               cancel_in_txn(
                 txn,
                 %{
                   wake_id: wake_id,
                   requester: %{kind: "process", id: "tightbeam:wake-scheduler"},
                   reason_kind: "target_unresolvable",
                   causal_source: %{kind: "scheduler_delivery", id: wake_id},
                   outcome: outcome
                 },
                 fn -> at end
               ) do
          EventLog.lifecycle_in_txn(txn, "wake_undeliverable", wake_id, reason)
          :canceled
        else
          _ -> :unresolved
        end

      _ ->
        :settled
    end
  end

  def undeliverable_delivery_in_txn(%Txn{}, _wake_id, _reason, _at), do: :unresolved

  defp delivery_failure_outcome(txn, wake, %{impact: "linked_work_open"} = primary) do
    kind = if primary.kind == "assignment", do: :assignment, else: :work_item

    case Supervision.inactivity_deadline_trigger_in_txn(txn, {kind, primary.id}) do
      {:ok, trigger} -> %{kind: "no_replacement", liveness_trigger: trigger}
      _ -> nil
    end
  end

  defp delivery_failure_outcome(_txn, _wake, _primary), do: %{kind: "no_replacement"}

  # A wake nobody can deliver is still CONSUMED — leaving it pending would spin the
  # sweep forever on what is necessarily a code bug — but it is recorded as
  # `canceled`, NEVER as `fired`. `fired` is this substrate's word for delivered,
  # and claiming it for a delivery that never happened makes the durable row lie:
  # this path carries owner decision notifications, so a consumer-name typo would
  # silently eat a decision request while the record showed it delivered.
  #
  # No new state value: `canceled` already means "will not be delivered", and the
  # named lifecycle row carries WHY. Recording is best-effort so an unavailable
  # sink cannot fail this notice's delivery pass.
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

  # Keep failed internal work pending and record each attempt. The scheduler
  # retries it with an in-memory deadline rather than scanning it on a tick.
  defp attempt_internal_delivery(db, wake, internal_consumer) do
    case internal_consumer.(wake) do
      {:error, reason} -> internal_delivery_failed(db, wake, inspect(reason))
      {:ok, {:deferred, _reason}} -> :deferred
      {:ok, :deferred} -> :deferred
      result when result in [false, :retry] -> internal_delivery_failed(db, wake, inspect(result))
      {:ok, result} when result in [false, :retry] ->
        internal_delivery_failed(db, wake, inspect(result))

      _ -> true
    end
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

      if Txn.changes(txn) == 1, do: publish_change_in_txn(txn, "wake.fired", wake_id)
    end)

    :ok
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
            WHERE f.id>?1 AND f.id<=?2 AND w.state='pending' AND w.firedAt IS NULL
              AND f.id>w.conditionAfterId
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
          WHERE w.state='pending' AND w.firedAt IS NULL
            AND w.dueAt<=?1 AND w.conditionKind IS NOT NULL
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
          WHERE f.id=?1 AND w.state='pending' AND w.firedAt IS NULL
            AND f.id>w.conditionAfterId
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
          WHERE w.state='pending' AND w.firedAt IS NULL
            AND w.dueAt<=?1 AND w.conditionKind IS NOT NULL
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
      DB.transaction_then(
        db,
        fn txn ->
          case Txn.q(txn, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id]) do
            [row] -> fire_in_txn(txn, to_wake(row), fact_id)
            [] -> :noop
          end
        end,
        fn txn, result ->
          row_commit_in_txn(txn, [])
          result
        end
      )

    case result do
      {:ok, {:fired, :staged}} ->
        GenServer.cast(self(), :wake_ready)

      {:ok, {:fired, delivery}} ->
        Gateway.complete_delivery(db, delivery)

      {:ok, _} ->
        :ok

      {:error, %DB.Overloaded{} = error} ->
        raise error

      {:error, error} ->
        log_wake_deferral(wake_id, "condition delivery", error)
    end
  end

  defp fire_in_txn(txn, %{state: "pending", condition_kind: kind} = wake, fact_id)
       when is_binary(kind) do
    batchable? = batchable_for_recipient?(txn, wake)

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

      stamp =
        if cause == "condition",
          do: "[woke: fact #{kind}/#{match.scope || "nil"}]",
          else: "[woke: fallback deadline]"

      stamped_prompt = stamp <> "\n\n" <> wake.prompt

      Txn.q(
        txn,
        if(batchable?,
          do:
            "UPDATE wakes SET firedAt = ?2, firedBy = ?3, recognitionEvidence = ?4 WHERE wakeId = ?1 AND state = 'pending' AND firedAt IS NULL",
          else:
            "UPDATE wakes SET state = 'fired', firedAt = ?2, firedBy = ?3, recognitionEvidence = ?4 WHERE wakeId = ?1 AND state = 'pending' AND firedAt IS NULL"
        ),
        [
          wake.wake_id,
          fired_at,
          cause,
          if(match,
            do: JSON.encode!(%{condition_fact: %{id: match.id, kind: kind, scope: match.scope}})
          )
        ]
      )

      updated? = Txn.changes(txn) == 1

      delivery =
        cond do
          not updated? ->
            :noop

          batchable? ->
            :staged

          true ->
            Gateway.deliver_prompt_in_txn(
              txn,
              wake.session_key,
              wake.origin,
              stamped_prompt,
              wake_id: wake.wake_id,
              sender: wake.origin,
              target_gate: wake,
              role_ref: wake.target_role
            )
        end

      if updated? do
        lifecycle_for_fire(txn, wake, cause, match, delivery)
        publish_change_in_txn(txn, "wake.fired", wake.wake_id)
        if delivery == :staged, do: schedule_changed_in_txn(txn, :wake_ready)
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

  @doc false
  def publish_change_in_txn(%Txn{} = txn, class, wake_id) do
    case delivery_projection_in_txn(txn, wake_id) do
      nil ->
        :ok

      wake ->
        Tightbeam.Firehose.Publisher.committed_in_txn(
          txn,
          class,
          wake,
          %{"wakeId" => wake_id, "sessionKey" => wake.session_key}
        )
    end
  end

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
      "firedBy=#{cause}#{matched} target=#{target} reason=delivery_skipped"
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

  defp select_wake_sql(extra_columns \\ "") do
    "SELECT wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state, createdAt, firedAt, reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope, conditionAfterId, firedBy, creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt, targetGate, class, classElection, deliveryRule, digest, summon, ownerUserId, obligationRef, waitMode, predicate, resolverKind, resolverId, resolverHolder, resolverAddressee, necessity, verificationAssignmentId, verificationHolderKey, selectedPolicyName, verificationState, verificationAttestId, verificationNoticeWakeId, originatingTurnSeq, recognitionAt, recognitionPath, recognitionReason, recognitionEvidence, recognitionDisposition, recognitionTransition#{extra_columns} FROM wakes"
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

  defp queue_due(%{fire_pending: true} = state), do: state

  defp queue_due(state) do
    send(self(), :fire_due)
    %{state | fire_pending: true}
  end

  defp retry_later(state, wake_id) do
    attempt = Map.get(state.retry_attempts, wake_id, 0)
    delay = min(1_000 * Integer.pow(2, min(attempt, 9)), 300_000)

    %{
      state
      | retries: Map.put(state.retries, wake_id, now() + delay),
        retry_attempts: Map.put(state.retry_attempts, wake_id, attempt + 1)
    }
  end

  defp clear_retry(state, wake_id) do
    %{
      state
      | retries: Map.delete(state.retries, wake_id),
        retry_attempts: Map.delete(state.retry_attempts, wake_id)
    }
  end

  defp set_due_timer(state, due_at) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if due_at do
      deadline = System.monotonic_time(:millisecond) + max(0, due_at - now())
      timer = :erlang.start_timer(deadline, self(), :due, abs: true)
      %{state | timer: timer, deadline: due_at}
    else
      %{state | timer: nil, deadline: nil}
    end
  end

  defp arm_due_timer(state) do
    next =
      DB.background_pass(
        fn ->
          {:ok, rows} =
            DB.query(
              state.db,
              """
              SELECT MIN(dueAt) FROM wakes INDEXED BY wakes_due
              WHERE state='pending' AND typeof(dueAt)='integer' AND dueAt>?1 AND dueAt<253402300799000
              """,
              [state.scanned_through]
            )

          case rows do
            [[due_at]] -> due_at
            [] -> nil
          end
        end,
        :overloaded
      )

    next = if next == :overloaded, do: now() + 1_000, else: next
    pass_at = Map.get(state.retries, :pass)
    next = if next && pass_at, do: max(next, pass_at), else: next

    retry_at =
      state.retries
      |> Map.values()
      |> Enum.map(&max(&1, pass_at || 0))
      |> Enum.min(fn -> nil end)

    due_at = [next, retry_at] |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
    set_due_timer(state, due_at)
  end

  defp run_due(state) do
    at = now()
    result = if Map.get(state.retries, :pass, 0) > at, do: :waiting, else: deliver_due(state)

    case result do
      :waiting ->
        arm_due_timer(state)

      :overloaded ->
        arm_due_timer(retry_later(state, :pass))

      updated ->
        updated = clear_retry(updated, :pass)
        arm_due_timer(%{updated | scanned_through: max(state.scanned_through, at)})
    end
  end

  defp detect_misses(state) do
    at = now()

    candidates =
      transaction!(state.db, fn txn ->
        Txn.q(
          txn,
          select_wake_sql() <>
            """
             INDEXED BY wakes_due
            WHERE state='pending' AND dueAt<?1 AND consumer='prompt'
              AND #{prompt_eligibility_sql()}
              AND deliveredTurnSeq IS NULL
            ORDER BY dueAt
            """,
          [at - @miss_lateness_ms]
        )
        |> Enum.flat_map(fn row ->
          try do
            wake = to_wake(row)

            case if(wait_eligible_in_txn?(txn, wake), do: resolved_recipient(txn, wake)) do
              {recipient, _, _} ->
                if Txn.q(
                     txn,
                     "SELECT 1 FROM turns WHERE sessionKey=?1 AND status IN ('running','queued') LIMIT 1",
                     [recipient]
                   ) == [] do
                  last_ended =
                    case Txn.q(
                           txn,
                           "SELECT endedAt FROM turns WHERE sessionKey=?1 AND endedAt IS NOT NULL ORDER BY seq DESC LIMIT 1",
                           [recipient]
                         ) do
                      [[ended_at]] -> ended_at
                      [] -> wake.due_at
                    end

                  eligible_at = max(wake.due_at, last_ended)

                  if eligible_at < at - @miss_lateness_ms,
                    do: [{wake, recipient, eligible_at}],
                    else: []
                else
                  []
                end

              nil ->
                []
            end
          rescue
            error ->
              Logger.error(
                "wake scheduler miss candidate #{hd(row)} refused: #{Exception.message(error)}"
              )

              []
          end
        end)
      end)

    for {wake, recipient, eligible_at} <- candidates do
      try do
        # The event path may have delivered or occupied the recipient since sampling.
        ready =
          transaction!(state.db, fn txn ->
            Txn.q(
              txn,
              """
              SELECT 1 FROM wakes WHERE wakeId=?1 AND state='pending' AND deliveredTurnSeq IS NULL
                AND NOT EXISTS (SELECT 1 FROM turns WHERE sessionKey=?2 AND status IN ('running','queued'))
                AND NOT EXISTS (SELECT 1 FROM turns WHERE sessionKey=?2 AND endedAt>?3)
              """,
              [wake.wake_id, recipient, at - @miss_lateness_ms]
            ) != []
          end)

        if ready do
          deliver_eligible_waits(state.db, state.delivery_opts, recipient)
          NoticeBatcher.recover(state.db, at, state.delivery_opts, recipient)

          if match?(
               {:ok, [[seq]]} when is_integer(seq),
               DB.query(state.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
                 wake.wake_id
               ])
             ) do
            Logger.warning(
              "wake scheduler miss wake=#{wake.wake_id} kind=#{wake.condition_kind || wake.wait_mode || wake.consumer} late_ms=#{at - eligible_at}"
            )

            Tightbeam.SchedulerMisses.record(:wake, wake.wake_id, max(0, at - eligible_at))
          end
        end
      rescue
        error ->
          Logger.error(
            "wake scheduler miss recovery #{wake.wake_id} failed: #{Exception.message(error)}"
          )
      end
    end

    state = %{state | detected_misses: MapSet.new()}
    if candidates != [], do: run_due(state), else: state
  end

  defp resolved_recipient(txn, wake) do
    gate =
      cond do
        is_binary(wake.target_role) -> %{target_role: wake.target_role}
        wake.target_gate == 0 -> nil
        true -> Map.take(wake, [:reresolve, :reresolve_seed, :reresolve_rung])
      end

    Gateway.delivery_target(txn, wake.session_key, gate)
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
