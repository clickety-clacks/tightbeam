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

  alias Tightbeam.{ConditionFacts, DB, EventLog, Gateway}
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
          summon: boolean()
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
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

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

  @digest_rule "turn-boundary-digest #{@rules_rev}"
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
    # "principal immediately".
    "blocker" => %{immediacy: :immediate, ceiling_ms: 0},
    # "bypasses every bone and every desk. Never batched, never digested."
    #
    # PARTIAL AGAINST §7, and named rather than papered over: the seed default
    # routes an alarm to the principal AND the org's configured human channel.
    # The bypass half ships here. The dual-routing half does NOT — there is no
    # human-channel carrier on this line to route to, and inventing one inside
    # the batching seam would be a routing decision smuggled in under a timing
    # mechanism. An alarm reaches its target and skips every bone; it does not
    # yet reach a human by a second path.
    "algedonic" => %{immediacy: :bypass, ceiling_ms: 0}
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
          ceiling_ms: non_neg_integer(),
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
  def digest_signature(count) do
    "coalesced by #{@digest_rule} (#{count} #{if count == 1, do: "notice", else: "notices"})"
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
      summon: Map.get(input, :summon, false)
    }

    Txn.q(
      txn,
      """
        INSERT INTO wakes
          (wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state, createdAt, firedAt,
           reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope,
           conditionAfterId, firedBy, creatorSessionKey, rumination, work_item_id, assignmentId,
           targetGate, class, classElection, deliveryRule, digest, summon)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', ?8, NULL, ?9, ?10, ?11,
                ?12, ?13, ?14, NULL, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)
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
        if(wake.summon, do: 1, else: 0)
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

    wake
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

  defp apply_delivery_policy(_txn, input, class, created_at, condition_kind) do
    policy = delivery_policy(class)

    cond do
      # The carrier the batcher itself just built. Signed with the rule that
      # produced it, delivered at the moment that rule chose, and never a
      # member of anything: `digest = 1` is what keeps it out of its own group.
      Map.get(input, :digest, false) ->
        {@digest_rule, Map.fetch!(input, :due_at)}

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

  # FAIL QUIET AND VISIBLE (§5 policy-skew rule). An extended class this build
  # has no mapping for is delivered as `fyi` — never dropped, never promoted —
  # and the gap is a durable row somebody can act on, not a silent downgrade.
  defp file_policy_skew(txn, %{class: class, wake_id: wake_id}) when is_binary(class) do
    if delivery_policy(class).skew do
      EventLog.lifecycle_in_txn(
        txn,
        "wake_class_policy_skew",
        wake_id,
        "class=#{class} deliveredAs=#{classifier_default()} rule=#{@digest_rule}"
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

    case Txn.q(
           txn,
           "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'",
           [replacement_target]
         ) do
      [[1]] ->
        Txn.q(
          txn,
          """
          INSERT INTO wakes
            (wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state,
             createdAt, firedAt, reresolve, reresolveSeed, reresolveRung,
             conditionKind, conditionScope, conditionAfterId, firedBy,
             creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt,
             targetGate)
          SELECT ?2, ?3, targetRole, origin, prompt, consumer, dueAt, 'pending', ?4, NULL,
                 reresolve, reresolveSeed, reresolveRung, conditionKind,
                 conditionScope, conditionAfterId, NULL, creatorSessionKey,
                 rumination, work_item_id, assignmentId, NULL, targetGate
          FROM wakes
          WHERE wakeId=?1 AND state='pending'
          """,
          [wake_id, replacement_id, replacement_target, created_at]
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

      [] ->
        :error
    end
  end

  def retarget_in_txn(%Txn{}, _wake_id, _replacement_target), do: :error

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
      commit_cancellation(txn, wake, cancellation)
    else
      _ -> false
    end
  end

  def cancel_in_txn(%Txn{}, _command, _clock), do: false

  defp capture_clock(clock) do
    case clock.() do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp pending_wake(txn, %{wake_id: wake_id}) when is_binary(wake_id) do
    case Txn.q(
           txn,
           "SELECT wakeId, origin, state, conditionKind, work_item_id, assignmentId FROM wakes WHERE wakeId=?1",
           [wake_id]
         ) do
      [[^wake_id, origin, "pending", condition_kind, work_item_id, assignment_id]] ->
        {:ok,
         %{
           wake_id: wake_id,
           origin: origin,
           condition_kind: condition_kind,
           work_item_id: work_item_id,
           assignment_id: assignment_id
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
         {:ok, tagged} <- validate_outcome(txn, outcome_kind, outcome, wake, primary),
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

  defp validate_outcome(txn, "replacement", outcome, wake, primary) do
    replacement_id = Map.get(outcome, :replacement_wake_id)

    with true <- primary.impact != "linked_work_not_open",
         true <- is_binary(replacement_id) and replacement_id != wake.wake_id,
         :ok <- replacement_matches(txn, replacement_id, primary),
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

  defp validate_outcome(txn, "disposition", outcome, wake, primary) do
    disposition_kind = Map.get(outcome, :disposition_kind)
    disposition_id = Map.get(outcome, :disposition_id)

    with true <- disposition_kind in @disposition_kinds and is_binary(disposition_id),
         :ok <- validate_disposition(txn, disposition_kind, disposition_id),
         true <- is_nil(Map.get(outcome, :replacement_wake_id)),
         {:ok, liveness} <- validate_required_liveness(txn, outcome, wake, primary) do
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

  defp validate_outcome(txn, "no_replacement", outcome, wake, primary) do
    with true <- is_nil(Map.get(outcome, :replacement_wake_id)),
         true <- is_nil(Map.get(outcome, :disposition_kind)),
         true <- is_nil(Map.get(outcome, :disposition_id)),
         {:ok, liveness} <- validate_required_liveness(txn, outcome, wake, primary) do
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

  defp validate_required_liveness(_txn, outcome, _wake, %{impact: impact})
       when impact != "linked_work_open" do
    if is_nil(Map.get(outcome, :liveness_trigger)) do
      {:ok, %{liveness_kind: nil, liveness_id: nil, action_needed: 0}}
    else
      :error
    end
  end

  defp validate_required_liveness(txn, outcome, wake, primary) do
    case Map.get(outcome, :liveness_trigger) do
      %{kind: kind, id: id} when kind in @liveness_kinds and is_binary(id) ->
        case validate_liveness(txn, kind, id, wake, primary) do
          :ok -> {:ok, %{liveness_kind: kind, liveness_id: id, action_needed: 1}}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp replacement_matches(txn, replacement_id, primary) do
    case Txn.q(
           txn,
           "SELECT wakeId, origin, state, conditionKind, work_item_id, assignmentId FROM wakes WHERE wakeId=?1",
           [replacement_id]
         ) do
      [[^replacement_id, origin, "pending", condition_kind, work_item_id, assignment_id]] ->
        replacement = %{
          wake_id: replacement_id,
          origin: origin,
          condition_kind: condition_kind,
          work_item_id: work_item_id,
          assignment_id: assignment_id
        }

        case primary_work(txn, replacement) do
          {:ok, replacement_primary} ->
            if is_nil(primary.kind) or
                 {replacement_primary.kind, replacement_primary.id} == {primary.kind, primary.id},
               do: :ok,
               else: :error

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

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
        """
        UPDATE supervision_liveness_sidecar
        SET controllerState='settled'
        WHERE wakeId=?1 AND controllerOrigin='scheduled' AND controllerState='pending'
        """,
        [wake.wake_id]
      )

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
          -- compares NULL correctly and only the true digest-held case matches.
          AND NOT (digest = 0 AND deliveryRule IS ?2)
        """,
        [session_key, @digest_rule]
      )

    count
  end

  ## The batcher (fabric §5 `batcher`; Invariant 3)

  @doc """
  Materialize every digest whose delivery moment has arrived.

  ONE TURN FOR N PAYLOADS. Members are grouped by target session AND class —
  per-class, because the ceiling is per-class and mixing a four-hour `fyi` with
  a thirty-minute `input-needed` would either delay one or promote the other.

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
    # A candidate LIST only — which (session, class) groups currently hold any
    # digest-ruled pending wake at all. Nothing about WHETHER a group is due is
    # decided here; that judgment happens exactly once, per member, inside the
    # transaction below, against this same `at`.
    {:ok, groups} =
      DB.query(
        db,
        """
        SELECT DISTINCT sessionKey, class
        FROM wakes
        WHERE state = 'pending' AND consumer = 'prompt' AND digest = 0
          AND deliveryRule = ?1
        """,
        [@digest_rule]
      )

    Enum.flat_map(groups, fn [session_key, class] ->
      case materialize_digest(db, session_key, class, at) do
        nil -> []
        wake_id -> [wake_id]
      end
    end)
  end

  defp materialize_digest(db, session_key, class, at) do
    transaction!(db, fn txn ->
      members =
        Txn.q(
          txn,
          """
          SELECT wakeId, prompt, origin, creatorSessionKey, createdAt, dueAt
          FROM wakes
          WHERE state = 'pending' AND consumer = 'prompt' AND digest = 0
            AND deliveryRule = ?1 AND sessionKey = ?2 AND class = ?3
          -- Filing order. `createdAt` ties inside a millisecond, and the tie
          -- must not be broken by an id, which is random: rowid IS the order
          -- the org filed them in, and a digest that reordered its members
          -- would misreport the sequence a reader is trying to reconstruct.
          ORDER BY createdAt ASC, rowid ASC
          """,
          [@digest_rule, session_key, class]
        )

      materialize_due(txn, session_key, class, at, members)
    end)
  end

  # Nothing pending for this group in THIS snapshot — a race with another
  # materialization, not an error: nothing to carry, nothing to sign.
  defp materialize_due(_txn, _session_key, _class, _at, []), do: nil

  defp materialize_due(txn, session_key, class, at, members) do
    boundary = latest_turn_end(txn, session_key)

    due =
      members
      |> Enum.map(fn [wake_id, prompt, origin, creator, created_at, due_at] ->
        {[wake_id, prompt, origin, creator, created_at],
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
        materialize_members(txn, session_key, class, reason, at, rows)
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

  defp materialize_members(txn, session_key, class, reason, at, members) do
    digest =
      schedule_in_txn(txn, %{
        session_key: session_key,
        origin: "process:tightbeam",
        prompt: digest_prompt(class, members),
        due_at: at,
        class: class,
        digest: true,
        # The members already resolved their target; the digest delivers to the
        # session they resolved to, not to whoever is active now.
        target_gate: 0
      })

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
    # here: roll the whole materialization back and name what refused.
    if carried != length(members) do
      raise "incompatible_delivery_policy_v1: batcher consumed #{carried} of " <>
              "#{length(members)} digest members for #{session_key}/#{class}"
    end

    EventLog.lifecycle_in_txn(
      txn,
      "wake_digest_materialized",
      digest.wake_id,
      "rule=#{@digest_rule} target=#{session_key} class=#{class} members=#{carried} " <>
        "trigger=#{reason}"
    )

    digest.wake_id
  end

  # THE BRIEF. Every payload appears in full and in filing order; the digest
  # summarizes nothing, because an optimization that loses rows is wrong. The
  # signature names the rule and its revision so a reader knows which reflex to
  # inhibit (§8 legibility).
  defp digest_prompt(class, members) do
    body =
      members
      |> Enum.with_index(1)
      |> Enum.map(fn {[_wake_id, prompt, origin, creator, _created_at], index} ->
        "#{index}. [#{class} from #{creator || origin}] #{prompt}"
      end)
      |> Enum.join("\n")

    "[digest] #{digest_signature(length(members))}\n\n#{body}"
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

  @impl true
  def init(opts) do
    state = %{
      deliver: Keyword.fetch!(opts, :deliver),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      tick_ms: Keyword.get(opts, :tick_ms, 1_000),
      batch: Keyword.get(opts, :batch, 100),
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
    # THE BATCHER RUNS FIRST, so a digest that just came due is delivered in
    # this same pass rather than waiting a tick. Held members are consumed here
    # and never reach the loop below as individual deliveries.
    materialize_digests(db)

    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <>
          " WHERE state = 'pending' AND dueAt <= ?1 AND conditionKind IS NULL ORDER BY dueAt ASC",
        [now()]
      )

    for row <- rows do
      wake = to_wake(row)

      delivered =
        case wake.consumer do
          "prompt" ->
            if suppressed_by_recognition?(db, wake) do
              false
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

      if delivered and wake.consumer == "prompt" do
        mark_fired(db, wake.wake_id)
      end
    end

    evaluate_conditions(state, :tick)
    :ok
  end

  # THE PRODDER'S TRUE ACT TIME (spec production-machine-v1 §The prod
  # production). The prodder is three-phase on the ground: match records a
  # pending branch, drain SCHEDULES a wake, and this sweep FIRES it — so a
  # work-blocked fact asserted after the drain's recheck but before the fire
  # still has one effectful edge left to recognize at. Only supervision's own
  # wakes are eligible: origin `process:tightbeam` AND an assignmentId AND the
  # prompt consumer — today that combination is scheduled nowhere else (the
  # escalation decision notices carry no assignmentId), and it must stay that
  # way or this discriminator learns to suppress someone else's mail. The
  # holder is `reresolveSeed` for an escalation wake (its TARGET is the
  # ancestor being told) and the target itself for a prod. Nothing here gates
  # the turn queue: a suppressed wake is supervision's own prompt withdrawn by
  # recognition, consumed as `canceled` with the reason named — never a turn,
  # never an agent's wake.
  defp suppressed_by_recognition?(db, wake) do
    supervision_owned? =
      wake.origin == "process:tightbeam" and is_binary(wake.assignment_id)

    holder = wake.reresolve_seed || wake.session_key

    if supervision_owned? and ConditionFacts.standing?(db, "work-blocked", holder) do
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
      delivery.()
      true
    rescue
      _ -> false
    catch
      :exit, _ -> false
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
    {rows, watermark} = select_candidates(db, batch, mode)

    rows
    |> Enum.sort_by(fn
      [branch, _wake_id, fact_id, _scope, rid] when branch in ["C1", "C2"] ->
        {0, fact_id, rid}

      [_branch, _wake_id, _fact_id, _scope, rid] ->
        {1, rid, rid}
    end)
    |> Enum.each(fn [_branch, wake_id, _fact_id, _scope, _rid] ->
      fire_candidate(db, wake_id)
    end)

    if mode == :tick do
      advance_watermark(db, rows, batch, watermark)
    end

    saturated? =
      Enum.any?(~w(C1 C2 F), fn branch ->
        Enum.count(rows, &(hd(&1) == branch)) == batch
      end)

    if saturated?, do: :saturated, else: :done
  end

  defp select_candidates(db, batch, :tick) do
    transaction!(db, fn txn ->
      [[after_fact]] = Txn.q(txn, "SELECT afterFact FROM scheduler_state WHERE id = 0")
      [[ceil]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
      rows = Txn.q(txn, candidate_sql(:tick), [after_fact, ceil, batch, now()])
      {rows, {after_fact, ceil}}
    end)
  end

  defp select_candidates(db, batch, {:eager, fact_id}) do
    transaction!(db, fn txn ->
      {Txn.q(txn, candidate_sql(:eager), [fact_id, batch, now()]), nil}
    end)
  end

  defp candidate_sql(:tick) do
    """
    SELECT * FROM (
      SELECT 'C1' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id > ?1 AND f.id <= ?2
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope = f.scope AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?3
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'C2' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id > ?1 AND f.id <= ?2
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope IS NULL AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?3
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'F' AS branch, w.wakeId AS wakeId, NULL AS matchedFactId,
             NULL AS matchedScope, w.rowid AS rid
      FROM wakes w INDEXED BY wakes_due
      WHERE w.state = 'pending' AND w.dueAt <= ?4 AND w.conditionKind IS NOT NULL
      ORDER BY w.rowid ASC LIMIT ?3
    )
    """
  end

  defp candidate_sql(:eager) do
    """
    SELECT * FROM (
      SELECT 'C1' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id = ?1
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope = f.scope AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?2
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'C2' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id = ?1
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope IS NULL AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?2
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'F' AS branch, w.wakeId AS wakeId, NULL AS matchedFactId,
             NULL AS matchedScope, w.rowid AS rid
      FROM wakes w INDEXED BY wakes_due
      WHERE w.state = 'pending' AND w.dueAt <= ?3 AND w.conditionKind IS NOT NULL
      ORDER BY w.rowid ASC LIMIT ?2
    )
    """
  end

  defp advance_watermark(db, rows, batch, {after_fact, ceil}) do
    boundaries =
      Enum.map(~w(C1 C2), fn branch ->
        branch_rows = Enum.filter(rows, &(hd(&1) == branch))

        if length(branch_rows) < batch do
          ceil
        else
          branch_rows
          |> Enum.map(&Enum.at(&1, 2))
          |> Enum.max()
          |> Kernel.-(1)
        end
      end)

    after_fact_new = max(after_fact, Enum.min(boundaries))

    {:ok, _} =
      DB.query(db, "UPDATE scheduler_state SET afterFact = ?1 WHERE id = 0", [after_fact_new])

    :ok
  end

  defp fire_candidate(db, wake_id) do
    result =
      DB.transaction(db, fn txn ->
        case Txn.q(txn, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id]) do
          [row] -> fire_in_txn(txn, to_wake(row))
          [] -> :noop
        end
      end)

    case result do
      {:ok, {:fired, delivery}} -> Gateway.complete_delivery(db, delivery)
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  defp fire_in_txn(txn, %{state: "pending", condition_kind: kind} = wake)
       when is_binary(kind) do
    {match_sql, params} =
      if is_nil(wake.condition_scope) do
        {"SELECT id, scope FROM condition_facts WHERE id > ?1 AND kind = ?2 ORDER BY id ASC LIMIT 1",
         [wake.condition_after_id, kind]}
      else
        {"SELECT id, scope FROM condition_facts INDEXED BY condition_facts_match WHERE id > ?1 AND kind = ?2 AND scope = ?3 ORDER BY id ASC LIMIT 1",
         [wake.condition_after_id, kind, wake.condition_scope]}
      end

    match =
      case Txn.q(txn, match_sql, params) do
        [[id, scope]] -> %{id: id, scope: scope}
        [] -> nil
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

  defp fire_in_txn(_txn, _wake), do: :noop

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
    "SELECT wakeId, sessionKey, targetRole, origin, prompt, consumer, dueAt, state, createdAt, firedAt, reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope, conditionAfterId, firedBy, creatorSessionKey, rumination, work_item_id, assignmentId, canceledAt, targetGate, class, classElection, deliveryRule, digest, summon FROM wakes"
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
         summon
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
      summon: summon == 1
    }
  end

  defp schedule_tick(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
