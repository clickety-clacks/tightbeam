CREATE TABLE admin_projection_versions (
  resource    TEXT NOT NULL,
  primaryKey  TEXT NOT NULL,
  rowVersion  INTEGER NOT NULL CHECK (rowVersion > 0),
  updatedAt   INTEGER NOT NULL,
  fingerprint TEXT,
  item        TEXT,
  PRIMARY KEY (resource, primaryKey)
);
CREATE TABLE artifacts (
  artifactId        TEXT PRIMARY KEY,
  kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
  title             TEXT NOT NULL,
  description       TEXT,
  createdBySession  TEXT NOT NULL REFERENCES sessions(sessionKey),
  workItemId        TEXT NOT NULL REFERENCES work_items(id),
  producedByAssignmentId TEXT NULL REFERENCES assignments(id),
  parentSession     TEXT REFERENCES sessions(sessionKey),
  originPath        TEXT NOT NULL,
  contentSha256     TEXT,
  recordedMessageId TEXT REFERENCES messages(id),
  recordedTurnEvidence TEXT NOT NULL DEFAULT 'none'
                    CHECK (recordedTurnEvidence IN
                           ('tool-call-observed','session-concurrent','none')),
  state             TEXT NOT NULL DEFAULT 'in-workspace'
                    CHECK (state IN ('in-workspace','archived','released')),
  home              TEXT,
  createdAt         INTEGER NOT NULL,
  updatedAt         INTEGER NOT NULL,
  CHECK ((state = 'archived') = (home IS NOT NULL))

);
CREATE TABLE assets (
  assetId     TEXT PRIMARY KEY,
  ownerUserId TEXT NOT NULL,
  mimeType    TEXT NOT NULL,
  size        INTEGER NOT NULL,
  filename    TEXT,
  createdAt   INTEGER NOT NULL
);
CREATE TABLE assignment_effects (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  effectKind TEXT NOT NULL CHECK(effectKind IN ('code', 'policy', 'release', 'live_mutation', 'evidence', 'review', 'coordination'))
);
CREATE TABLE assignment_files (
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  path TEXT NOT NULL,
  PRIMARY KEY (assignmentId, path)
);
CREATE TABLE assignment_interruptions (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  sessionKey   TEXT NOT NULL REFERENCES sessions(sessionKey),
  reason       TEXT NOT NULL CHECK(reason = 'interrupted-by-retire'),
  ts           INTEGER NOT NULL
);
CREATE TABLE assignment_priorities (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  priority INTEGER NOT NULL
);
CREATE TABLE assignment_prods (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  attemptCount INTEGER NOT NULL DEFAULT 0,
  prodCount INTEGER NOT NULL DEFAULT 0,
  deniedStreak INTEGER NOT NULL DEFAULT 0,
  attestCount INTEGER NOT NULL DEFAULT 0,
  lastProdAt INTEGER,
  stalledAt INTEGER,
  strandedAt INTEGER NULL
);
CREATE TABLE assignment_repair_attempts (
  id                 TEXT PRIMARY KEY,
  assignmentId       TEXT NOT NULL REFERENCES assignments(id),
  repairKey          TEXT NOT NULL,
  requestFingerprint TEXT NOT NULL CHECK(length(trim(requestFingerprint)) > 0),
  action             TEXT NOT NULL CHECK(action IN
                     ('tune','restart','rerun','resume','relaunch')),
  principal          TEXT NOT NULL CHECK(length(trim(principal)) > 0),
  state              TEXT NOT NULL CHECK(state IN ('claimed','succeeded','failed')),
  resultJson         TEXT,
  createdAt          INTEGER NOT NULL CHECK(createdAt >= 0),
  completedAt        INTEGER,
  UNIQUE (assignmentId, repairKey),
  CHECK(
    (state = 'claimed' AND resultJson IS NULL AND completedAt IS NULL)
    OR
    (state IN ('succeeded','failed') AND resultJson IS NOT NULL AND completedAt >= createdAt)
  )
);
CREATE TABLE assignments (
  id TEXT PRIMARY KEY,
  subject TEXT NOT NULL CHECK(length(subject) BETWEEN 1 AND 2000 AND length(trim(subject)) >= 1),
  holderKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  holderRole TEXT NULL,
  holderFallback INTEGER NOT NULL DEFAULT 0 CHECK(holderFallback IN (0, 1)),
  openedByUser TEXT NULL,
  openedBySession TEXT NULL,
  openedAt INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open', 'closed')),
  outcome TEXT NULL CHECK(outcome IN ('completed', 'surrendered', 'revoked')),
  closedAt INTEGER NULL,
  closedByUser TEXT NULL,
  closedBySession TEXT NULL,
  closingAttestId TEXT NULL REFERENCES attests(id),
  workItemId TEXT NULL REFERENCES work_items(id),
  reviewsAssignmentId TEXT NULL REFERENCES assignments(id),
  holderHarness TEXT NULL,
  holderProvider TEXT NULL,
  CHECK(holderRole IS NOT NULL OR holderFallback = 0),
  CHECK((openedByUser IS NOT NULL) != (openedBySession IS NOT NULL)),
  CHECK(
    (state = 'open' AND outcome IS NULL AND closedAt IS NULL AND
     closedByUser IS NULL AND closedBySession IS NULL AND closingAttestId IS NULL)
    OR
    (state = 'closed' AND outcome IS NOT NULL AND closedAt IS NOT NULL AND
     ((closedByUser IS NOT NULL) != (closedBySession IS NOT NULL)))
  ),
  CHECK(outcome NOT IN ('completed', 'surrendered') OR closingAttestId IS NOT NULL),
  CHECK(outcome != 'revoked' OR closingAttestId IS NULL)
);
CREATE TABLE attests (
  id TEXT PRIMARY KEY,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
  verdictKind TEXT NULL,
  note TEXT NULL CHECK(note IS NULL OR length(trim(note)) BETWEEN 1 AND 2000),
  bySession TEXT NULL REFERENCES sessions(sessionKey),
  byUser TEXT NULL REFERENCES users(userId),
  producer TEXT NULL,
  producerCommand TEXT NULL,
  byHarness TEXT NULL,
  byProvider TEXT NULL,
  commitRefs TEXT NULL,
  artifactId TEXT NULL REFERENCES artifacts(artifactId),
  contentSha256 TEXT NULL,
  waitId TEXT NULL REFERENCES wakes(wakeId),
  ts INTEGER NOT NULL,
  CHECK(
    (kind IN ('progress', 'completion', 'surrender') AND bySession IS NOT NULL AND
     byUser IS NULL AND verdictKind IS NULL)
    OR
    (kind = 'verdict' AND verdictKind IS NOT NULL AND
     ((bySession IS NOT NULL) != (byUser IS NOT NULL)))
  ),
  CHECK(producer IS NULL OR kind = 'verdict'),
  CHECK(producerCommand IS NULL OR producer IS NOT NULL),
  CHECK(byHarness IS NULL OR kind = 'verdict'),
  CHECK(byProvider IS NULL OR kind = 'verdict'),
  CHECK((artifactId IS NULL) = (contentSha256 IS NULL)),
  CHECK(artifactId IS NULL OR kind = 'verdict')
);
CREATE TABLE boot_epochs (
  epoch           INTEGER PRIMARY KEY AUTOINCREMENT,
  bootedAt        INTEGER NOT NULL,
  cleanShutdownAt INTEGER
);
CREATE TABLE causal_events (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  at           INTEGER NOT NULL,
  jobRef       TEXT,
  assignmentId TEXT,
  sessionKey   TEXT,
  kind         TEXT NOT NULL CHECK (kind IN
    ('effort_rung_advance','prod_fired','prod_answered',
     'disposition_transition')),
  detail       TEXT NOT NULL
);
CREATE TABLE causal_events_epoch (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  at INTEGER NOT NULL
);
CREATE TABLE command_executions (
  executionId          TEXT PRIMARY KEY,
  idempotencyKey       TEXT NOT NULL UNIQUE,
  holderSessionKey     TEXT NOT NULL,
  assignmentId         TEXT NOT NULL,
  turnIntent           TEXT NOT NULL,
  turnSeq              INTEGER,
  host                 TEXT NOT NULL,
  cwd                  TEXT NOT NULL,
  commandJson          TEXT NOT NULL,
  commandSha256        TEXT NOT NULL,
  cause                TEXT NOT NULL,
  principal            TEXT NOT NULL,
  preparedPath         TEXT NOT NULL,
  claimPath            TEXT NOT NULL,
  launcherIdentityPath TEXT NOT NULL,
  startedPath          TEXT NOT NULL,
  stdoutPath           TEXT NOT NULL,
  stderrPath           TEXT NOT NULL,
  notStartedPath       TEXT NOT NULL,
  terminalPath         TEXT NOT NULL,
  state                TEXT NOT NULL CHECK (state IN
                       ('prepared','not_started','started','finished','started_unknown')),
  osPid                INTEGER,
  processGroupId       INTEGER,
  preparedAt           INTEGER NOT NULL,
  startedAt            INTEGER,
  finishedAt           INTEGER,
  exitCode             INTEGER,
  signal               INTEGER,
  stdoutBytes          INTEGER,
  stdoutSha256         TEXT,
  stderrBytes          INTEGER,
  stderrSha256         TEXT,
  lastError            TEXT
);
CREATE TABLE condition_facts (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  ts     INTEGER NOT NULL,
  kind   TEXT    NOT NULL,
  scope  TEXT,
  origin TEXT    NOT NULL,
  ownerUserId TEXT NULL
);
CREATE TABLE critical_leases (
  sessionKey   TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
  reason       TEXT NOT NULL,
  startedAt    INTEGER NOT NULL,
  expiresAt    INTEGER NOT NULL,
  hardDeadline INTEGER NOT NULL,
  updatedAt    INTEGER NOT NULL
);
CREATE TABLE decision_request_integrity_evidence (
  requestId TEXT NOT NULL,
  shapeDigest TEXT NOT NULL,
  schemaVersion TEXT NOT NULL,
  causeCode TEXT NOT NULL,
  failingFields TEXT NOT NULL,
  firstSurface TEXT NOT NULL CHECK (firstSurface IN ('list','detail','consume','migration-preflight')),
  firstObservedAt INTEGER NOT NULL,
  observerPrincipal TEXT NOT NULL,
  PRIMARY KEY (requestId, shapeDigest)
);
CREATE TABLE decision_request_terminal_epoch (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  schemaVersion TEXT NOT NULL,
  legacyRulingFactMaxId INTEGER NOT NULL,
  activatedAt INTEGER NOT NULL,
  cause TEXT NOT NULL,
  principal TEXT NOT NULL
);
CREATE TABLE decision_requests (
  id                TEXT PRIMARY KEY,
  kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','operator')),
  raiserId          TEXT NOT NULL,
  raiserSessionKey  TEXT,
  ownerUserId       TEXT NOT NULL,
  assignmentId      TEXT,
  expecterSessionKey TEXT,
  expecterUserId    TEXT,
  lineageRung       INTEGER,
  effortGeneration  INTEGER,
  deadlineWakeId    TEXT,
  raisedAt          INTEGER NOT NULL,
  deadlineAt        INTEGER NOT NULL,
  statuteName       TEXT,
  actionKey         TEXT,
  question          TEXT NOT NULL,
  options           TEXT,
  context           TEXT NOT NULL,
  status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded')),
  decision          TEXT,
  rationale         TEXT,
  ruledBy           TEXT,
  ruledViaPrincipal TEXT,
  ruledViaSessionKey TEXT,
  ruledViaSessionState TEXT CHECK (ruledViaSessionState IS NULL OR ruledViaSessionState IN ('known','none')),
  ruledAt           INTEGER,
  rulingFactId      INTEGER,
  consumedAt        INTEGER,
  parkWakeId        TEXT,
  withdrawnBy       TEXT,
  withdrawnReason   TEXT,
  withdrawnAt       INTEGER,
  CHECK (
    (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
     AND expecterSessionKey IS NULL AND expecterUserId IS NULL
     AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
     AND ruledViaSessionKey IS NULL
     AND (decision IS NULL OR decision IN ('allow','deny','waived')))
    OR
    (kind = 'effort' AND raiserId = 'process:tightbeam'
     AND raiserSessionKey IS NULL
     AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
     AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
     AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
     AND ruledViaSessionKey IS NULL
     AND (decision IS NULL OR decision IN ('continue','dismiss')))
    OR
    (kind = 'operator'
     AND raiserSessionKey IS NOT NULL
     AND statuteName IS NULL AND actionKey IS NOT NULL
     AND expecterSessionKey IS NULL AND expecterUserId IS NULL
     AND lineageRung IS NULL AND effortGeneration IS NULL
     AND deadlineWakeId IS NULL
     AND options IS NOT NULL
     AND parkWakeId IS NULL AND consumedAt IS NULL
     AND status <> 'consumed'
     AND (
       (status = 'ruled'
        AND decision IS NOT NULL
        AND ruledBy = 'user:' || ownerUserId
        AND ruledAt IS NOT NULL AND rulingFactId IS NOT NULL)
       OR
       (status <> 'ruled'
        AND decision IS NULL AND rationale IS NULL
        AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
        AND ruledViaSessionKey IS NULL)
     ))
  )
);
CREATE TABLE devices (
  deviceId    TEXT PRIMARY KEY,
  userId      TEXT NOT NULL REFERENCES users(userId),
  claimedName TEXT NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('allowlisted','pending','denied')),
  token       TEXT UNIQUE,
  platform    TEXT,
  model       TEXT,
  createdAt   INTEGER NOT NULL
);
CREATE TABLE effort_checkin_generations (
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  generation INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('armed','probed','canceled')),
  baseHorizonMs INTEGER NOT NULL,
  multiplier INTEGER NOT NULL CHECK (multiplier IN (1,2,4)),
  armedAt INTEGER NOT NULL,
  terminalSeqWatermark INTEGER NOT NULL,
  holderKey TEXT NOT NULL,
  host TEXT NOT NULL,
  root TEXT NOT NULL,
  baseline TEXT NOT NULL,
  wakeId TEXT NOT NULL,
  evidence TEXT,
  agentProdded INTEGER NOT NULL DEFAULT 0,
  artifactWatermark INTEGER NOT NULL DEFAULT 0,
  attestWatermark INTEGER NOT NULL DEFAULT 0,
  workItemWatermark INTEGER NOT NULL DEFAULT 0,
  reliefStartedAt INTEGER,
  reliefExcludedMs INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (assignmentId, generation)
);
CREATE TABLE escalation_waivers (
  id                TEXT PRIMARY KEY,
  raiserId          TEXT NOT NULL,
  statuteName       TEXT NOT NULL,
  grantedBy         TEXT NOT NULL,
  grantedAt         INTEGER NOT NULL,
  reason            TEXT,
  revokedBy         TEXT,
  revokedAt         INTEGER
);
CREATE TABLE events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         INTEGER NOT NULL,
  kind       TEXT    NOT NULL CHECK (kind IN ('verb','denied')),
  verb       TEXT    NOT NULL,
  origin     TEXT    NOT NULL,
  principal  TEXT,
  sessionKey TEXT,
  payload    TEXT    NOT NULL DEFAULT 'null'
);
CREATE TABLE harness_env_overlays (
  host    TEXT NOT NULL,
  harness TEXT NOT NULL,
  name    TEXT NOT NULL,
  value   TEXT NOT NULL,
  setBy   TEXT NOT NULL,
  setAt   INTEGER NOT NULL,
  PRIMARY KEY (host, harness, name)
);
CREATE TABLE harness_health_assignments (
  incidentId   TEXT NOT NULL,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  sessionKey   TEXT NOT NULL REFERENCES sessions(sessionKey),
  PRIMARY KEY (incidentId, assignmentId),
  FOREIGN KEY (incidentId, sessionKey)
    REFERENCES harness_health_members(incidentId, sessionKey)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE harness_health_incidents (
  id                      TEXT PRIMARY KEY,
  harness                 TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  host                    TEXT NOT NULL CHECK(length(trim(host)) > 0),
  failureClass            TEXT NOT NULL CHECK(failureClass IN (
                            'auth-dead','rate-limit-dead','adapter_unavailable',
                            'model_unavailable','task_crash','interrupted-outcome-unknown'
                          )),
  state                   TEXT NOT NULL CHECK(state IN ('open','resolved')),
  openedAt                INTEGER NOT NULL CHECK(openedAt >= 0),
  openObservationId       TEXT NOT NULL REFERENCES harness_health_observations(id)
                            DEFERRABLE INITIALLY DEFERRED,
  openedFactId            INTEGER NOT NULL REFERENCES condition_facts(id),
  resolvedAt              INTEGER,
  resolutionObservationId TEXT REFERENCES harness_health_observations(id)
                            DEFERRABLE INITIALLY DEFERRED,
  resolvedFactId          INTEGER REFERENCES condition_facts(id),
  CHECK(
    (state = 'open' AND resolvedAt IS NULL AND resolutionObservationId IS NULL AND
     resolvedFactId IS NULL)
    OR
    (state = 'resolved' AND resolvedAt >= openedAt AND
     resolutionObservationId IS NOT NULL AND resolvedFactId IS NOT NULL)
  )
);
CREATE TABLE harness_health_members (
  incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  PRIMARY KEY (incidentId, sessionKey)
);
CREATE TABLE harness_health_observations (
  id            TEXT PRIMARY KEY,
  correlationId TEXT NOT NULL UNIQUE,
  harness       TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  host          TEXT NOT NULL CHECK(length(trim(host)) > 0),
  failureClass  TEXT NOT NULL CHECK(failureClass IN (
                  'auth-dead','rate-limit-dead','adapter_unavailable','model_unavailable',
                  'task_crash','interrupted-outcome-unknown'
                )),
  evidenceKind  TEXT NOT NULL CHECK(evidenceKind IN (
                  'authoritative-provider','terminal-failure','normal-turn-success'
                )),
  sessionKey    TEXT REFERENCES sessions(sessionKey),
  assignmentId TEXT REFERENCES assignments(id),
  observedAt    INTEGER NOT NULL CHECK(observedAt >= 0),
  cause         TEXT NOT NULL CHECK(length(trim(cause)) > 0),
  principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
  incidentId    TEXT REFERENCES harness_health_incidents(id)
                  DEFERRABLE INITIALLY DEFERRED,
  CHECK(evidenceKind != 'terminal-failure' OR sessionKey IS NOT NULL),
  CHECK(evidenceKind != 'normal-turn-success' OR incidentId IS NOT NULL),
  CHECK(assignmentId IS NULL OR sessionKey IS NOT NULL)
);
CREATE TABLE harness_park_fences (
  adapterKey       TEXT PRIMARY KEY,
  requestedAt      INTEGER NOT NULL
);
CREATE TABLE harness_pointers (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  sessionKey       TEXT NOT NULL REFERENCES sessions(sessionKey),
  harnessSessionId TEXT NOT NULL,
  sourceSessionRef TEXT NOT NULL,
  harness          TEXT NOT NULL,
  machine          TEXT NOT NULL,
  reason           TEXT NOT NULL CHECK (reason IN ('created','loaded','fallback')),
  createdAt        INTEGER NOT NULL
);
CREATE TABLE harness_processes (
  launchId        TEXT PRIMARY KEY,
  adapterKey      TEXT NOT NULL,
  harness         TEXT NOT NULL,
  preset          TEXT NOT NULL,
  host             TEXT NOT NULL,
  ssh              TEXT,
  helperPath       TEXT NOT NULL,
  identityPath     TEXT NOT NULL,
  launchSequence   INTEGER NOT NULL,
  osPid            INTEGER,
  processGroupId   INTEGER,
  bootIdentity     TEXT,
  identityToken    TEXT,
  state            TEXT NOT NULL CHECK (state IN
                   ('launching','running','park_requested','closed_gracefully',
                    'killed','kill_failed','exited')),
  createdAt        INTEGER NOT NULL,
  parkRequestedAt  INTEGER,
  killAttemptedAt  INTEGER,
  killSentAt       INTEGER,
  resolvedAt       INTEGER,
  lastError        TEXT
);
CREATE TABLE host_toolchain_dirs (
  host     TEXT NOT NULL,
  position INTEGER NOT NULL CHECK (position >= 0),
  dir      TEXT NOT NULL,
  setBy    TEXT NOT NULL,
  setAt    INTEGER NOT NULL,
  PRIMARY KEY (host, position)
);
CREATE TABLE hosts (
  name          TEXT PRIMARY KEY,
  ssh           TEXT,
  baseDir       TEXT NOT NULL,
  cliBin        TEXT,
  adapterBinDir TEXT
);
CREATE TABLE identity_publication_markers (
  invocationId      TEXT NOT NULL,
  expectedPriorLive TEXT NOT NULL,
  candidateRevision TEXT,
  treeFingerprint   TEXT NOT NULL,
  principal         TEXT NOT NULL,
  validationResult  TEXT NOT NULL CHECK (validationResult IN ('accepted', 'denied')),
  cause             TEXT,
  denialCode        TEXT,
  denialMessage     TEXT,
  denialExpected    TEXT,
  denialActual      TEXT,
  state             TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'denied')),
  createdAt         INTEGER NOT NULL,
  updatedAt         INTEGER NOT NULL,
  PRIMARY KEY (invocationId, expectedPriorLive)
);
CREATE TABLE lifecycle_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      INTEGER NOT NULL,
  kind    TEXT    NOT NULL,
  subject TEXT    NOT NULL,
  detail  TEXT
);
CREATE TABLE messages (
  seq                    INTEGER PRIMARY KEY AUTOINCREMENT,
  id                     TEXT NOT NULL UNIQUE,
  sessionKey             TEXT NOT NULL,
  role                   TEXT NOT NULL CHECK (role IN ('user','assistant')),
  content                TEXT NOT NULL,
  timestamp              INTEGER NOT NULL,
  sender                 TEXT,
  deviceId               TEXT,
  clientMessageId        TEXT,
  replyToMessageId       TEXT,
  replyToClientMessageId TEXT,
  llmVisibleMessageId    TEXT NOT NULL,
  attachments            TEXT NOT NULL DEFAULT '[]',
  attentionTier          INTEGER NOT NULL DEFAULT 0,
  messageType            TEXT,
  markerKind             TEXT CHECK (
    markerKind IS NULL OR markerKind IN ('harness-switch','model-retune','session-restart')
  ),
  markerFrom             TEXT,
  markerTo               TEXT,
  CHECK (
    (messageType IS 'marker' AND markerKind IS NOT NULL AND markerFrom IS NOT NULL AND markerTo IS NOT NULL)
    OR
    (messageType IS NOT 'marker' AND markerKind IS NULL AND markerFrom IS NULL AND markerTo IS NULL)
  )
);
CREATE TABLE notice_batch_members (
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
CREATE TABLE notice_batches (
  batchId TEXT PRIMARY KEY,
  recipientAddress TEXT NOT NULL,
  sessionKey TEXT NOT NULL,
  targetRole TEXT,
  visibilityScope TEXT NOT NULL,
  policyRevision TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN (
    'open','sealed','delivery_pending','delivered','delivery_failed','canceled'
  )),
  dueAt INTEGER NOT NULL CHECK (dueAt >= 0),
  openedAt INTEGER NOT NULL CHECK (openedAt >= 0),
  sealedAt INTEGER,
  releaseCause TEXT,
  deliveryToken TEXT UNIQUE,
  envelope TEXT,
  envelopeSha256 TEXT,
  deliveryWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
  deliveredAt INTEGER,
  terminalCause TEXT,
  terminalPrincipal TEXT,
  retryCount INTEGER NOT NULL DEFAULT 0 CHECK (retryCount >= 0),
  overflowCount INTEGER NOT NULL DEFAULT 0 CHECK (overflowCount >= 0),
  memberCount INTEGER NOT NULL DEFAULT 0 CHECK (memberCount >= 0),
  renderedBytes INTEGER NOT NULL DEFAULT 0 CHECK (renderedBytes >= 0),
  lastAttemptAt INTEGER,
  lastFailure TEXT,
  CHECK (
    (state = 'open' AND sealedAt IS NULL AND deliveryToken IS NULL AND envelope IS NULL)
    OR
    (state IN ('sealed','delivery_pending','delivered','delivery_failed') AND
     sealedAt IS NOT NULL AND deliveryToken IS NOT NULL AND envelope IS NOT NULL)
    OR
    state = 'canceled'
  )
);
CREATE TABLE notice_batching_lane_policies (
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
CREATE TABLE notice_delivery_policies (
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
CREATE TABLE org_settings (
  key       TEXT PRIMARY KEY,
  value     TEXT NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE TABLE patrol_failure_boundary (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  firstTurnSeq INTEGER NOT NULL CHECK (firstTurnSeq > 0),
  activatedAt INTEGER NOT NULL,
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
CREATE TABLE patrol_failure_escalations (
  id TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  firstTurnSeq INTEGER NOT NULL REFERENCES turns(seq),
  thresholdTurnSeq INTEGER NOT NULL UNIQUE REFERENCES turns(seq),
  ownerUserId TEXT NOT NULL,
  failureClass TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','admitted','resolved','owner_alerted','record_only')),
  firstRecipient TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  cause TEXT NOT NULL CHECK (cause = 'consecutive_turn_failures'),
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam'),
  UNIQUE (sessionKey, generation)
);
CREATE TABLE patrol_failure_streaks (
  sessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
  generation INTEGER NOT NULL CHECK (generation > 0),
  failureCount INTEGER NOT NULL CHECK (failureCount >= 0),
  firstTurnSeq INTEGER REFERENCES turns(seq),
  latestTurnSeq INTEGER REFERENCES turns(seq),
  latestAt INTEGER,
  thresholdState TEXT NOT NULL CHECK (thresholdState IN ('active','escalated')),
  escalationId TEXT UNIQUE,
  ownerUserId TEXT NOT NULL,
  cause TEXT NOT NULL,
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam'),
  CHECK ((failureCount = 0) = (firstTurnSeq IS NULL)),
  CHECK ((thresholdState = 'escalated') = (escalationId IS NOT NULL))
);
CREATE TABLE patrol_terminal_classifications (
  turnSeq INTEGER PRIMARY KEY REFERENCES turns(seq),
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  classification TEXT NOT NULL CHECK (classification IN (
    'delivered','canceled','turn_failed',
    'bubble_notice_delivered','bubble_notice_ignored'
  )),
  failureClass TEXT,
  streakGeneration INTEGER,
  streakCount INTEGER,
  classifiedAt INTEGER NOT NULL,
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
CREATE TABLE production_cursors (
  name TEXT PRIMARY KEY,
  seq  INTEGER NOT NULL
);
CREATE TABLE rail_remedy_episodes (
  statute TEXT NOT NULL,
  subject TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('claimed','dispatched','live','closed')),
  producerKey TEXT,
  occurrence INTEGER NOT NULL,
  rewakeCount INTEGER NOT NULL,
  claimToken TEXT NOT NULL,
  openedAt INTEGER NOT NULL,
  closedAt INTEGER, noticeState TEXT NULL,
  PRIMARY KEY (statute, subject)
);
CREATE TABLE read_states (
  userId            TEXT NOT NULL,
  sessionKey        TEXT NOT NULL,
  lastReadMessageId TEXT NOT NULL,
  PRIMARY KEY (userId, sessionKey)
);
CREATE TABLE recurrence_suppression_deliveries (
  statute TEXT NOT NULL,
  subject TEXT NOT NULL,
  receiptId TEXT NOT NULL,
  dispatchKey TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','delivered')),
  targetSession TEXT,
  fingerprintDigest TEXT,
  PRIMARY KEY (statute, subject, receiptId),
  UNIQUE (dispatchKey)
);
CREATE TABLE recurrence_suppression_episodes (
  statute TEXT NOT NULL,
  targetSession TEXT NOT NULL,
  subject TEXT NOT NULL,
  fingerprintDigest TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  suppressedCount INTEGER NOT NULL DEFAULT 0 CHECK (suppressedCount >= 0),
  openedEvidenceSequence INTEGER NOT NULL,
  openedOccurrenceSequence INTEGER NOT NULL,
  recoveryClearedSequence INTEGER,
  recoveredSequence INTEGER,
  recoveredOccurrenceSequence INTEGER,
  recurrenceBaselineSequence INTEGER,
  escalated INTEGER NOT NULL DEFAULT 0 CHECK (escalated IN (0, 1)),
  PRIMARY KEY (statute, targetSession, subject, fingerprintDigest)
);
CREATE TABLE recurrence_suppression_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  outcome TEXT NOT NULL,
  statute TEXT NOT NULL,
  targetSession TEXT,
  subject TEXT NOT NULL,
  fingerprintDigest TEXT,
  generation INTEGER NOT NULL,
  receiptId TEXT,
  suppressedCount INTEGER NOT NULL,
  cause TEXT NOT NULL,
  principal TEXT NOT NULL,
  recoverySequence INTEGER,
  recurrenceSequence INTEGER
);
CREATE TABLE recurrence_suppression_fact_observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  statute TEXT NOT NULL,
  targetSession TEXT NOT NULL,
  subject TEXT NOT NULL,
  fingerprintDigest TEXT NOT NULL,
  generation INTEGER NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN ('recovered','recurred')),
  signature TEXT NOT NULL,
  matched INTEGER NOT NULL CHECK (matched IN (0,1))
);
CREATE TABLE recurrence_suppression_receipts (
  statute TEXT NOT NULL,
  targetSession TEXT NOT NULL,
  subject TEXT NOT NULL,
  fingerprintDigest TEXT NOT NULL,
  generation INTEGER NOT NULL,
  receiptId TEXT NOT NULL,
  outcome TEXT NOT NULL,
  PRIMARY KEY (statute, targetSession, subject, fingerprintDigest, receiptId)
);
CREATE TABLE roles (
  name            TEXT PRIMARY KEY,
  boundSessionKey TEXT,
  ownerUserId     TEXT NOT NULL,
  createdAt       INTEGER NOT NULL,
  updatedAt       INTEGER NOT NULL
);
CREATE TABLE scheduler_state (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  afterFact INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE schema_stamp (
  shape     TEXT PRIMARY KEY,
  stampedAt INTEGER NOT NULL
);
CREATE TABLE sessions (
  sessionKey    TEXT PRIMARY KEY,
  displayName   TEXT NOT NULL,
  kind          TEXT NOT NULL DEFAULT 'custom' CHECK (kind IN ('main','dm','custom')),
  orderIndex    INTEGER NOT NULL DEFAULT 0,
  isBuiltIn     INTEGER NOT NULL DEFAULT 0,
  adopted       INTEGER NOT NULL DEFAULT 0,
  ownerUserId   TEXT NOT NULL,
  origin        TEXT NOT NULL,
  spawnedBy     TEXT,
  handle        TEXT UNIQUE,
  archetype     TEXT NOT NULL,
  overrides     TEXT,
  identityName  TEXT,
  identityRevision TEXT,
  identityRenderContract TEXT,
  identityGuidanceDigest TEXT,
  cliToken      TEXT,
  harness       TEXT NOT NULL CHECK (harness IN ('claude','codex','fixture')),
  provider      TEXT NOT NULL CHECK (provider IN ('anthropic','openai','fixture_provider')),
  model         TEXT NOT NULL,
  thinkingLevel TEXT,
  modelContext  TEXT,
  host          TEXT NOT NULL DEFAULT 'local',
  clearedThroughSeq INTEGER NOT NULL DEFAULT 0,
  state         TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','retired')),
  createdAt     INTEGER NOT NULL,
  updatedAt     INTEGER NOT NULL
);
CREATE TABLE subagent_markers (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  kind           TEXT NOT NULL CHECK (kind IN ('subagent_start','subagent_stop')),
  principal      TEXT NOT NULL REFERENCES sessions(sessionKey),
  subagentRef    TEXT NOT NULL,
  sourceEventRef TEXT NOT NULL,
  harness        TEXT NOT NULL CHECK (harness IN ('claude','codex','fixture')),
  at             INTEGER NOT NULL,
  assignmentId   TEXT,
  UNIQUE (kind, sourceEventRef)
);
CREATE TABLE supervision_entitlements (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  dueAt INTEGER,
  state TEXT NOT NULL CHECK (state IN ('armed','claimed','terminus')),
  lastAttemptGeneration INTEGER,
  claimClock INTEGER,
  basisKind TEXT NOT NULL CHECK (basisKind IN (
    'assignment_open','prod_scheduled','escalation_scheduled','policy_denied',
    'progress','no_terminal','parent_retirement','recovery_backfill'
  )),
  basisId TEXT NOT NULL,
  terminusAt INTEGER,
  cause TEXT NOT NULL CHECK (cause IN (
    'assignment_open','progress','deadline','new_terminal','pending_turn','pending_wake',
    'work_blocked','prod_scheduled','escalation_scheduled','policy_denied','no_terminal',
    'terminal_disposition','holder_retired','parent_elevated','terminus',
    'parent_target_retired','recovery_backfill','stale_generation'
  )),
  principal TEXT NOT NULL,
  supervisionIntervalMs INTEGER,
  CHECK (
    (state = 'armed' AND dueAt >= 0 AND supervisionIntervalMs > 0 AND
     claimClock IS NULL AND terminusAt IS NULL)
    OR
    (state = 'claimed' AND dueAt >= 0 AND supervisionIntervalMs > 0 AND
     claimClock >= 0 AND terminusAt IS NULL)
    OR
    (state = 'terminus' AND dueAt IS NULL AND supervisionIntervalMs IS NULL AND
     claimClock IS NULL AND lastAttemptGeneration IS NULL AND terminusAt >= 0)
  ),
  CHECK (
    lastAttemptGeneration IS NULL OR
    (lastAttemptGeneration > 0 AND lastAttemptGeneration <= generation)
  )
);
CREATE TABLE supervision_liveness_checkpoint_bindings (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  holderSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  sourceTurnSeq INTEGER NOT NULL REFERENCES turns(seq),
  boundAt INTEGER NOT NULL CHECK (boundAt >= 0),
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
CREATE TABLE supervision_liveness_epoch (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  activatedAt INTEGER NOT NULL CHECK (activatedAt >= 0),
  cause TEXT NOT NULL CHECK (cause = 'schema_activation'),
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
CREATE TABLE supervision_liveness_migrations (
  migrationId TEXT PRIMARY KEY,
  appliedAt INTEGER NOT NULL,
  affectedRows INTEGER NOT NULL CHECK (affectedRows >= 0),
  cause TEXT NOT NULL,
  principal TEXT NOT NULL
);
CREATE TABLE supervision_liveness_receipt_state (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  artifactCursor INTEGER NOT NULL CHECK (artifactCursor >= 0),
  attestCursor INTEGER NOT NULL CHECK (attestCursor >= 0),
  workItemEventCursor INTEGER NOT NULL CHECK (workItemEventCursor >= 0),
  wakeCursor INTEGER NOT NULL CHECK (wakeCursor >= 0),
  baselineCause TEXT NOT NULL CHECK (baselineCause IN (
    'assignment_open','first_prod','recovery_backfill'
  )),
  baselinePrincipal TEXT NOT NULL
);
CREATE TABLE supervision_liveness_receipts (
  receiptId INTEGER PRIMARY KEY AUTOINCREMENT,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  sourceKind TEXT NOT NULL CHECK (sourceKind IN (
    'artifact','work_item_update','verdict','progress','checkpoint'
  )),
  sourceId TEXT NOT NULL,
  sourceAt INTEGER NOT NULL CHECK (sourceAt >= 0),
  acceptedAt INTEGER NOT NULL CHECK (acceptedAt >= 0),
  generation INTEGER NOT NULL CHECK (generation > 0),
  expiresAt INTEGER CHECK (expiresAt >= 0),
  UNIQUE (assignmentId, sourceKind, sourceId),
  CHECK (
    (sourceKind = 'checkpoint' AND expiresAt > acceptedAt)
    OR
    (sourceKind != 'checkpoint' AND expiresAt IS NULL)
  )
);
CREATE TABLE supervision_liveness_sidecar (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  controllerOrigin TEXT CHECK (controllerOrigin IN ('scheduled','retirement_elevation','holder_continuation')),
  wakeKind TEXT CHECK (wakeKind IN ('prod','escalation')),
  controllerState TEXT CHECK (controllerState IN ('pending','settled')),
  chargedGeneration INTEGER CHECK (chargedGeneration > 0),
  transferEvidenceId TEXT,
  retirementEpoch INTEGER CHECK (retirementEpoch >= 0),
  retiringSessionKey TEXT REFERENCES sessions(sessionKey),
  retirementOutcomeKind TEXT CHECK (
    retirementOutcomeKind IN ('child_rearm','parent_elevation','main_elevation')
  ),
  retirementOutcomeId TEXT,
  retirementTargetSessionKey TEXT REFERENCES sessions(sessionKey),
  retirementCause TEXT CHECK (
    retirementCause IN ('parent_target_retired','legacy_parent_target_retired')
  ),
  retirementPrincipal TEXT,
  retirementActionNeeded INTEGER CHECK (retirementActionNeeded IN (0,1)),
  CHECK (
    (controllerOrigin IS NULL AND wakeKind IS NULL AND controllerState IS NULL AND
     chargedGeneration IS NULL)
    OR
    (controllerOrigin = 'scheduled' AND wakeKind IN ('prod','escalation') AND
     controllerState IN ('pending','settled') AND chargedGeneration > 0)
    OR
    (controllerOrigin = 'retirement_elevation' AND wakeKind = 'escalation' AND
     controllerState = 'settled' AND chargedGeneration IS NULL)
    OR
    (controllerOrigin = 'holder_continuation' AND wakeKind IS NULL AND
     controllerState IN ('pending','settled') AND chargedGeneration IS NULL)
  ),
  CHECK (
    (transferEvidenceId IS NULL AND retirementEpoch IS NULL AND
     retiringSessionKey IS NULL AND retirementOutcomeKind IS NULL AND
     retirementOutcomeId IS NULL AND retirementTargetSessionKey IS NULL AND
     retirementCause IS NULL AND retirementPrincipal IS NULL AND
     retirementActionNeeded IS NULL)
    OR
    (transferEvidenceId IS NOT NULL AND retirementEpoch >= 0 AND
     retiringSessionKey IS NOT NULL AND retirementOutcomeKind IS NOT NULL AND
     retirementOutcomeId IS NOT NULL AND retirementCause IS NOT NULL AND
     retirementPrincipal IS NOT NULL AND retirementActionNeeded IN (0,1) AND
     ((retirementOutcomeKind = 'child_rearm' AND
       retirementTargetSessionKey IS NULL AND retirementActionNeeded = 0)
      OR
      (retirementOutcomeKind = 'parent_elevation' AND
       retirementTargetSessionKey IS NOT NULL AND retirementActionNeeded = 0)
      OR
      (retirementOutcomeKind = 'main_elevation' AND
       retirementTargetSessionKey IS NOT NULL AND retirementActionNeeded = 1)))
  ),
  CHECK (
    retirementCause IS NULL OR retirementCause = 'parent_target_retired' OR
    (retirementCause = 'legacy_parent_target_retired' AND
     retirementOutcomeKind = 'main_elevation' AND
     retirementPrincipal = 'process:tightbeam' AND retirementActionNeeded = 1)
  ),
  CHECK (controllerOrigin IS NOT NULL OR transferEvidenceId IS NOT NULL)
);
CREATE TABLE supervision_progress_absorptions (
  attestId TEXT PRIMARY KEY REFERENCES attests(id),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  attestTs INTEGER NOT NULL CHECK (attestTs >= 0),
  generation INTEGER NOT NULL CHECK (generation > 0),
  recoveryBaseline INTEGER NOT NULL CHECK (recoveryBaseline IN (0,1)),
  cause TEXT NOT NULL CHECK (cause IN ('progress','recovery_backfill')),
  principal TEXT NOT NULL,
  CHECK (
    (recoveryBaseline = 0 AND cause = 'progress') OR
    (recoveryBaseline = 1 AND cause = 'recovery_backfill' AND
     principal = 'process:tightbeam')
  )
);
CREATE TABLE supervision_watermarks (
  sessionKey TEXT NOT NULL,
  assignmentId TEXT NOT NULL DEFAULT '',
  lastEvaluatedTerminal INTEGER NOT NULL,
  pendingBranch TEXT CHECK (pendingBranch IN ('prod','escalation','terminus')),
  pendingAssignment TEXT,
  pendingK INTEGER NULL,
  pendingN INTEGER NULL,
  PRIMARY KEY (sessionKey, assignmentId)
);
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
CREATE TABLE topline_schema_stamp (
  singleton INTEGER PRIMARY KEY CHECK (typeof(singleton) = 'integer' AND singleton = 1),
  shape      TEXT NOT NULL CHECK (typeof(shape) = 'text' AND length(trim(shape)) > 0),
  stampedAt  INTEGER NOT NULL CHECK (typeof(stampedAt) = 'integer' AND stampedAt >= 0)
);
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
CREATE TABLE turn_repair_attempts (
  id            TEXT PRIMARY KEY,
  repairKey     TEXT NOT NULL,
  sourceSeq     INTEGER NOT NULL REFERENCES turns(seq),
  attemptSeq    INTEGER NOT NULL UNIQUE REFERENCES turns(seq),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
  createdAt     INTEGER NOT NULL CHECK(createdAt >= 0),
  UNIQUE (assignmentId, repairKey)
);
CREATE TABLE turns (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  sessionKey TEXT NOT NULL,
  messageId  TEXT NOT NULL,
  wakeId     TEXT UNIQUE,
  origin     TEXT NOT NULL,
  prompt     TEXT NOT NULL,
  roleRef    TEXT,
  roleFallback INTEGER NOT NULL DEFAULT 0,
  assignmentId TEXT,
  jobRef     TEXT,
  model      TEXT,
  thinkingLevel TEXT,
  modelContext  TEXT,
  harness    TEXT,
  replyAttention INTEGER NOT NULL DEFAULT 0,
  status     TEXT NOT NULL DEFAULT 'queued'
             CHECK (status IN ('queued','running','delivered','canceled',
                               'failed','failed_unknown')),
  owner      TEXT,
  adapterGen INTEGER,
  requestRef TEXT,
  error      TEXT,
  createdAt  INTEGER NOT NULL,
  startedAt  INTEGER,
  endedAt    INTEGER,
  publishedAt INTEGER
);
CREATE TABLE users (
  userId    TEXT PRIMARY KEY,
  isAdmin   INTEGER NOT NULL DEFAULT 0,
  createdAt INTEGER NOT NULL
);
CREATE TABLE wake_cancellations (
  wakeId TEXT PRIMARY KEY,
  wakeState TEXT NOT NULL DEFAULT 'canceled' CHECK (wakeState = 'canceled'),
  canceledAt INTEGER NOT NULL CHECK (canceledAt >= 0),
  requesterKind TEXT NOT NULL CHECK (requesterKind IN ('user','session','process')),
  requesterId TEXT NOT NULL,
  reasonKind TEXT NOT NULL CHECK (reasonKind IN (
    'requester_withdrew','superseded','obligation_disposed',
    'routing_bracket_satisfied','target_retired','production_unmatched',
    'consumer_unavailable','target_unresolvable'
  )),
  causalSourceKind TEXT NOT NULL CHECK (causalSourceKind IN (
    'verb_call','wake','progress_attest','condition_fact','assignment_transition',
    'work_item_transition','decision_request','monitor_generation','routing_bracket',
    'session_transition','scheduler_delivery'
  )),
  causalSourceId TEXT NOT NULL,
  outcomeKind TEXT NOT NULL CHECK (
    outcomeKind IN ('replacement','disposition','no_replacement')
  ),
  replacementWakeId TEXT REFERENCES wakes(wakeId) DEFERRABLE INITIALLY DEFERRED,
  dispositionKind TEXT CHECK (dispositionKind IN (
    'assignment_transition','work_item_transition',
    'decision_request_transition','monitor_generation_transition'
  )),
  dispositionId TEXT,
  primaryWorkKind TEXT CHECK (primaryWorkKind IN ('assignment','work_item')),
  primaryWorkId TEXT,
  workImpactKind TEXT NOT NULL CHECK (
    workImpactKind IN ('no_linked_work','linked_work_not_open','linked_work_open')
  ),
  livenessTriggerKind TEXT CHECK (livenessTriggerKind IN (
    'supervision_entitlement','supervision_transfer','pending_wake','routing_bracket'
  )),
  livenessTriggerId TEXT,
  actionNeeded INTEGER NOT NULL CHECK (actionNeeded IN (0,1)),
  FOREIGN KEY (wakeId, wakeState, canceledAt)
    REFERENCES wakes(wakeId, state, canceledAt) DEFERRABLE INITIALLY DEFERRED,
  CHECK (
    (workImpactKind = 'no_linked_work' AND primaryWorkKind IS NULL AND
     primaryWorkId IS NULL)
    OR
    (workImpactKind IN ('linked_work_not_open','linked_work_open') AND
     primaryWorkKind IS NOT NULL AND primaryWorkId IS NOT NULL)
  ),
  CHECK (
    (outcomeKind = 'replacement' AND replacementWakeId IS NOT NULL AND
     replacementWakeId != wakeId AND dispositionKind IS NULL AND dispositionId IS NULL AND
     livenessTriggerKind IS NULL AND livenessTriggerId IS NULL AND actionNeeded = 0 AND
     workImpactKind != 'linked_work_not_open')
    OR
    (outcomeKind = 'disposition' AND replacementWakeId IS NULL AND
     dispositionKind IS NOT NULL AND dispositionId IS NOT NULL AND
     ((workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NOT NULL AND
       livenessTriggerId IS NOT NULL AND actionNeeded = 1)
      OR
      (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
       livenessTriggerId IS NULL AND actionNeeded = 0 AND
       requesterKind = 'process' AND requesterId = 'tightbeam:effort-checkin' AND
       reasonKind = 'obligation_disposed' AND causalSourceKind = 'decision_request' AND
       dispositionKind = 'decision_request_transition' AND
       causalSourceId = dispositionId)
      OR
      (workImpactKind != 'linked_work_open' AND livenessTriggerKind IS NULL AND
       livenessTriggerId IS NULL AND actionNeeded = 0)))
    OR
    (outcomeKind = 'no_replacement' AND replacementWakeId IS NULL AND
     dispositionKind IS NULL AND dispositionId IS NULL AND
     ((workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NOT NULL AND
       livenessTriggerId IS NOT NULL AND actionNeeded = 1)
      OR
      (workImpactKind = 'linked_work_open' AND
       livenessTriggerKind IS NULL AND livenessTriggerId IS NULL AND actionNeeded = 0 AND
       requesterKind = 'process' AND requesterId = 'tightbeam:rail-remedy' AND
       reasonKind = 'superseded' AND causalSourceKind = 'wake')
 OR
      (workImpactKind != 'linked_work_open' AND livenessTriggerKind IS NULL AND
       livenessTriggerId IS NULL AND actionNeeded = 0)))
  ),
  CHECK (
    (reasonKind = 'requester_withdrew' AND causalSourceKind = 'verb_call' AND
     outcomeKind = 'no_replacement')
    OR
    (requesterKind = 'process' AND (
            (requesterId = 'tightbeam:rail-remedy' AND
       ((reasonKind = 'target_unresolvable' AND
         causalSourceKind = 'scheduler_delivery' AND outcomeKind = 'replacement')
        OR
        (reasonKind = 'superseded' AND
         causalSourceKind = 'wake' AND outcomeKind = 'no_replacement')))
      OR
(requesterId = 'tightbeam:wake-scheduler' AND
       ((reasonKind = 'production_unmatched' AND causalSourceKind = 'condition_fact' AND
         outcomeKind = 'no_replacement')
        OR
        (reasonKind IN ('consumer_unavailable','target_unresolvable') AND
         causalSourceKind = 'scheduler_delivery' AND outcomeKind = 'no_replacement')))
      OR
      (requesterId = 'tightbeam:work-items' AND
       reasonKind = 'routing_bracket_satisfied' AND
       causalSourceKind IN ('assignment_transition','work_item_transition','routing_bracket') AND
       outcomeKind IN ('replacement','disposition'))
      OR
      (requesterId = 'tightbeam:assignments' AND
       reasonKind = 'obligation_disposed' AND causalSourceKind = 'assignment_transition' AND
       outcomeKind = 'disposition')
      OR
      (requesterId = 'tightbeam:effort-checkin' AND
       ((reasonKind = 'superseded' AND
         causalSourceKind IN ('wake','monitor_generation','decision_request') AND
         outcomeKind = 'replacement')
        OR
        (reasonKind = 'obligation_disposed' AND
         causalSourceKind IN ('work_item_transition','decision_request','monitor_generation') AND
         outcomeKind = 'disposition')))
    OR
    (requesterId = 'tightbeam:supervision' AND reasonKind = 'superseded' AND
     causalSourceKind = 'progress_attest' AND outcomeKind = 'no_replacement')
    OR
    -- The batcher consumes exactly one member by naming the digest wake
    -- that replaces it. No other cancellation shape is admitted.
    (requesterId = 'tightbeam:batcher' AND reasonKind = 'superseded' AND
     causalSourceKind = 'wake' AND outcomeKind = 'replacement')
    OR
    (requesterId = 'tightbeam:retirement' AND
       ((reasonKind = 'target_retired' AND causalSourceKind = 'session_transition' AND
         outcomeKind IN ('replacement','no_replacement'))
        OR
        (reasonKind = 'obligation_disposed' AND
         causalSourceKind = 'assignment_transition' AND outcomeKind = 'disposition')))
    ))
  )
);
CREATE TABLE wake_retry_attempts (
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
CREATE TABLE wakes (
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
CREATE TABLE wire_idempotency (
  ownerUserId    TEXT NOT NULL,
  operation      TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake','assign','condition','work-item-create')),
  idempotencyKey TEXT NOT NULL,
  sessionKey     TEXT NOT NULL,
  PRIMARY KEY (ownerUserId, operation, idempotencyKey)
);
CREATE TABLE work_item_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  ts           INTEGER NOT NULL,
  workItemId   TEXT    NOT NULL REFERENCES work_items(id),
  kind         TEXT    NOT NULL,
  CHECK (kind IN ('metadata','composition'))
);
CREATE TABLE work_item_priorities (
  workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
  priority INTEGER NOT NULL
);
CREATE TABLE work_item_versions (
  workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
  rowVersion INTEGER NOT NULL CHECK(rowVersion > 0)
);
CREATE TABLE work_items (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 2000),
  specRefName TEXT NULL CHECK(specRefName IS NULL OR length(trim(specRefName)) BETWEEN 1 AND 2000),
  specRefSha256 TEXT NULL CHECK(specRefSha256 IS NULL OR (length(specRefSha256) = 64 AND specRefSha256 NOT GLOB '*[^0-9a-f]*')),
  isBug INTEGER NOT NULL DEFAULT 0 CHECK(isBug IN (0, 1)),
  ownerUserId TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','iceboxed','closed','failed')),
  failReason TEXT NULL,
  routingWakeId TEXT NULL,
  slateWakeId TEXT NULL,
  createdByUser TEXT NULL,
  createdBySession TEXT NULL,
  createdInTurnSeq INTEGER NULL,
  createdContextKnown INTEGER NOT NULL DEFAULT 0,
  createdAt INTEGER NOT NULL,
  CHECK((specRefName IS NULL) = (specRefSha256 IS NULL)),
  CHECK((createdByUser IS NOT NULL) != (createdBySession IS NOT NULL))
);
CREATE TABLE work_state_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  ts           INTEGER NOT NULL,
  assignmentId TEXT    NOT NULL REFERENCES assignments(id),
  fromState    TEXT,
  toState      TEXT    NOT NULL,
  CHECK (fromState IS NULL OR fromState IN
    ('open','active','stranded','claims-done','verified','abandoned')),
  CHECK (toState IN
    ('open','active','stranded','claims-done','verified','abandoned'))
);
INSERT INTO "causal_events_epoch" VALUES (0,1788887611415);
INSERT INTO "decision_request_terminal_epoch" VALUES (0,'terminal-operator-decision-parity-v1',0,1788887611508,'terminal-operator-decision-parity-v1','process:tightbeam');
INSERT INTO "scheduler_state" VALUES (0,0);
INSERT INTO "schema_stamp" VALUES ('row-driven-o2-v1-019',1788887611508);
INSERT INTO "supervision_liveness_epoch" VALUES (0,1788887611508,'schema_activation','process:tightbeam');
INSERT INTO "topline_schema_stamp" VALUES (1,'standalone-toplines-v5',1788887611504);
CREATE INDEX artifacts_created_by_session ON artifacts (createdBySession);
CREATE INDEX artifacts_producer ON artifacts (producedByAssignmentId);
CREATE INDEX artifacts_recorded_message ON artifacts (recordedMessageId);
CREATE INDEX artifacts_work_item ON artifacts (workItemId);
CREATE INDEX assignment_files_path ON assignment_files(path)
;
CREATE INDEX assignment_repair_history
  ON assignment_repair_attempts (assignmentId, createdAt, id);
CREATE INDEX causal_events_assignment
  ON causal_events (assignmentId, seq);
CREATE INDEX causal_events_job ON causal_events (jobRef, seq);
CREATE UNIQUE INDEX causal_events_seq_job_ref ON causal_events (seq, jobRef);
CREATE INDEX command_executions_assignment
  ON command_executions (assignmentId, preparedAt DESC);
CREATE INDEX command_executions_holder
  ON command_executions (holderSessionKey, preparedAt DESC);
CREATE INDEX condition_facts_match
  ON condition_facts (kind, scope, id);
CREATE INDEX condition_facts_owner_match
  ON condition_facts (ownerUserId, kind, scope, id);
CREATE UNIQUE INDEX decision_requests_effort_generation
  ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
CREATE INDEX decision_requests_key
  ON decision_requests (raiserId, statuteName, actionKey);
CREATE UNIQUE INDEX decision_requests_one_open
  ON decision_requests (raiserId, statuteName, actionKey)
  WHERE kind = 'statute' AND status = 'open';
CREATE UNIQUE INDEX decision_requests_operator_open
  ON decision_requests (ownerUserId, raiserId, actionKey)
  WHERE kind = 'operator' AND status = 'open';
CREATE INDEX decision_requests_owner
  ON decision_requests (ownerUserId, status);
CREATE TRIGGER decision_requests_terminal_insert_guard
BEFORE INSERT ON decision_requests
WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND
  (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
BEGIN
  SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
END;
CREATE TRIGGER decision_requests_terminal_update_guard
BEFORE UPDATE OF status ON decision_requests
WHEN OLD.kind = 'operator' AND OLD.status = 'open' AND NEW.status = 'ruled' AND
  (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
BEGIN
  SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
END;
CREATE INDEX effort_checkin_wake
  ON effort_checkin_generations (wakeId, state);
CREATE INDEX escalation_waivers_lookup
  ON escalation_waivers (raiserId, statuteName, revokedAt);
CREATE INDEX events_session ON events (sessionKey, id);
CREATE TRIGGER harness_health_assignment_holder
BEFORE INSERT ON harness_health_assignments
WHEN NOT EXISTS (
  SELECT 1 FROM assignments
  WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
)
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment must belong to its affected member');
END;
CREATE TRIGGER harness_health_assignment_immutable_delete
BEFORE DELETE ON harness_health_assignments
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment history is immutable');
END;
CREATE TRIGGER harness_health_assignment_immutable_update
BEFORE UPDATE ON harness_health_assignments
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment history is immutable');
END;
CREATE INDEX harness_health_assignment_session
  ON harness_health_assignments (sessionKey, incidentId);
CREATE INDEX harness_health_incident_history
  ON harness_health_incidents (harness, host, openedAt, id);
CREATE TRIGGER harness_health_incident_identity_immutable
BEFORE UPDATE OF id,harness,host,failureClass,openedAt,openObservationId,openedFactId
ON harness_health_incidents
BEGIN
  SELECT RAISE(ABORT, 'harness health incident identity is immutable');
END;
CREATE TRIGGER harness_health_incident_no_delete
BEFORE DELETE ON harness_health_incidents
BEGIN
  SELECT RAISE(ABORT, 'harness health incident history is immutable');
END;
CREATE TRIGGER harness_health_incident_resolution_once
BEFORE UPDATE OF state,resolvedAt,resolutionObservationId,resolvedFactId
ON harness_health_incidents
WHEN NOT (
  OLD.state = 'open' AND OLD.resolvedAt IS NULL AND
  OLD.resolutionObservationId IS NULL AND OLD.resolvedFactId IS NULL AND
  NEW.state = 'resolved' AND NEW.resolvedAt IS NOT NULL AND
  NEW.resolutionObservationId IS NOT NULL AND NEW.resolvedFactId IS NOT NULL AND
  EXISTS (
    SELECT 1 FROM harness_health_observations
    WHERE id = NEW.resolutionObservationId AND incidentId = OLD.id AND
          harness = OLD.harness AND host = OLD.host AND
          failureClass = OLD.failureClass AND evidenceKind = 'normal-turn-success'
  )
)
BEGIN
  SELECT RAISE(ABORT, 'harness health incident may resolve exactly once');
END;
CREATE TRIGGER harness_health_member_immutable_delete
BEFORE DELETE ON harness_health_members
BEGIN
  SELECT RAISE(ABORT, 'harness health membership history is immutable');
END;
CREATE TRIGGER harness_health_member_immutable_update
BEFORE UPDATE ON harness_health_members
BEGIN
  SELECT RAISE(ABORT, 'harness health membership history is immutable');
END;
CREATE INDEX harness_health_member_session
  ON harness_health_members (sessionKey, incidentId);
CREATE TRIGGER harness_health_observation_assignment_holder
BEFORE INSERT ON harness_health_observations
WHEN NEW.assignmentId IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM assignments
  WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
)
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment must belong to its affected session');
END;
CREATE TRIGGER harness_health_observation_attachment_once
BEFORE UPDATE OF incidentId ON harness_health_observations
WHEN OLD.incidentId IS NOT NULL OR NEW.incidentId IS NULL
BEGIN
  SELECT RAISE(ABORT, 'harness health observation attachment is immutable');
END;
CREATE TRIGGER harness_health_observation_identity_immutable
BEFORE UPDATE OF id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,
                 assignmentId,observedAt,cause,principal
ON harness_health_observations
BEGIN
  SELECT RAISE(ABORT, 'harness health observation identity is immutable');
END;
CREATE INDEX harness_health_observation_incident
  ON harness_health_observations (incidentId, observedAt, id);
CREATE TRIGGER harness_health_observation_no_delete
BEFORE DELETE ON harness_health_observations
BEGIN
  SELECT RAISE(ABORT, 'harness health observation history is immutable');
END;
CREATE INDEX harness_health_observation_window
  ON harness_health_observations
    (harness, host, failureClass, evidenceKind, observedAt, sessionKey);
CREATE UNIQUE INDEX harness_health_one_open_class
  ON harness_health_incidents (harness, host, failureClass) WHERE state = 'open';
CREATE TRIGGER harness_pointer_reverse_unique
BEFORE INSERT ON harness_pointers
WHEN EXISTS (
  SELECT 1 FROM harness_pointers
  WHERE sourceSessionRef = NEW.sourceSessionRef
    AND sessionKey != NEW.sessionKey
)
BEGIN
  SELECT RAISE(ABORT, 'harness source session already belongs to another parent');
END;
CREATE INDEX harness_processes_adapter_launch_sequence ON harness_processes (adapterKey, state, launchSequence);
CREATE UNIQUE INDEX messages_client_dedupe
  ON messages (sessionKey, deviceId, clientMessageId)
  WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
CREATE INDEX messages_session ON messages (sessionKey, seq);
CREATE INDEX notice_batch_members_batch
  ON notice_batch_members(batchId, publicationSeq);
CREATE UNIQUE INDEX notice_batches_one_open_lane
  ON notice_batches(recipientAddress, visibilityScope)
  WHERE state = 'open';
CREATE INDEX notice_batches_recovery
  ON notice_batches(state, dueAt, openedAt);
CREATE INDEX patrol_classifications_session
  ON patrol_terminal_classifications (sessionKey, turnSeq);
CREATE INDEX patrol_failure_escalations_pending
  ON patrol_failure_escalations (state, thresholdTurnSeq);
CREATE INDEX pointers_session ON harness_pointers (sessionKey, id);
CREATE INDEX pointers_source ON harness_pointers (sourceSessionRef, id);
CREATE UNIQUE INDEX sessions_cli_token ON sessions(cliToken);
CREATE INDEX sessions_owner ON sessions (ownerUserId, state);
CREATE UNIQUE INDEX subagent_markers_one_stop
  ON subagent_markers (subagentRef) WHERE kind = 'subagent_stop';
CREATE INDEX subagent_markers_principal
  ON subagent_markers (principal, id);
CREATE TRIGGER supervision_checkpoint_binding_insert_coherent
BEFORE INSERT ON supervision_liveness_checkpoint_bindings
WHEN NOT EXISTS (
  SELECT 1
  FROM wakes w
  JOIN assignments a ON a.id=NEW.assignmentId
  JOIN turns t ON t.seq=NEW.sourceTurnSeq
  JOIN supervision_entitlements e ON e.assignmentId=a.id
  WHERE w.wakeId=NEW.wakeId
    AND w.sessionKey=NEW.holderSessionKey
    AND w.creatorSessionKey=NEW.holderSessionKey
    AND w.consumer='prompt' AND w.state='pending'
    AND w.dueAt > w.createdAt
    AND a.holderKey=NEW.holderSessionKey AND a.state='open'
    AND t.sessionKey=NEW.holderSessionKey AND t.status='running'
    AND t.assignmentId=NEW.assignmentId
    AND e.state IN ('armed','claimed')
)
BEGIN
  SELECT RAISE(ABORT, 'supervision checkpoint binding requires a running held assignment');
END;
CREATE TRIGGER supervision_fired_lineage_sidecar_identity_immutable
BEFORE UPDATE OF wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
                 chargedGeneration
ON supervision_liveness_sidecar
WHEN EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
    AND w.state = 'fired' AND w.consumer = 'prompt'
    AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
)
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage sidecar identity is immutable');
END;
CREATE TRIGGER supervision_fired_lineage_sidecar_required_delete
BEFORE DELETE ON supervision_liveness_sidecar
WHEN EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
    AND w.state = 'fired' AND w.consumer = 'prompt'
    AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
)
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage sidecar is required');
END;
CREATE TRIGGER supervision_fired_lineage_turn_immutable_delete
BEFORE DELETE ON turns
WHEN EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
    AND w.state = 'fired' AND w.consumer = 'prompt'
    AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
)
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage turn is required');
END;
CREATE TRIGGER supervision_fired_lineage_turn_immutable_update
BEFORE UPDATE OF seq, sessionKey, wakeId, assignmentId ON turns
WHEN EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
    AND w.state = 'fired' AND w.consumer = 'prompt'
    AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
)
  AND (
    NEW.seq IS NOT OLD.seq OR NEW.sessionKey IS NOT OLD.sessionKey
    OR NEW.wakeId IS NOT OLD.wakeId OR NEW.assignmentId IS NOT OLD.assignmentId
  )
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage turn attribution is immutable');
END;
CREATE TRIGGER supervision_lineage_fire_requires_sidecar
BEFORE UPDATE OF state ON wakes
WHEN OLD.state = 'pending' AND NEW.state = 'fired'
  AND NEW.consumer = 'prompt'
  AND NEW.origin = 'process:tightbeam'
  AND NEW.assignmentId IS NOT NULL
  AND NEW.reresolve = 'lineage'
  AND (
    NOT EXISTS (
      SELECT 1 FROM supervision_liveness_sidecar s
      WHERE s.wakeId = NEW.wakeId AND s.assignmentId = NEW.assignmentId
        AND s.wakeKind = 'escalation'
        AND (
          (s.controllerOrigin = 'scheduled' AND s.controllerState = 'settled'
           AND s.chargedGeneration > 0)
          OR
          (s.controllerOrigin = 'retirement_elevation' AND s.controllerState = 'settled'
           AND s.chargedGeneration IS NULL)
        )
    )
    OR NOT EXISTS (
      SELECT 1 FROM turns t
      WHERE t.wakeId = NEW.wakeId AND t.assignmentId = NEW.assignmentId
    )
  )
