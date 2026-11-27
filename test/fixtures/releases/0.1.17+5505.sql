PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE schema_stamp (
  shape TEXT PRIMARY KEY,
  stampedAt INTEGER NOT NULL
);
INSERT INTO schema_stamp VALUES('holder-role-provenance-v1-0118',1735689600000);
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
  publishedAt INTEGER,
  triggerSource TEXT CHECK (
    triggerSource IS NULL OR triggerSource IN ('batch','human','agent','process','other')
  ),
  batchMemberCount INTEGER CHECK (
    batchMemberCount IS NULL OR batchMemberCount >= 0
  ),
  isBatchCarrier INTEGER CHECK (isBatchCarrier IS NULL OR isBatchCarrier=1)
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
CREATE TABLE lifecycle_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      INTEGER NOT NULL,
  kind    TEXT    NOT NULL,
  subject TEXT    NOT NULL,
  detail  TEXT
);
INSERT INTO lifecycle_events VALUES(1,1735689600000,'condition_fact_filed','1','kind=decision-request-filed scope=dr_00000000-0000-4000-8000-000000000001 by=process:tightbeam');
INSERT INTO lifecycle_events VALUES(2,1735689600000,'decision_request_opened','dr_00000000-0000-4000-8000-000000000001','raiser=agent:fixture:holder kind=operator owner=fixture assignment=asg_00000000-0000-4000-8000-000000000002');
CREATE TABLE rail_sweep_cleanup (
  id INTEGER PRIMARY KEY CHECK (id = 0)
);
CREATE TABLE boot_epochs (
  epoch           INTEGER PRIMARY KEY AUTOINCREMENT,
  bootedAt        INTEGER NOT NULL,
  cleanShutdownAt INTEGER
);
INSERT INTO boot_epochs VALUES(1,1735689600000,1735689600000);
CREATE TABLE assets (
  assetId     TEXT PRIMARY KEY,
  ownerUserId TEXT NOT NULL,
  mimeType    TEXT NOT NULL,
  size        INTEGER NOT NULL,
  filename    TEXT,
  createdAt   INTEGER NOT NULL
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
INSERT INTO causal_events_epoch VALUES(0,1735689600000);
CREATE TABLE users (
  userId    TEXT PRIMARY KEY,
  isAdmin   INTEGER NOT NULL DEFAULT 0,
  createdAt INTEGER NOT NULL
);
INSERT INTO users VALUES('fixture',1,1735689600000);
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
CREATE TABLE device_versions (
  deviceId   TEXT PRIMARY KEY REFERENCES devices(deviceId),
  rowVersion INTEGER NOT NULL
);
CREATE TABLE admin_projection_versions (
  resource    TEXT NOT NULL,
  primaryKey  TEXT NOT NULL,
  rowVersion  INTEGER NOT NULL CHECK (rowVersion > 0),
  updatedAt   INTEGER NOT NULL,
  fingerprint TEXT,
  item        TEXT,
  PRIMARY KEY (resource, primaryKey)
);
INSERT INTO admin_projection_versions VALUES('identity','served',1,1735689600000,'f555cff8ad625b978f2915e19e3830f9f518a0927446ffa174424960df892440','{"conflicts":[],"liveRevision":"6dae81361d9c8284ae2f67b313a0f082c528b00f","name":"served","sessionRevisions":{},"staleness":[],"state":"ready"}');
INSERT INTO admin_projection_versions VALUES('kungfu','harklight-decision-briefings',1,1735689600000,'4d57d8454642cb3a32013419fa91d2935d25d049a349b70714a6697460ba29a2','{"documents":[],"installedRevision":null,"name":"harklight-decision-briefings","phrases":[],"purpose":"An example template to configure, not a built-in conversion: Tightbeam ships only the decision-request-filed rule hook. It routes decision requests through a configurable investigator, preserves its Harklight conversation, and reconciles staged catchup without duplicate briefings. A filed decision request is already a proper ask; a Harklight briefing is optional and a refused briefing send does not block it.","rootArchetype":"harklight-decision-briefings.orchestrator","status":"available"}');
INSERT INTO admin_projection_versions VALUES('kungfu','sentinels',1,1735689600000,'3fb6c11897e5c5d0ee3761a7dbdc67cd3cbb61144ae25dd2485fd1d21d3f1dda','{"documents":[],"installedRevision":null,"name":"sentinels","phrases":[],"purpose":"Share generic event subscription tools and a read-only Matrix event watcher.","rootArchetype":"default","status":"available"}');
INSERT INTO admin_projection_versions VALUES('kungfu','uncle-enzo',1,1735689600000,'b99113c6702e85f5692727ced6d7d36d6675c311da18ef127aa12c7cd5fd28ac','{"documents":[],"installedRevision":null,"name":"uncle-enzo","phrases":["I want each feature to have one owner who sees it through.","I want my agents to coordinate with each other directly.","I want one agent to talk to, and I don''t want it buried in status traffic.","My coordinators spend more time messaging each other than shipping."],"purpose":"Run your organization with executives who hold your intent and talk to you, and deliverators who own getting each feature or concern delivered.","rootArchetype":"uncle-enzo.exec","status":"available"}');
INSERT INTO admin_projection_versions VALUES('users','fixture',1,1735689600000,NULL,NULL);
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
  updatedAt         INTEGER NOT NULL, denialDiagnostic TEXT,
  PRIMARY KEY (invocationId, expectedPriorLive)
);
CREATE TABLE host_environment_projection (
  host         TEXT NOT NULL,
  harness      TEXT NOT NULL,
  name         TEXT NOT NULL,
  valuePresent INTEGER NOT NULL CHECK (valuePresent IN (0, 1)),
  updatedAt    INTEGER NOT NULL,
  rowVersion   INTEGER NOT NULL CHECK (rowVersion > 0),
  PRIMARY KEY (host, harness, name)
);
CREATE TABLE admin_projection_faults (
  resource   TEXT NOT NULL,
  primaryKey TEXT NOT NULL,
  code       TEXT NOT NULL,
  detail     TEXT NOT NULL,
  occurredAt INTEGER NOT NULL,
  PRIMARY KEY (resource, primaryKey)
);
CREATE TABLE condition_facts (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  ts     INTEGER NOT NULL,
  kind   TEXT    NOT NULL,
  scope  TEXT,
  origin TEXT    NOT NULL,
  ownerUserId TEXT NULL
, payload TEXT NULL);
INSERT INTO condition_facts VALUES(1,1735689600000,'decision-request-filed','dr_00000000-0000-4000-8000-000000000001','process:tightbeam','fixture','{"addressedPrincipal":"user:fixture","assignmentId":"asg_00000000-0000-4000-8000-000000000002","cause":"operator-ask","creatingPrincipal":"agent:fixture:holder","kind":"operator","raisedAt":1735689600000,"raiserPrincipal":"agent:fixture:holder","requestId":"dr_00000000-0000-4000-8000-000000000001"}');
CREATE TABLE fact_producer_claims (
  producer TEXT PRIMARY KEY,
  kinds TEXT NOT NULL,
  liveUntil INTEGER NOT NULL
);
CREATE TABLE decision_request_terminal_epoch (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  schemaVersion TEXT NOT NULL,
  legacyRulingFactMaxId INTEGER NOT NULL,
  activatedAt INTEGER NOT NULL,
  cause TEXT NOT NULL,
  principal TEXT NOT NULL
);
INSERT INTO decision_request_terminal_epoch VALUES(0,'terminal-operator-decision-parity-v1',0,1735689600000,'terminal-operator-decision-parity-v1','process:tightbeam');
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
  recognitionTransition TEXT NULL, sourceClientIdentity TEXT CHECK (
  sourceClientIdentity IS NULL OR (
    json_valid(sourceClientIdentity) AND json_type(sourceClientIdentity)='object'
    AND json_type(sourceClientIdentity,'$.targetSessionKey')='text'
    AND json_type(sourceClientIdentity,'$.deviceId')='text'
    AND json_type(sourceClientIdentity,'$.clientMessageId')='text'
    AND json_type(sourceClientIdentity,'$.sourceWakeId')='text'
    AND json_type(sourceClientIdentity,'$.payloadSha256')='text'
    AND length(json_extract(sourceClientIdentity,'$.payloadSha256'))=64
    AND json_type(sourceClientIdentity,'$.createdAt')='integer'
    AND json_extract(sourceClientIdentity,'$.createdAt')>=0
    AND json_extract(sourceClientIdentity,'$.sourceWakeId')=wakeId
  )
), sourceAttachments TEXT CHECK (sourceAttachments IS NULL OR json_valid(sourceAttachments)), sourceVisibilityScope TEXT CHECK (sourceVisibilityScope IS NULL OR length(trim(sourceVisibilityScope))>0), sourceAddress TEXT CHECK (sourceAddress IS NULL OR length(trim(sourceAddress))>0), deliveredTurnSeq INTEGER, recordEventIds TEXT,
  CHECK (consumer != 'prompt' OR prompt IS NOT NULL),
  CHECK ((class IS NULL) = (classElection IS NULL)),
  CHECK (digest = 0 OR class IS NOT NULL)
);
INSERT INTO wakes VALUES('w_reaction_0000000000000000000000000000000000000000000000000000000000000003','agent:main:clawline:fixture:main',NULL,'process:tightbeam','route it or icebox it — work item wi_00000000-0000-4000-8000-000000000003: Fixture work','prompt',1735776000000,'canceled',1735689600000,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,'wi_00000000-0000-4000-8000-000000000003',NULL,1735689600000,1,'fyi','classifier','notice-batching-v1 r2',0,0,'fixture',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'session:agent:main:clawline:fixture:main:recipient','session:agent:main:clawline:fixture:main',NULL,NULL);
INSERT INTO wakes VALUES('w_00000000-0000-4000-8000-000000000004','agent:main:clawline:fixture:main',NULL,'process:tightbeam',replace('Operator decision dr_00000000-0000-4000-8000-000000000001 passed its deadline unanswered.\nAsked by: agent:fixture:holder\nRequest: Continue fixture work?\nRead it with tightbeam decision-request --request dr_00000000-0000-4000-8000-000000000001.','\n',char(10)),'prompt',3312489600000,'pending',1735689600000,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'fyi','classifier','notice-batching-v1 r2',0,0,NULL,'decision-request-notice:dr_00000000-0000-4000-8000-000000000001',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'session:agent:main:clawline:fixture:main:recipient:delivery-target-gate-0','session:agent:main:clawline:fixture:main',NULL,NULL);
INSERT INTO wakes VALUES('w_00000000-0000-4000-8000-000000000005','agent:fixture:holder',NULL,'agent:fixture:opener','Fixture wake','prompt',4102444800000,'pending',1735689600000,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,1,'fyi','classifier','notice-batching-v1 r2',0,0,'fixture',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'session:agent:fixture:holder:recipient','session:agent:fixture:holder',NULL,NULL);
CREATE TABLE scheduler_state (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  afterFact INTEGER NOT NULL DEFAULT 0
);
INSERT INTO scheduler_state VALUES(0,0);
CREATE TABLE wake_activity_exclusions (
  wakeId TEXT PRIMARY KEY
);
CREATE TABLE wake_wait_reasons (
  wakeId TEXT PRIMARY KEY,
  reason TEXT NOT NULL
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
CREATE TABLE org_settings (
  key       TEXT PRIMARY KEY,
  value     TEXT NOT NULL,
  updatedAt INTEGER NOT NULL
);
INSERT INTO org_settings VALUES('record-event-feed-activation:assignment.opened','1735689600000',1735689600000);
INSERT INTO org_settings VALUES('record-event-feed-activation:work_item.filed','1735689600000',1735689600000);
CREATE TABLE critical_leases (
  sessionKey   TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
  reason       TEXT NOT NULL,
  startedAt    INTEGER NOT NULL,
  expiresAt    INTEGER NOT NULL,
  hardDeadline INTEGER NOT NULL,
  updatedAt    INTEGER NOT NULL
);
CREATE TABLE roles (
  name            TEXT PRIMARY KEY,
  boundSessionKey TEXT,
  ownerUserId     TEXT NOT NULL,
  createdAt       INTEGER NOT NULL,
  updatedAt       INTEGER NOT NULL
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
  createdAt INTEGER NOT NULL, deliveryOwnerSessionKey TEXT NULL REFERENCES sessions(sessionKey),
  CHECK((specRefName IS NULL) = (specRefSha256 IS NULL))
);
INSERT INTO work_items VALUES('wi_00000000-0000-4000-8000-000000000003','Fixture work',NULL,NULL,0,'fixture','open',NULL,NULL,NULL,NULL,'agent:fixture:opener',NULL,1,1735689600000,NULL);
CREATE TABLE work_item_versions (
  workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
  rowVersion INTEGER NOT NULL CHECK(rowVersion > 0)
);
INSERT INTO work_item_versions VALUES('wi_00000000-0000-4000-8000-000000000003',1735689600000);
CREATE TABLE work_item_priorities (
  workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
  priority INTEGER NOT NULL
);
INSERT INTO work_item_priorities VALUES('wi_00000000-0000-4000-8000-000000000003',4);
CREATE TABLE assignment_files (
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  path TEXT NOT NULL,
  PRIMARY KEY (assignmentId, path)
);
CREATE TABLE assignment_effects (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  effectKind TEXT NOT NULL CHECK(effectKind IN ('code', 'policy', 'release', 'live_mutation', 'evidence', 'review', 'coordination'))
);
INSERT INTO assignment_effects VALUES('asg_00000000-0000-4000-8000-000000000002','coordination');
CREATE TABLE assignment_priorities (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  priority INTEGER NOT NULL
);
INSERT INTO assignment_priorities VALUES('asg_00000000-0000-4000-8000-000000000002',4);
CREATE TABLE assignment_interruptions (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  sessionKey   TEXT NOT NULL REFERENCES sessions(sessionKey),
  reason       TEXT NOT NULL CHECK(reason = 'interrupted-by-retire'),
  ts           INTEGER NOT NULL
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
CREATE TABLE hosts (
  name          TEXT PRIMARY KEY,
  ssh           TEXT,
  baseDir       TEXT NOT NULL,
  cliBin        TEXT,
  adapterBinDir TEXT
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
CREATE TABLE host_toolchain_dirs (
  host     TEXT NOT NULL,
  position INTEGER NOT NULL CHECK (position >= 0),
  dir      TEXT NOT NULL,
  setBy    TEXT NOT NULL,
  setAt    INTEGER NOT NULL,
  PRIMARY KEY (host, position)
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
CREATE TABLE work_item_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  ts           INTEGER NOT NULL,
  workItemId   TEXT    NOT NULL REFERENCES work_items(id),
  kind         TEXT    NOT NULL,
  CHECK (kind IN ('metadata','composition'))
);
CREATE TABLE production_cursors (
  name TEXT PRIMARY KEY,
  seq  INTEGER NOT NULL
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
, preparationBootIdentity TEXT);
CREATE TABLE harness_park_fences (
  adapterKey       TEXT PRIMARY KEY,
  requestedAt      INTEGER NOT NULL
, generation TEXT);
CREATE TABLE toplines (
  id               TEXT PRIMARY KEY CHECK (substr(id, 1, 3) = 'tl_'),
  ownerUserId      TEXT NOT NULL REFERENCES users(userId),
  title            ANY NOT NULL,
  state            TEXT NOT NULL CHECK (state IN ('open','closed')),
  createdActorKind TEXT NOT NULL CHECK (createdActorKind IN ('user','session','process')),
  createdActorRef  TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
  createdAt        INTEGER NOT NULL,
  updatedAt        INTEGER NOT NULL,
  closedAt         INTEGER,
  CHECK (typeof(title) = 'text'),
  CHECK (typeof(createdAt) = 'integer'),
  CHECK (typeof(updatedAt) = 'integer' AND updatedAt >= createdAt),
  CHECK (
    (state = 'open' AND closedAt IS NULL) OR
    (state = 'closed' AND typeof(closedAt) = 'integer' AND closedAt >= createdAt)
  )
);
CREATE TABLE topline_work_memberships (
  id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlm_'),
  toplineId         TEXT NOT NULL,
  workItemId        TEXT NOT NULL,
  ownerUserId       TEXT NOT NULL,
  linkReason        TEXT NOT NULL CHECK (length(trim(linkReason)) BETWEEN 1 AND 4000),
  linkedActorKind   TEXT NOT NULL CHECK (linkedActorKind IN ('user','session','process')),
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
     unlinkedActorKind IS NOT NULL AND unlinkedActorKind IN ('user','session','process') AND
     unlinkedActorRef IS NOT NULL AND length(trim(unlinkedActorRef)) > 0)
  )
);
CREATE TABLE topline_concerns (
  id                TEXT PRIMARY KEY CHECK (substr(id, 1, 4) = 'tlc_'),
  toplineId         TEXT NOT NULL REFERENCES toplines(id),
  title             ANY NOT NULL,
  createdActorKind  TEXT NOT NULL CHECK (createdActorKind IN ('user','session','process')),
  createdActorRef   TEXT NOT NULL CHECK (length(trim(createdActorRef)) > 0),
  createdAt         INTEGER NOT NULL,
  CHECK (typeof(title) = 'text'),
  CHECK (typeof(createdAt) = 'integer')
);
CREATE TABLE topline_concern_refs (
  toplineId         TEXT NOT NULL,
  concernId         TEXT NOT NULL,
  workItemId        TEXT NOT NULL REFERENCES work_items(id),
  tagReason         TEXT NOT NULL CHECK (length(trim(tagReason)) BETWEEN 1 AND 4000),
  taggedActorKind   TEXT NOT NULL CHECK (taggedActorKind IN ('user','session','process')),
  taggedActorRef    TEXT NOT NULL CHECK (length(trim(taggedActorRef)) > 0),
  taggedAt          INTEGER NOT NULL CHECK (typeof(taggedAt) = 'integer'),
  PRIMARY KEY (concernId, workItemId),
  FOREIGN KEY (concernId, toplineId) REFERENCES topline_concerns(id, toplineId),
  CHECK (length(trim(taggedActorRef)) > 0)
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
  actorKind           TEXT NOT NULL CHECK (actorKind IN ('user','session','process')),
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
     openedActorKind IN ('user','session','process')) OR
    (cause = 'migration' AND openedActorKind = 'process' AND openedActorRef = 'tightbeam') OR
    (cause = 'reopened' AND
     (openedActorKind IN ('user','session','process') OR
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
    (state IN ('linked','left_unlinked') AND resolutionActorKind IN ('user','session','process') AND
     resolutionCausalEventSeq IS NULL) OR
    (state = 'work_terminal' AND resolutionActorKind IN ('user','session','process') AND
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
INSERT INTO topline_schema_stamp VALUES(1,'standalone-toplines-v7',1735689600000);
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
CREATE TABLE supervision_liveness_epoch (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  activatedAt INTEGER NOT NULL CHECK (activatedAt >= 0),
  cause TEXT NOT NULL CHECK (cause = 'schema_activation'),
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
INSERT INTO supervision_liveness_epoch VALUES(0,1735689600000,'schema_activation','process:tightbeam');
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
CREATE TABLE supervision_liveness_checkpoint_bindings (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  holderSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  sourceTurnSeq INTEGER NOT NULL REFERENCES turns(seq),
  boundAt INTEGER NOT NULL CHECK (boundAt >= 0),
  principal TEXT NOT NULL CHECK (principal = 'process:tightbeam')
);
CREATE TABLE supervision_liveness_migrations (
  migrationId TEXT PRIMARY KEY,
  appliedAt INTEGER NOT NULL,
  affectedRows INTEGER NOT NULL CHECK (affectedRows >= 0),
  cause TEXT NOT NULL,
  principal TEXT NOT NULL
);
INSERT INTO supervision_liveness_migrations VALUES('harness-health-cycle-redelivery/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('terminal-row-reactions/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('terminal-row-reaction-receipts/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('harness-health-recovery-schedules/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('harness-recovery-notices/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('0.1.9/pending-recognition-v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('0.1.15/pending-recognition-fact-wait-v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('row-reaction-cancellation/v1',1735689600000,0,'release_upgrade','process:tightbeam');
INSERT INTO supervision_liveness_migrations VALUES('retirement-continuation-cancellation/v1',1735689600000,0,'release_upgrade','process:tightbeam');
CREATE TABLE IF NOT EXISTS "decision_requests" (
  id                TEXT PRIMARY KEY,
  kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','operator','agent')),
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
  deadlineAt        INTEGER,
  statuteName       TEXT,
  actionKey         TEXT,
  question          TEXT NOT NULL,
  options           TEXT,
  context           TEXT NOT NULL,
  status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded','answered','returned')),
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
  askedOfRole       TEXT,
  answer            TEXT,
  answeredBy        TEXT,
  answeredAt        INTEGER,
  returnedBy        TEXT,
  returnReason      TEXT,
  returnedAt        INTEGER, rowVersion INTEGER NOT NULL DEFAULT 1, rowSchemaRevision INTEGER NOT NULL DEFAULT 1, currentRaiserSessionKey TEXT REFERENCES sessions(sessionKey), currentExpecterSessionKey TEXT REFERENCES sessions(sessionKey),
  CHECK (
    (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
     AND expecterSessionKey IS NULL AND expecterUserId IS NULL
     AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
     AND deadlineAt IS NOT NULL
     AND ruledViaSessionKey IS NULL
     AND (decision IS NULL OR decision IN ('allow','deny','waived')))
    OR
    (kind = 'effort' AND raiserId = 'process:tightbeam'
     AND raiserSessionKey IS NULL
     AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
     AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
     AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
     AND deadlineAt IS NOT NULL
     AND ruledViaSessionKey IS NULL
     AND (decision IS NULL OR decision IN ('continue','dismiss')))
    OR
    (kind = 'operator'
     AND ((raiserId <> 'process:tightbeam/coordinator-hold' AND raiserSessionKey IS NOT NULL)
          OR (raiserId = 'process:tightbeam/coordinator-hold' AND raiserSessionKey IS NULL
              AND assignmentId IS NULL AND deadlineAt IS NULL))
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
        
        AND ruledAt IS NOT NULL AND rulingFactId IS NOT NULL)
       OR
       (status <> 'ruled'
        AND decision IS NULL AND rationale IS NULL
        AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
        AND ruledViaSessionKey IS NULL)
     ))
    OR
    (kind = 'agent'
     AND raiserSessionKey IS NOT NULL AND raiserId = 'session:' || raiserSessionKey
     AND expecterSessionKey IS NOT NULL AND expecterUserId IS NOT NULL
     AND statuteName IS NULL AND actionKey IS NULL AND options IS NULL
     AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
     AND deadlineAt IS NULL
     AND decision IS NULL AND rationale IS NULL
     AND ruledBy IS NULL AND ruledViaPrincipal IS NULL
     AND ruledViaSessionKey IS NULL AND ruledViaSessionState IS NULL
     AND ruledAt IS NULL AND rulingFactId IS NULL
     AND consumedAt IS NULL AND parkWakeId IS NULL
     AND status IN ('open','answered','withdrawn','returned')
     AND (status = 'answered') = (answer IS NOT NULL)
     AND (answer IS NULL) = (answeredBy IS NULL)
     AND (answer IS NULL) = (answeredAt IS NULL)
     AND (status = 'returned') = (returnReason IS NOT NULL)
     AND (returnReason IS NULL OR length(trim(returnReason)) > 0)
     AND (returnReason IS NULL) = (returnedBy IS NULL)
     AND (returnReason IS NULL) = (returnedAt IS NULL))
  ),
  CHECK (kind = 'agent' OR
    (askedOfRole IS NULL AND answer IS NULL AND answeredBy IS NULL AND answeredAt IS NULL
     AND returnedBy IS NULL AND returnReason IS NULL AND returnedAt IS NULL
     AND status NOT IN ('answered','returned')))
);
INSERT INTO decision_requests VALUES('dr_00000000-0000-4000-8000-000000000001','operator','agent:fixture:holder','agent:fixture:holder','fixture','asg_00000000-0000-4000-8000-000000000002',NULL,NULL,NULL,NULL,NULL,1735689600000,3312489600000,NULL,'0000000000000000000000000000000000000000000000000000000000000001','Continue fixture work?','[{"label":"accept"},{"label":"dismiss"}]','{"note":null,"project":"Fixture","supersedes":null,"workItemId":"wi_00000000-0000-4000-8000-000000000003"}','open',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,2,NULL,NULL);
CREATE TABLE artifact_version_floors (artifactId TEXT NOT NULL PRIMARY KEY,
rowVersion INTEGER NOT NULL
  CHECK (typeof(rowVersion) = 'integer' AND rowVersion > 0)
);
INSERT INTO artifact_version_floors VALUES('art_00000006',1);
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
  closedByProcess TEXT NULL CHECK(closedByProcess IS NULL OR closedByProcess = 'process:tightbeam'),
  closingAttestId TEXT NULL REFERENCES attests(id),
  workItemId TEXT NULL REFERENCES work_items(id),
  reviewsAssignmentId TEXT NULL REFERENCES assignments(id),
  holderHarness TEXT NULL,
  holderProvider TEXT NULL,
  reminderState TEXT NULL, parentAssignmentId TEXT NULL REFERENCES assignments(id), currentOpenerSessionKey TEXT REFERENCES sessions(sessionKey),
  CHECK(holderRole IS NOT NULL OR holderFallback = 0),
  CHECK(
    (state = 'open' AND outcome IS NULL AND closedAt IS NULL AND
     closedByUser IS NULL AND closedBySession IS NULL AND closedByProcess IS NULL AND closingAttestId IS NULL)
    OR
    (state = 'closed' AND outcome IS NOT NULL AND closedAt IS NOT NULL)
  ),
  CHECK(closedByProcess IS NULL OR outcome = 'revoked'),
  CHECK(outcome NOT IN ('completed', 'surrendered') OR closingAttestId IS NOT NULL),
  CHECK(outcome != 'revoked' OR closingAttestId IS NULL)
);
INSERT INTO assignments VALUES('asg_00000000-0000-4000-8000-000000000002','Fixture task','agent:fixture:holder',NULL,0,NULL,'agent:fixture:opener',1735689600000,'open',NULL,NULL,NULL,NULL,NULL,NULL,'wi_00000000-0000-4000-8000-000000000003',NULL,'claude','anthropic',NULL,NULL,NULL);
CREATE TABLE assignment_reopenings (
  id                   INTEGER PRIMARY KEY AUTOINCREMENT,
  assignmentId         TEXT    NOT NULL REFERENCES assignments(id),
  ts                   INTEGER NOT NULL,
  reopenedByUser       TEXT    NULL REFERENCES users(userId),
  reopenedBySession    TEXT    NULL REFERENCES sessions(sessionKey),
  reason               TEXT    NOT NULL
    CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
  priorOutcome         TEXT    NOT NULL
    CHECK(priorOutcome IN ('completed', 'surrendered', 'revoked')),
  priorClosedAt        INTEGER NOT NULL,
  priorClosedByUser    TEXT    NULL,
  priorClosedBySession TEXT    NULL,
  priorClosedByProcess TEXT    NULL CHECK(priorClosedByProcess IS NULL OR priorClosedByProcess = 'process:tightbeam'),
  priorClosingAttestId TEXT    NULL REFERENCES attests(id)
);
CREATE TABLE assignment_revocations (
  id TEXT PRIMARY KEY,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  revokedAt INTEGER NOT NULL,
  revokedByUser TEXT NULL REFERENCES users(userId),
  revokedBySession TEXT NULL REFERENCES sessions(sessionKey),
  revokedByProcess TEXT NULL CHECK(revokedByProcess IS NULL OR revokedByProcess = 'process:tightbeam'),
  -- Match String.trim/1's Unicode whitespace contract. SQLite's one-argument
  -- trim only removes ASCII spaces, so a tab-only reason would otherwise be
  -- a durable but content-free revocation motive.
  reason TEXT NOT NULL CHECK(
    length(reason) BETWEEN 1 AND 2000
    AND length(trim(reason,
      char(9) || char(10) || char(11) || char(12) || char(13) || ' ' ||
      char(133) || char(160) || char(5760) ||
      char(8192) || char(8193) || char(8194) || char(8195) || char(8196) ||
      char(8197) || char(8198) || char(8199) || char(8200) || char(8201) ||
      char(8202) || char(8232) || char(8233) || char(8239) || char(8287) ||
      char(12288)
    )) >= 1
  ),
  CHECK(revokedByProcess IS NULL OR reason = 'holder session retired')
);
CREATE TABLE assignment_revocation_generations (
  revocationId TEXT PRIMARY KEY REFERENCES assignment_revocations(id),
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  reopeningId INTEGER NULL REFERENCES assignment_reopenings(id)
);
CREATE TABLE artifact_contents (
  artifactId TEXT PRIMARY KEY REFERENCES artifacts(artifactId),
  contentSha256 TEXT NOT NULL,
  contentSize INTEGER NOT NULL CHECK (contentSize >= 0),
  content BLOB NOT NULL,
  storedAt INTEGER NOT NULL,
  CHECK (length(content) = contentSize),
  CHECK (length(contentSha256) = 64 AND contentSha256 = lower(contentSha256))
);
CREATE TABLE session_po_associations (
  sessionKey    TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
  ownerUserId   TEXT NOT NULL,
  poRole        TEXT NOT NULL,
  revision      INTEGER NOT NULL CHECK (revision >= 1),
  noticeWakeId  TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
  setBy         TEXT NOT NULL,
  cause         TEXT NOT NULL CHECK (cause = 'explicit_set'),
  createdAt     INTEGER NOT NULL,
  updatedAt     INTEGER NOT NULL,
  CHECK (length(trim(poRole)) > 0),
  CHECK (length(trim(setBy)) > 0),
  CHECK (updatedAt >= createdAt)
);
CREATE TABLE runtime_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  request TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','applied','failed')),
  result TEXT,
  createdAt INTEGER NOT NULL,
  finishedAt INTEGER
);
CREATE TABLE health_redelivery_attempts (
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
  cycleReleaseCorrelation TEXT,
  cycleReleaseTurnSeq INTEGER REFERENCES turns(seq),
  UNIQUE(sessionKey, sourceTurnSeq),
  UNIQUE(sessionKey, sourceMessageId),
  CHECK((restorationTurnSeq IS NULL) = (redeliveryTurnSeq IS NULL))
);
CREATE TABLE harklight_send_operations (
  opId TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  host TEXT NOT NULL,
  payload TEXT NOT NULL,
  result TEXT,
  handle TEXT,
  senderId TEXT,
  messageId TEXT,
  attemptedAt INTEGER,
  state TEXT NOT NULL CHECK(state IN ('pending','bound')),
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL, currentReceiverSessionKey TEXT REFERENCES sessions(sessionKey),
  CHECK ((state='pending' AND result IS NULL AND handle IS NULL AND senderId IS NULL AND messageId IS NULL)
     OR (state='bound' AND result IS NOT NULL AND handle IS NOT NULL AND senderId IS NOT NULL AND messageId IS NOT NULL))
);
CREATE TABLE harklight_pending_supersedes (
  opId TEXT NOT NULL REFERENCES harklight_send_operations(opId),
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  PRIMARY KEY(opId,senderId,messageId)
);
CREATE TABLE harklight_wake_handles (
  handle TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  host TEXT NOT NULL,
  vendorSessionId TEXT,
  state TEXT NOT NULL CHECK(state IN ('active','complete','unavailable')),
  lastCursor INTEGER NOT NULL DEFAULT 0,
  lastError TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
, currentReceiverSessionKey TEXT REFERENCES sessions(sessionKey));
CREATE TABLE harklight_feed_checkpoints (
  handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
  rev INTEGER NOT NULL CHECK(rev >= 0)
);
CREATE TABLE harklight_feed_launches (
  handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
  owner TEXT NOT NULL
);
CREATE TABLE harklight_feed_stops (
  handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle)
);
CREATE TABLE harklight_feed_pauses (
  handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
  diagnostic TEXT NOT NULL
);
CREATE TABLE harklight_wake_requests (
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
  PRIMARY KEY(senderId,messageId)
);
CREATE TABLE harklight_wake_follows (
  followId TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  kind TEXT NOT NULL CHECK(kind IN ('message','conversation')),
  handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
  senderId TEXT,
  messageId TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','ended')),
  createdAt INTEGER NOT NULL,
  endedAt INTEGER,
  CHECK ((kind='conversation' AND senderId IS NULL AND messageId='') OR
         (kind='message' AND senderId IS NOT NULL AND messageId<>''))
);
CREATE TABLE harklight_wake_entries (
  handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
  eventId TEXT NOT NULL,
  feedCursor INTEGER NOT NULL,
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  requestRevision INTEGER,
  entryKind TEXT NOT NULL,
  entryAuthor TEXT NOT NULL,
  rawLine TEXT NOT NULL,
  wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
  capturedAt INTEGER NOT NULL,
  PRIMARY KEY(handle,eventId),
  UNIQUE(handle,feedCursor)
);
CREATE TABLE harklight_wake_deliveries (
  handle TEXT NOT NULL,
  eventId TEXT NOT NULL,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId), currentRecipientSessionKey TEXT REFERENCES sessions(sessionKey),
  PRIMARY KEY(handle,eventId,sessionKey),
  FOREIGN KEY(handle,eventId) REFERENCES harklight_wake_entries(handle,eventId)
);
CREATE TABLE harklight_wake_suppressed_entries (
  handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
  eventId TEXT NOT NULL,
  feedCursor INTEGER NOT NULL,
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  requestRevision INTEGER,
  entryKind TEXT NOT NULL,
  entryAuthor TEXT NOT NULL,
  rawLine TEXT NOT NULL,
  capturedAt INTEGER NOT NULL,
  PRIMARY KEY(handle,eventId),
  UNIQUE(handle,feedCursor)
);
CREATE TABLE harklight_listener_outages (
  handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
  episode TEXT NOT NULL,
  startedAt INTEGER NOT NULL,
  noticeWakeId TEXT,
  error TEXT NOT NULL,
  operation TEXT,
  diagnostic TEXT,
  checkpoint INTEGER NOT NULL DEFAULT -1
);
CREATE TABLE harklight_operation_pauses (
  opId TEXT PRIMARY KEY,
  diagnostic TEXT NOT NULL
);
CREATE TABLE harklight_operation_guards (
  opId TEXT PRIMARY KEY
);
CREATE TABLE harklight_command_results (
  opId TEXT PRIMARY KEY,
  outcome TEXT NOT NULL,
  effects TEXT NOT NULL
);
CREATE TABLE harklight_subscription_ends (
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  handle TEXT NOT NULL,
  opId TEXT NOT NULL,
  replacementId TEXT,
  state TEXT NOT NULL CHECK(state IN ('ended','open')),
  acknowledgment TEXT NOT NULL CHECK(acknowledgment IN ('not_needed','pending','acknowledged','failed')),
  ackEventId TEXT,
  reason TEXT,
  PRIMARY KEY(senderId,messageId)
);
CREATE TABLE harklight_follow_message_ends (
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  handle TEXT NOT NULL,
  opId TEXT NOT NULL,
  replacementId TEXT,
  endedBySessionKey TEXT,
  endKind TEXT NOT NULL CHECK(endKind IN ('retracted','superseded','terminal')),
  PRIMARY KEY(senderId,messageId)
);
CREATE TABLE harklight_held_terminals (
  handle TEXT NOT NULL,
  eventId TEXT NOT NULL,
  senderId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  rawLine TEXT NOT NULL,
  PRIMARY KEY(handle,eventId)
);
CREATE TABLE harklight_entry_context (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  statement TEXT NOT NULL
);
CREATE TABLE harklight_handoff_receipts (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  turnSeq INTEGER NOT NULL REFERENCES turns(seq),
  argv TEXT NOT NULL,
  opId TEXT NOT NULL UNIQUE,
  journalId TEXT,
  completedAt INTEGER
);
CREATE TABLE harklight_decision_briefings (
  requestId TEXT PRIMARY KEY,
  ownerUserId TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN (
    'staged','reuse_staged','admitted','reserved','pending','bound',
    'reused','unresolved','excluded'
  )),
  disposition TEXT NOT NULL,
  actorSessionKey TEXT,
  sessionKey TEXT,
  wakeId TEXT,
  sendOpId TEXT,
  handle TEXT,
  senderId TEXT,
  messageId TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE TABLE harklight_bounces (
  advisoryId TEXT PRIMARY KEY,
  itemId TEXT NOT NULL,
  handle TEXT NOT NULL REFERENCES harklight_wake_handles(handle),
  advisoryType TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK(outcome IN ('woken','closed')),
  recipient TEXT REFERENCES sessions(sessionKey),
  wakeId TEXT REFERENCES wakes(wakeId),
  capturedAt INTEGER NOT NULL,
  ackOpId TEXT NOT NULL UNIQUE,
  ackJournalId TEXT,
  ackCompletedAt INTEGER,
  ackOutcome TEXT CHECK(ackOutcome IN ('acknowledged','gone','moot','delivered','not_owed')),
  CHECK ((outcome='woken' AND recipient IS NOT NULL AND wakeId IS NOT NULL)
      OR (outcome='closed' AND recipient IS NULL AND wakeId IS NULL)),
  CHECK ((ackCompletedAt IS NULL AND ackOutcome IS NULL)
      OR (ackCompletedAt IS NOT NULL AND ackOutcome IS NOT NULL))
);
CREATE TABLE harklight_pending_supersedes_migration (
  id INTEGER PRIMARY KEY CHECK(id=0),
  appliedAt INTEGER NOT NULL CHECK(appliedAt >= 0)
);
INSERT INTO harklight_pending_supersedes_migration VALUES(0,1735689600000);
CREATE TABLE message_attachment_delivery_results (
  seq            INTEGER PRIMARY KEY AUTOINCREMENT,
  messageId      TEXT NOT NULL REFERENCES messages(id),
  sessionKey     TEXT NOT NULL,
  clientMessageId TEXT NOT NULL,
  assetId        TEXT NOT NULL,
  outcome        TEXT NOT NULL CHECK (outcome IN ('pending','delivered','not-delivered','unknown')),
  reason         TEXT,
  recordedAt     INTEGER NOT NULL,
  CHECK (
    (outcome IN ('pending','delivered') AND reason IS NULL) OR
    (outcome IN ('not-delivered','unknown') AND reason IS NOT NULL)
  )
);
CREATE TABLE rail_scope_migrations (
  migrationId TEXT PRIMARY KEY,
  reportJson  TEXT NOT NULL,
  completedAt INTEGER NOT NULL
);
INSERT INTO rail_scope_migrations VALUES('rail-scope-v1','{"flagged_conditions":[],"removed_entries":[],"result_revision":"6dae81361d9c8284ae2f67b313a0f082c528b00f","rewritten_names":[],"schema":"tightbeam-rail-scope-migration/v1","source_revision":"b8064c420da61dc3c396f6c45c83885b2dbe8b15","status":"complete","stops":[]}',1735689600000);
CREATE TABLE harness_switch_contexts (
  contextId TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  sourceHarness TEXT NOT NULL,
  sourceModel TEXT NOT NULL,
  sourceModelContext TEXT,
  sourcePointerId INTEGER,
  sourceNativeSessionId TEXT,
  sourceClearedThroughSeq INTEGER NOT NULL,
  processedMessageIds TEXT NOT NULL,
  processedWindowCount INTEGER NOT NULL,
  processedWindowTruncated INTEGER NOT NULL CHECK (processedWindowTruncated IN (0,1)),
  processedWindowStartsAtSeq INTEGER,
  pendingMessageIds TEXT NOT NULL,
  excludedMessageIds TEXT NOT NULL,
  excludedWindowCount INTEGER NOT NULL,
  excludedWindowTruncated INTEGER NOT NULL CHECK (excludedWindowTruncated IN (0,1)),
  excludedWindowStartsAtSeq INTEGER,
  summaryStatus TEXT NOT NULL CHECK (summaryStatus = 'unavailable'),
  summaryReason TEXT NOT NULL,
  destinationHarness TEXT NOT NULL,
  destinationModel TEXT NOT NULL,
  destinationModelContext TEXT,
  destinationPayloadEvidence TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','bound','superseded')),
  boundTurnSeq INTEGER REFERENCES turns(seq),
  boundMessageId TEXT,
  boundPrompt TEXT,
  handoffOutcome TEXT,
  budgetEvidence TEXT,
  includedMessageIds TEXT,
  omittedMessageIds TEXT,
  compactorModel TEXT,
  compactorUsage TEXT,
  compactionEvidence TEXT,
  fallbackReason TEXT,
  createdAt INTEGER NOT NULL,
  boundAt INTEGER
);
CREATE TABLE assignment_cannot_proceed (
  id TEXT PRIMARY KEY,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  attestId TEXT NOT NULL UNIQUE REFERENCES attests(id),
  decisionRequestId TEXT NOT NULL UNIQUE,
  decisionWakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
  openerRef TEXT,
  disposerRef TEXT,
  reason TEXT NOT NULL CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
  releaseFactKind TEXT NULL,
  releaseFactScope TEXT NULL,
  releaseFactPrincipalRef TEXT NULL,
  state TEXT NOT NULL CHECK(state IN ('standing', 'settled')),
  createdAt INTEGER NOT NULL,
  settledAt INTEGER NULL,
  settlementKind TEXT NULL CHECK(settlementKind IN ('release-fact', 'disposed')),
  settlementFactId INTEGER NULL REFERENCES condition_facts(id),
  settledBy TEXT NULL,
  CHECK(
    (releaseFactKind IS NULL AND releaseFactScope IS NULL AND releaseFactPrincipalRef IS NULL)
    OR
    (releaseFactKind IS NOT NULL AND releaseFactScope IS NOT NULL AND
     releaseFactPrincipalRef IS NOT NULL)
  ),
  CHECK(
    (state = 'standing' AND settledAt IS NULL AND settlementKind IS NULL AND
     settlementFactId IS NULL AND settledBy IS NULL)
    OR
    (state = 'settled' AND settledAt IS NOT NULL AND settlementKind IS NOT NULL AND
     settledBy IS NOT NULL)
  )
);
CREATE TABLE assignment_commit_ref_corrections (
  id                 TEXT PRIMARY KEY,
  assignmentId       TEXT NOT NULL UNIQUE REFERENCES assignments(id),
  commitRefs         TEXT NOT NULL CHECK (json_valid(commitRefs) AND json_type(commitRefs) = 'array'),
  reason             TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 4000),
  evidenceArtifactId TEXT NOT NULL REFERENCES artifacts(artifactId),
  actorKind          TEXT NOT NULL ,
  actorRef           TEXT NOT NULL,
  cause              TEXT NOT NULL CHECK (cause = 'historical_canonical_commitref_correction'),
  idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
  requestFingerprint TEXT NOT NULL CHECK (length(requestFingerprint) = 64),
  verifiedAt         INTEGER,
  createdAt          INTEGER NOT NULL,
  UNIQUE (actorKind, actorRef, idempotencyKey)
);
CREATE TABLE harness_compaction_observations (
  attemptKey TEXT PRIMARY KEY,
  harness TEXT NOT NULL,
  host TEXT NOT NULL,
  model TEXT NOT NULL,
  failureClass TEXT NOT NULL,
  observedAt INTEGER NOT NULL
);
CREATE TABLE work_item_bodies (
  workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
  body TEXT,
  updatedByUser TEXT REFERENCES users(userId),
  updatedBySession TEXT REFERENCES sessions(sessionKey),
  updatedAt INTEGER NOT NULL CHECK(updatedAt >= 0),
  CHECK(body IS NULL OR (typeof(body) = 'text' AND length(CAST(body AS BLOB)) <= 65536))
);
CREATE TABLE work_item_body_activation (
  id INTEGER PRIMARY KEY CHECK(id = 0),
  activatedAt INTEGER NOT NULL CHECK(activatedAt >= 0),
  cause TEXT NOT NULL CHECK(cause = 'schema_activation'),
  principal TEXT NOT NULL CHECK(principal = 'process:tightbeam')
);
INSERT INTO work_item_body_activation VALUES(0,1735689600000,'schema_activation','process:tightbeam');
CREATE TABLE IF NOT EXISTS "sessions" (
  sessionKey TEXT PRIMARY KEY, displayName TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'custom' CHECK (kind IN ('main','dm','custom')),
  orderIndex INTEGER NOT NULL DEFAULT 0, isBuiltIn INTEGER NOT NULL DEFAULT 0,
  adopted INTEGER NOT NULL DEFAULT 0, ownerUserId TEXT NOT NULL, origin TEXT NOT NULL,
  spawnedBy TEXT, handle TEXT UNIQUE, archetype TEXT NOT NULL, overrides TEXT,
  identityName TEXT, identityRevision TEXT, identityRenderContract TEXT,
  identityGuidanceDigest TEXT, cliToken TEXT,
  harness TEXT NOT NULL CHECK (harness IN ('claude','codex','pi','cursor')),
  provider TEXT NOT NULL CHECK (provider IN ('anthropic','openai','cursor','opencode_go','local_openai')),
  model TEXT NOT NULL, thinkingLevel TEXT, modelContext TEXT,
  host TEXT NOT NULL DEFAULT 'local', clearedThroughSeq INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','retired')),
  createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
  mechanicalStatus TEXT NOT NULL DEFAULT 'idle'
    CHECK (mechanicalStatus IN ('idle','running'))
, runningModelId TEXT, runningModelLabel TEXT, runningModelHarness TEXT);
INSERT INTO sessions VALUES('agent:fixture:opener','Fixture opener','custom',0,0,0,'fixture','user:fixture',NULL,NULL,'default',NULL,'default',NULL,NULL,NULL,'fixture-token-7','claude','anthropic','claude-sonnet-5','medium',NULL,'fixture',0,'active',1735689600000,1735689600000,'idle',NULL,NULL,NULL);
INSERT INTO sessions VALUES('agent:fixture:holder','Fixture holder','custom',0,0,0,'fixture','user:fixture',NULL,NULL,'default',NULL,'default',NULL,NULL,NULL,'fixture-token-8','claude','anthropic','claude-sonnet-5','medium',NULL,'fixture',0,'active',1735689600000,1735689600000,'idle',NULL,NULL,NULL);
CREATE TABLE IF NOT EXISTS "subagent_markers" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('subagent_start','subagent_stop')),
  principal TEXT NOT NULL REFERENCES sessions(sessionKey),
  subagentRef TEXT NOT NULL, sourceEventRef TEXT NOT NULL,
  harness TEXT NOT NULL CHECK (harness IN ('claude','codex','pi','cursor')),
  at INTEGER NOT NULL, assignmentId TEXT, UNIQUE (kind, sourceEventRef)
);
CREATE TABLE IF NOT EXISTS "attests" (
  id TEXT PRIMARY KEY,
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'cannot-proceed', 'verdict')),
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
    (kind IN ('progress', 'completion', 'surrender', 'cannot-proceed') AND verdictKind IS NULL AND (bySession IS NULL OR byUser IS NULL))
    OR
    (kind = 'verdict' AND verdictKind IS NOT NULL AND (bySession IS NULL OR byUser IS NULL))
  ),
  CHECK(producer IS NULL OR kind = 'verdict'),
  CHECK(producerCommand IS NULL OR producer IS NOT NULL),
  CHECK(byHarness IS NULL OR kind = 'verdict'),
  CHECK(byProvider IS NULL OR kind = 'verdict'),
  CHECK((artifactId IS NULL) = (contentSha256 IS NULL)),
  CHECK(artifactId IS NULL OR kind = 'verdict')
);
INSERT INTO attests VALUES('att_00000000-0000-4000-8000-000000000009','asg_00000000-0000-4000-8000-000000000002','progress',NULL,'Fixture progress','agent:fixture:holder',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1735689600000);
CREATE TABLE harness_health_observations (
  id            TEXT PRIMARY KEY,
  correlationId TEXT NOT NULL UNIQUE,
  harness       TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  host          TEXT NOT NULL CHECK(length(trim(host)) > 0),
  failureClass  TEXT NOT NULL CHECK(failureClass IN (
                  'auth-dead','rate-limit-dead','adapter_unavailable','model_unavailable',
                  'task_crash','interrupted-outcome-unknown','other'
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
  description TEXT,
  descriptionDigest TEXT,
  observedState TEXT,
  evidenceMode TEXT CHECK(evidenceMode IS NULL OR evidenceMode IN ('exact_error','probe_digest')),
  exactObservedError TEXT,
  exactProbe TEXT,
  outputDigest TEXT,
  recoveryCondition TEXT,
  recoveryConditionDigest TEXT,
  recoverySatisfied INTEGER CHECK(recoverySatisfied IS NULL OR recoverySatisfied IN (0,1)),
  notKnownClassReason TEXT,
  validUntil INTEGER,
  worldStatus TEXT CHECK(worldStatus IS NULL OR worldStatus IN ('PROVEN','UNKNOWN')),
  redactionConfirmed INTEGER CHECK(redactionConfirmed IS NULL OR redactionConfirmed IN (0,1)),
  CHECK(evidenceKind != 'terminal-failure' OR sessionKey IS NOT NULL),
  CHECK(evidenceKind != 'normal-turn-success' OR incidentId IS NOT NULL),
  CHECK(assignmentId IS NULL OR sessionKey IS NOT NULL),
  CHECK(failureClass != 'other' OR evidenceKind != 'authoritative-provider' OR
    (evidenceKind = 'authoritative-provider' AND
     description IS NOT NULL AND descriptionDigest IS NOT NULL AND
     observedState IS NOT NULL AND exactProbe IS NOT NULL AND
     recoveryCondition IS NOT NULL AND recoveryConditionDigest IS NOT NULL AND
     notKnownClassReason IS NOT NULL AND validUntil IS NOT NULL AND
     worldStatus IS NOT NULL AND redactionConfirmed = 1 AND
     recoverySatisfied IS NULL AND
     ((evidenceMode = 'exact_error' AND exactObservedError IS NOT NULL AND outputDigest IS NULL) OR
      (evidenceMode = 'probe_digest' AND exactObservedError IS NULL AND outputDigest IS NOT NULL)))),
  CHECK(failureClass != 'other' OR evidenceKind != 'normal-turn-success' OR
    (description IS NULL AND exactObservedError IS NULL AND recoveryCondition IS NULL AND
     notKnownClassReason IS NULL AND validUntil IS NULL AND
     observedState IS NOT NULL AND exactProbe IS NOT NULL AND
     evidenceMode = 'probe_digest' AND outputDigest IS NOT NULL AND
     recoveryConditionDigest IS NOT NULL AND recoverySatisfied = 1 AND
     worldStatus = 'PROVEN' AND redactionConfirmed = 1)),
  CHECK(failureClass = 'other' OR
    description IS NULL AND descriptionDigest IS NULL AND observedState IS NULL AND
    evidenceMode IS NULL AND exactObservedError IS NULL AND exactProbe IS NULL AND
    outputDigest IS NULL AND recoveryCondition IS NULL AND recoveryConditionDigest IS NULL AND
    recoverySatisfied IS NULL AND notKnownClassReason IS NULL AND validUntil IS NULL AND
    worldStatus IS NULL AND redactionConfirmed IS NULL)
);
CREATE TABLE harness_health_incidents (
  id                      TEXT PRIMARY KEY,
  harness                 TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  host                    TEXT NOT NULL CHECK(length(trim(host)) > 0),
  failureClass            TEXT NOT NULL CHECK(failureClass IN (
                            'auth-dead','rate-limit-dead','adapter_unavailable',
                            'model_unavailable','task_crash','interrupted-outcome-unknown','other'
                          )),
  state                   TEXT NOT NULL CHECK(state IN ('open','resolved','expired')),
  openedAt                INTEGER NOT NULL CHECK(openedAt >= 0),
  openObservationId       TEXT NOT NULL REFERENCES harness_health_observations(id)
                            DEFERRABLE INITIALLY DEFERRED,
  openedFactId            INTEGER REFERENCES condition_facts(id),
  resolvedAt              INTEGER,
  resolutionObservationId TEXT REFERENCES harness_health_observations(id)
                            DEFERRABLE INITIALLY DEFERRED,
  resolvedFactId          INTEGER REFERENCES condition_facts(id),
  descriptionDigest       TEXT,
  expiresAt               INTEGER,
  expiredAt               INTEGER,
  expiryFactId            INTEGER REFERENCES condition_facts(id),
  CHECK(
    (state = 'open' AND resolvedAt IS NULL AND resolutionObservationId IS NULL AND
     resolvedFactId IS NULL AND expiredAt IS NULL AND expiryFactId IS NULL)
    OR
    (state = 'resolved' AND resolvedAt >= openedAt AND
     resolutionObservationId IS NOT NULL AND expiredAt IS NULL AND
     (failureClass = 'other' OR resolvedFactId IS NOT NULL))
    OR
    (state = 'expired' AND expiredAt >= openedAt AND
     resolvedAt IS NULL AND resolutionObservationId IS NULL AND resolvedFactId IS NULL AND
     (failureClass = 'other' OR expiryFactId IS NOT NULL))
  ),
  CHECK(failureClass != 'other' OR
    (descriptionDigest IS NOT NULL AND expiresAt IS NOT NULL)),
  CHECK(failureClass = 'other' OR
    (descriptionDigest IS NULL AND expiresAt IS NULL AND expiredAt IS NULL AND expiryFactId IS NULL))
);
CREATE TABLE harness_health_members (
  incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  PRIMARY KEY (incidentId, sessionKey)
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
CREATE TABLE harness_health_other_idempotency (
  principalRef TEXT NOT NULL,
  operation TEXT NOT NULL,
  idempotencyKey TEXT NOT NULL,
  requestFingerprint TEXT NOT NULL,
  response TEXT NOT NULL,
  PRIMARY KEY (principalRef, operation, idempotencyKey)
);
CREATE TABLE harness_health_other_reviews (
  incidentId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
  state TEXT NOT NULL CHECK(state IN ('pending','closed')),
  custodian TEXT NOT NULL,
  routeOrdinal INTEGER NOT NULL CHECK(routeOrdinal >= 0),
  outcome TEXT CHECK(outcome IS NULL OR outcome IN ('confirmed_other','reclassified','promotion_required')),
  namedClass TEXT,
  promotionCaseId TEXT,
  reviewer TEXT,
  cause TEXT,
  closedAt INTEGER,
  CHECK(outcome != 'reclassified' OR namedClass IS NOT NULL),
  CHECK(outcome = 'reclassified' OR namedClass IS NULL)
);
CREATE TABLE harness_health_other_routes (
  incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  recipient TEXT NOT NULL,
  targetKind TEXT NOT NULL CHECK(targetKind IN ('session','owner_user')),
  targetRef TEXT NOT NULL,
  relation TEXT NOT NULL CHECK(relation IN ('parent','ancestor','owner_main','owner_user')),
  state TEXT NOT NULL CHECK(state IN ('skipped','pending','delivered','non_delivered','alerted')),
  closedReason TEXT,
  noticeWakeId TEXT,
  turnSeq INTEGER,
  createdAt INTEGER NOT NULL,
  resolvedAt INTEGER,
  settledAt INTEGER,
  CHECK(
    (state = 'skipped' AND closedReason IN ('inactive','foreign_owner','cycle','hop_limit')) OR
    (state = 'non_delivered' AND closedReason IN ('failed','failed_unknown','canceled','target_retired')) OR
    (state IN ('pending','delivered') AND closedReason IS NULL) OR
    (state = 'alerted' AND closedReason = 'no_active_main')
  ),
  PRIMARY KEY (incidentId, ordinal)
);
CREATE TABLE harness_health_class_promotions (
  id TEXT PRIMARY KEY,
  descriptionDigest TEXT NOT NULL UNIQUE,
  firstIncidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  secondIncidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  createdPrincipal TEXT NOT NULL CHECK(createdPrincipal = 'process:tightbeam'),
  state TEXT NOT NULL CHECK(state IN ('open','closed')),
  namedClass TEXT,
  specRef TEXT,
  specSha256 TEXT,
  reviewArtifactId TEXT,
  reviewAttestId TEXT REFERENCES attests(id),
  reviewedClean INTEGER CHECK(reviewedClean IS NULL OR reviewedClean IN (0,1)),
  closedBy TEXT,
  createdAt INTEGER NOT NULL,
  closedAt INTEGER,
  CHECK(
    (state = 'open' AND namedClass IS NULL AND specRef IS NULL AND specSha256 IS NULL AND
     reviewArtifactId IS NULL AND reviewAttestId IS NULL AND reviewedClean IS NULL AND
     closedBy IS NULL AND closedAt IS NULL)
    OR
    (state = 'closed' AND namedClass IS NOT NULL AND specRef IS NOT NULL AND
     specSha256 IS NOT NULL AND reviewArtifactId IS NOT NULL AND reviewAttestId IS NOT NULL AND
     reviewedClean = 1 AND closedBy IS NOT NULL AND closedAt IS NOT NULL)
  )
);
CREATE TABLE harness_health_other_review_events (
  id TEXT PRIMARY KEY,
  incidentId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  eventKind TEXT NOT NULL,
  actor TEXT NOT NULL,
  payload TEXT NOT NULL,
  createdAt INTEGER NOT NULL
);
CREATE TABLE harness_health_prod_suppressions (
  consumerKind TEXT NOT NULL,
  candidateId TEXT NOT NULL,
  harness TEXT NOT NULL,
  host TEXT NOT NULL,
  incidentIds TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  PRIMARY KEY (consumerKind, candidateId, harness, host)
);
CREATE TABLE harness_health_schema_stamp (
  shape TEXT PRIMARY KEY,
  predecessorStamp TEXT NOT NULL,
  predecessorObjectSetSha256 TEXT NOT NULL,
  appliedAt INTEGER NOT NULL
);
INSERT INTO harness_health_schema_stamp VALUES('harness-health-other-v1-019','fresh','c811a7a0584197a7111e317f128b1bd9c08b21450511654b84f691ecc325a150',1735689600000);
CREATE TABLE turn_lifecycle_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  turnSeq      INTEGER NOT NULL REFERENCES turns(seq),
  ordinal      INTEGER NOT NULL,
  at           INTEGER NOT NULL,
  eventKey     TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN (
                 'claimed','prompt_dispatched','terminal_committed'
               )),
  stage        TEXT CHECK (stage IS NULL OR stage IN ('checkout','session','prompt')),
  outcome      TEXT,
  cause        TEXT NOT NULL,
  principal    TEXT NOT NULL,
  ownerLease   TEXT,
  adapterGen   INTEGER,
  acpRequestId INTEGER,
  producerEventId TEXT NOT NULL,
  detail       TEXT NOT NULL DEFAULT '{}',
  UNIQUE (turnSeq, ordinal),
  UNIQUE (turnSeq, eventKey),
  UNIQUE (turnSeq, producerEventId)
);
CREATE TABLE turn_lifecycle_epoch (
  singleton   INTEGER PRIMARY KEY CHECK (singleton = 1),
  firstTurnSeq INTEGER NOT NULL CHECK (firstTurnSeq > 0),
  activatedAt INTEGER NOT NULL
);
INSERT INTO turn_lifecycle_epoch VALUES(1,1,1735689600000);
CREATE TABLE terminal_credential_incidents (
  id                 TEXT PRIMARY KEY,
  class              TEXT NOT NULL CHECK(class = 'terminal_credential_failure'),
  state              TEXT NOT NULL CHECK(state IN ('open','resolved')),
  host               TEXT NOT NULL CHECK(length(trim(host)) > 0),
  harness            TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  provider           TEXT NOT NULL CHECK(length(trim(provider)) > 0),
  openedAt           INTEGER NOT NULL CHECK(openedAt >= 0),
  openingWatermark   INTEGER NOT NULL CHECK(openingWatermark >= 0),
  openingObservationId TEXT NOT NULL UNIQUE,
  assertionFactId    INTEGER NOT NULL,
  statementId        TEXT NOT NULL UNIQUE,
  recoveryState      TEXT NOT NULL CHECK(recoveryState IN ('idle','claimed','outcome_unknown')),
  claimedFactId      INTEGER,
  pendingFactId      INTEGER,
  consumedFactId     INTEGER,
  lastOutcomeClass   TEXT CHECK(lastOutcomeClass IN ('final_401','transient_failure','empty_catalog','catalog_published')),
  resolvedAt         INTEGER,
  resolutionFactId   INTEGER,
  CHECK(
    (state = 'open' AND resolvedAt IS NULL AND resolutionFactId IS NULL)
    OR
    (state = 'resolved' AND resolvedAt >= openedAt AND resolutionFactId IS NOT NULL)
  ),
  CHECK(
    (recoveryState = 'idle' AND claimedFactId IS NULL)
    OR
    (recoveryState IN ('claimed','outcome_unknown') AND claimedFactId IS NOT NULL)
  ),
  CHECK(pendingFactId IS NULL OR pendingFactId > openingWatermark),
  CHECK(consumedFactId IS NULL OR consumedFactId > openingWatermark)
);
CREATE TABLE terminal_credential_observations (
  id            TEXT PRIMARY KEY,
  correlationId TEXT NOT NULL UNIQUE,
  incidentId    TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
  kind          TEXT NOT NULL CHECK(kind IN (
                  'opening','suppression-activated','recovery-claim',
                  'recovery-outcome','resolution'
                )),
  sourceKind    TEXT NOT NULL CHECK(length(trim(sourceKind)) > 0),
  principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
  factId        INTEGER,
  outcomeClass  TEXT CHECK(outcomeClass IN (
                  'final_401','transient_failure','empty_catalog','catalog_published'
                )),
  observedAt    INTEGER NOT NULL CHECK(observedAt >= 0)
);
CREATE TABLE terminal_credential_redirects (
  incidentId      TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
  requestIdentity TEXT NOT NULL CHECK(length(trim(requestIdentity)) > 0),
  destinationHost TEXT NOT NULL CHECK(length(trim(destinationHost)) > 0),
  observedAt      INTEGER NOT NULL CHECK(observedAt >= 0),
  PRIMARY KEY(incidentId, requestIdentity)
);
CREATE TABLE terminal_credential_deliveries (
  statementId TEXT NOT NULL,
  incidentId  TEXT NOT NULL REFERENCES terminal_credential_incidents(id),
  adminUserId TEXT NOT NULL REFERENCES users(userId),
  state       TEXT NOT NULL CHECK(state IN ('pending','delivered','resolved')),
  messageId   TEXT,
  updatedAt   INTEGER NOT NULL CHECK(updatedAt >= 0),
  PRIMARY KEY(statementId, adminUserId),
  UNIQUE(messageId),
  CHECK(
    (state = 'pending' AND messageId IS NULL)
    OR (state = 'delivered' AND messageId IS NOT NULL)
    OR state = 'resolved'
  )
);
CREATE TABLE read_markers (
  userId    TEXT NOT NULL,
  scopeKey  TEXT NOT NULL,
  marker,
  updatedAt INTEGER NOT NULL,
  PRIMARY KEY (userId, scopeKey)
);
CREATE TABLE sentinel_states (
  host          TEXT NOT NULL,
  sentinel      TEXT NOT NULL,
  state         TEXT NOT NULL CHECK (state IN ('enabled', 'disabled', 'stopped')),
  enabledBy     TEXT,
  commandSha256 TEXT,
  startedAt     INTEGER,
  reason        TEXT,
  updatedAt     INTEGER NOT NULL,
  PRIMARY KEY (host, sentinel)
);
CREATE TABLE sentinel_subscriptions (
  subscriptionId TEXT PRIMARY KEY,
  sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  event TEXT NOT NULL,
  filter TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  endedAt INTEGER
, mode TEXT NOT NULL DEFAULT 'standing', afterFact INTEGER NOT NULL DEFAULT 0, fallbackMs INTEGER, fallbackAt INTEGER, fulfilledAt INTEGER);
CREATE TABLE sentinel_subscription_wake_matches (
  wakeId TEXT NOT NULL REFERENCES wakes(wakeId) ON DELETE CASCADE,
  subscriptionId TEXT NOT NULL REFERENCES sentinel_subscriptions(subscriptionId),
  PRIMARY KEY (wakeId, subscriptionId)
);
CREATE TABLE subscription_schema (version INTEGER PRIMARY KEY);
INSERT INTO subscription_schema VALUES(1);
CREATE TABLE subtree_guidance_entries (
  writerSessionKey TEXT NOT NULL,
  name             TEXT NOT NULL,
  archetypes       TEXT,
  text             TEXT NOT NULL,
  createdAt        INTEGER NOT NULL,
  updatedAt        INTEGER NOT NULL,
  PRIMARY KEY (writerSessionKey, name)
);
CREATE TABLE artifact_custody (
  artifactId TEXT PRIMARY KEY REFERENCES artifacts(artifactId),
  status TEXT NOT NULL CHECK (status IN ('pinned','unpinned','external_pointer'))
);
CREATE TABLE turn_clear_attempts (
  sessionKey         TEXT NOT NULL,
  idempotencyKey     TEXT NOT NULL,
  turnSeq            INTEGER NOT NULL REFERENCES turns(seq),
  requestFingerprint TEXT NOT NULL CHECK(length(trim(requestFingerprint)) > 0),
  principal          TEXT NOT NULL CHECK(length(trim(principal)) > 0),
  createdAt          INTEGER NOT NULL CHECK(createdAt >= 0),
  PRIMARY KEY (sessionKey, idempotencyKey)
);
CREATE TABLE supervision_receipt_cancellation_epoch (
  id INTEGER PRIMARY KEY CHECK(id = 0),
  shape TEXT NOT NULL CHECK(shape = 'supervision-receipt-cancellation-v1-019'),
  activatedAt INTEGER NOT NULL CHECK(activatedAt >= 0),
  principal TEXT NOT NULL CHECK(principal = 'process:tightbeam')
);
INSERT INTO supervision_receipt_cancellation_epoch VALUES(0,'supervision-receipt-cancellation-v1-019',1735689600000,'process:tightbeam');
CREATE TABLE wake_cancellations (
  wakeId TEXT PRIMARY KEY,
  wakeState TEXT NOT NULL DEFAULT 'canceled' CHECK (wakeState = 'canceled'),
  canceledAt INTEGER NOT NULL CHECK (canceledAt >= 0),
  requesterKind TEXT NOT NULL CHECK (requesterKind IN ('user','session','process')),
  requesterId TEXT NOT NULL,
  reasonKind TEXT NOT NULL CHECK (reasonKind IN (
    'requester_withdrew','superseded','obligation_disposed','cannot_proceed_released',
    'routing_bracket_satisfied','target_retired','production_unmatched',
    'consumer_unavailable','target_unresolvable','condition_cleared'
  )),
  causalSourceKind TEXT NOT NULL CHECK (causalSourceKind IN (
    'verb_call','wake','progress_attest','condition_fact','assignment_transition',
    'work_item_transition','decision_request','monitor_generation','routing_bracket',
    'session_transition','scheduler_delivery','retirement_transition','sentinel_transition','harness_health_transition','supervision_receipt'
  )),
  causalSourceId TEXT NOT NULL,
  outcomeKind TEXT NOT NULL CHECK (
    outcomeKind IN ('replacement','disposition','no_replacement')
  ),
  replacementWakeId TEXT REFERENCES wakes(wakeId) DEFERRABLE INITIALLY DEFERRED,
  dispositionKind TEXT CHECK (dispositionKind IN (
    'assignment_transition','work_item_transition',
    'decision_request_transition','monitor_generation_transition','retirement_transition'
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
        (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:assignments' AND reasonKind = 'obligation_disposed' AND
   causalSourceKind = 'assignment_transition' AND dispositionKind = 'assignment_transition' AND
   causalSourceId = dispositionId)
  OR
  (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:escalation' AND reasonKind = 'obligation_disposed' AND
   causalSourceKind = 'decision_request' AND dispositionKind = 'decision_request_transition' AND
   causalSourceId = dispositionId)
  OR
  (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:retirement' AND reasonKind = 'obligation_disposed' AND
   causalSourceKind = 'assignment_transition' AND dispositionKind = 'assignment_transition' AND
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
      (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND requesterId = 'tightbeam:effort-checkin' AND reasonKind = 'superseded' AND causalSourceKind = 'progress_attest') OR
              (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:retirement' AND reasonKind = 'target_retired' AND
   causalSourceKind = 'session_transition')
  OR
  (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:assignments' AND reasonKind = 'cannot_proceed_released' AND
   causalSourceKind = 'condition_fact')
  OR
  (workImpactKind = 'linked_work_open' AND livenessTriggerKind IS NULL AND
   livenessTriggerId IS NULL AND actionNeeded = 0 AND requesterKind = 'process' AND
   requesterId = 'tightbeam:sentinel-supervisor' AND reasonKind = 'condition_cleared' AND
   causalSourceKind = 'sentinel_transition')
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
     ((reasonKind = 'obligation_disposed' AND
       causalSourceKind = 'assignment_transition' AND outcomeKind = 'disposition')
      OR
      (reasonKind = 'cannot_proceed_released' AND
       causalSourceKind = 'condition_fact' AND outcomeKind = 'no_replacement')))

      OR
      (requesterId = 'tightbeam:assignments' AND reasonKind = 'superseded' AND
 causalSourceKind = 'wake' AND outcomeKind = 'replacement')
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
    (requesterId = 'tightbeam:effort-checkin' AND reasonKind = 'superseded' AND
     causalSourceKind = 'progress_attest' AND outcomeKind = 'no_replacement')
    OR
    (requesterId = 'tightbeam:escalation' AND reasonKind = 'obligation_disposed' AND causalSourceKind = 'decision_request' AND outcomeKind = 'disposition')
    OR
    (requesterId = 'tightbeam:sentinel-supervisor' AND reasonKind = 'condition_cleared' AND causalSourceKind = 'sentinel_transition' AND outcomeKind = 'no_replacement')
    OR
    (requesterId = 'tightbeam:harness-health' AND reasonKind = 'condition_cleared' AND causalSourceKind = 'harness_health_transition' AND outcomeKind = 'no_replacement')
    OR
    (requesterId = 'tightbeam:row-reactions' AND reasonKind = 'superseded' AND causalSourceKind = 'wake' AND outcomeKind = 'no_replacement')
 OR
 (requesterId = 'tightbeam:supervision' AND reasonKind = 'superseded' AND
     causalSourceKind IN ('progress_attest','supervision_receipt') AND outcomeKind = 'no_replacement')
    OR
    -- The batcher consumes exactly one member by naming the digest wake
    -- that replaces it. No other cancellation shape is admitted.
    (requesterId = 'tightbeam:batcher' AND reasonKind = 'superseded' AND
     causalSourceKind = 'wake' AND outcomeKind = 'replacement')
    OR
    (requesterId = 'tightbeam:retirement' AND reasonKind = 'obligation_disposed' AND causalSourceKind = 'retirement_transition' AND outcomeKind = 'disposition' AND dispositionKind = 'retirement_transition' AND causalSourceId = dispositionId) OR (requesterId = 'tightbeam:retirement' AND
       ((reasonKind = 'target_retired' AND causalSourceKind = 'session_transition' AND
         outcomeKind IN ('replacement','no_replacement'))
        OR
        (reasonKind = 'obligation_disposed' AND
         causalSourceKind = 'assignment_transition' AND outcomeKind = 'disposition')))
    ))
  )
);
INSERT INTO wake_cancellations VALUES('w_reaction_0000000000000000000000000000000000000000000000000000000000000003','canceled',1735689600000,'process','tightbeam:work-items','routing_bracket_satisfied','assignment_transition','asg_00000000-0000-4000-8000-000000000002','disposition',NULL,'assignment_transition','asg_00000000-0000-4000-8000-000000000002','work_item','wi_00000000-0000-4000-8000-000000000003','linked_work_open','routing_bracket','wi_00000000-0000-4000-8000-000000000003',1);
CREATE TABLE queued_message_replacement_requests (
  wakeId       TEXT PRIMARY KEY REFERENCES wakes(wakeId) ON DELETE RESTRICT,
  assignmentId TEXT NOT NULL REFERENCES assignments(id) ON DELETE RESTRICT,
  requestedAt  INTEGER NOT NULL CHECK(requestedAt >= 0)
);
CREATE TABLE queued_message_prod_requests (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId) ON DELETE RESTRICT,
  recipientSessionKey TEXT NOT NULL,
  senderKind TEXT NOT NULL,
  senderId TEXT NOT NULL,
  prodId TEXT NOT NULL,
  requestedAt INTEGER NOT NULL CHECK(requestedAt >= 0)
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
  chatMessageFormat TEXT CHECK (
    chatMessageFormat IS NULL OR chatMessageFormat = 'member-rows-v1'
  ),
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
CREATE TABLE notice_batch_members (
  memberId TEXT PRIMARY KEY,
  batchId TEXT NOT NULL REFERENCES notice_batches(batchId),
  sourceWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
  policyRef TEXT NOT NULL,
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
CREATE TABLE row_reaction_events (
  org TEXT NOT NULL, eventId TEXT NOT NULL, version INTEGER NOT NULL CHECK(version=1),
  event TEXT NOT NULL, facts TEXT NOT NULL, admittedAt INTEGER NOT NULL,
  PRIMARY KEY(org,eventId)
);
INSERT INTO row_reaction_events VALUES('fixture','work-item:wi_00000000-0000-4000-8000-000000000003:created:work_item:wi_00000000-0000-4000-8000-000000000003',1,'{"after":{"createdAt":1735689600000,"createdBySession":"agent:fixture:opener","createdByUser":null,"createdContextKnown":1,"deliveryOwnerSessionKey":null,"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","routingWakeId":null,"slateWakeId":null,"state":"open","title":"Fixture work"},"at":1735689600000,"before":{"deliveredWakeId":null,"sourceRow":null,"workItem":null},"generation":"wi_00000000-0000-4000-8000-000000000003","id":"work-item:wi_00000000-0000-4000-8000-000000000003:created:work_item:wi_00000000-0000-4000-8000-000000000003","kind":"work_item_observation","operation":"created","org":"fixture","principal":{"id":"agent:fixture:opener","kind":"session"},"source":{"id":"wi_00000000-0000-4000-8000-000000000003","kind":"work_item"},"sourceAfter":{"createdAt":1735689600000,"createdBySession":"agent:fixture:opener","createdByUser":null,"createdContextKnown":1,"deliveryOwnerSessionKey":null,"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","routingWakeId":null,"slateWakeId":null,"state":"open","title":"Fixture work"},"transition":null,"workItemId":"wi_00000000-0000-4000-8000-000000000003"}','{"configured_triage_deadline_ms":null,"open_assignment_count":0,"personal_session_key":"agent:main:clawline:fixture:main","scope_participant_archetypes":["default"],"scope_record_session_groups":[[]],"sessions":[{"archetype":"default","ownerUserId":"fixture","sessionKey":"agent:fixture:opener","state":"active"}],"work_item":{"createdAt":1735689600000,"createdBySession":"agent:fixture:opener","createdByUser":null,"createdContextKnown":1,"deliveryOwnerSessionKey":null,"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","routingWakeId":null,"slateWakeId":null,"state":"open","title":"Fixture work"}}',1735689600000);
INSERT INTO row_reaction_events VALUES('fixture','work-item:wi_00000000-0000-4000-8000-000000000003:transition:assignment_transition:asg_00000000-0000-4000-8000-000000000002',1,'{"after":{"createdAt":1735689600000,"createdBySession":"agent:fixture:opener","createdByUser":null,"createdContextKnown":1,"deliveryOwnerSessionKey":null,"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","routingWakeId":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","slateWakeId":null,"state":"open","title":"Fixture work"},"at":1735689600000,"before":{"deliveredWakeId":null,"sourceRow":null,"workItem":null},"generation":"asg_00000000-0000-4000-8000-000000000002","id":"work-item:wi_00000000-0000-4000-8000-000000000003:transition:assignment_transition:asg_00000000-0000-4000-8000-000000000002","kind":"work_item_observation","operation":"transition","org":"fixture","principal":{"id":"agent:fixture:opener","kind":"session"},"source":{"id":"asg_00000000-0000-4000-8000-000000000002","kind":"assignment_transition"},"sourceAfter":{"closedAt":null,"closedByProcess":null,"closedBySession":null,"closedByUser":null,"closingAttestId":null,"currentOpenerSessionKey":null,"holderKey":"agent:fixture:holder","id":"asg_00000000-0000-4000-8000-000000000002","openedAt":1735689600000,"openedBySession":"agent:fixture:opener","openedByUser":null,"outcome":null,"reviewsAssignmentId":null,"state":"open","workItemId":"wi_00000000-0000-4000-8000-000000000003"},"transition":{"causal_source":{"id":"asg_00000000-0000-4000-8000-000000000002","kind":"assignment_transition"},"outcome":{"disposition_id":"asg_00000000-0000-4000-8000-000000000002","disposition_kind":"assignment_transition","kind":"disposition","liveness_trigger":{"id":"wi_00000000-0000-4000-8000-000000000003","kind":"routing_bracket"}}},"workItemId":"wi_00000000-0000-4000-8000-000000000003"}','{"configured_triage_deadline_ms":null,"open_assignment_count":1,"personal_session_key":"agent:main:clawline:fixture:main","scope_participant_archetypes":["default"],"scope_record_session_groups":[[]],"sessions":[{"archetype":"default","ownerUserId":"fixture","sessionKey":"agent:fixture:opener","state":"active"}],"work_item":{"createdAt":1735689600000,"createdBySession":"agent:fixture:opener","createdByUser":null,"createdContextKnown":1,"deliveryOwnerSessionKey":null,"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","routingWakeId":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","slateWakeId":null,"state":"open","title":"Fixture work"}}',1735689600000);
INSERT INTO row_reaction_events VALUES('fixture','attest:att_00000000-0000-4000-8000-000000000009',1,'{"after":{"assignment":{"closedAt":null,"closedByProcess":null,"closedBySession":null,"closedByUser":null,"closingAttestId":null,"currentOpenerSessionKey":null,"holderKey":"agent:fixture:holder","id":"asg_00000000-0000-4000-8000-000000000002","openedAt":1735689600000,"openedBySession":"agent:fixture:opener","openedByUser":null,"outcome":null,"reviewsAssignmentId":null,"state":"open","workItemId":"wi_00000000-0000-4000-8000-000000000003"},"attest":{"artifactId":null,"assignmentId":"asg_00000000-0000-4000-8000-000000000002","byHarness":null,"byProvider":null,"bySession":"agent:fixture:holder","byUser":null,"commitRefs":null,"contentSha256":null,"id":"att_00000000-0000-4000-8000-000000000009","kind":"progress","note":"Fixture progress","producer":null,"producerCommand":null,"ts":1735689600000,"verdictKind":null,"waitId":null},"inserted":true,"lateRequestId":null},"at":1735689600000,"before":{"assignment":{"closedAt":null,"closedByProcess":null,"closedBySession":null,"closedByUser":null,"closingAttestId":null,"currentOpenerSessionKey":null,"holderKey":"agent:fixture:holder","id":"asg_00000000-0000-4000-8000-000000000002","openedAt":1735689600000,"openedBySession":"agent:fixture:opener","openedByUser":null,"outcome":null,"reviewsAssignmentId":null,"state":"open","workItemId":"wi_00000000-0000-4000-8000-000000000003"},"attest":null},"generation":"att_00000000-0000-4000-8000-000000000009","id":"attest:att_00000000-0000-4000-8000-000000000009","kind":"assignment_attest","org":"fixture","principal":{"id":"agent:fixture:holder","kind":"session"},"source":{"id":"att_00000000-0000-4000-8000-000000000009","kind":"attest"}}','{"assignment":{"closedAt":null,"closedByProcess":null,"closedBySession":null,"closedByUser":null,"closingAttestId":null,"currentOpenerSessionKey":null,"holderKey":"agent:fixture:holder","id":"asg_00000000-0000-4000-8000-000000000002","openedAt":1735689600000,"openedBySession":"agent:fixture:opener","openedByUser":null,"outcome":null,"reviewsAssignmentId":null,"state":"open","workItemId":"wi_00000000-0000-4000-8000-000000000003"},"assignment_owner_user_id":"fixture","personal_session_key":"agent:main:clawline:fixture:main","process_notification_recipient":null,"request":null,"ruling_result_recipients":[],"scope_participant_archetypes":["default"],"scope_record_session_groups":[[]],"sessions":[{"archetype":"default","ownerUserId":"fixture","sessionKey":"agent:fixture:holder","state":"active"},{"archetype":"default","ownerUserId":"fixture","sessionKey":"agent:fixture:opener","state":"active"}],"work_item":{"id":"wi_00000000-0000-4000-8000-000000000003","ownerUserId":"fixture","state":"open"}}',1735689600000);
CREATE TABLE row_reaction_actions (
  id TEXT PRIMARY KEY, org TEXT NOT NULL, eventId TEXT NOT NULL,
  family TEXT NOT NULL, slot TEXT NOT NULL, plan TEXT NOT NULL,
  payloadDigest TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','accepted','canceled','held')),
  result TEXT, attempts INTEGER NOT NULL DEFAULT 0, lastError TEXT, updatedAt INTEGER NOT NULL,
  UNIQUE(org,family,eventId,slot),
  FOREIGN KEY(org,eventId) REFERENCES row_reaction_events(org,eventId)
);
INSERT INTO row_reaction_actions VALUES('reaction_0000000000000000000000000000000000000000000000000000000000000002','fixture','work-item:wi_00000000-0000-4000-8000-000000000003:created:work_item:wi_00000000-0000-4000-8000-000000000003','r04-work-item','notice','{"value":{"arguments":{"title":"Fixture work","work_item_id":"wi_00000000-0000-4000-8000-000000000003"},"due_at":1735776000000,"on_unavailable":"schedule","origin":"process:tightbeam","owner_user_id":"fixture","reference":{"expected":null,"field":"routingWakeId","id":"wi_00000000-0000-4000-8000-000000000003","resource":"work_item"},"sender_scheduled":true,"session_key":"agent:main:clawline:fixture:main","template":"work-item-routing","wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","work_item_id":"wi_00000000-0000-4000-8000-000000000003"},"slot":"notice","family":"r04-work-item","selected":true,"kind":"notice","identity":["fixture","r04-work-item","work-item:wi_00000000-0000-4000-8000-000000000003:created:work_item:wi_00000000-0000-4000-8000-000000000003","notice"],"withdraw":null,"rule":"r04-work-item-notice","provenance":{"bundle":"substrate","content_sha256":"0000000000000000000000000000000000000000000000000000000000000004","revision":"6dae81361d9c8284ae2f67b313a0f082c528b00f","source":"rules/row-reaction-work-items.toml"},"source_event_id":"work-item:wi_00000000-0000-4000-8000-000000000003:created:work_item:wi_00000000-0000-4000-8000-000000000003"}','0000000000000000000000000000000000000000000000000000000000000005','pending','{"delivery":"queued","emitted":{"due_at":1735776000000,"origin":"process:tightbeam","owner_user_id":"fixture","prompt":"route it or icebox it — work item wi_00000000-0000-4000-8000-000000000003: Fixture work","sender_scheduled":true,"session_key":"agent:main:clawline:fixture:main","wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","work_item_id":"wi_00000000-0000-4000-8000-000000000003"},"intent_wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","requested_due_at":1735776000000,"wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003"}',1,NULL,1735689600000);
INSERT INTO row_reaction_actions VALUES('reaction_0000000000000000000000000000000000000000000000000000000000000006','fixture','work-item:wi_00000000-0000-4000-8000-000000000003:transition:assignment_transition:asg_00000000-0000-4000-8000-000000000002','r04-work-item-withdraw','withdraw','{"value":{"reference":{"expected":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","field":"routingWakeId","id":"wi_00000000-0000-4000-8000-000000000003","resource":"work_item"},"session_key":"agent:main:clawline:fixture:main","wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003","withdraw":{"outcome":{"disposition_id":"asg_00000000-0000-4000-8000-000000000002","disposition_kind":"assignment_transition","kind":"disposition","liveness_trigger":{"id":"wi_00000000-0000-4000-8000-000000000003","kind":"routing_bracket"}},"reason_kind":"routing_bracket_satisfied","requester_id":"tightbeam:work-items","source_id":"asg_00000000-0000-4000-8000-000000000002","source_kind":"assignment_transition"}},"slot":"withdraw","family":"r04-work-item-withdraw","selected":true,"kind":"cancel_notice","identity":["fixture","r04-work-item-withdraw","work-item:wi_00000000-0000-4000-8000-000000000003:transition:assignment_transition:asg_00000000-0000-4000-8000-000000000002","withdraw"],"withdraw":null,"rule":"r04-work-item-withdraw","provenance":{"bundle":"substrate","content_sha256":"0000000000000000000000000000000000000000000000000000000000000004","revision":"6dae81361d9c8284ae2f67b313a0f082c528b00f","source":"rules/row-reaction-work-items.toml"},"source_event_id":"work-item:wi_00000000-0000-4000-8000-000000000003:transition:assignment_transition:asg_00000000-0000-4000-8000-000000000002"}','0000000000000000000000000000000000000000000000000000000000000007','accepted','{"canceled_wake_id":"w_reaction_0000000000000000000000000000000000000000000000000000000000000003"}',1,NULL,1735689600000);
CREATE TABLE row_reaction_cutovers (
  source TEXT PRIMARY KEY, watermark TEXT NOT NULL, adoptedAt INTEGER NOT NULL,
  heldCount INTEGER NOT NULL
);
INSERT INTO row_reaction_cutovers VALUES('terminal-notices/v1','{"wakeRowid":0}',1735689600000,0);
INSERT INTO row_reaction_cutovers VALUES('terminal-notices/pending-adoption/v1','{"wakeRowid":0}',1735689600000,0);
INSERT INTO row_reaction_cutovers VALUES('assignment-attest-notices/v1','{"wakeRowid":0}',1735689600000,0);
INSERT INTO row_reaction_cutovers VALUES('work-item-references/v1','{"wakeRowid":0}',1735689600000,0);
CREATE TABLE record_fyis (
  recordKind TEXT NOT NULL CHECK (recordKind IN ('attest','assignment','session','decision_request','harness_health_promotion','harness_health_review')),
  recordId   TEXT NOT NULL,
  fyi        TEXT NOT NULL CHECK (json_valid(fyi) AND json_type(fyi) = 'array'),
  createdAt  INTEGER NOT NULL,
  PRIMARY KEY (recordKind, recordId)
);
CREATE TABLE harness_health_recovery_schedules (
  holdId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
  org TEXT NOT NULL,
  family TEXT NOT NULL,
  slot TEXT NOT NULL,
  sourceEventId TEXT NOT NULL,
  cycleId TEXT NOT NULL UNIQUE,
  failureClass TEXT NOT NULL,
  eligibleClasses TEXT NOT NULL,
  intervalMs INTEGER NOT NULL CHECK(intervalMs > 0),
  timeoutMs INTEGER NOT NULL CHECK(timeoutMs > 0),
  policyDigest TEXT NOT NULL,
  dueAt INTEGER NOT NULL CHECK(dueAt >= 0),
  startedAt INTEGER,
  previousStartedAt INTEGER,
  status TEXT NOT NULL CHECK(status IN ('pending','due','withdrawn','completed')),
  createdAt INTEGER NOT NULL CHECK(createdAt >= 0),
  updatedAt INTEGER NOT NULL CHECK(updatedAt >= 0),
  UNIQUE(org,family,sourceEventId,slot)
);
CREATE TABLE harness_health_recovery_checks (
  holdId TEXT NOT NULL REFERENCES harness_health_incidents(id),
  cycleId TEXT NOT NULL,
  routeKey TEXT NOT NULL,
  routeJson TEXT NOT NULL,
  harness TEXT NOT NULL,
  host TEXT NOT NULL,
  sharedAccount TEXT NOT NULL,
  model TEXT NOT NULL,
  startedAt INTEGER NOT NULL CHECK(startedAt >= 0),
  finishedAt INTEGER,
  outcome TEXT NOT NULL CHECK(outcome IN ('running','succeeded','failed','inconclusive','uncheckable')),
  errorExcerpt TEXT,
  eventId TEXT NOT NULL UNIQUE,
  org TEXT NOT NULL,
  PRIMARY KEY(holdId,cycleId,routeKey),
  CHECK((outcome='running' AND finishedAt IS NULL) OR
        (outcome!='running' AND finishedAt IS NOT NULL)),
  CHECK(errorExcerpt IS NULL OR length(errorExcerpt) <= 512)
);
CREATE TABLE harness_health_recovery_warnings (
  holdId TEXT PRIMARY KEY REFERENCES harness_health_incidents(id),
  reason TEXT NOT NULL,
  eventId TEXT NOT NULL UNIQUE,
  createdAt INTEGER NOT NULL CHECK(createdAt >= 0)
);
CREATE TABLE harness_recovery_notices (
  holdId TEXT NOT NULL,
  ownerUserId TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('awaiting_main','attempting','delivered','canceled')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
  wakeId TEXT,
  turnSeq INTEGER,
  lastOutcome TEXT,
  canceledBy TEXT,
  prompt TEXT NOT NULL,
  failedRoutesJson TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  PRIMARY KEY(holdId,ownerUserId),
  CHECK(state != 'attempting' OR wakeId IS NOT NULL),
  CHECK(state != 'delivered' OR turnSeq IS NOT NULL)
);
CREATE TABLE IF NOT EXISTS "wake_retry_attempts" (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  rootWakeId TEXT NOT NULL REFERENCES wakes(wakeId),
  predecessorWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
  attempt INTEGER NOT NULL CHECK (attempt >= 0),
  sourceTurnSeq INTEGER REFERENCES turns(seq),
  outcome TEXT NOT NULL CHECK (outcome IN ('pending','failed','acted','canceled')),
  retryWakeId TEXT UNIQUE REFERENCES wakes(wakeId),
  observedAt INTEGER NOT NULL,
  UNIQUE (rootWakeId, attempt), UNIQUE (rootWakeId, sourceTurnSeq)
);
CREATE TABLE wake_delivery_backfill (
  id INTEGER PRIMARY KEY CHECK(id=0),
  afterRowid INTEGER NOT NULL,
  throughRowid INTEGER NOT NULL,
  startedAt INTEGER NOT NULL,
  completedAt INTEGER
);
INSERT INTO wake_delivery_backfill VALUES(0,0,0,1735689600000,1735689600000);
CREATE TABLE hot_query_indexes_migration (
  id INTEGER PRIMARY KEY CHECK(id=0),
  appliedAt INTEGER NOT NULL CHECK(appliedAt >= 0)
);
INSERT INTO hot_query_indexes_migration VALUES(0,1735689600000);
CREATE TABLE retired_workspace_cleanup_migration (id INTEGER PRIMARY KEY CHECK(id=0));
INSERT INTO retired_workspace_cleanup_migration VALUES(0);
CREATE TABLE retired_workspace_cleanup (
  sessionKey TEXT PRIMARY KEY, completed INTEGER NOT NULL DEFAULT 0,
  nextAt INTEGER NOT NULL DEFAULT 0, archivePath TEXT, report TEXT,
  reason TEXT, attempts INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE ephemeral_migration (
  id INTEGER PRIMARY KEY CHECK(id=0)
);
INSERT INTO ephemeral_migration VALUES(0);
CREATE TABLE ephemeral_sessions (
  sessionKey TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
  callerSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  turnUsed INTEGER NOT NULL DEFAULT 0 CHECK(turnUsed IN (0,1))
);
CREATE TABLE cron_wake_migration (
  id INTEGER PRIMARY KEY CHECK(id=0),
  appliedAt INTEGER NOT NULL
);
INSERT INTO cron_wake_migration VALUES(0,1735689600000);
CREATE TABLE cron_wake_schedules (
  wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
  schedule TEXT NOT NULL
);
CREATE TABLE pending_recognition (
  id TEXT PRIMARY KEY,
  version INTEGER NOT NULL CHECK(version = 1),
  payload BLOB NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  nextAt INTEGER NOT NULL,
  flagged INTEGER NOT NULL DEFAULT 0 CHECK(flagged IN (0,1))
);
CREATE TABLE pending_recognition_waits (
  recognitionId TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  scope TEXT NOT NULL,
  FOREIGN KEY (recognitionId) REFERENCES pending_recognition(id) ON DELETE CASCADE
);
CREATE TABLE effort_holder_activity_cancellation_epoch (
  id INTEGER PRIMARY KEY CHECK(id = 0),
  shape TEXT NOT NULL CHECK(shape = 'effort-holder-activity-cancellation-v1-019'),
  activatedAt INTEGER NOT NULL CHECK(activatedAt >= 0),
  principal TEXT NOT NULL CHECK(principal = 'process:tightbeam')
);
INSERT INTO effort_holder_activity_cancellation_epoch VALUES(0,'effort-holder-activity-cancellation-v1-019',1735689600000,'process:tightbeam');
CREATE TABLE memento_history (
  id INTEGER PRIMARY KEY,
  recordKind TEXT NOT NULL CHECK(recordKind IN ('work_item','assignment','attest')),
  recordId TEXT NOT NULL,
  name TEXT NOT NULL,
  valueJson TEXT NOT NULL,
  byKind TEXT NOT NULL ,
  byRef TEXT NOT NULL,
  identityRevision TEXT NOT NULL,
  ts INTEGER NOT NULL
);
CREATE TABLE memento_current (
  recordKind TEXT NOT NULL,
  recordId TEXT NOT NULL,
  name TEXT NOT NULL,
  valueJson TEXT NOT NULL,
  historyId INTEGER NOT NULL REFERENCES memento_history(id),
  PRIMARY KEY(recordKind,recordId,name)
) WITHOUT ROWID;
CREATE TABLE memento_judgments (
  assignmentId TEXT NOT NULL REFERENCES assignments(id),
  selector TEXT NOT NULL CHECK(selector IN ('holder','linked_review')),
  ts INTEGER NOT NULL,
  attestRow INTEGER NOT NULL,
  attestId TEXT NOT NULL REFERENCES attests(id),
  judgmentKind TEXT,
  independent INTEGER NOT NULL CHECK(independent IN (0,1)),
  PRIMARY KEY(assignmentId,selector,ts,attestRow)
) WITHOUT ROWID;
CREATE TABLE memento_judgment_index_version (
  version INTEGER PRIMARY KEY CHECK(version=1)
);
INSERT INTO memento_judgment_index_version VALUES(1);
CREATE TABLE tool_call_transition_migration (
  id        INTEGER PRIMARY KEY CHECK (id = 0),
  shape     TEXT NOT NULL CHECK (shape = 'tool-call-transition-v1-011'),
  appliedAt INTEGER NOT NULL CHECK (appliedAt >= 0)
);
INSERT INTO tool_call_transition_migration VALUES(0,'tool-call-transition-v1-011',1735689600000);
CREATE TABLE IF NOT EXISTS "messages" (
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
    markerKind IS NULL OR markerKind IN ('harness-switch','model-retune','session-restart','context-compacted')
  ),
  markerFrom             TEXT,
  markerTo               TEXT, submitter TEXT, recordEventIds TEXT,
  CHECK (
    (messageType IS 'marker' AND markerKind IS NOT NULL AND markerFrom IS NOT NULL AND markerTo IS NOT NULL)
    OR
    (messageType IS NOT 'marker' AND markerKind IS NULL AND markerFrom IS NULL AND markerTo IS NULL)
  )
);
INSERT INTO messages VALUES(1,'s_00000000-0000-4000-8000-00000000000a','agent:fixture:holder','assistant','[assignment opened: asg_00000000-0000-4000-8000-000000000002]',1735689600000,'process:tightbeam',NULL,NULL,NULL,NULL,'s_00000000-0000-4000-8000-00000000000a','[]',0,'substrate',NULL,NULL,NULL,NULL,'["assignment.opened:asg_00000000-0000-4000-8000-000000000002"]');
INSERT INTO messages VALUES(2,'s_00000000-0000-4000-8000-00000000000b','agent:fixture:holder','assistant','[progress filed on asg_00000000-0000-4000-8000-000000000002: Fixture progress]',1735689600000,'process:tightbeam',NULL,NULL,NULL,NULL,'s_00000000-0000-4000-8000-00000000000b','[]',0,'substrate',NULL,NULL,NULL,NULL,NULL);
CREATE TABLE tool_calls (
  seq               INTEGER PRIMARY KEY AUTOINCREMENT,
  id                TEXT NOT NULL UNIQUE,
  sessionKey        TEXT NOT NULL REFERENCES sessions(sessionKey),
  turnSeq           INTEGER NOT NULL REFERENCES turns(seq),
  afterMessageSeq   INTEGER NOT NULL CHECK (afterMessageSeq >= 0),
  harnessToolCallId TEXT NOT NULL CHECK (length(harnessToolCallId) > 0),
  title             TEXT NOT NULL,
  kind              TEXT NOT NULL,
  toolName          TEXT,
  status            TEXT NOT NULL CHECK (status IN ('pending','in_progress','completed','failed')),
  rawInput          TEXT CHECK (rawInput IS NULL OR json_valid(rawInput)),
  rawOutput         TEXT CHECK (rawOutput IS NULL OR json_valid(rawOutput)),
  content           TEXT CHECK (content IS NULL OR json_valid(content)),
  truncated         TEXT NOT NULL CHECK (json_valid(truncated)),
  startedAt         INTEGER NOT NULL CHECK (startedAt >= 0),
  endedAt           INTEGER,
  rowVersion        INTEGER NOT NULL CHECK (rowVersion > 0),
  UNIQUE (sessionKey, harnessToolCallId),
  CHECK (
    (status IN ('completed','failed') AND endedAt IS NOT NULL)
    OR
    (status IN ('pending','in_progress') AND endedAt IS NULL)
  )
);
CREATE TABLE tool_call_full_outputs (
  toolCallId TEXT PRIMARY KEY REFERENCES tool_calls(id) ON DELETE CASCADE,
  rawOutputGzip BLOB,
  contentGzip BLOB,
  CHECK (rawOutputGzip IS NOT NULL OR contentGzip IS NOT NULL)
);
CREATE TABLE tool_call_full_output_migration (
  id INTEGER PRIMARY KEY CHECK (id = 0),
  shape TEXT NOT NULL CHECK (shape = 'tool-call-full-output-v1'),
  appliedAt INTEGER NOT NULL CHECK (appliedAt >= 0)
);
INSERT INTO tool_call_full_output_migration VALUES(0,'tool-call-full-output-v1',1735689600000);
CREATE TABLE turn_event_migration (
  id        INTEGER PRIMARY KEY CHECK (id = 0),
  shape     TEXT NOT NULL CHECK (shape = 'turn-event-order-v1'),
  appliedAt INTEGER NOT NULL CHECK (appliedAt >= 0)
);
INSERT INTO turn_event_migration VALUES(0,'turn-event-order-v1',1735689600000);
CREATE TABLE turn_events (
  id            TEXT PRIMARY KEY CHECK (length(id) = 39),
  sessionKey    TEXT NOT NULL REFERENCES sessions(sessionKey),
  turnSeq       INTEGER NOT NULL REFERENCES turns(seq),
  turnEventSeq  INTEGER NOT NULL CHECK (turnEventSeq > 0),
  kind          TEXT NOT NULL CHECK (kind IN ('assistant.segment','tool.started','tool.ended')),
  messageId     TEXT,
  toolCallId    TEXT REFERENCES tool_calls(id),
  content       TEXT CHECK (content IS NULL OR json_valid(content)),
  toolCall      TEXT CHECK (toolCall IS NULL OR json_valid(toolCall)),
  rowVersion    INTEGER NOT NULL CHECK (rowVersion = 1),
  UNIQUE (sessionKey, turnSeq, turnEventSeq),
  CHECK (
    (kind='assistant.segment' AND messageId IS NOT NULL AND length(messageId)>0
      AND toolCallId IS NULL AND content IS NOT NULL AND toolCall IS NULL)
    OR
    (kind IN ('tool.started','tool.ended') AND messageId IS NULL
      AND toolCallId IS NOT NULL AND content IS NULL AND toolCall IS NOT NULL
      AND json_extract(toolCall,'$.id')=toolCallId
      AND json_extract(toolCall,'$.sessionKey')=sessionKey
      AND json_extract(toolCall,'$.turnSeq')=turnSeq)
  )
);
CREATE TABLE artifacts (  artifactId        TEXT PRIMARY KEY,
  kind              TEXT NOT NULL CHECK (kind IN ('spec','report','doc','data','other')),
  title             TEXT NOT NULL,
  description       TEXT,
  createdBySession  TEXT NULL REFERENCES sessions(sessionKey),
    createdByProcess  TEXT NULL,
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
    originHost        TEXT,
    originWorkspace   TEXT,
  CHECK ((state = 'archived') = (home IS NOT NULL)),
    CHECK (createdBySession IS NOT NULL OR createdByProcess IS NOT NULL)
);
INSERT INTO artifacts VALUES('art_00000006','report','Fixture artifact',NULL,'agent:fixture:holder',NULL,'wi_00000000-0000-4000-8000-000000000003',NULL,NULL,'/fixture/report.txt',NULL,NULL,'none','in-workspace',NULL,1735689600000,1735689600000,'fixture',NULL);
CREATE TABLE session_retirement_parent_moves (
  eventSeq INTEGER PRIMARY KEY AUTOINCREMENT,
  eventId TEXT NOT NULL UNIQUE,
  ownerUserId TEXT NOT NULL,
  childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  retiredTargetSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  previousCurrentParentSessionKey TEXT REFERENCES sessions(sessionKey),
  newCurrentParentSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  retirementRequestId TEXT NOT NULL,
  principalRef TEXT NOT NULL CHECK (length(principalRef)>0),
  idempotencyKey TEXT,
  createdAt INTEGER NOT NULL CHECK (createdAt>=0)
);
CREATE TABLE unfinished_retirements (
  id TEXT PRIMARY KEY,
  targetSessionKey TEXT NOT NULL,
  ownerSessionKey TEXT NOT NULL,
  principalRef TEXT NOT NULL,
  keepOpenDescendants INTEGER NOT NULL CHECK(keepOpenDescendants IN (0,1)),
  blockerKind TEXT NOT NULL CHECK(blockerKind IN ('work','lease')),
  hardDeadline INTEGER,
  wakeId TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','retired','withdrawn','superseded')),
  createdAt INTEGER NOT NULL,
  closedAt INTEGER,
  supersededBy TEXT,
  withdrawalReason TEXT,
  withdrawnBy TEXT
);
CREATE TABLE retirement_blockers (
  retirementId TEXT NOT NULL REFERENCES unfinished_retirements(id),
  kind TEXT NOT NULL CHECK(kind IN ('assignment','role')),
  reference TEXT NOT NULL,
  sessionKey TEXT NOT NULL,
  PRIMARY KEY(retirementId,kind,reference)
);
CREATE TABLE retirement_owner_transfers (
  id INTEGER PRIMARY KEY,
  retirementId TEXT NOT NULL REFERENCES unfinished_retirements(id),
  formerOwnerSessionKey TEXT NOT NULL,
  newOwnerSessionKey TEXT NOT NULL,
  successorId TEXT NOT NULL REFERENCES unfinished_retirements(id),
  handoffWakeId TEXT,
  createdAt INTEGER NOT NULL
);
CREATE TABLE session_reparent_events (
  eventSeq INTEGER PRIMARY KEY AUTOINCREMENT,
  eventId TEXT NOT NULL UNIQUE,
  ownerUserId TEXT NOT NULL,
  childSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  assignmentId TEXT REFERENCES assignments(id),
  workItemId TEXT REFERENCES work_items(id),
  originParentSessionKey TEXT,
  previousCurrentParentSessionKey TEXT,
  newCurrentParentSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  originAssignmentOpenerKind TEXT ,
  originAssignmentOpenerRef TEXT,
  previousCurrentCoordinationParentSessionKey TEXT,
  newCurrentCoordinationParentSessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
  cause TEXT NOT NULL CHECK (cause IN ('owner_topology_correction','delivery_owner_reparent')),
  principalKind TEXT NOT NULL ,
  principalRef TEXT NOT NULL,
  idempotencyKey TEXT NOT NULL,
  requestFingerprint TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  UNIQUE(ownerUserId,idempotencyKey,assignmentId),
CHECK ((assignmentId IS NULL AND workItemId IS NULL AND
        originAssignmentOpenerKind IS NULL AND originAssignmentOpenerRef IS NULL) OR
       (assignmentId IS NOT NULL AND originAssignmentOpenerKind IS NOT NULL AND
        originAssignmentOpenerRef IS NOT NULL)),

  CHECK (newCurrentParentSessionKey=newCurrentCoordinationParentSessionKey)
);
CREATE TABLE IF NOT EXISTS "wire_idempotency" (
  ownerUserId TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN
    ('spawn','retire','wake','assign','condition','work-item-create',
     'session-reparent','session-po-set','settle-turn','session-custody-transfer')),
  idempotencyKey TEXT NOT NULL,
  sessionKey TEXT NOT NULL,
  requestFingerprint TEXT,
  canonicalResponse TEXT,
  responseJson TEXT,
  PRIMARY KEY(ownerUserId,operation,idempotencyKey),
  CHECK (operation NOT IN ('session-reparent','session-po-set','session-custody-transfer') OR
    (requestFingerprint IS NOT NULL AND canonicalResponse IS NOT NULL)),
  CHECK (operation != 'settle-turn' OR
    (requestFingerprint IS NOT NULL AND responseJson IS NOT NULL))
);
CREATE TABLE assignment_holder_prod_custody (
  assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
  changedAt INTEGER NOT NULL
);
CREATE TABLE assignment_holder_prod_attempts (
  id INTEGER PRIMARY KEY,
  episodeId TEXT NOT NULL,
  assignmentId TEXT NOT NULL,
  holderKey TEXT NOT NULL,
  repeatNumber INTEGER NOT NULL,
  admittedAt INTEGER NOT NULL,
  wakeId TEXT UNIQUE
);
CREATE TABLE harness_model_rate_limits (
  id TEXT PRIMARY KEY,
  harness TEXT NOT NULL CHECK(length(trim(harness)) > 0),
  host TEXT NOT NULL CHECK(length(trim(host)) > 0),
  model TEXT NOT NULL CHECK(length(trim(model)) > 0),
  modelContext TEXT,
  sessionKey TEXT,
  assignmentId TEXT,
  turnSeq INTEGER,
  compactionAttemptKey TEXT,
  observedAt INTEGER NOT NULL,
  cause TEXT NOT NULL,
  principal TEXT NOT NULL,
  releasedAt INTEGER,
  releaseCause TEXT CHECK(releaseCause IN ('normal-turn','escalated')),
  releaseTurnSeq INTEGER,
  CHECK((compactionAttemptKey IS NULL AND sessionKey IS NOT NULL AND turnSeq IS NOT NULL) OR
        (compactionAttemptKey IS NOT NULL AND sessionKey IS NULL AND turnSeq IS NULL
         AND assignmentId IS NULL)),
  CHECK((releasedAt IS NULL AND releaseCause IS NULL) OR
        (releasedAt IS NOT NULL AND releaseCause IS NOT NULL))
);
CREATE TABLE coordinator_outage_decisions (
  id TEXT PRIMARY KEY,
  ownerUserId TEXT NOT NULL,
  openedAt INTEGER NOT NULL,
  closedAt INTEGER,
  requestId TEXT UNIQUE REFERENCES decision_requests(id),
  filedAt INTEGER,
  CHECK((requestId IS NULL) = (filedAt IS NULL))
);
CREATE TABLE coordinator_outage_retries (
  requestId TEXT NOT NULL REFERENCES decision_requests(id),
  holdId TEXT NOT NULL,
  cycleId TEXT NOT NULL,
  PRIMARY KEY(requestId,holdId)
);
DELETE FROM sqlite_sequence;
INSERT INTO sqlite_sequence VALUES('subagent_markers',0);
INSERT INTO sqlite_sequence VALUES('messages',2);
INSERT INTO sqlite_sequence VALUES('session_reparent_events',0);
INSERT INTO sqlite_sequence VALUES('boot_epochs',1);
INSERT INTO sqlite_sequence VALUES('condition_facts',1);
INSERT INTO sqlite_sequence VALUES('lifecycle_events',2);
CREATE INDEX turns_pending
  ON turns (status, sessionKey, seq)
  WHERE status IN ('queued','running');
