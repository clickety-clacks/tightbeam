defmodule Tightbeam.Toplines.Schema do
  @moduledoc "The closed Standalone Toplines V5 schema manifest and activation rail."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @shape "standalone-toplines-v5"

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
        activate_with_stamp(txn, stored)
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

  defp activate_with_stamp(txn, stored) do
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
          if exact_manifest?(stored), do: :ok, else: refusal("schema_shape_mismatch")
        end

      _invalid ->
        refusal("schema_shape_mismatch")
    end
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