BEGIN
  SELECT RAISE(ABORT, 'supervision lineage wake requires controller sidecar');
END;
CREATE INDEX supervision_liveness_assignment ON supervision_liveness_sidecar(assignmentId, wakeId);
CREATE UNIQUE INDEX supervision_liveness_pending_controller ON supervision_liveness_sidecar(assignmentId) WHERE controllerState = 'pending' AND controllerOrigin = 'scheduled';
CREATE INDEX supervision_liveness_receipts_assignment ON supervision_liveness_receipts(assignmentId, receiptId);
CREATE UNIQUE INDEX supervision_liveness_retirement_dedupe ON supervision_liveness_sidecar(transferEvidenceId, retirementEpoch, retirementCause) WHERE transferEvidenceId IS NOT NULL;
CREATE TRIGGER supervision_liveness_retirement_immutable_delete
BEFORE DELETE ON supervision_liveness_sidecar
WHEN OLD.transferEvidenceId IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
END;
CREATE TRIGGER supervision_liveness_retirement_immutable_update
BEFORE UPDATE ON supervision_liveness_sidecar
WHEN OLD.transferEvidenceId IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
END;
CREATE TRIGGER supervision_liveness_sidecar_insert_coherent
BEFORE INSERT ON supervision_liveness_sidecar
WHEN NOT EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId=NEW.wakeId AND w.assignmentId=NEW.assignmentId
    AND w.consumer='prompt'
    AND (w.origin='process:tightbeam' OR NEW.controllerOrigin='holder_continuation')
)
OR (
  NEW.controllerOrigin IN ('scheduled','retirement_elevation')
  AND NOT EXISTS (
    SELECT 1 FROM wakes w
    WHERE w.wakeId=NEW.wakeId AND w.assignmentId=NEW.assignmentId
      AND w.state='pending' AND w.consumer='prompt'
      AND w.origin='process:tightbeam'
      AND (
        (NEW.wakeKind='prod' AND w.reresolve IS NULL
         AND w.reresolveSeed IS NULL AND w.reresolveRung IS NULL)
        OR
        (NEW.wakeKind='escalation' AND w.reresolve='lineage'
         AND w.reresolveSeed IS NOT NULL AND w.reresolveRung > 0)
      )
  )
)
OR (
  NEW.controllerOrigin='holder_continuation'
  AND NOT EXISTS (
    SELECT 1 FROM wakes w
    JOIN assignments a ON a.id=w.assignmentId
    JOIN sessions s ON s.sessionKey=a.holderKey
    WHERE w.wakeId=NEW.wakeId AND w.state='pending' AND a.state='open'
      AND w.obligationRef=a.id AND w.sessionKey=a.holderKey
      AND w.ownerUserId=s.ownerUserId
      AND EXISTS (
        WITH RECURSIVE lineage(sessionKey,spawnedBy) AS (
          SELECT sessionKey,spawnedBy FROM sessions
            WHERE sessionKey=a.holderKey AND ownerUserId=w.ownerUserId
          UNION
          SELECT ancestor.sessionKey,ancestor.spawnedBy
            FROM sessions ancestor JOIN lineage child ON ancestor.sessionKey=child.spawnedBy
            WHERE ancestor.ownerUserId=w.ownerUserId
        )
        SELECT 1 FROM lineage WHERE sessionKey=w.creatorSessionKey
      )
      AND w.waitMode IN ('dependency','after-turn') AND w.prompt IS NOT NULL
      AND (w.originatingTurnSeq IS NULL OR EXISTS (
        SELECT 1 FROM turns t WHERE t.seq=w.originatingTurnSeq
          AND t.sessionKey=w.creatorSessionKey AND t.status='running'
      ))
  )
)
BEGIN
  SELECT RAISE(ABORT, 'supervision sidecar requires coherent pending wake');