CREATE INDEX turns_session ON turns (sessionKey, seq);
CREATE INDEX turns_unpublished
  ON turns (endedAt) WHERE endedAt IS NOT NULL AND publishedAt IS NULL;
CREATE INDEX turns_job_ref ON turns (jobRef);
CREATE INDEX turns_assignment_id ON turns (assignmentId);
CREATE INDEX turn_repair_source
  ON turn_repair_attempts (sourceSeq, createdAt, id);
CREATE INDEX assignment_repair_history
  ON assignment_repair_attempts (assignmentId, createdAt, id);
CREATE INDEX events_session ON events (sessionKey, id);
CREATE INDEX causal_events_job ON causal_events (jobRef, seq);
CREATE INDEX causal_events_assignment
  ON causal_events (assignmentId, seq);
CREATE INDEX condition_facts_match
  ON condition_facts (kind, scope, id);
CREATE INDEX condition_facts_owner_match
  ON condition_facts (ownerUserId, kind, scope, id);
CREATE INDEX escalation_waivers_lookup
  ON escalation_waivers (raiserId, statuteName, revokedAt);
CREATE INDEX wakes_due ON wakes (state, dueAt);
CREATE INDEX wakes_delivery ON wakes (state, deliveryRule, sessionKey, class);
CREATE INDEX wakes_condition ON wakes (state, conditionKind, conditionScope);
CREATE INDEX wakes_wait_recognition
  ON wakes (state, waitMode, ownerUserId, recognitionAt, dueAt);
