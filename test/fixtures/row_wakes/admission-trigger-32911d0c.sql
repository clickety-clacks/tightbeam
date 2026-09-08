CREATE TRIGGER IF NOT EXISTS supervision_liveness_sidecar_insert_coherent
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
      AND w.creatorSessionKey=a.holderKey AND w.ownerUserId=s.ownerUserId
      AND w.waitMode IN ('dependency','after-turn') AND w.prompt IS NOT NULL
      AND (w.originatingTurnSeq IS NULL OR EXISTS (
        SELECT 1 FROM turns t WHERE t.seq=w.originatingTurnSeq
          AND t.sessionKey=w.creatorSessionKey AND t.status='running'
      ))
  )
)
BEGIN
  SELECT RAISE(ABORT, 'supervision sidecar requires coherent pending wake');
END
