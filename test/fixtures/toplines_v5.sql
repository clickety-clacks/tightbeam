-- Immutable Toplines V5 manifest from public 9b8b2221.
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
);

CREATE UNIQUE INDEX toplines_id_owner ON toplines (id, ownerUserId);

CREATE UNIQUE INDEX work_items_id_owner ON work_items (id, ownerUserId);

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
);

CREATE UNIQUE INDEX topline_memberships_active_pair ON topline_work_memberships (toplineId, workItemId) WHERE unlinkedAt IS NULL;

CREATE UNIQUE INDEX topline_memberships_id_topline ON topline_work_memberships (id, toplineId);

CREATE INDEX topline_memberships_work_active ON topline_work_memberships (workItemId) WHERE unlinkedAt IS NULL;

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
);

CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId);

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
);

CREATE TRIGGER topline_concern_refs_active_membership_insert
BEFORE INSERT ON topline_concern_refs
WHEN NOT EXISTS (
  SELECT 1 FROM topline_work_memberships m
  WHERE m.toplineId = NEW.toplineId AND m.workItemId = NEW.workItemId
    AND m.unlinkedAt IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'concern tag requires active topline membership');
END;

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
);

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
);

CREATE UNIQUE INDEX causal_events_seq_job_ref ON causal_events (seq, jobRef);

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
);

CREATE UNIQUE INDEX topline_placements_one_pending ON topline_placement_obligations (workItemId) WHERE state = 'pending';

CREATE UNIQUE INDEX topline_placements_one_reopen ON topline_placement_obligations (workItemId, sourceCausalEventSeq) WHERE sourceCausalEventSeq IS NOT NULL;

CREATE UNIQUE INDEX topline_placements_one_terminal_resolution ON topline_placement_obligations (workItemId, resolutionCausalEventSeq) WHERE resolutionCausalEventSeq IS NOT NULL;

CREATE TABLE topline_schema_stamp (
  singleton INTEGER PRIMARY KEY CHECK (typeof(singleton) = 'integer' AND singleton = 1),
  shape      TEXT NOT NULL CHECK (typeof(shape) = 'text' AND length(trim(shape)) > 0),
  stampedAt  INTEGER NOT NULL CHECK (typeof(stampedAt) = 'integer' AND stampedAt >= 0)
);
INSERT INTO topline_schema_stamp VALUES(1,'standalone-toplines-v5',123);