CREATE INDEX pointers_session ON harness_pointers (sessionKey, id);
CREATE INDEX pointers_source ON harness_pointers (sourceSessionRef, id);
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
CREATE INDEX work_items_created_in_turn ON work_items (createdInTurnSeq)
;
CREATE INDEX assignment_files_path ON assignment_files(path)
;
CREATE INDEX effort_checkin_wake
  ON effort_checkin_generations (wakeId, state);
CREATE INDEX command_executions_holder
  ON command_executions (holderSessionKey, preparedAt DESC);
CREATE INDEX command_executions_assignment
  ON command_executions (assignmentId, preparedAt DESC);
CREATE INDEX work_state_events_assignment
  ON work_state_events (assignmentId, id);
CREATE INDEX work_item_events_item
  ON work_item_events (workItemId, id);
CREATE INDEX harness_processes_adapter_launch_sequence ON harness_processes (adapterKey, state, launchSequence);
CREATE UNIQUE INDEX toplines_id_owner ON toplines (id, ownerUserId);
CREATE UNIQUE INDEX work_items_id_owner ON work_items (id, ownerUserId);
CREATE UNIQUE INDEX topline_memberships_active_pair ON topline_work_memberships (toplineId, workItemId) WHERE unlinkedAt IS NULL;
CREATE UNIQUE INDEX topline_memberships_id_topline ON topline_work_memberships (id, toplineId);
CREATE INDEX topline_memberships_work_active ON topline_work_memberships (workItemId) WHERE unlinkedAt IS NULL;
CREATE UNIQUE INDEX topline_concerns_id_topline ON topline_concerns (id, toplineId);
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
CREATE UNIQUE INDEX causal_events_seq_job_ref ON causal_events (seq, jobRef);
CREATE UNIQUE INDEX topline_placements_one_pending ON topline_placement_obligations (workItemId) WHERE state = 'pending';
CREATE UNIQUE INDEX topline_placements_one_reopen ON topline_placement_obligations (workItemId, sourceCausalEventSeq) WHERE sourceCausalEventSeq IS NOT NULL;
CREATE UNIQUE INDEX topline_placements_one_terminal_resolution ON topline_placement_obligations (workItemId, resolutionCausalEventSeq) WHERE resolutionCausalEventSeq IS NOT NULL;
CREATE INDEX supervision_progress_assignment ON supervision_progress_absorptions(assignmentId, attestTs, attestId);
CREATE INDEX supervision_liveness_assignment ON supervision_liveness_sidecar(assignmentId, wakeId);
CREATE UNIQUE INDEX supervision_liveness_pending_controller ON supervision_liveness_sidecar(assignmentId) WHERE controllerState = 'pending' AND controllerOrigin = 'scheduled';
CREATE UNIQUE INDEX supervision_liveness_retirement_dedupe ON supervision_liveness_sidecar(transferEvidenceId, retirementEpoch, retirementCause) WHERE transferEvidenceId IS NOT NULL;
CREATE UNIQUE INDEX wakes_cancellation_state ON wakes(wakeId, state, canceledAt);
CREATE TRIGGER supervision_liveness_retirement_immutable_update
BEFORE UPDATE ON supervision_liveness_sidecar
WHEN OLD.transferEvidenceId IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
END;
CREATE TRIGGER supervision_liveness_retirement_immutable_delete
BEFORE DELETE ON supervision_liveness_sidecar
WHEN OLD.transferEvidenceId IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'supervision retirement outcome is immutable');
END;
CREATE INDEX supervision_liveness_receipts_assignment ON supervision_liveness_receipts(assignmentId, receiptId);
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
CREATE INDEX decision_requests_owner
  ON decision_requests (ownerUserId, status);
