# Database observation retention

The gateway appends newline-delimited `db-gateway-v1` JSON records under its
base directory's `diagnostics/` directory. The existing `db-gateway-v1.log`
and its `.1`–`.3` rotations remain unchanged. Readers that parse these JSON
records can parse the additional files the same way:

- `db-gateway-v1.log.slow` and `.slow.1`–`.slow.3`: completed writer
  transactions whose total time minus queue wait is at least 1,000 ms.
- `db-gateway-v1.log.pressure` and `.pressure.1`–`.pressure.3`: completed
  caller observations with at least 1,000 ms queue wait, or an unsent overload
  refusal (`result_class: "db_overloaded"`).

Each archive has its own four segments. Each segment holds at most 4,096
records or 16 MiB, whichever comes first; rotation replaces the oldest segment.
A refusal burst cannot evict slow transactions. Normal fast traffic cannot
evict either archive. Each archive also keeps its last 16,384 records in
memory. `Tightbeam.Diagnostics.records/1` returns the union of the existing
recent window and both in-memory archives, in timestamp order without exact
duplicates. Disk archives survive a gateway restart; in-memory records do not.
The existing log remains the record of all accepted observations, including
HTTP responses that can be correlated by request id.

Records retain their observation time, database call and request ids, operation,
duration and queue wait. `caller` carries the matched HTTP method and route
template, or the internal component reference already bound at entry. Unbound
internal calls retain `internal:db_client`. No concrete URL, SQL, request body,
exception text or credential is added. The existing diagnostic field allowlist,
text clamps and 4,096-byte encoded-record limit apply to all streams.

At 500–600 database calls a second and two observations per call, the original
16,384-record window covers about 14–16 seconds. The slow archive's capacity is
independent of that rate: a single writer cannot complete more than one
transaction taking at least one second per second. Its disk window is at least
12,288 such completions (about 3.4 hours at that maximum rate), and up to 16,384
(4.6 hours). At one slow transaction per minute it covers 8.5–11.4 days. Byte
limits do not reduce this count for admitted records: 4,096 records of at most
4,096 bytes plus newline would exceed 16 MiB by at most one record per segment.
These are capacity estimates, not a guarantee against dropped ingress records
or storage failures.

The pressure archive covers roughly 3.4–4.6 hours at one event per second,
but only 20–33 seconds under a sustained flood of 500–600 pressure events per
second. That flood cannot shorten slow-transaction retention. Each archive
adds at most 64 MiB of disk (128 MiB combined), plus at most 16,384 in-memory
record maps and queue entries (32,768 combined). Actual heap cost depends on
record fields and shared terms. There are no database writes, new processes,
timers or writer-queue entries. Classification, extra file writes, rotation
and retained queues run only in the existing asynchronous diagnostic sink.

The sink retains its existing bounded, non-blocking ingress and drop/failure
counters exposed by `/version`. Saturation can drop records; an absent record
is not proof that an event did not occur. An unavailable archive increments the
same write-failure counter and does not change the observed database result.
The released 0.1.16 implementation has no environment or runtime configuration
setting for these compiled retention bounds.

An isolated synthetic probe submitted 51,200 ordinary observations, then 16,384
slow and 16,384 queued observations, in bounded batches with zero drops. With
archives enabled the ordinary phase took 2.986 s versus 2.849 s on unchanged
source; the significant phase took 3.347 s versus 1.772 s (the latter does not
retain archives). After garbage collection the sink process occupied
11,516,752 bytes versus 9,597,464 bytes after the significant phase. Disk usage
was 13,211,744 bytes in 12 files versus 3,649,632 bytes in four files. These are
illustrative measurements of this record mix, not fixed per-record costs or a
service latency guarantee. Both ordinary runs drained over 17,000 observations
per second, comfortably above 1,000–1,200 observations/s at the incident call
rate. The measurements ran consecutively on the same isolated checkout with
one-minute system load between 0.8 and 1.9.
