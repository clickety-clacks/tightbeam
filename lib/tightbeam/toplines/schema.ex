defmodule Tightbeam.Toplines.Schema do
  @moduledoc "The closed Standalone Toplines V5 schema manifest and activation rail."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @shape "standalone-toplines-v5"

  @legacy_concern_objects [
    %{
      type: "table",
      name: "topline_concerns",
      sql:
        String.trim("""
        CREATE TABLE topline_concerns (
          id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlc_'),
          toplineId         TEXT NOT NULL REFERENCES toplines(id),
          title             ANY NOT NULL,
          state             TEXT NOT NULL CHECK (state IN ('open','resolved')),
          createdActorKind  TEXT NOT NULL CHECK (createdActorKind IN ('user','session')),
          createdActorRef   TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
          createdAt         INTEGER NOT NULL,
          updatedAt         INTEGER NOT NULL,
          resolveReason     TEXT,
          resolvedActorKind TEXT,
          resolvedActorRef  TEXT,
          resolvedAt        INTEGER,
          CHECK (typeof(title) = 'text'),
          CHECK (tightbeam_canonical_title(title) IS NOT NULL),
          CHECK (title = tightbeam_canonical_title(title)),
          CHECK (tightbeam_unicode_scalar_length(title) BETWEEN 1 AND 2000),
          CHECK (typeof(createdAt) = 'integer'),
          CHECK (typeof(updatedAt) = 'integer' AND updatedAt >= createdAt),
          CHECK (
            (state = 'open' AND resolveReason IS NULL AND resolvedActorKind IS NULL AND
             resolvedActorRef IS NULL AND resolvedAt IS NULL) OR
            (state = 'resolved' AND resolveReason IS NOT NULL AND
             length(trim(resolveReason)) BETWEEN 1 AND 4000 AND
             resolvedActorKind IS NOT NULL AND resolvedActorKind IN ('user','session') AND
             resolvedActorRef IS NOT NULL AND length(trim(resolvedActorRef)) > 0 AND
             typeof(resolvedAt) = 'integer' AND resolvedAt >= createdAt)
          )
        )
        """)
    },
    %{
      type: "index",
      name: "topline_concerns_id_topline",
      sql: "CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId)"
    },
    %{
      type: "table",
      name: "topline_concern_refs",
      sql:
        String.trim("""
        CREATE TABLE topline_concern_refs (
          id                TEXT PRIMARY KEY CHECK (substr(id, 1, 5) = 'tlcr_'),
          toplineId         TEXT NOT NULL,
          concernId         TEXT NOT NULL,
          membershipId      TEXT NOT NULL,
          linkReason        TEXT NOT NULL CHECK (length(trim(linkReason)) BETWEEN 1 AND 4000),
          linkedActorKind   TEXT NOT NULL CHECK (linkedActorKind IN ('user','session')),
          linkedActorRef    TEXT NOT NULL CHECK (length(trim(linkedActorRef)) > 0),
          linkedAt          INTEGER NOT NULL CHECK (typeof(linkedAt) = 'integer'),
          unlinkReason      TEXT,
          unlinkedActorKind TEXT,
          unlinkedActorRef  TEXT,
          unlinkedAt        INTEGER,
          FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
          FOREIGN KEY (membershipId, toplineId)
            REFERENCES topline_work_memberships(id, toplineId),
          CHECK (
            (unlinkedAt IS NULL AND unlinkReason IS NULL AND
             unlinkedActorKind IS NULL AND unlinkedActorRef IS NULL) OR
            (typeof(unlinkedAt) = 'integer' AND unlinkedAt >= linkedAt AND
             unlinkReason IS NOT NULL AND
             length(trim(unlinkReason)) BETWEEN 1 AND 4000 AND
             unlinkedActorKind IS NOT NULL AND unlinkedActorKind IN ('user','session') AND
             unlinkedActorRef IS NOT NULL AND length(trim(unlinkedActorRef)) > 0)
          )
        )
        """)
    },
    %{
      type: "index",
      name: "topline_concern_refs_active_pair",
      sql:
        "CREATE UNIQUE INDEX topline_concern_refs_active_pair ON topline_concern_refs (concernId, membershipId) WHERE unlinkedAt IS NULL"
    },
    %{
      type: "index",
      name: "topline_concern_refs_id_tuple",
      sql:
        "CREATE UNIQUE INDEX topline_concern_refs_id_tuple ON topline_concern_refs (id, toplineId, concernId, membershipId)"
    },
    %{
      type: "table",
      name: "topline_events",
      sql:
        String.trim("""
        CREATE TABLE topline_events (
          toplineId          TEXT NOT NULL REFERENCES toplines(id),
          seq                 INTEGER NOT NULL CHECK (typeof(seq) = 'integer' AND seq >= 1),
          kind                TEXT NOT NULL CHECK (kind IN (
            'topline_created','topline_renamed','topline_closed','topline_reopened',
            'work_linked','work_unlinked','concern_created','concern_renamed',
            'concern_resolved','concern_reopened','concern_work_linked',
            'concern_work_unlinked'
          )),
          membershipId       TEXT,
          concernId          TEXT,
          concernReferenceId TEXT,
          actorKind           TEXT NOT NULL CHECK (actorKind IN ('user','session')),
          actorRef            TEXT NOT NULL CHECK (length(trim(actorRef)) > 0),
          reason              TEXT,
          eventAt             INTEGER NOT NULL CHECK (typeof(eventAt) = 'integer'),
          detail              TEXT NOT NULL CHECK (json_valid(detail) AND json_type(detail) = 'object'),
          PRIMARY KEY (toplineId, seq),
          FOREIGN KEY (membershipId, toplineId)
            REFERENCES topline_work_memberships(id, toplineId),
          FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
          FOREIGN KEY (concernReferenceId, toplineId, concernId, membershipId)
            REFERENCES topline_concern_refs(id, toplineId, concernId, membershipId),
          CHECK (
            (kind IN ('topline_created','topline_renamed','topline_closed','topline_reopened') AND
             membershipId IS NULL AND concernId IS NULL AND concernReferenceId IS NULL) OR
            (kind IN ('work_linked','work_unlinked') AND membershipId IS NOT NULL AND
             concernId IS NULL AND concernReferenceId IS NULL) OR
            (kind IN ('concern_created','concern_renamed','concern_resolved','concern_reopened') AND
             membershipId IS NULL AND concernId IS NOT NULL AND concernReferenceId IS NULL) OR
            (kind IN ('concern_work_linked','concern_work_unlinked') AND
             membershipId IS NOT NULL AND concernId IS NOT NULL AND concernReferenceId IS NOT NULL)
          ),
          CHECK (
            (kind IN ('topline_created','concern_created') AND reason IS NULL) OR
            (kind NOT IN ('topline_created','concern_created') AND
             reason IS NOT NULL AND
             length(trim(reason)) BETWEEN 1 AND 4000)
          ),
          CHECK (
            COALESCE((kind IN ('topline_created','concern_created') AND
             json_type(detail, '$.title') = 'text' AND json_remove(detail, '$.title') = '{}') OR
            (kind IN ('topline_renamed','concern_renamed') AND
             json_type(detail, '$.fromTitle') = 'text' AND
             json_type(detail, '$.toTitle') = 'text' AND
             json_remove(detail, '$.fromTitle', '$.toTitle') = '{}') OR
            (kind IN ('topline_closed','topline_reopened','concern_resolved','concern_reopened') AND
             json_type(detail, '$.fromState') = 'text' AND
             json_type(detail, '$.toState') = 'text' AND
             json_remove(detail, '$.fromState', '$.toState') = '{}') OR
            (kind = 'work_linked' AND json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.linkReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.linkReason') = '{}') OR
            (kind = 'work_unlinked' AND json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.unlinkReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.unlinkReason') = '{}') OR
            (kind = 'concern_work_linked' AND json_type(detail, '$.membershipId') = 'text' AND
             json_type(detail, '$.linkReason') = 'text' AND
             json_remove(detail, '$.membershipId', '$.linkReason') = '{}') OR
            (kind = 'concern_work_unlinked' AND
             json_type(detail, '$.membershipId') = 'text' AND
             json_type(detail, '$.unlinkReason') = 'text' AND
             json_extract(detail, '$.cause') IN ('explicit','membership_unlinked') AND
             json_remove(detail, '$.membershipId', '$.unlinkReason', '$.cause') = '{}'), 0)
          )
        )
        """)
    },
    %{
      type: "table",
      name: "topline_idempotency",
      sql:
        String.trim("""
        CREATE TABLE topline_idempotency (
          callerUserId       TEXT NOT NULL REFERENCES users(userId),
          operation          TEXT NOT NULL CHECK (operation IN (
            'topline-create','topline-update','topline-close','topline-reopen',
            'topline-link-work','topline-unlink-work','topline-concern-create',
            'topline-concern-update','topline-concern-resolve','topline-concern-reopen',
            'topline-concern-link-work','topline-concern-unlink-work',
            'topline-work-leave-unlinked'
          )),
          idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
          requestFingerprint TEXT NOT NULL CHECK (
            length(requestFingerprint) = 64 AND requestFingerprint NOT GLOB '*[^0-9a-f]*'
          ),
          canonicalResponse  TEXT NOT NULL CHECK (
            json_valid(canonicalResponse) AND json_type(canonicalResponse) = 'object'
          ),
          PRIMARY KEY (callerUserId, operation, idempotencyKey)
        )
        """)
    }
  ]

  @objects [
    %{
      type: "table",
      name: "toplines",
      sql:
        String.trim("""
        CREATE TABLE toplines (
          id               TEXT PRIMARY KEY CHECK (substr(id, 1, 3) = 'tl_'),
          ownerUserId      TEXT NOT NULL REFERENCES users(userId),
          title            ANY NOT NULL,
          state            TEXT NOT NULL CHECK (state IN ('open','closed')),
          createdActorKind TEXT NOT NULL CHECK (createdActorKind IN ('user','session')),
          createdActorRef  TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
          createdAt        INTEGER NOT NULL,
          updatedAt        INTEGER NOT NULL,
          closedAt         INTEGER,
          CHECK (typeof(title) = 'text'),
          CHECK (tightbeam_canonical_title(title) IS NOT NULL),
          CHECK (title = tightbeam_canonical_title(title)),
          CHECK (tightbeam_unicode_scalar_length(title) BETWEEN 1 AND 2000),
          CHECK (typeof(createdAt) = 'integer'),
          CHECK (typeof(updatedAt) = 'integer' AND updatedAt >= createdAt),
          CHECK (
            (state = 'open' AND closedAt IS NULL) OR
            (state = 'closed' AND typeof(closedAt) = 'integer' AND closedAt >= createdAt)
          )
        )
        """)
    },
    %{
      type: "index",
      name: "toplines_id_owner",
      sql: "CREATE UNIQUE INDEX toplines_id_owner ON toplines (id, ownerUserId)"
    },
    %{
      type: "index",
      name: "work_items_id_owner",
      sql: "CREATE UNIQUE INDEX work_items_id_owner ON work_items (id, ownerUserId)"
    },
    %{
      type: "table",
      name: "topline_work_memberships",
      sql:
        String.trim("""
        CREATE TABLE topline_work_memberships (
          id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlm_'),
          toplineId         TEXT NOT NULL,
          workItemId        TEXT NOT NULL,
          ownerUserId       TEXT NOT NULL,
          linkReason        TEXT NOT NULL CHECK (length(trim(linkReason)) BETWEEN 1 AND 4000),
          linkedActorKind   TEXT NOT NULL CHECK (linkedActorKind IN ('user','session')),
          linkedActorRef    TEXT NOT NULL CHECK (length(trim(linkedActorRef)) > 0),
          linkedAt          INTEGER NOT NULL CHECK (typeof(linkedAt) = 'integer'),
          unlinkReason      TEXT,
          unlinkedActorKind TEXT,
          unlinkedActorRef  TEXT,
          unlinkedAt        INTEGER,
          FOREIGN KEY (toplineId, ownerUserId) REFERENCES toplines(id, ownerUserId),
          FOREIGN KEY (workItemId, ownerUserId) REFERENCES work_items(id, ownerUserId),
          CHECK (
            (unlinkedAt IS NULL AND unlinkReason IS NULL AND
             unlinkedActorKind IS NULL AND unlinkedActorRef IS NULL) OR
            (typeof(unlinkedAt) = 'integer' AND unlinkedAt >= linkedAt AND
             unlinkReason IS NOT NULL AND
             length(trim(unlinkReason)) BETWEEN 1 AND 4000 AND
             unlinkedActorKind IS NOT NULL AND unlinkedActorKind IN ('user','session') AND
             unlinkedActorRef IS NOT NULL AND length(trim(unlinkedActorRef)) > 0)
          )
        )
        """)
    },
    %{
      type: "index",
      name: "topline_memberships_active_pair",
      sql:
        "CREATE UNIQUE INDEX topline_memberships_active_pair ON topline_work_memberships (toplineId, workItemId) WHERE unlinkedAt IS NULL"
    },
    %{
      type: "index",
      name: "topline_memberships_id_topline",
      sql:
        "CREATE UNIQUE INDEX topline_memberships_id_topline ON topline_work_memberships (id, toplineId)"
    },
    %{
      type: "index",
      name: "topline_memberships_work_active",
      sql:
        "CREATE INDEX topline_memberships_work_active ON topline_work_memberships (workItemId) WHERE unlinkedAt IS NULL"
    },
    %{
      type: "table",
      name: "topline_concerns",
      sql:
        String.trim("""
        CREATE TABLE topline_concerns (
          id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlc_'),
          toplineId         TEXT NOT NULL REFERENCES toplines(id),
          title             ANY NOT NULL,
          createdActorKind  TEXT NOT NULL CHECK (createdActorKind IN ('user','session')),
          createdActorRef   TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
          createdAt         INTEGER NOT NULL,
          CHECK (typeof(title) = 'text'),
          CHECK (tightbeam_canonical_title(title) IS NOT NULL),
          CHECK (title = tightbeam_canonical_title(title)),
          CHECK (tightbeam_unicode_scalar_length(title) BETWEEN 1 AND 2000),
          CHECK (typeof(createdAt) = 'integer')
        )
        """)
    },
    %{
      type: "index",
      name: "topline_concerns_id_topline",
      sql: "CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId)"
    },
    %{
      type: "table",
      name: "topline_concern_refs",
      sql:
        String.trim("""
        CREATE TABLE topline_concern_refs (
          toplineId         TEXT NOT NULL,
          concernId         TEXT NOT NULL,
          workItemId        TEXT NOT NULL REFERENCES work_items(id),
          tagReason         TEXT NOT NULL CHECK (length(trim(tagReason)) BETWEEN 1 AND 4000),
          taggedActorKind   TEXT NOT NULL CHECK (taggedActorKind IN ('user','session')),
          taggedActorRef    TEXT NOT NULL CHECK (length(trim(taggedActorRef)) > 0),
          taggedAt          INTEGER NOT NULL CHECK (typeof(taggedAt) = 'integer'),
          PRIMARY KEY (concernId, workItemId),
          FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
          CHECK (length(trim(taggedActorRef)) > 0)
        )
        """)
    },
    %{
      type: "trigger",
      name: "topline_concern_refs_active_membership_insert",
      sql:
        String.trim("""
        CREATE TRIGGER topline_concern_refs_active_membership_insert
        BEFORE INSERT ON topline_concern_refs
        WHEN NOT EXISTS (
          SELECT 1 FROM topline_work_memberships m
          WHERE m.toplineId = NEW.toplineId AND m.workItemId = NEW.workItemId
            AND m.unlinkedAt IS NULL
        )
        BEGIN
          SELECT RAISE(ABORT, 'concern tag requires active topline membership');
        END
        """)
    },
    %{
      type: "table",
      name: "topline_events",
      sql:
        String.trim("""
        CREATE TABLE topline_events (
          toplineId          TEXT NOT NULL REFERENCES toplines(id),
          seq                 INTEGER NOT NULL CHECK (typeof(seq) = 'integer' AND seq >= 1),
          kind                TEXT NOT NULL CHECK (kind IN (
            'topline_created','topline_renamed','topline_closed','topline_reopened',
            'work_linked','work_unlinked','concern_created','concern_work_tagged',
            'concern_work_untagged'
          )),
          membershipId       TEXT,
          concernId          TEXT,
          actorKind           TEXT NOT NULL CHECK (actorKind IN ('user','session')),
          actorRef            TEXT NOT NULL CHECK (length(trim(actorRef)) > 0),
          reason              TEXT,
          eventAt             INTEGER NOT NULL CHECK (typeof(eventAt) = 'integer'),
          detail              TEXT NOT NULL CHECK (json_valid(detail) AND json_type(detail) = 'object'),
          PRIMARY KEY (toplineId, seq),
          FOREIGN KEY (membershipId, toplineId)
            REFERENCES topline_work_memberships(id, toplineId),
          FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
          CHECK (
            (kind IN ('topline_created','topline_renamed','topline_closed','topline_reopened') AND
             membershipId IS NULL AND concernId IS NULL) OR
            (kind IN ('work_linked','work_unlinked') AND membershipId IS NOT NULL AND
             concernId IS NULL) OR
            (kind = 'concern_created' AND membershipId IS NULL AND concernId IS NOT NULL) OR
            (kind IN ('concern_work_tagged','concern_work_untagged') AND
             membershipId IS NULL AND concernId IS NOT NULL)
          ),
          CHECK (
            (kind IN ('topline_created','concern_created') AND reason IS NULL) OR
            (kind NOT IN ('topline_created','concern_created') AND
             reason IS NOT NULL AND
             length(trim(reason)) BETWEEN 1 AND 4000)
          ),
          CHECK (
            COALESCE((kind IN ('topline_created','concern_created') AND
             json_type(detail, '$.title') = 'text' AND json_remove(detail, '$.title') = '{}') OR
            (kind = 'topline_renamed' AND
             json_type(detail, '$.fromTitle') = 'text' AND
             json_type(detail, '$.toTitle') = 'text' AND
             json_remove(detail, '$.fromTitle', '$.toTitle') = '{}') OR
            (kind IN ('topline_closed','topline_reopened') AND
             json_type(detail, '$.fromState') = 'text' AND
             json_type(detail, '$.toState') = 'text' AND
             json_remove(detail, '$.fromState', '$.toState') = '{}') OR
            (kind = 'work_linked' AND json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.linkReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.linkReason') = '{}') OR
            (kind = 'work_unlinked' AND json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.unlinkReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.unlinkReason') = '{}') OR
            (kind = 'concern_work_tagged' AND json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.tagReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.tagReason') = '{}') OR
            (kind = 'concern_work_untagged' AND
             json_type(detail, '$.workItemId') = 'text' AND
             json_type(detail, '$.untagReason') = 'text' AND
             json_remove(detail, '$.workItemId', '$.untagReason') = '{}'), 0)
          )
        )
        """)
    },
    %{
      type: "table",
      name: "topline_idempotency",
      sql:
        String.trim("""
        CREATE TABLE topline_idempotency (
          callerUserId       TEXT NOT NULL REFERENCES users(userId),
          operation          TEXT NOT NULL CHECK (operation IN (
            'topline-create','topline-update','topline-close','topline-reopen',
            'topline-link-work','topline-unlink-work','topline-concern-create',
            'topline-concern-link-work','topline-concern-unlink-work',
            'topline-work-leave-unlinked'
          )),
          idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
          requestFingerprint TEXT NOT NULL CHECK (
            length(requestFingerprint) = 64 AND requestFingerprint NOT GLOB '*[^0-9a-f]*'
          ),
          canonicalResponse  TEXT NOT NULL CHECK (
            json_valid(canonicalResponse) AND json_type(canonicalResponse) = 'object'
          ),
          PRIMARY KEY (callerUserId, operation, idempotencyKey)
        )
        """)
    },
    %{
      type: "index",
      name: "causal_events_seq_job_ref",
      sql: "CREATE UNIQUE INDEX causal_events_seq_job_ref ON causal_events (seq, jobRef)"
    },
    %{
      type: "table",
      name: "topline_placement_obligations",
      sql:
        String.trim("""
        CREATE TABLE topline_placement_obligations (
          id                       TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlp_'),
          workItemId               TEXT NOT NULL,
          ownerUserId              TEXT NOT NULL,
          cause                    TEXT NOT NULL CHECK (cause IN (
            'created','reopened','last_membership_unlinked','migration'
          )),
          causeRef                 TEXT NOT NULL CHECK (length(trim(causeRef)) > 0),
          sourceCausalEventSeq     INTEGER,
          resolutionCausalEventSeq INTEGER,
          historyCausalSeq         INTEGER NOT NULL CHECK (
            typeof(historyCausalSeq) = 'integer' AND historyCausalSeq >= 0
          ),
          openedActorKind          TEXT NOT NULL CHECK (openedActorKind IN ('user','session','process')),
          openedActorRef           TEXT NOT NULL CHECK (length(trim(openedActorRef)) > 0),
          state                    TEXT NOT NULL CHECK (state IN (
            'pending','linked','left_unlinked','work_terminal'
          )),
          openedAt                 INTEGER NOT NULL CHECK (typeof(openedAt) = 'integer'),
          dueAt                    INTEGER NOT NULL CHECK (typeof(dueAt) = 'integer' AND dueAt = openedAt),
          promptWakeId             TEXT NOT NULL REFERENCES wakes(wakeId)
            CHECK (length(trim(promptWakeId)) > 0),
          resolutionActorKind      TEXT,
          resolutionActorRef       TEXT,
          resolutionReason         TEXT,
          resolvedAt               INTEGER,
          FOREIGN KEY (workItemId, ownerUserId) REFERENCES work_items(id, ownerUserId),
          FOREIGN KEY (sourceCausalEventSeq, workItemId)
            REFERENCES causal_events(seq, jobRef),
          FOREIGN KEY (resolutionCausalEventSeq, workItemId)
            REFERENCES causal_events(seq, jobRef),
          CHECK (
            (cause = 'reopened' AND typeof(sourceCausalEventSeq) = 'integer' AND
             sourceCausalEventSeq > 0) OR
            (cause != 'reopened' AND sourceCausalEventSeq IS NULL)
          ),
          CHECK (
            (cause IN ('created','reopened') AND causeRef = workItemId) OR
            (cause = 'last_membership_unlinked' AND substr(causeRef, 1, 4) = 'tlm_') OR
            (cause = 'migration' AND length(trim(causeRef)) > 0)
          ),
          CHECK (
            (cause IN ('created','last_membership_unlinked') AND
             openedActorKind IN ('user','session')) OR
            (cause = 'migration' AND openedActorKind = 'process' AND openedActorRef = 'tightbeam') OR
            (cause = 'reopened' AND
             (openedActorKind IN ('user','session') OR
              (openedActorKind = 'process' AND openedActorRef = 'tightbeam')))
          ),
          CHECK (
            (state = 'pending' AND resolutionActorKind IS NULL AND
             resolutionActorRef IS NULL AND resolutionReason IS NULL AND
             resolvedAt IS NULL AND resolutionCausalEventSeq IS NULL) OR
            (state != 'pending' AND resolutionActorKind IS NOT NULL AND
             resolutionActorKind IN ('user','session','process') AND
             resolutionActorRef IS NOT NULL AND length(trim(resolutionActorRef)) > 0 AND
             resolutionReason IS NOT NULL AND length(trim(resolutionReason)) > 0 AND
             typeof(resolvedAt) = 'integer' AND resolvedAt >= openedAt)
          ),
          CHECK (
            (state IN ('linked','left_unlinked') AND resolutionActorKind IN ('user','session') AND
             resolutionCausalEventSeq IS NULL) OR
            (state = 'work_terminal' AND resolutionActorKind IN ('user','session') AND
             resolutionReason IN ('work_item_closed','work_item_failed','work_item_iceboxed') AND
             resolutionCausalEventSeq IS NULL) OR
            (state = 'work_terminal' AND resolutionActorKind = 'process' AND
             resolutionActorRef = 'tightbeam' AND
             resolutionReason IN (
               'reupgrade_terminal_reconciliation_closed',
               'reupgrade_terminal_reconciliation_failed',
               'reupgrade_terminal_reconciliation_iceboxed'
             ) AND typeof(resolutionCausalEventSeq) = 'integer' AND
             resolutionCausalEventSeq > 0) OR
            state = 'pending'
          )
        )
        """)
    },
    %{
      type: "index",
      name: "topline_placements_one_pending",
      sql:
        "CREATE UNIQUE INDEX topline_placements_one_pending ON topline_placement_obligations (workItemId) WHERE state = 'pending'"
    },
    %{
      type: "index",
      name: "topline_placements_one_reopen",
      sql:
        "CREATE UNIQUE INDEX topline_placements_one_reopen ON topline_placement_obligations (workItemId, sourceCausalEventSeq) WHERE sourceCausalEventSeq IS NOT NULL"
    },
    %{
      type: "index",
      name: "topline_placements_one_terminal_resolution",
      sql:
        "CREATE UNIQUE INDEX topline_placements_one_terminal_resolution ON topline_placement_obligations (workItemId, resolutionCausalEventSeq) WHERE resolutionCausalEventSeq IS NOT NULL"
    },
    %{
      type: "table",
      name: "topline_schema_stamp",
      sql:
        String.trim("""
        CREATE TABLE topline_schema_stamp (
          singleton INTEGER PRIMARY KEY CHECK (typeof(singleton) = 'integer' AND singleton = 1),
          shape      TEXT NOT NULL CHECK (typeof(shape) = 'text' AND length(trim(shape)) > 0),
          stampedAt  INTEGER NOT NULL CHECK (typeof(stampedAt) = 'integer' AND stampedAt >= 0)
        )
        """)
    }
  ]

  @doc "Return the exact closed Toplines object manifest."
  @spec manifest() :: [map()]
  def manifest, do: @objects

  @doc false
  def __legacy_concern_manifest__, do: @legacy_concern_objects

  @doc "Activate or verify the exact V5 schema without inferring or repairing old state."
  @spec activate(DB.server(), non_neg_integer(), keyword()) :: :ok | {:error, map()}
  def activate(db, stamped_at \\ System.system_time(:millisecond), opts \\ [])

  def activate(db, stamped_at, opts)
      when is_integer(stamped_at) and stamped_at >= 0 and is_list(opts) do
    case DB.transaction(db, fn txn -> activate_in_txn(txn, stamped_at, opts) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _} = refusal} -> refusal
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec activate_in_txn(Txn.t(), non_neg_integer(), keyword()) :: :ok | {:error, map()}
  def activate_in_txn(%Txn{} = txn, stamped_at, opts \\ []) do
    stored = stored_objects(txn)
    stamp = Enum.find(@objects, &(&1.name == "topline_schema_stamp"))

    case Map.get(stored, stamp.name) do
      nil ->
        activate_without_stamp(txn, stored, stamped_at, opts)

      %{type: type, sql: sql} when type != stamp.type or sql != stamp.sql ->
        refusal("schema_shape_mismatch")

      _exact ->
        activate_with_stamp(txn, stored, opts)
    end
  end

  defp activate_without_stamp(txn, stored, stamped_at, opts) do
    if Enum.any?(@objects, &(&1.name != "topline_schema_stamp" and Map.has_key?(stored, &1.name))) do
      refusal("unregistered_toplines_core_shape")
    else
      @objects
      |> Enum.with_index(1)
      |> Enum.each(fn {object, ordinal} ->
        :ok = Txn.exec(txn, object.sql)
        maybe_interrupt!(opts, ordinal)
      end)

      Txn.q(
        txn,
        "INSERT INTO topline_schema_stamp (singleton, shape, stampedAt) VALUES (1, ?1, ?2)",
        [@shape, stamped_at]
      )

      maybe_interrupt!(opts, :after_stamp)
      verify_manifest!(txn)
      :ok
    end
  end

  defp activate_with_stamp(txn, stored, opts) do
    case Txn.q(
           txn,
           "SELECT singleton, typeof(singleton), shape, typeof(shape), stampedAt, typeof(stampedAt) FROM topline_schema_stamp"
         ) do
      [] ->
        refusal("unregistered_toplines_core_shape")

      [[1, "integer", shape, "text", stamped_at, "integer"]]
      when is_binary(shape) and shape != "" and is_integer(stamped_at) and stamped_at >= 0 ->
        if shape != @shape do
          refusal("unknown_toplines_schema_stamp")
        else
          cond do
            exact_manifest?(stored) -> :ok
            legacy_concern_shape?(txn) -> migrate_legacy_concerns!(txn, opts)
            true -> refusal("schema_shape_mismatch")
          end
        end

      _invalid ->
        refusal("schema_shape_mismatch")
    end
  end

  defp legacy_concern_shape?(txn) do
    Enum.all?(@legacy_concern_objects, fn object ->
      Txn.q(txn, "SELECT type, sql FROM sqlite_schema WHERE name = ?1", [object.name]) ==
        [[object.type, object.sql]]
    end) and not object_exists?(txn, "topline_concern_refs_active_membership_insert")
  end

  defp migrate_legacy_concerns!(txn, opts) do
    for table <- ~w(topline_concerns topline_concern_refs topline_events topline_idempotency) do
      :ok = Txn.exec(txn, "ALTER TABLE #{table} RENAME TO #{table}_legacy")
    end

    for index <-
          ~w(topline_concerns_id_topline topline_concern_refs_active_pair topline_concern_refs_id_tuple) do
      :ok = Txn.exec(txn, "DROP INDEX #{index}")
    end

    changed_names =
      ~w(topline_concerns topline_concerns_id_topline topline_concern_refs topline_concern_refs_active_membership_insert topline_events topline_idempotency)

    @objects
    |> Enum.filter(&(&1.name in changed_names))
    |> Enum.each(fn object -> :ok = Txn.exec(txn, object.sql) end)

    Txn.q(
      txn,
      """
      INSERT INTO topline_concerns
        (id, toplineId, title, createdActorKind, createdActorRef, createdAt)
      SELECT id, toplineId, title, createdActorKind, createdActorRef, createdAt
      FROM topline_concerns_legacy
      """
    )

    Txn.q(
      txn,
      """
      INSERT INTO topline_concern_refs
        (toplineId, concernId, workItemId, tagReason,
         taggedActorKind, taggedActorRef, taggedAt)
      SELECT r.toplineId, r.concernId, m.workItemId, r.linkReason,
             r.linkedActorKind, r.linkedActorRef, r.linkedAt
      FROM topline_concern_refs_legacy r
      JOIN topline_work_memberships m ON m.id = r.membershipId
      WHERE r.unlinkedAt IS NULL AND m.unlinkedAt IS NULL AND m.toplineId = r.toplineId
      ORDER BY r.concernId, m.workItemId
      """
    )

    Txn.q(
      txn,
      """
      INSERT INTO topline_events
        (toplineId, seq, kind, membershipId, concernId,
         actorKind, actorRef, reason, eventAt, detail)
      SELECT toplineId, seq, kind, membershipId, concernId,
             actorKind, actorRef, reason, eventAt, detail
      FROM topline_events_legacy
      WHERE kind IN (
        'topline_created','topline_renamed','topline_closed','topline_reopened',
        'work_linked','work_unlinked','concern_created'
      )
      """
    )

    Txn.q(
      txn,
      """
      INSERT INTO topline_events
        (toplineId, seq, kind, membershipId, concernId,
         actorKind, actorRef, reason, eventAt, detail)
      SELECT e.toplineId, e.seq, 'concern_work_tagged', NULL, e.concernId,
             e.actorKind, e.actorRef, e.reason, e.eventAt,
             json_object('tagReason', r.linkReason, 'workItemId', m.workItemId)
      FROM topline_events_legacy e
      JOIN topline_concern_refs_legacy r ON r.id = e.concernReferenceId
      JOIN topline_work_memberships m ON m.id = r.membershipId
      WHERE e.kind = 'concern_work_linked' AND r.unlinkedAt IS NULL
        AND m.unlinkedAt IS NULL AND m.toplineId = r.toplineId
      """
    )

    Txn.q(
      txn,
      """
      INSERT INTO topline_idempotency
      SELECT callerUserId, operation, idempotencyKey, requestFingerprint, canonicalResponse
      FROM topline_idempotency_legacy
      WHERE operation NOT IN (
        'topline-concern-update','topline-concern-resolve','topline-concern-reopen',
        'topline-concern-link-work','topline-concern-unlink-work'
      )
      """
    )

    maybe_interrupt!(opts, :during_concern_migration)

    for table <-
          ~w(topline_events_legacy topline_concern_refs_legacy topline_concerns_legacy topline_idempotency_legacy) do
      :ok = Txn.exec(txn, "DROP TABLE #{table}")
    end

    verify_manifest!(txn)
    :ok
  end

  defp object_exists?(txn, name) do
    Txn.q(txn, "SELECT 1 FROM sqlite_schema WHERE name = ?1", [name]) == [[1]]
  end

  defp stored_objects(txn) do
    names = Enum.map(@objects, & &1.name)
    placeholders = names |> Enum.with_index(1) |> Enum.map_join(",", fn {_name, i} -> "?#{i}" end)

    txn
    |> Txn.q(
      "SELECT type, name, sql FROM sqlite_schema WHERE name IN (#{placeholders}) ORDER BY name",
      names
    )
    |> Map.new(fn [type, name, sql] -> {name, %{type: type, sql: sql}} end)
  end

  defp exact_manifest?(stored) do
    Enum.all?(@objects, fn object ->
      Map.get(stored, object.name) == %{type: object.type, sql: object.sql}
    end)
  end

  defp verify_manifest!(txn) do
    unless exact_manifest?(stored_objects(txn)) do
      raise "Toplines schema manifest did not round-trip through sqlite_schema"
    end
  end

  defp maybe_interrupt!(opts, point) do
    if Keyword.get(opts, :interrupt_after) == point,
      do: raise("Toplines schema activation interrupted at #{inspect(point)}")
  end

  defp refusal(code), do: {:error, %{code: code, message: code}}
end