CREATE INDEX decision_requests_key
  ON decision_requests (raiserId, statuteName, actionKey);
CREATE UNIQUE INDEX decision_requests_one_open
  ON decision_requests (raiserId, statuteName, actionKey)
  WHERE kind = 'statute' AND status = 'open';
CREATE UNIQUE INDEX decision_requests_effort_generation
  ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
CREATE UNIQUE INDEX decision_requests_operator_open
  ON decision_requests (ownerUserId, raiserId, actionKey)
  WHERE kind = 'operator' AND status = 'open';
CREATE INDEX decision_requests_asked
  ON decision_requests (expecterSessionKey, status) WHERE kind = 'agent';
CREATE TRIGGER decision_requests_terminal_insert_guard
BEFORE INSERT ON decision_requests
WHEN typeof(NEW.rowVersion) <> 'integer' OR NEW.rowVersion < 1 OR
  (NEW.kind = 'operator' AND NEW.status = 'ruled' AND
  (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL)))
BEGIN
  SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
END;
CREATE TRIGGER decision_requests_terminal_update_guard
BEFORE UPDATE ON decision_requests
WHEN typeof(NEW.rowVersion) <> 'integer' OR NEW.rowVersion < 1 OR
  (OLD.kind = 'operator' AND OLD.status = 'open' AND NEW.status = 'ruled' AND
  (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
   (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
   (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL)))
BEGIN
  SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
END;
CREATE TRIGGER decision_requests_r7_row_version
AFTER UPDATE OF
  id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
  expecterSessionKey, expecterUserId, lineageRung, effortGeneration,
  deadlineWakeId, raisedAt, deadlineAt, statuteName, question, options,
  context, status, decision, rationale, ruledBy, ruledAt, consumedAt,
  withdrawnBy, withdrawnReason, withdrawnAt, askedOfRole, answer,
  answeredBy, answeredAt, returnedBy, returnReason, returnedAt
ON decision_requests
WHEN NEW.id IS NOT OLD.id
  OR NEW.kind IS NOT OLD.kind
  OR NEW.raiserId IS NOT OLD.raiserId
  OR NEW.raiserSessionKey IS NOT OLD.raiserSessionKey
  OR NEW.ownerUserId IS NOT OLD.ownerUserId
  OR NEW.assignmentId IS NOT OLD.assignmentId
  OR NEW.expecterSessionKey IS NOT OLD.expecterSessionKey
  OR NEW.expecterUserId IS NOT OLD.expecterUserId
  OR NEW.lineageRung IS NOT OLD.lineageRung
  OR NEW.effortGeneration IS NOT OLD.effortGeneration
  OR NEW.deadlineWakeId IS NOT OLD.deadlineWakeId
  OR NEW.raisedAt IS NOT OLD.raisedAt
  OR NEW.deadlineAt IS NOT OLD.deadlineAt
  OR NEW.statuteName IS NOT OLD.statuteName
  OR NEW.question IS NOT OLD.question
  OR NEW.options IS NOT OLD.options
  OR NEW.context IS NOT OLD.context
  OR NEW.status IS NOT OLD.status
  OR NEW.decision IS NOT OLD.decision
  OR NEW.rationale IS NOT OLD.rationale
  OR NEW.ruledBy IS NOT OLD.ruledBy
  OR NEW.ruledAt IS NOT OLD.ruledAt
  OR NEW.consumedAt IS NOT OLD.consumedAt
  OR NEW.withdrawnBy IS NOT OLD.withdrawnBy
  OR NEW.withdrawnReason IS NOT OLD.withdrawnReason
  OR NEW.withdrawnAt IS NOT OLD.withdrawnAt
  OR NEW.askedOfRole IS NOT OLD.askedOfRole
  OR NEW.answer IS NOT OLD.answer
  OR NEW.answeredBy IS NOT OLD.answeredBy
  OR NEW.answeredAt IS NOT OLD.answeredAt
  OR NEW.returnedBy IS NOT OLD.returnedBy
  OR NEW.returnReason IS NOT OLD.returnReason
  OR NEW.returnedAt IS NOT OLD.returnedAt
BEGIN
  UPDATE decision_requests
  SET rowVersion = OLD.rowVersion + 1
  WHERE id = NEW.id;
END;
CREATE INDEX assignment_reopenings_assignment
  ON assignment_reopenings (assignmentId, id);
CREATE INDEX assignment_revocations_assignment
  ON assignment_revocations (assignmentId, revokedAt, id)
;
CREATE UNIQUE INDEX assignment_revocation_generation_initial
  ON assignment_revocation_generations (assignmentId)
  WHERE reopeningId IS NULL;
CREATE TRIGGER assignments_revocation_reason_required
BEFORE UPDATE OF state, outcome, closedAt, closedByUser, closedBySession, closedByProcess ON assignments
WHEN NEW.state = 'closed' AND NEW.outcome = 'revoked'
  AND NOT EXISTS (
    SELECT 1 FROM assignment_revocation_generations g
    JOIN assignment_revocations r ON r.id = g.revocationId
    WHERE g.assignmentId = NEW.id
      AND g.reopeningId IS (
        SELECT reopening.id FROM assignment_reopenings reopening
        WHERE reopening.assignmentId = NEW.id
        ORDER BY reopening.id DESC LIMIT 1
      )
      AND r.revokedAt = NEW.closedAt
      AND r.revokedByUser IS NEW.closedByUser
      AND r.revokedBySession IS NEW.closedBySession
      AND r.revokedByProcess IS NEW.closedByProcess
  )
BEGIN
  SELECT RAISE(ABORT, 'revoked assignment requires revocation provenance');
END;
CREATE TRIGGER assignments_revocation_reason_required_insert
BEFORE INSERT ON assignments
WHEN NEW.state = 'closed' AND NEW.outcome = 'revoked'
  AND NOT EXISTS (
    SELECT 1 FROM assignment_revocation_generations g
    JOIN assignment_revocations r ON r.id = g.revocationId
    WHERE g.assignmentId = NEW.id
      AND g.reopeningId IS (
        SELECT reopening.id FROM assignment_reopenings reopening
        WHERE reopening.assignmentId = NEW.id
        ORDER BY reopening.id DESC LIMIT 1
      )
      AND r.revokedAt = NEW.closedAt
      AND r.revokedByUser IS NEW.closedByUser
      AND r.revokedBySession IS NEW.closedBySession
      AND r.revokedByProcess IS NEW.closedByProcess
  )
BEGIN
  SELECT RAISE(ABORT, 'revoked assignment requires revocation provenance');
END;
CREATE TRIGGER assignment_revocations_immutable_update
BEFORE UPDATE ON assignment_revocations
BEGIN
  SELECT RAISE(ABORT, 'revocation provenance is immutable');
END;
CREATE TRIGGER assignment_revocations_immutable_delete
BEFORE DELETE ON assignment_revocations
BEGIN
  SELECT RAISE(ABORT, 'revocation provenance is immutable');
END;
CREATE TRIGGER assignment_revocation_generations_match_provenance
BEFORE INSERT ON assignment_revocation_generations
WHEN NOT EXISTS (
  SELECT 1 FROM assignment_revocations r
  WHERE r.id = NEW.revocationId AND r.assignmentId = NEW.assignmentId
) OR NEW.reopeningId IS NOT (
  SELECT reopening.id FROM assignment_reopenings reopening
  WHERE reopening.assignmentId = NEW.assignmentId
  ORDER BY reopening.id DESC LIMIT 1
)
BEGIN
  SELECT RAISE(ABORT, 'revocation generation requires current matching provenance');
END;
CREATE TRIGGER assignment_revocation_generations_immutable_update
BEFORE UPDATE ON assignment_revocation_generations
BEGIN
  SELECT RAISE(ABORT, 'revocation generation is immutable');
END;
CREATE TRIGGER assignment_revocation_generations_immutable_delete
BEFORE DELETE ON assignment_revocation_generations
BEGIN
  SELECT RAISE(ABORT, 'revocation generation is immutable');
END;
CREATE TRIGGER artifact_contents_released_immutable
BEFORE UPDATE ON artifact_contents
WHEN EXISTS (
  SELECT 1 FROM artifacts a
  WHERE a.artifactId = OLD.artifactId AND a.state = 'released'
)
BEGIN
  SELECT RAISE(ABORT, 'released artifact content is immutable');
END;
CREATE TRIGGER artifact_contents_released_retained
BEFORE DELETE ON artifact_contents
WHEN EXISTS (
  SELECT 1 FROM artifacts a
  WHERE a.artifactId = OLD.artifactId AND a.state = 'released'
)
BEGIN
  SELECT RAISE(ABORT, 'released artifact content is retained');
END;
CREATE INDEX session_po_associations_owner
  ON session_po_associations(ownerUserId, sessionKey);
CREATE INDEX runtime_changes_pending
  ON runtime_changes(sessionKey, state, seq);
CREATE INDEX health_redelivery_pending ON health_redelivery_attempts(sourceHarness,sourceHost,sourceTurnSeq) WHERE redeliveryTurnSeq IS NULL AND cycleReleaseTurnSeq IS NULL;
CREATE UNIQUE INDEX health_redelivery_cycle_release_turn ON health_redelivery_attempts(cycleReleaseTurnSeq) WHERE cycleReleaseTurnSeq IS NOT NULL;
CREATE INDEX health_redelivery_cycle_release_pending ON health_redelivery_attempts(cycleReleaseCorrelation,sourceHarness,sourceHost) WHERE cycleReleaseCorrelation IS NOT NULL AND cycleReleaseTurnSeq IS NULL;
CREATE UNIQUE INDEX harklight_send_bound_request
  ON harklight_send_operations(senderId,messageId);
CREATE INDEX harklight_pending_supersedes_target
  ON harklight_pending_supersedes(senderId,messageId,opId);
CREATE UNIQUE INDEX harklight_wake_follows_open
  ON harklight_wake_follows(sessionKey,kind,handle,messageId) WHERE state='open';
CREATE INDEX harklight_wake_requests_handle
  ON harklight_wake_requests(handle);
CREATE INDEX harklight_wake_follows_handle
  ON harklight_wake_follows(handle,state,kind,messageId);
CREATE INDEX harklight_wake_deliveries_session
  ON harklight_wake_deliveries(sessionKey,handle,eventId);
CREATE INDEX harklight_handoff_receipts_pending
  ON harklight_handoff_receipts(turnSeq,wakeId) WHERE completedAt IS NULL;
CREATE UNIQUE INDEX harklight_decision_briefings_operation
  ON harklight_decision_briefings(sendOpId) WHERE sendOpId IS NOT NULL;
CREATE INDEX harklight_decision_briefings_thread
  ON harklight_decision_briefings(handle,senderId,messageId);
CREATE INDEX harklight_bounces_owed
  ON harklight_bounces(capturedAt,advisoryId) WHERE ackCompletedAt IS NULL;
CREATE INDEX message_attachment_delivery_latest
  ON message_attachment_delivery_results (messageId, assetId, seq DESC);
CREATE INDEX harness_switch_context_pending
  ON harness_switch_contexts(sessionKey, state, createdAt);
CREATE INDEX harness_switch_context_message
  ON harness_switch_contexts(sessionKey, boundMessageId, createdAt);
CREATE UNIQUE INDEX assignment_cannot_proceed_standing
  ON assignment_cannot_proceed(assignmentId) WHERE state='standing';
CREATE INDEX assignment_cannot_proceed_release
  ON assignment_cannot_proceed(releaseFactKind, releaseFactScope, releaseFactPrincipalRef)
  WHERE state='standing' AND releaseFactKind IS NOT NULL;
CREATE INDEX assignment_commit_ref_corrections_assignment ON assignment_commit_ref_corrections (assignmentId, createdAt, id);
CREATE INDEX harness_compaction_observations_route
  ON harness_compaction_observations(harness,host,observedAt DESC);
CREATE INDEX sessions_owner ON sessions (ownerUserId, state);
CREATE UNIQUE INDEX sessions_cli_token ON sessions(cliToken);
CREATE UNIQUE INDEX subagent_markers_one_stop
  ON subagent_markers (subagentRef) WHERE kind = 'subagent_stop';
CREATE INDEX subagent_markers_principal
  ON subagent_markers (principal, id);
CREATE INDEX harness_health_observation_window
  ON harness_health_observations
    (harness, host, failureClass, evidenceKind, observedAt, sessionKey);
CREATE INDEX harness_health_observation_incident
  ON harness_health_observations (incidentId, observedAt, id);
CREATE UNIQUE INDEX harness_health_one_open_class
  ON harness_health_incidents (harness, host, failureClass)
  WHERE state = 'open' AND failureClass != 'other';
CREATE UNIQUE INDEX harness_health_other_one_open
  ON harness_health_incidents (harness, host, descriptionDigest)
  WHERE state = 'open' AND failureClass = 'other';
CREATE INDEX harness_health_incident_history
  ON harness_health_incidents (harness, host, openedAt, id);
CREATE INDEX harness_health_member_session
  ON harness_health_members (sessionKey, incidentId);
CREATE INDEX harness_health_assignment_session
  ON harness_health_assignments (sessionKey, incidentId);
CREATE UNIQUE INDEX harness_health_other_route_target_unique
  ON harness_health_other_routes (incidentId, targetKind, targetRef)
  WHERE state != 'skipped';
CREATE TRIGGER harness_health_other_route_identity_immutable
BEFORE UPDATE OF incidentId,ordinal,recipient,targetKind,targetRef,relation,createdAt
ON harness_health_other_routes
BEGIN
  SELECT RAISE(ABORT, 'harness health route identity is immutable');
END;
CREATE TRIGGER harness_health_other_route_terminal_once
BEFORE UPDATE OF state,closedReason,noticeWakeId,turnSeq,resolvedAt,settledAt
ON harness_health_other_routes
WHEN OLD.state IN ('skipped','delivered','non_delivered','alerted') AND
     (NEW.state != OLD.state OR NEW.closedReason IS NOT OLD.closedReason OR
      NEW.noticeWakeId IS NOT OLD.noticeWakeId OR NEW.turnSeq IS NOT OLD.turnSeq OR
      NEW.resolvedAt IS NOT OLD.resolvedAt OR NEW.settledAt IS NOT OLD.settledAt)
BEGIN
  SELECT RAISE(ABORT, 'harness health route is terminal and immutable');
END;
CREATE TRIGGER harness_health_other_route_pending_terminal
BEFORE UPDATE OF state ON harness_health_other_routes
WHEN OLD.state = 'pending' AND NEW.state != 'pending' AND (
  NEW.state NOT IN ('delivered','non_delivered','alerted') OR
  (NEW.state = 'delivered' AND
    (NEW.closedReason IS NOT NULL OR NEW.resolvedAt IS NULL OR NEW.settledAt IS NULL)) OR
  (NEW.state = 'non_delivered' AND
    (NEW.closedReason NOT IN ('failed','failed_unknown','canceled','target_retired') OR
     NEW.resolvedAt IS NULL OR NEW.settledAt IS NULL)) OR
  (NEW.state = 'alerted' AND
    (NEW.closedReason IS NOT 'no_active_main' OR NEW.settledAt IS NULL))
)
BEGIN
  SELECT RAISE(ABORT, 'harness health route transition is invalid');
END;
CREATE TRIGGER harness_health_other_route_no_delete
BEFORE DELETE ON harness_health_other_routes
BEGIN
  SELECT RAISE(ABORT, 'harness health route rows are immutable');
END;
CREATE TRIGGER harness_health_other_review_event_append_only_update
BEFORE UPDATE ON harness_health_other_review_events
BEGIN
  SELECT RAISE(ABORT, 'harness health review events are append-only');
END;
CREATE TRIGGER harness_health_other_review_event_append_only_delete
BEFORE DELETE ON harness_health_other_review_events
BEGIN
  SELECT RAISE(ABORT, 'harness health review events are append-only');
END;
CREATE TRIGGER harness_health_class_promotion_close_once
BEFORE UPDATE OF state,namedClass,specRef,specSha256,reviewArtifactId,reviewAttestId,
                 reviewedClean,closedBy,closedAt
ON harness_health_class_promotions
WHEN OLD.state = 'closed' OR (OLD.state = 'open' AND NEW.state != 'closed')
BEGIN
  SELECT RAISE(ABORT, 'harness health promotion closure is one-way');
END;
CREATE TRIGGER harness_health_observation_assignment_holder
BEFORE INSERT ON harness_health_observations
WHEN NEW.assignmentId IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM assignments
  WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
)
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment must belong to its affected session');
END;
CREATE TRIGGER harness_health_observation_identity_immutable
BEFORE UPDATE OF id,correlationId,harness,host,failureClass,evidenceKind,sessionKey,
                 assignmentId,observedAt,cause,principal
