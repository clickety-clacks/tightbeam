-- Captured predecessor-domain fixture.
-- Source build: Tightbeam 724e5c96f9513b37e937dc52eb014ba1ef2d1b5e
-- Source shape: coordination-fabric-v1-phase1-v9
-- Capture method: exact base Schema.ensure_all/1 followed by a SQLite dump of
-- closed, failed, completed, surrendered, revoked, and completed-then-reopened rows.

INSERT INTO users (userId,isAdmin,creationKind,createdAt)
VALUES ('flynn',0,'admin_add',1);

INSERT INTO sessions
  (sessionKey,displayName,kind,orderIndex,isBuiltIn,adopted,ownerUserId,origin,
   spawnedBy,operationalParent,archetype,harness,provider,model,host,state,
   createdAt,updatedAt)
VALUES
  ('v9-main','V9 Main','main',0,0,0,'flynn','fixture',NULL,NULL,'main',
   'codex','openai','gpt-5','testhost','active',2,2),
  ('v9-product-owner','V9 Product Owner','custom',0,0,0,'flynn','fixture',
   'v9-main','v9-main','product-owner','codex','openai','gpt-5','testhost','active',3,3),
  ('v9-holder','V9 Holder','custom',0,0,0,'flynn','fixture',
   'v9-product-owner','v9-product-owner','coder','codex','openai','gpt-5','testhost','active',4,4);

INSERT INTO work_items
  (id,title,isBug,ownerUserId,state,failReason,createdByUser,createdContextKnown,createdAt)
VALUES
  ('wi_v9_closed','Captured closed card',0,'flynn','closed',NULL,'flynn',1,10),
  ('wi_v9_failed','Captured failed card',0,'flynn','failed','captured failure','flynn',1,11),
  ('wi_v9_active','Captured active card',0,'flynn','open',NULL,'flynn',1,12);

INSERT INTO assignments
  (id,subject,holderKey,holderFallback,openedByUser,openedAt,state,workItemId,
   holderHarness,holderProvider)
VALUES
  ('asg_v9_completed','Captured completed result','v9-holder',0,'flynn',20,'open',
   'wi_v9_closed','codex','openai'),
  ('asg_v9_surrendered','Captured surrendered result','v9-holder',0,'flynn',21,'open',
   'wi_v9_active','codex','openai'),
  ('asg_v9_revoked','Captured revoked result','v9-holder',0,'flynn',22,'open',
   'wi_v9_active','codex','openai'),
  ('asg_v9_reopened','Captured reopened result','v9-holder',0,'flynn',23,'open',
   'wi_v9_active','codex','openai');

INSERT INTO assignment_effects (assignmentId,effectKind)
VALUES
  ('asg_v9_completed','code'),
  ('asg_v9_surrendered','code'),
  ('asg_v9_revoked','code'),
  ('asg_v9_reopened','code');

INSERT INTO attests
  (id,assignmentId,kind,note,bySession,commitRefs,ts)
VALUES
  ('att_v9_completed','asg_v9_completed','completion','captured completion','v9-holder',
   '[{"repo":"testhost:/captured/repo","commit":"1111111111111111111111111111111111111111"}]',30),
  ('att_v9_surrendered','asg_v9_surrendered','surrender','captured surrender','v9-holder',NULL,31),
  ('att_v9_reopened_old','asg_v9_reopened','completion','captured old completion','v9-holder',NULL,32);

UPDATE assignments
SET state='closed',outcome='completed',closedAt=30,closedBySession='v9-holder',
    closingAttestId='att_v9_completed'
WHERE id='asg_v9_completed';

UPDATE assignments
SET state='closed',outcome='surrendered',closedAt=31,closedBySession='v9-holder',
    closingAttestId='att_v9_surrendered'
WHERE id='asg_v9_surrendered';

UPDATE assignments
SET state='closed',outcome='revoked',closedAt=33,closedByUser='flynn'
WHERE id='asg_v9_revoked';

INSERT INTO assignment_reopenings
  (assignmentId,ts,reopenedByUser,reason,priorOutcome,priorClosedAt,
   priorClosedBySession,priorClosingAttestId)
VALUES
  ('asg_v9_reopened',34,'flynn','captured predecessor reopen','completed',32,
   'v9-holder','att_v9_reopened_old');
