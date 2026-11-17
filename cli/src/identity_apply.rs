//! `tightbeam identity apply --all` as a sequence of bounded gateway steps.
//!
//! The gateway handles a bounded number of sessions per request and returns a
//! cursor for the rest. Each step's work is durable when the step returns, so
//! an interrupted run loses nothing and a repeated run passes quickly over
//! sessions that are already current.

use std::io::Write;

use serde_json::{Map, Value, json};

/// Sessions asked for per step. The gateway also ends a step on a time budget.
pub const STEP_LIMIT: u32 = 100;

/// What a run has done so far, across the steps it has completed.
#[derive(Default)]
pub struct Run {
    revision: Option<String>,
    total: u64,
    complete: bool,
    results: Vec<Value>,
    applied: Vec<Value>,
    targets: Vec<Value>,
}

/// How one session came out, in the terms the final report uses.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Outcome {
    Updated,
    AlreadyCurrent,
    Skipped,
    Busy,
    Superseded,
    Failed,
}

impl Outcome {
    fn of(result: &Value) -> Self {
        let field = |name: &str| result.get(name).and_then(Value::as_str).unwrap_or("");
        match (field("outcome"), field("files")) {
            ("applied", "already_current") => Self::AlreadyCurrent,
            ("applied", _) => Self::Updated,
            ("skipped", _) => Self::Skipped,
            ("busy", _) => Self::Busy,
            ("superseded", _) => Self::Superseded,
            _ => Self::Failed,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Updated => "updated",
            Self::AlreadyCurrent => "already current",
            Self::Skipped => "skipped",
            Self::Busy => "busy",
            Self::Superseded => "superseded",
            Self::Failed => "failed",
        }
    }

    const ALL: [Self; 6] = [
        Self::Updated,
        Self::AlreadyCurrent,
        Self::Skipped,
        Self::Busy,
        Self::Superseded,
        Self::Failed,
    ];
}

impl Run {
    fn count(&self, outcome: Outcome) -> usize {
        self.results
            .iter()
            .filter(|result| Outcome::of(result) == outcome)
            .count()
    }