ON harness_health_observations
BEGIN
  SELECT RAISE(ABORT, 'harness health observation identity is immutable');
END;
CREATE TRIGGER harness_health_observation_evidence_immutable
BEFORE UPDATE OF description,descriptionDigest,observedState,evidenceMode,
                 exactObservedError,exactProbe,outputDigest,recoveryCondition,
                 recoveryConditionDigest,recoverySatisfied,notKnownClassReason,
                 validUntil,worldStatus,redactionConfirmed
ON harness_health_observations
BEGIN
  SELECT RAISE(ABORT, 'harness health evidence is immutable');
END;
CREATE TRIGGER harness_health_observation_attachment_once
BEFORE UPDATE OF incidentId ON harness_health_observations
WHEN OLD.incidentId IS NOT NULL OR NEW.incidentId IS NULL
BEGIN
  SELECT RAISE(ABORT, 'harness health observation attachment is immutable');
END;
CREATE TRIGGER harness_health_observation_no_delete
BEFORE DELETE ON harness_health_observations
BEGIN
  SELECT RAISE(ABORT, 'harness health observation history is immutable');
END;
CREATE TRIGGER harness_health_incident_identity_immutable
BEFORE UPDATE OF id,harness,host,failureClass,openedAt,openObservationId,openedFactId,
                 descriptionDigest,expiresAt