END;
CREATE TRIGGER supervision_pending_controller_sidecar_delete
BEFORE DELETE ON supervision_liveness_sidecar
WHEN OLD.controllerOrigin='scheduled' AND OLD.controllerState='pending'
  AND EXISTS (
    SELECT 1 FROM wakes w
    WHERE w.wakeId=OLD.wakeId AND w.assignmentId=OLD.assignmentId
      AND w.state='pending'
  )
BEGIN
  SELECT RAISE(ABORT, 'pending supervision controller sidecar is required');
END;
CREATE TRIGGER supervision_pending_controller_sidecar_update
BEFORE UPDATE ON supervision_liveness_sidecar
WHEN OLD.controllerOrigin='scheduled' AND OLD.controllerState='pending'
  AND EXISTS (
    SELECT 1 FROM wakes w
    WHERE w.wakeId=OLD.wakeId AND w.assignmentId=OLD.assignmentId
      AND w.state='pending'
  )
  AND NOT (
    NEW.wakeId IS OLD.wakeId AND NEW.assignmentId IS OLD.assignmentId
    AND NEW.controllerOrigin IS OLD.controllerOrigin
    AND NEW.wakeKind IS OLD.wakeKind
    AND NEW.chargedGeneration IS OLD.chargedGeneration
    AND NEW.transferEvidenceId IS OLD.transferEvidenceId
    AND NEW.retirementEpoch IS OLD.retirementEpoch
    AND NEW.retiringSessionKey IS OLD.retiringSessionKey
    AND NEW.retirementOutcomeKind IS OLD.retirementOutcomeKind
    AND NEW.retirementOutcomeId IS OLD.retirementOutcomeId
    AND NEW.retirementTargetSessionKey IS OLD.retirementTargetSessionKey
    AND NEW.retirementCause IS OLD.retirementCause
    AND NEW.retirementPrincipal IS OLD.retirementPrincipal
    AND NEW.retirementActionNeeded IS OLD.retirementActionNeeded
    AND NEW.controllerState='settled'
  )
