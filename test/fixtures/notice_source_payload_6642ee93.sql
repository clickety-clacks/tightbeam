-- Frozen accepted predecessor objects, copied verbatim from
-- 6642ee9387627b7fac85da989039ffe42d425787:lib/tightbeam/notice_batcher.ex
-- No current-source DDL generation or shape inference.

CREATE TABLE IF NOT EXISTS notice_batching_lane_policies (
  recipientAddress TEXT NOT NULL,
  visibilityScope TEXT NOT NULL,
  enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
  policyRevision TEXT NOT NULL,
  policyRef TEXT NOT NULL CHECK (length(trim(policyRef)) > 0),
  selectedBy TEXT NOT NULL,
  cause TEXT NOT NULL CHECK (length(trim(cause)) > 0),
  selectedAt INTEGER NOT NULL CHECK (selectedAt >= 0),
  PRIMARY KEY (recipientAddress, visibilityScope),
  UNIQUE (policyRef)
);

CREATE TABLE IF NOT EXISTS notice_delivery_policies (
  policyRef TEXT PRIMARY KEY,
  sourceWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
  recipientAddress TEXT NOT NULL,
  sessionKey TEXT NOT NULL,
  targetRole TEXT,
  visibilityScope TEXT NOT NULL,
  policyRevision TEXT NOT NULL,
  deadlineAt INTEGER NOT NULL CHECK (deadlineAt >= 0),
  enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
  createdAt INTEGER NOT NULL CHECK (createdAt >= 0)
);

CREATE TABLE IF NOT EXISTS staged_message_dedupes (
  targetSessionKey TEXT NOT NULL,
  deviceId TEXT NOT NULL,
  clientMessageId TEXT NOT NULL,
  sourceWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
  payloadSha256 TEXT NOT NULL CHECK (length(payloadSha256)=64),
  createdAt INTEGER NOT NULL CHECK (createdAt >= 0),
  PRIMARY KEY (targetSessionKey, deviceId, clientMessageId)
);

CREATE TABLE IF NOT EXISTS notice_batch_source_attachments (
  sourceWakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  attachments TEXT NOT NULL CHECK (json_valid(attachments))
);

CREATE TABLE IF NOT EXISTS notice_batch_members (
  memberId TEXT PRIMARY KEY,
  batchId TEXT NOT NULL REFERENCES notice_batches(batchId),
  sourceWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
  policyRef TEXT NOT NULL REFERENCES notice_delivery_policies(policyRef),
  recipientAddress TEXT NOT NULL,
  visibilityScope TEXT NOT NULL,
  publicationSeq INTEGER NOT NULL CHECK (publicationSeq > 0),
  policyRevision TEXT NOT NULL,
  senderPrincipal TEXT NOT NULL,
  cause TEXT NOT NULL,
  class TEXT NOT NULL CHECK (class = 'fyi'),
  payload TEXT NOT NULL,
  renderedBytes INTEGER NOT NULL CHECK (renderedBytes > 0),
  state TEXT NOT NULL CHECK (state IN ('active','included','canceled')),
  addedAt INTEGER NOT NULL CHECK (addedAt >= 0),
  canceledAt INTEGER,
  cancellationRef TEXT,
  UNIQUE(sourceWakeId, recipientAddress, visibilityScope),
  UNIQUE(recipientAddress, visibilityScope, publicationSeq),
  CHECK (
    (state = 'canceled' AND canceledAt IS NOT NULL AND cancellationRef IS NOT NULL)
    OR
    (state != 'canceled' AND canceledAt IS NULL AND cancellationRef IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS notice_batch_members_batch
  ON notice_batch_members(batchId, publicationSeq);