ON harness_health_incidents
BEGIN
  SELECT RAISE(ABORT, 'harness health incident identity is immutable');
END;
CREATE TRIGGER harness_health_incident_resolution_once
BEFORE UPDATE OF state,resolvedAt,resolutionObservationId,resolvedFactId
ON harness_health_incidents
WHEN NOT (
  (OLD.state = 'open' AND OLD.resolvedAt IS NULL AND
   OLD.resolutionObservationId IS NULL AND OLD.resolvedFactId IS NULL AND
   NEW.state = 'resolved' AND NEW.resolvedAt IS NOT NULL AND
     NEW.resolutionObservationId IS NOT NULL AND
     (NEW.resolvedFactId IS NOT NULL OR
      (OLD.failureClass = 'other' AND NOT EXISTS (
        SELECT 1 FROM harness_health_incidents remaining
        WHERE remaining.id != OLD.id AND remaining.harness = OLD.harness AND
              remaining.host = OLD.host AND remaining.failureClass = 'other' AND
              remaining.state = 'open'
      ))) AND
   EXISTS (
     SELECT 1 FROM harness_health_observations
     WHERE id = NEW.resolutionObservationId AND incidentId = OLD.id AND
           harness = OLD.harness AND host = OLD.host AND
           failureClass = OLD.failureClass AND evidenceKind = 'normal-turn-success'
   ))
  OR
  (OLD.state = 'open' AND NEW.state = 'expired' AND NEW.expiredAt IS NOT NULL AND
   (NEW.expiryFactId IS NOT NULL OR
    (OLD.failureClass = 'other' AND NOT EXISTS (
      SELECT 1 FROM harness_health_incidents remaining
      WHERE remaining.id != OLD.id AND remaining.harness = OLD.harness AND
            remaining.host = OLD.host AND remaining.failureClass = 'other' AND
            remaining.state = 'open'
    ))))
)
BEGIN
  SELECT RAISE(ABORT, 'harness health incident may resolve exactly once');
