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
          SELECT sessionKey,COALESCE((SELECT rp.newCurrentParentSessionKey FROM session_reparent_events rp WHERE rp.childSessionKey=sessions.sessionKey ORDER BY rp.eventSeq DESC LIMIT 1), sessions.spawnedBy) FROM sessions
            WHERE sessionKey=a.holderKey AND ownerUserId=w.ownerUserId
          UNION
          SELECT ancestor.sessionKey,COALESCE((SELECT rp.newCurrentParentSessionKey FROM session_reparent_events rp WHERE rp.childSessionKey=ancestor.sessionKey ORDER BY rp.eventSeq DESC LIMIT 1), ancestor.spawnedBy)
            FROM sessions ancestor JOIN lineage child ON ancestor.sessionKey=child.spawnedBy
            WHERE ancestor.ownerUserId=w.ownerUserId
        )
        SELECT 1 FROM lineage WHERE sessionKey=w.creatorSessionKey
      )
      AND w.waitMode IN ('dependency','after-turn') AND w.prompt IS NOT NULL
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
    AND EXISTS (SELECT 1 FROM (SELECT t.seq AS turnSeq,t.wakeId AS sourceWakeId,t.assignmentId AS assignmentId,
       0 AS carrier,NULL AS publicationSeq
FROM turns t WHERE t.wakeId IS NOT NULL
UNION ALL
SELECT t.seq,m.sourceWakeId,w.assignmentId,1,m.publicationSeq
FROM notice_batch_members m
JOIN notice_batches b ON b.batchId=m.batchId
JOIN wakes w ON w.wakeId=m.sourceWakeId
JOIN turns t ON t.wakeId=b.deliveryWakeId
WHERE m.state='included'
) delivery
      WHERE delivery.sourceWakeId=old.wakeId AND delivery.turnSeq=failed.seq
        AND delivery.assignmentId=w.assignmentId)
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
END