    /// Fold one step's response into the run. Returns the cursor for the next
    /// step, or `None` when the gateway has no sessions left.
    pub fn absorb(&mut self, step: &Value) -> Option<String> {
        let first = self.revision.is_none();
        if first {
            self.revision = step
                .get("identityRevision")
                .and_then(Value::as_str)
                .map(str::to_owned);
            self.complete = true;
        }
        let list = |name: &str| {
            step.get(name)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let results = list("results");
        // A gateway that does not page answers the whole run in one response.
        self.total = step
            .get("total")
            .and_then(Value::as_u64)
            .unwrap_or((self.results.len() + results.len()) as u64);
        self.complete &= step.get("complete").and_then(Value::as_bool) == Some(true);
        self.results.extend(results);
        self.applied.extend(list("applied"));
        self.targets.extend(list("targetSessionKeys"));
        step.get("cursor")
            .and_then(Value::as_str)
            .map(str::to_owned)
    }

    fn counts(&self) -> String {
        Outcome::ALL
            .iter()
            .filter_map(|outcome| match self.count(*outcome) {
                0 => None,
                count => Some(format!("{count} {}", outcome.label())),
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// One line per completed step, for the terminal.
    pub fn progress_line(&self) -> String {
        format!(
            "identity apply: {} of {} sessions ({})",
            self.results.len(),
            self.total,
            self.counts()
        )
    }

    /// The closing lines: every session that was not brought to the revision,
    /// with the gateway's reason, and what to do about them.
    pub fn closing_lines(&self, finished: bool) -> Vec<String> {
        let mut lines = Vec::new();
        for result in &self.results {
            let outcome = Outcome::of(result);
            if matches!(outcome, Outcome::Updated | Outcome::AlreadyCurrent) {
                continue;
            }
            let session = result
                .get("sessionKey")
                .and_then(Value::as_str)
                .unwrap_or("?");
            let reason = result
                .get("reason")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| {
                    result
                        .get("currentIdentityRevision")
                        .and_then(Value::as_str)
                        .map(|live| {
                            format!("identity revision {live} was published during the run")
                        })
                })
                .unwrap_or_else(|| match outcome {
                    Outcome::Skipped => "retired during the run".to_owned(),
                    _ => "no reason reported".to_owned(),
                });
            lines.push(format!("  {:<10} {session}: {reason}", outcome.label()));
        }
        let unfinished = self.total.saturating_sub(self.results.len() as u64) as usize;
        let open = unfinished
            + self.count(Outcome::Busy)
            + self.count(Outcome::Superseded)
            + self.count(Outcome::Failed);
        let revision = self.revision.as_deref().unwrap_or("unknown");
        if finished && open == 0 {
            lines.push(format!(
                "identity apply: every session is on revision {revision}"
            ));
        } else {
            lines.push(format!(
                "identity apply: {open} sessions are not on revision {revision}; what was applied is kept. Run the same command again to continue."
            ));
        }
        lines
    }

    /// The machine-readable result: the fields one unpaged response carried,
    /// for the whole run, plus the count by outcome.
    pub fn report(&self, finished: bool) -> Value {
        let complete = finished && self.complete;
        let mut summary = Map::new();
        for (name, outcome) in [
            ("updated", Outcome::Updated),
            ("alreadyCurrent", Outcome::AlreadyCurrent),
            ("skipped", Outcome::Skipped),
            ("busy", Outcome::Busy),
            ("superseded", Outcome::Superseded),
            ("failed", Outcome::Failed),
        ] {
            summary.insert(name.to_owned(), json!(self.count(outcome)));
        }
        json!({
            "status": if complete { "complete" } else { "partial" },
            "complete": complete,
            "identityRevision": self.revision,
            "total": self.total,
            "handled": self.results.len(),
            "summary": summary,
            "targetSessionKeys": self.targets,
            "applied": self.applied,
            "results": self.results,
        })
    }
}

/// Drive the run: one request per step until the gateway returns no cursor.
/// Progress goes to `progress`, the final JSON to `output`.
pub fn run_all<S>(
    send_step: S,
    output: &mut dyn Write,
    progress: &mut dyn Write,
) -> Result<(), String>
where
    S: Fn(Option<&str>) -> Result<Option<Value>, String>,
{
    let mut run = Run::default();
    let mut cursor: Option<String> = None;
    loop {
        let step = match send_step(cursor.as_deref()) {
            Ok(Some(step)) => step,
            Ok(None) => json!({}),
            Err(error) => {
                // Earlier steps are durable; say what they did before failing.
                if !run.results.is_empty() {
                    for line in run.closing_lines(false) {
                        let _ = writeln!(progress, "{line}");
                    }
                    let _ = writeln!(output, "{}", pretty(&run.report(false)));
                }
                return Err(error);
            }
        };
        cursor = run.absorb(&step);
        let _ = writeln!(progress, "{}", run.progress_line());
        if cursor.is_none() {
            break;
        }
    }
    for line in run.closing_lines(true) {
        let _ = writeln!(progress, "{line}");
    }
    writeln!(output, "{}", pretty(&run.report(true))).map_err(|error| error.to_string())
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).expect("JSON value serializes")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn result(session: &str, outcome: &str, files: &str) -> Value {
        json!({"sessionKey": session, "outcome": outcome, "files": files})
    }

    fn step(results: Vec<Value>, total: u64, cursor: Option<&str>) -> Value {
        let applied: Vec<Value> = results
            .iter()
            .filter(|result| result["outcome"] == "applied")
            .map(|result| result["sessionKey"].clone())
            .collect();
        let targets: Vec<Value> = results
            .iter()
            .map(|result| result["sessionKey"].clone())
            .collect();
        let complete = results
            .iter()
            .all(|result| result["outcome"] == "applied" || result["outcome"] == "skipped");
        json!({
            "status": if complete { "complete" } else { "partial" },
            "complete": complete,
            "identityRevision": "rev-1",
            "targetSessionKeys": targets,
            "applied": applied,
            "results": results,
            "total": total,
            "cursor": cursor,
        })
    }

    #[test]
    fn a_run_follows_the_cursor_and_reports_every_step_and_session() {
        let steps = RefCell::new(vec![
            step(
                vec![
                    result("agent:a", "applied", "materialized"),
                    result("agent:b", "applied", "already_current"),
                ],
                4,
                Some("cursor-1"),
            ),
            step(
                vec![
                    json!({"sessionKey": "agent:c", "outcome": "busy", "files": "not_started",
                           "reason": "a turn is being set up"}),
                    json!({"sessionKey": "agent:d", "outcome": "partial",
                           "files": "materialized", "reason": "disk full"}),
                ],
                4,
                None,
            ),
        ]);
        let cursors = RefCell::new(Vec::new());
        let mut output = Vec::new();
        let mut progress = Vec::new();

        run_all(
            |cursor| {
                cursors.borrow_mut().push(cursor.map(str::to_owned));
                Ok(Some(steps.borrow_mut().remove(0)))
            },
            &mut output,
            &mut progress,
        )
        .unwrap();

        // The second request resumes from the cursor the first step returned.
        assert_eq!(*cursors.borrow(), vec![None, Some("cursor-1".to_owned())]);

        let progress = String::from_utf8(progress).unwrap();
        assert_eq!(
            progress.lines().collect::<Vec<_>>(),
            vec![
                "identity apply: 2 of 4 sessions (1 updated, 1 already current)",
                "identity apply: 4 of 4 sessions (1 updated, 1 already current, 1 busy, 1 failed)",
                "  busy       agent:c: a turn is being set up",
                "  failed     agent:d: disk full",
                "identity apply: 2 sessions are not on revision rev-1; what was applied is kept. Run the same command again to continue.",
            ]
        );

        let report: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(report["status"], "partial");
        assert_eq!(report["complete"], false);
        assert_eq!(report["identityRevision"], "rev-1");
        assert_eq!(report["total"], 4);
        assert_eq!(report["handled"], 4);
        assert_eq!(
            report["summary"],
            json!({"updated": 1, "alreadyCurrent": 1, "skipped": 0, "busy": 1,
                   "superseded": 0, "failed": 1})
        );
        assert_eq!(report["applied"], json!(["agent:a", "agent:b"]));
        assert_eq!(
            report["targetSessionKeys"],
            json!(["agent:a", "agent:b", "agent:c", "agent:d"])
        );
        assert_eq!(report["results"].as_array().unwrap().len(), 4);
    }

    #[test]
    fn a_step_that_fails_keeps_and_reports_what_earlier_steps_did() {
        let calls = RefCell::new(0);
        let mut output = Vec::new();
        let mut progress = Vec::new();

        let error = run_all(
            |_cursor| {
                *calls.borrow_mut() += 1;
                if *calls.borrow() == 1 {
                    Ok(Some(step(
                        vec![result("agent:a", "applied", "materialized")],
                        3,
                        Some("cursor-1"),
                    )))
                } else {
                    Err("gateway_transport_uncertain".to_owned())
                }
            },
            &mut output,
            &mut progress,
        )
        .unwrap_err();

        assert_eq!(error, "gateway_transport_uncertain");
        let report: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(report["status"], "partial");
        assert_eq!(report["complete"], false);
        assert_eq!(report["handled"], 1);
        assert_eq!(report["total"], 3);
        assert_eq!(report["applied"], json!(["agent:a"]));
        assert!(String::from_utf8(progress).unwrap().ends_with(
            "identity apply: 2 sessions are not on revision rev-1; what was applied is kept. Run the same command again to continue.\n"
        ));
    }

    #[test]
    fn a_complete_run_says_every_session_is_on_the_revision() {
        let mut output = Vec::new();
        let mut progress = Vec::new();

        run_all(
            |_cursor| {
                Ok(Some(step(
                    vec![
                        result("agent:a", "applied", "materialized"),
                        result("agent:b", "skipped", "not_updated"),
                    ],
                    2,
                    None,
                )))
            },
            &mut output,
            &mut progress,
        )
        .unwrap();

        let report: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(report["status"], "complete");
        assert_eq!(report["complete"], true);
        assert_eq!(
            String::from_utf8(progress)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            vec![
                "identity apply: 2 of 2 sessions (1 updated, 1 skipped)",
                "  skipped    agent:b: retired during the run",
                "identity apply: every session is on revision rev-1",
            ]
        );
    }
}