END;
CREATE TRIGGER harness_health_incident_no_delete
BEFORE DELETE ON harness_health_incidents
BEGIN
  SELECT RAISE(ABORT, 'harness health incident history is immutable');
END;
CREATE TRIGGER harness_health_member_immutable_update
BEFORE UPDATE ON harness_health_members
BEGIN
  SELECT RAISE(ABORT, 'harness health membership history is immutable');
END;
CREATE TRIGGER harness_health_member_immutable_delete
BEFORE DELETE ON harness_health_members
BEGIN
  SELECT RAISE(ABORT, 'harness health membership history is immutable');
END;
CREATE TRIGGER harness_health_assignment_holder
BEFORE INSERT ON harness_health_assignments
WHEN NOT EXISTS (
  SELECT 1 FROM assignments
  WHERE id = NEW.assignmentId AND holderKey = NEW.sessionKey
)
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment must belong to its affected member');
END;
CREATE TRIGGER harness_health_assignment_immutable_update
BEFORE UPDATE ON harness_health_assignments
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment history is immutable');
END;
CREATE TRIGGER harness_health_assignment_immutable_delete
BEFORE DELETE ON harness_health_assignments
BEGIN
  SELECT RAISE(ABORT, 'harness health assignment history is immutable');
END;
CREATE INDEX turn_lifecycle_by_turn
  ON turn_lifecycle_events (turnSeq, ordinal);
CREATE UNIQUE INDEX terminal_credential_one_open_key
  ON terminal_credential_incidents(host, harness) WHERE state = 'open';
CREATE INDEX terminal_credential_open_provider
  ON terminal_credential_incidents(host, provider, state, openingWatermark);
CREATE INDEX terminal_credential_observation_incident
  ON terminal_credential_observations(incidentId, observedAt, id);
CREATE INDEX terminal_credential_redirect_destinations
  ON terminal_credential_redirects(incidentId, destinationHost);
CREATE INDEX terminal_credential_delivery_incident
  ON terminal_credential_deliveries(incidentId, state, adminUserId);
CREATE TRIGGER terminal_credential_incident_identity_immutable
BEFORE UPDATE OF id,class,host,harness,provider,openedAt,openingWatermark,
                 openingObservationId,assertionFactId,statementId
ON terminal_credential_incidents
BEGIN
  SELECT RAISE(ABORT, 'terminal credential incident identity is immutable');
END;
CREATE TRIGGER terminal_credential_incident_no_delete
BEFORE DELETE ON terminal_credential_incidents
BEGIN
  SELECT RAISE(ABORT, 'terminal credential incident history is immutable');
END;
CREATE TRIGGER terminal_credential_resolution_immutable
BEFORE UPDATE OF state,resolvedAt,resolutionFactId
ON terminal_credential_incidents
WHEN OLD.state = 'resolved'
BEGIN
  SELECT RAISE(ABORT, 'terminal credential resolution is immutable');
END;
CREATE TRIGGER terminal_credential_observation_immutable
BEFORE UPDATE ON terminal_credential_observations
BEGIN
  SELECT RAISE(ABORT, 'terminal credential observation is immutable');
END;
CREATE TRIGGER terminal_credential_observation_no_delete
BEFORE DELETE ON terminal_credential_observations
BEGIN
  SELECT RAISE(ABORT, 'terminal credential observation history is immutable');
END;
CREATE TRIGGER terminal_credential_redirect_immutable
BEFORE UPDATE ON terminal_credential_redirects
BEGIN
  SELECT RAISE(ABORT, 'terminal credential redirect is immutable');
END;
CREATE TRIGGER terminal_credential_redirect_no_delete
BEFORE DELETE ON terminal_credential_redirects
BEGIN
  SELECT RAISE(ABORT, 'terminal credential redirect history is immutable');
END;
CREATE TRIGGER terminal_credential_delivery_identity_immutable
BEFORE UPDATE OF statementId,incidentId,adminUserId,messageId
ON terminal_credential_deliveries
WHEN OLD.messageId IS NOT NULL OR NEW.messageId IS NULL
BEGIN
  SELECT RAISE(ABORT, 'terminal credential delivery identity is immutable');
END;
CREATE TRIGGER terminal_credential_delivery_no_delete
BEFORE DELETE ON terminal_credential_deliveries
BEGIN
  SELECT RAISE(ABORT, 'terminal credential delivery history is immutable');
END;
CREATE INDEX sentinel_subscriptions_active
  ON sentinel_subscriptions (sessionKey, event, endedAt, createdAt);
CREATE INDEX sentinel_subscription_wake_matches_subscription
  ON sentinel_subscription_wake_matches (subscriptionId, wakeId);
CREATE INDEX turn_clear_attempts_turn
  ON turn_clear_attempts (turnSeq, createdAt);
CREATE INDEX turns_message_id ON turns(messageId);
CREATE TRIGGER wake_cancellations_pending_insert
BEFORE INSERT ON wake_cancellations
WHEN NOT EXISTS (
  SELECT 1 FROM wakes
  WHERE wakeId = NEW.wakeId AND state = 'pending' AND canceledAt IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'wake cancellation carrier requires a pending wake');
END;
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
CREATE INDEX assignments_parent ON assignments(parentAssignmentId,state,closedAt);
CREATE INDEX queued_message_replacement_assignment
  ON queued_message_replacement_requests(assignmentId, requestedAt);
CREATE INDEX queued_message_prod_scope
  ON queued_message_prod_requests(recipientSessionKey,senderKind,senderId,prodId,requestedAt);
CREATE UNIQUE INDEX notice_batches_one_open_lane
  ON notice_batches(recipientAddress, visibilityScope)
  WHERE state = 'open';
CREATE INDEX notice_batches_recovery
  ON notice_batches(state, dueAt, openedAt);
CREATE INDEX notice_batch_members_batch
  ON notice_batch_members(batchId, publicationSeq);
CREATE INDEX row_reaction_pending ON row_reaction_actions(status,org,eventId);
CREATE INDEX row_reaction_output ON row_reaction_actions(json_extract(result,'$.wake_id'));
CREATE INDEX row_reaction_receipt_candidates ON attests(bySession,note) WHERE kind='progress';
CREATE INDEX harness_health_recovery_schedule_due
  ON harness_health_recovery_schedules(status,dueAt,holdId);
CREATE INDEX harness_health_recovery_check_cycle
  ON harness_health_recovery_checks(holdId,cycleId,outcome,routeKey);
CREATE INDEX harness_recovery_notice_waiting
  ON harness_recovery_notices(state,ownerUserId,createdAt,holdId);
CREATE INDEX harness_recovery_notice_wake
  ON harness_recovery_notices(wakeId);
CREATE UNIQUE INDEX condition_facts_decision_request_filed
  ON condition_facts (scope) WHERE kind = 'decision-request-filed'
