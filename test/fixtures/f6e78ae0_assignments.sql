-- Exact assignments DDL from owned f6e78ae0; migration fixture prerequisite only.
-- Minimal FK parents for the deliberately narrow session/artifact fixtures.
CREATE TABLE IF NOT EXISTS users(userId TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS attests(id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS work_items(id TEXT PRIMARY KEY);
  CREATE TABLE IF NOT EXISTS assignments (
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
  )
