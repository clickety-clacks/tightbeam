      CREATE TABLE IF NOT EXISTS supervision_liveness_sidecar (
        wakeId TEXT PRIMARY KEY REFERENCES wakes(wakeId),
        assignmentId TEXT NOT NULL REFERENCES assignments(id),
        controllerOrigin TEXT CHECK (controllerOrigin IN ('scheduled','retirement_elevation')),
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
      CREATE TRIGGER IF NOT EXISTS supervision_liveness_sidecar_insert_coherent
      BEFORE INSERT ON supervision_liveness_sidecar
      WHEN NOT EXISTS (
        SELECT 1 FROM wakes w
        WHERE w.wakeId=NEW.wakeId AND w.assignmentId=NEW.assignmentId
          AND w.consumer='prompt' AND w.origin='process:tightbeam'
      )
      OR (
        NEW.controllerOrigin IS NOT NULL
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
      BEGIN
        SELECT RAISE(ABORT, 'supervision sidecar requires coherent pending wake');
      END;