;
CREATE INDEX lifecycle_events_subject_kind
ON lifecycle_events(subject, kind)
;
CREATE INDEX lifecycle_events_idle_cleanup_kind_id
ON lifecycle_events(kind, id)
WHERE kind='idle_cleanup_pending_observed'
;
CREATE INDEX supervision_entitlements_due ON supervision_entitlements(state, dueAt, assignmentId);
CREATE INDEX idle_cleanup_assignments_activity ON assignments(holderKey, state, openedAt DESC, id DESC);
CREATE INDEX idle_cleanup_assignments_closed_activity ON assignments(holderKey, state, closedAt DESC, id DESC);
CREATE INDEX idle_cleanup_assignments_work_item ON assignments(workItemId, state, holderKey);
CREATE INDEX idle_cleanup_attests_activity ON attests(bySession, ts DESC, id DESC);
CREATE INDEX idle_cleanup_wakes_created_activity ON wakes(creatorSessionKey, createdAt DESC, wakeId DESC);
CREATE INDEX idle_cleanup_wakes_fired_activity ON wakes(sessionKey, firedAt DESC, wakeId DESC) WHERE firedAt IS NOT NULL;
CREATE INDEX idle_cleanup_wakes_pending_session ON wakes(sessionKey, wakeId) WHERE state='pending' AND consumer='prompt';
CREATE INDEX sessions_rest_created_order ON sessions(createdAt, sessionKey);
CREATE INDEX sessions_rest_owner_created_order ON sessions(ownerUserId, createdAt, sessionKey);
CREATE INDEX sessions_rest_stream_owner_order ON sessions(ownerUserId, state, orderIndex, createdAt, sessionKey);
CREATE INDEX wakes_rest_session_created_order ON wakes(sessionKey, createdAt, wakeId);
CREATE INDEX wakes_rest_created_order ON wakes(createdAt, wakeId);
CREATE INDEX assignments_rest_opened_order ON assignments(openedAt DESC, id DESC);
CREATE INDEX attests_rest_assignment_status ON attests(assignmentId, kind, verdictKind);
CREATE INDEX work_items_rest_created_order ON work_items(createdAt, id);
CREATE INDEX work_items_rest_owner_order ON work_items(ownerUserId, createdAt, id);
CREATE INDEX work_items_rest_state_order ON work_items(state, createdAt, id);
CREATE INDEX work_items_rest_created_session_order ON work_items(createdBySession, createdAt, id);
CREATE INDEX work_items_rest_created_user_order ON work_items(createdByUser, createdAt, id);
CREATE INDEX work_items_rest_bug_order ON work_items(isBug, createdAt, id);
CREATE INDEX work_items_rest_spec_order ON work_items(specRefName, createdAt, id);
CREATE INDEX decision_requests_rest_raised_order ON decision_requests(raisedAt, id);
CREATE INDEX decision_requests_rest_status_order ON decision_requests(status, raisedAt, id);
CREATE INDEX decision_requests_rest_kind_order ON decision_requests(kind, raisedAt, id);
CREATE INDEX decision_requests_rest_owner_order ON decision_requests(ownerUserId, raisedAt, id);
CREATE INDEX decision_requests_rest_assignment_order ON decision_requests(assignmentId, raisedAt, id);
CREATE INDEX decision_requests_rest_raiser_order ON decision_requests(raiserId, raisedAt, id);
CREATE INDEX decision_requests_rest_raiser_session_order ON decision_requests(raiserSessionKey, raisedAt, id);
CREATE INDEX decision_requests_rest_expecter_session_order ON decision_requests(expecterSessionKey, raisedAt, id);
CREATE INDEX decision_requests_rest_expecter_user_order ON decision_requests(expecterUserId, raisedAt, id);
CREATE INDEX events_denied_principal ON events(principal) WHERE kind='denied';
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
      UNION ALL
      SELECT 1 FROM turns t
      JOIN notice_batches b ON b.deliveryWakeId=t.wakeId
      JOIN notice_batch_members m ON m.batchId=b.batchId AND m.state='included'
      JOIN wakes source ON source.wakeId=m.sourceWakeId
      WHERE source.wakeId=NEW.wakeId AND source.assignmentId=NEW.assignmentId
    )
  )
BEGIN
  SELECT RAISE(ABORT, 'supervision lineage wake requires controller sidecar');
END;
CREATE TRIGGER supervision_fired_lineage_sidecar_required_delete
BEFORE DELETE ON supervision_liveness_sidecar
WHEN EXISTS (
  SELECT 1 FROM wakes w
  WHERE w.wakeId = OLD.wakeId AND w.assignmentId = OLD.assignmentId
    AND w.state = 'fired' AND w.consumer = 'prompt'
    AND w.origin = 'process:tightbeam' AND w.reresolve = 'lineage'
  UNION ALL
  SELECT 1 FROM notice_batch_members m
  JOIN notice_batches b ON b.batchId=m.batchId AND b.deliveryWakeId=OLD.wakeId
  JOIN wakes w ON w.wakeId=m.sourceWakeId
  WHERE m.state='included' AND w.state='fired' AND w.consumer='prompt'
    AND w.origin='process:tightbeam' AND w.reresolve='lineage'
)
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage sidecar is required');
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
  UNION ALL
  SELECT 1 FROM notice_batch_members m
  JOIN notice_batches b ON b.batchId=m.batchId AND b.deliveryWakeId=OLD.wakeId
  JOIN wakes w ON w.wakeId=m.sourceWakeId
  WHERE m.state='included' AND w.state='fired' AND w.consumer='prompt'
    AND w.origin='process:tightbeam' AND w.reresolve='lineage'
)
BEGIN
  SELECT RAISE(ABORT, 'fired supervision lineage sidecar identity is immutable');
END;
CREATE INDEX wake_retry_root
  ON wake_retry_attempts (rootWakeId, attempt);
CREATE UNIQUE INDEX notice_source_client_identity ON wakes (
  json_extract(sourceClientIdentity,'$.targetSessionKey'),
  json_extract(sourceClientIdentity,'$.deviceId'),
  json_extract(sourceClientIdentity,'$.clientMessageId')
) WHERE sourceClientIdentity IS NOT NULL
;
CREATE INDEX wakes_assignment ON wakes(assignmentId);
CREATE INDEX wakes_delivered_turn ON wakes(deliveredTurnSeq,firedAt);
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
      
      AND w.prompt IS NOT NULL AND (
  w.waitMode IN ('dependency','after-turn') OR
  (w.waitMode IS NULL AND w.conditionKind IS NULL AND w.targetRole IS NULL
   AND w.creatorSessionKey=a.holderKey AND w.dueAt>w.createdAt)
)

      AND (w.originatingTurnSeq IS NULL OR EXISTS (
  SELECT 1 FROM wake_retry_attempts retry
  JOIN wake_retry_attempts prior ON prior.wakeId=retry.predecessorWakeId
  JOIN wakes old ON old.wakeId=prior.wakeId
  JOIN supervision_liveness_sidecar sidecar ON sidecar.wakeId=old.wakeId
  JOIN turns failed ON failed.seq=prior.sourceTurnSeq
  JOIN turn_lifecycle_events claim ON claim.turnSeq=failed.seq AND claim.kind='claimed'
  JOIN turn_lifecycle_events terminal ON terminal.turnSeq=failed.seq
    AND terminal.kind='terminal_committed' AND terminal.outcome='failed'
  JOIN turns originating ON originating.seq=w.originatingTurnSeq
  WHERE retry.wakeId=w.wakeId AND retry.attempt=prior.attempt+1
    AND retry.rootWakeId=prior.rootWakeId AND prior.retryWakeId=retry.wakeId
    AND retry.outcome='pending' AND prior.outcome='failed'
    AND old.state='fired' AND old.consumer=w.consumer AND old.digest=0 AND w.digest=0
    AND old.assignmentId=w.assignmentId AND old.obligationRef IS w.obligationRef
    AND old.sessionKey=w.sessionKey AND old.targetRole IS w.targetRole
    AND old.origin=w.origin AND old.creatorSessionKey IS w.creatorSessionKey
    AND old.ownerUserId=w.ownerUserId AND old.waitMode=w.waitMode
    AND old.originatingTurnSeq IS w.originatingTurnSeq
    AND old.recognitionAt IS w.recognitionAt AND w.recognitionAt IS NOT NULL
    AND old.recognitionPath IS w.recognitionPath
    AND old.recognitionEvidence IS w.recognitionEvidence
    AND old.recognitionTransition IS w.recognitionTransition
    AND s.state='active' AND originating.sessionKey=w.creatorSessionKey
    AND originating.status IN ('delivered','canceled','failed','failed_unknown')
    AND sidecar.assignmentId=w.assignmentId
    AND sidecar.controllerOrigin='holder_continuation' AND sidecar.controllerState='settled'
    AND sidecar.wakeKind IS NULL AND sidecar.chargedGeneration IS NULL
    AND sidecar.transferEvidenceId IS NULL
    AND failed.status='failed' AND failed.sessionKey=w.sessionKey
    AND claim.ownerLease IS NOT NULL AND length(claim.ownerLease)>0
    AND terminal.ownerLease=claim.ownerLease
    AND NOT EXISTS (SELECT 1 FROM turn_lifecycle_events dispatched
      WHERE dispatched.turnSeq=failed.seq AND dispatched.kind='prompt_dispatched')
    AND old.deliveredTurnSeq=failed.seq
    AND json_extract(terminal.detail,'$.prewrite.disposition')='not_dispatched'
    AND (SELECT count(*) FROM json_each(terminal.detail,'$.prewrite'))=4
    AND (
      (json_extract(terminal.detail,'$.prewrite.reason')='transport_capacity_exceeded'
        AND json_type(terminal.detail,'$.prewrite.requestBytes')='integer'
        AND json_type(terminal.detail,'$.prewrite.limitBytes')='integer'
        AND json_extract(terminal.detail,'$.prewrite.limitBytes')>0
        AND json_extract(terminal.detail,'$.prewrite.requestBytes')>
          json_extract(terminal.detail,'$.prewrite.limitBytes'))
      OR
      (json_extract(terminal.detail,'$.prewrite.reason')='submission_text_limit_exceeded'
        AND json_type(terminal.detail,'$.prewrite.textChars')='integer'
        AND json_extract(terminal.detail,'$.prewrite.limitChars')=1048576
        AND json_extract(terminal.detail,'$.prewrite.textChars')>1048576)
    )
)
 OR EXISTS (
        SELECT 1 FROM turns t WHERE t.seq=w.originatingTurnSeq
          AND t.sessionKey=w.creatorSessionKey AND t.status='running'
      ))
  )
)
BEGIN
  SELECT RAISE(ABORT, 'supervision sidecar requires coherent pending wake');
END;
CREATE TRIGGER decision_requests_row_schema_revision_insert_guard
BEFORE INSERT ON decision_requests
WHEN typeof(NEW.rowSchemaRevision) <> 'integer' OR NEW.rowSchemaRevision NOT IN (1,2)
BEGIN
  SELECT RAISE(ABORT, 'decision_request_row_revision_invalid');
END;
CREATE TRIGGER decision_requests_row_schema_revision_update_guard
BEFORE UPDATE OF rowSchemaRevision ON decision_requests
WHEN typeof(NEW.rowSchemaRevision) <> 'integer' OR NEW.rowSchemaRevision NOT IN (1,2)
BEGIN
  SELECT RAISE(ABORT, 'decision_request_row_revision_invalid');
END;
CREATE INDEX assignments_reviews_assignment ON assignments(reviewsAssignmentId);
CREATE UNIQUE INDEX assignment_revocation_generation_reopened ON assignment_revocation_generations(assignmentId,reopeningId);
CREATE INDEX retired_workspace_cleanup_due ON retired_workspace_cleanup(completed,nextAt);
CREATE TRIGGER retired_workspace_cleanup_enqueue AFTER UPDATE OF state ON sessions
WHEN NEW.state='retired' AND OLD.state<>'retired'
BEGIN
  INSERT OR IGNORE INTO retired_workspace_cleanup(sessionKey) VALUES(NEW.sessionKey);
END;
CREATE INDEX pending_recognition_waits_fact ON pending_recognition_waits(kind,scope);
CREATE INDEX notice_batch_members_source ON notice_batch_members(sourceWakeId);
CREATE TRIGGER attests_evidence_insert BEFORE INSERT ON attests
WHEN (NEW.artifactId IS NULL) != (NEW.contentSha256 IS NULL)
  OR (NEW.artifactId IS NOT NULL AND NEW.kind != 'verdict')
  OR (NEW.contentSha256 IS NOT NULL AND
      (length(NEW.contentSha256) != 64 OR
       NEW.contentSha256 != lower(NEW.contentSha256) OR
       NEW.contentSha256 GLOB '*[^0-9a-f]*'))
BEGIN SELECT RAISE(ABORT, 'invalid attest evidence binding'); END;
CREATE TRIGGER attests_evidence_immutable BEFORE UPDATE OF artifactId,contentSha256 ON attests
BEGIN SELECT RAISE(ABORT, 'attest evidence binding is immutable'); END;
CREATE INDEX memento_history_record ON memento_history(recordKind,recordId,id);
CREATE INDEX memento_history_key ON memento_history(recordKind,recordId,name,id);
CREATE TRIGGER memento_history_immutable_update
  BEFORE UPDATE ON memento_history BEGIN SELECT RAISE(ABORT,'memento_history_immutable'); END;
CREATE TRIGGER memento_history_immutable_delete
  BEFORE DELETE ON memento_history BEGIN SELECT RAISE(ABORT,'memento_history_immutable'); END;
CREATE TRIGGER memento_judgment_insert AFTER INSERT ON attests
WHEN NEW.kind='verdict'
BEGIN
  INSERT INTO memento_judgments
    (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
  SELECT a.id,'holder',NEW.ts,NEW.rowid,NEW.id,NEW.verdictKind,0
  FROM assignments a
  WHERE a.id=NEW.assignmentId AND NEW.bySession=a.holderKey AND NEW.byUser IS NULL;

  INSERT INTO memento_judgments
    (assignmentId,selector,ts,attestRow,attestId,judgmentKind,independent)
  SELECT p.id,'linked_review',NEW.ts,NEW.rowid,NEW.id,NEW.verdictKind,
         CASE WHEN r.holderKey!=p.holderKey THEN 1 ELSE 0 END
  FROM assignments r JOIN assignments p ON p.id=r.reviewsAssignmentId
  WHERE r.id=NEW.assignmentId AND NEW.bySession=r.holderKey AND NEW.byUser IS NULL;
END;
CREATE INDEX messages_session ON messages (sessionKey, seq);
CREATE UNIQUE INDEX messages_client_dedupe
  ON messages (sessionKey, deviceId, clientMessageId)
  WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
CREATE INDEX tool_calls_session_seq ON tool_calls (sessionKey, seq);
CREATE INDEX tool_calls_session_anchor ON tool_calls (sessionKey, afterMessageSeq);
CREATE INDEX turn_events_session_order
  ON turn_events (sessionKey, turnSeq, turnEventSeq, id);
CREATE TRIGGER turn_events_no_update
  BEFORE UPDATE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END;
CREATE TRIGGER turn_events_no_delete
  BEFORE DELETE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END;
CREATE INDEX events_process_assignment
ON events (json_extract(payload,'$.id'), verb, id)
WHERE kind='verb' AND verb IN ('assign','dispatch','revoke-assignment')
  AND substr(principal,1,8)='process:' AND principal!='process:tightbeam'
;
CREATE INDEX artifacts_work_item ON artifacts (workItemId);
CREATE INDEX artifacts_producer ON artifacts (producedByAssignmentId);
CREATE INDEX artifacts_created_by_session ON artifacts (createdBySession);
CREATE INDEX artifacts_recorded_message ON artifacts (recordedMessageId);
CREATE TRIGGER artifacts_released_requires_content_insert
BEFORE INSERT ON artifacts
WHEN NEW.state = 'released'
 AND EXISTS (
   SELECT 1 FROM artifact_contents c WHERE c.artifactId = NEW.artifactId
 )
 AND NOT EXISTS (
   SELECT 1 FROM artifact_contents c
   WHERE c.artifactId = NEW.artifactId AND c.contentSha256 = NEW.contentSha256
 )
BEGIN
  SELECT RAISE(ABORT, 'released artifact requires durable content');
END;
CREATE TRIGGER artifacts_released_requires_content_update
BEFORE UPDATE OF state, contentSha256 ON artifacts
WHEN NEW.state = 'released'
 AND EXISTS (
   SELECT 1 FROM artifact_contents c WHERE c.artifactId = NEW.artifactId
 )
 AND NOT EXISTS (
   SELECT 1 FROM artifact_contents c
   WHERE c.artifactId = NEW.artifactId AND c.contentSha256 = NEW.contentSha256
 )
BEGIN
  SELECT RAISE(ABORT, 'released artifact requires durable content');
END;
CREATE TRIGGER artifacts_origin_immutable
BEFORE UPDATE OF originHost, originWorkspace ON artifacts
WHEN NEW.originHost IS NOT OLD.originHost OR NEW.originWorkspace IS NOT OLD.originWorkspace
BEGIN
  SELECT RAISE(ABORT, 'artifact_origin_immutable');
END;
CREATE INDEX session_retirement_parent_moves_child ON session_retirement_parent_moves(childSessionKey,eventSeq);
CREATE INDEX session_retirement_parent_moves_request ON session_retirement_parent_moves(retirementRequestId,eventSeq);
CREATE INDEX session_retirement_parent_moves_idempotency ON session_retirement_parent_moves(retiredTargetSessionKey,ownerUserId,idempotencyKey,eventSeq);
CREATE TRIGGER session_retirement_parent_moves_no_update BEFORE UPDATE ON session_retirement_parent_moves BEGIN SELECT RAISE(ABORT,'session_retirement_parent_moves is append-only'); END;
CREATE TRIGGER session_retirement_parent_moves_no_delete BEFORE DELETE ON session_retirement_parent_moves BEGIN SELECT RAISE(ABORT,'session_retirement_parent_moves is append-only'); END;
CREATE UNIQUE INDEX unfinished_retirements_open_pair ON unfinished_retirements(targetSessionKey,ownerSessionKey) WHERE state='open';
CREATE INDEX unfinished_retirements_owner ON unfinished_retirements(ownerSessionKey) WHERE state='open';
CREATE INDEX retirement_blockers_reference ON retirement_blockers(kind,reference,retirementId);
CREATE INDEX session_reparent_child ON session_reparent_events(childSessionKey,eventSeq);
CREATE INDEX session_reparent_assignment ON session_reparent_events(assignmentId,eventSeq);
CREATE TRIGGER session_reparent_no_update BEFORE UPDATE ON session_reparent_events
BEGIN SELECT RAISE(ABORT,'session_reparent_events is append-only'); END;
CREATE TRIGGER session_reparent_no_delete BEFORE DELETE ON session_reparent_events
BEGIN SELECT RAISE(ABORT,'session_reparent_events is append-only'); END;
CREATE INDEX assignments_record_event_holder_order ON assignments(holderKey, openedAt, id);
CREATE INDEX assignments_record_event_opener_order ON assignments(openedBySession, openedAt, id);
CREATE INDEX messages_record_event_ids ON messages(recordEventIds, sessionKey, seq, id) WHERE recordEventIds IS NOT NULL;
CREATE INDEX messages_record_event_reply ON messages(replyToMessageId, sessionKey, seq, id) WHERE replyToMessageId IS NOT NULL;
CREATE INDEX wakes_record_event_ids ON wakes(recordEventIds, wakeId) WHERE recordEventIds IS NOT NULL;
CREATE INDEX holder_prod_turn_end
  ON turns(sessionKey, endedAt DESC) WHERE endedAt IS NOT NULL;
CREATE INDEX holder_prod_attempt_episode
  ON assignment_holder_prod_attempts(episodeId, id DESC);
CREATE INDEX holder_prod_attempt_report_recency
  ON assignment_holder_prod_attempts(admittedAt) WHERE wakeId IS NULL;
CREATE INDEX holder_prod_wake_delivery
  ON wakes(firedAt) WHERE deliveredTurnSeq IS NOT NULL
    AND origin='process:tightbeam' AND substr(obligationRef,1,26)='assignment-holder-prod-v1:';
CREATE UNIQUE INDEX harness_model_rate_limits_turn ON harness_model_rate_limits(turnSeq) WHERE turnSeq IS NOT NULL;
CREATE UNIQUE INDEX harness_model_rate_limits_attempt ON harness_model_rate_limits(compactionAttemptKey) WHERE compactionAttemptKey IS NOT NULL;
CREATE INDEX harness_model_rate_limits_held ON harness_model_rate_limits(harness,host,model,releasedAt);
CREATE UNIQUE INDEX coordinator_outage_decision_open
  ON coordinator_outage_decisions(ownerUserId) WHERE closedAt IS NULL;
COMMIT;