BEGIN
  SELECT RAISE(ABORT, 'pending supervision controller permits settlement only');
END;
CREATE TRIGGER supervision_pending_controller_wake_identity_immutable
BEFORE UPDATE OF wakeId, sessionKey, origin, consumer, assignmentId,
                 reresolve, reresolveSeed, reresolveRung
ON wakes
WHEN OLD.state='pending'
  AND EXISTS (
    SELECT 1 FROM supervision_liveness_sidecar s
    WHERE s.wakeId=OLD.wakeId AND s.assignmentId=OLD.assignmentId
      AND s.controllerOrigin='scheduled' AND s.controllerState='pending'
  )
  AND (
    NEW.wakeId IS NOT OLD.wakeId OR NEW.sessionKey IS NOT OLD.sessionKey
    OR NEW.origin IS NOT OLD.origin OR NEW.consumer IS NOT OLD.consumer
    OR NEW.assignmentId IS NOT OLD.assignmentId
    OR NEW.reresolve IS NOT OLD.reresolve
    OR NEW.reresolveSeed IS NOT OLD.reresolveSeed
    OR NEW.reresolveRung IS NOT OLD.reresolveRung
  )
BEGIN
  SELECT RAISE(ABORT, 'pending supervision controller wake identity is immutable');
END;
CREATE INDEX supervision_progress_assignment ON supervision_progress_absorptions(assignmentId, attestTs, attestId);
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
CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId);
CREATE UNIQUE INDEX topline_memberships_active_pair ON topline_work_memberships (toplineId, workItemId) WHERE unlinkedAt IS NULL;
CREATE UNIQUE INDEX topline_memberships_id_topline ON topline_work_memberships (id, toplineId);
CREATE INDEX topline_memberships_work_active ON topline_work_memberships (workItemId) WHERE unlinkedAt IS NULL;
CREATE UNIQUE INDEX topline_placements_one_pending ON topline_placement_obligations (workItemId) WHERE state = 'pending';
CREATE UNIQUE INDEX topline_placements_one_reopen ON topline_placement_obligations (workItemId, sourceCausalEventSeq) WHERE sourceCausalEventSeq IS NOT NULL;
CREATE UNIQUE INDEX topline_placements_one_terminal_resolution ON topline_placement_obligations (workItemId, resolutionCausalEventSeq) WHERE resolutionCausalEventSeq IS NOT NULL;
CREATE UNIQUE INDEX toplines_id_owner ON toplines (id, ownerUserId);
CREATE INDEX turn_repair_source
  ON turn_repair_attempts (sourceSeq, createdAt, id);
CREATE INDEX turns_assignment_id ON turns (assignmentId);
CREATE INDEX turns_job_ref ON turns (jobRef);
CREATE INDEX turns_pending
  ON turns (status, sessionKey, seq)
  WHERE status IN ('queued','running');
CREATE INDEX turns_session ON turns (sessionKey, seq);
CREATE INDEX turns_unpublished
  ON turns (endedAt) WHERE endedAt IS NOT NULL AND publishedAt IS NULL;
CREATE TRIGGER wake_cancellations_pending_insert
BEFORE INSERT ON wake_cancellations
WHEN NOT EXISTS (
  SELECT 1 FROM wakes
  WHERE wakeId = NEW.wakeId AND state = 'pending' AND canceledAt IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'wake cancellation carrier requires a pending wake');
END;
CREATE INDEX wake_retry_root
  ON wake_retry_attempts (rootWakeId, attempt);
CREATE UNIQUE INDEX wakes_cancellation_state ON wakes(wakeId, state, canceledAt);
CREATE INDEX wakes_condition ON wakes (state, conditionKind, conditionScope);
CREATE INDEX wakes_delivery ON wakes (state, deliveryRule, sessionKey, class);
CREATE INDEX wakes_due ON wakes (state, dueAt);
CREATE TRIGGER wakes_typed_cancellation_required
BEFORE UPDATE OF state, canceledAt ON wakes
WHEN NEW.state = 'canceled' AND OLD.state != 'canceled' AND NOT EXISTS (
  SELECT 1 FROM wake_cancellations c
  WHERE c.wakeId = NEW.wakeId AND c.wakeState = NEW.state AND
    c.canceledAt = NEW.canceledAt
)
BEGIN
  SELECT RAISE(ABORT, 'pending wake cancellation requires typed provenance');
END;
CREATE INDEX wakes_wait_recognition
  ON wakes (state, waitMode, ownerUserId, recognitionAt, dueAt);
CREATE INDEX work_item_events_item
  ON work_item_events (workItemId, id);
CREATE INDEX work_items_created_in_turn ON work_items (createdInTurnSeq)
;
CREATE UNIQUE INDEX work_items_id_owner ON work_items (id, ownerUserId);
CREATE INDEX work_state_events_assignment
  ON work_state_events (assignmentId, id);
