//! B-owned completion precursor for the frozen attempt_diagnostic carrier.
//! Register as a child of that module only in the approved fidelity handoff.
//! No network, retry, renderer, dependency, or shared Err-arm wiring lives here.

use super::*;
use base64::Engine;
use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(test)]
#[path = "observation_tests.rs"]
mod tests;

/// Facts must come from the actual transport boundary, never elapsed time,
/// error prose, a configured budget, or a previous attempt's connection.
pub(crate) enum FailureFact {
    Unclassified,
    DnsBeforeExchange,
    RefusedBeforeExchange,
    ConnectDeadlineBeforeExchange,
    RequestDeadlineAfterConnect,
    ResetAfterConnect,
    OtherAfterConnect,
}

impl FailureFact {
    fn from_transport(error: &ureq::Transport) -> Self {
        use std::error::Error as _;
        use std::io::ErrorKind as Io;
        use ureq::{ErrorKind, TransportPhase as Phase, TransportRoute as Route};

        if error.has_prior_exchange() {
            return Self::Unclassified;
        }
        let Some(evidence) = error.phase_evidence() else {
            return Self::Unclassified;
        };
        if evidence.route == Route::OtherProxy {
            return Self::Unclassified;
        }
        let io_kind = error.source().and_then(|source| {
            source
                .downcast_ref::<std::io::Error>()
                .map(std::io::Error::kind)
        });
        match evidence.phase {
            Phase::Resolve if error.kind() == ErrorKind::Dns => Self::DnsBeforeExchange,
            Phase::Connect => match io_kind {
                Some(Io::ConnectionRefused) => Self::RefusedBeforeExchange,
                Some(Io::TimedOut) => Self::ConnectDeadlineBeforeExchange,
                _ => Self::Unclassified,
            },
            Phase::ConnectedSetup | Phase::TlsHandshake if evidence.route == Route::Direct => {
                Self::after_connect(io_kind)
            }
            Phase::SendRequest | Phase::AwaitResponse
                if matches!(evidence.route, Route::Direct | Route::HttpTunnel) =>
            {
                Self::after_connect(io_kind)
            }
            // A proxy handshake/forwarded reply or stale pool check is not an
            // observed gateway channel. Do not infer it from a timeout kind.
            _ => Self::Unclassified,
        }
    }

    fn after_connect(kind: Option<std::io::ErrorKind>) -> Self {
        use std::io::ErrorKind;
        match kind {
            // These sites use blocking sockets; WouldBlock is their configured
            // socket deadline signal. PoolCheck's nonblocking I/O is excluded.
            Some(ErrorKind::TimedOut | ErrorKind::WouldBlock) => Self::RequestDeadlineAfterConnect,
            Some(
                ErrorKind::ConnectionReset
                | ErrorKind::ConnectionAborted
                | ErrorKind::UnexpectedEof,
            ) => Self::ResetAfterConnect,
            _ => Self::OtherAfterConnect,
        }
    }
}

/// Metadata supplied by the finite typed command/ceremony mapping.
/// An existing idempotency contract is evidence, not permission to retry here.
pub(crate) enum EffectContract {
    /// No verified per-request effect contract. Keep the closed diagnostic
    /// absent rather than inventing an effect or retry recommendation.
    Unknown,
    Read,
    WriteWithoutIdempotency,
    WriteWithExistingIdempotency,
    Schema,
}

pub(crate) struct IdUnavailable;

/// Neither Clone nor Copy: only the actual worker owns completion.
pub(crate) struct Attempt {
    request_id: RequestId,
    operation: TransportOperation,
    effect: EffectContract,
    started: Instant,
    connect_budget: Option<Duration>,
    request_budget: Option<Duration>,
    headers_observed: bool,
    correlated_headers: bool,
    listener_generation: Option<ListenerGeneration>,
}

/// Has no append method. Rendering this result repeatedly cannot write again.
pub(crate) struct CompletedAttempt {
    request_id: RequestId,
    operation: TransportOperation,
    listener_generation: Option<ListenerGeneration>,
    diagnostic: Option<FailureDiagnostic>,
    receipt: ReceiptAvailability,
}

impl Attempt {
    /// Call immediately before the worker's actual request, not during cache
    /// lookup, request building, or outer lease waiting. Failure creates no ID.
    pub(crate) fn begin(
        operation: TransportOperation,
        effect: EffectContract,
        connect_budget: Option<Duration>,
        request_budget: Option<Duration>,
    ) -> Result<Self, IdUnavailable> {
        let mut entropy = [0_u8; 16];
        std::fs::File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut entropy))
            .map_err(|_| IdUnavailable)?;
        let request_id = RequestId(format!(
            "req_{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(entropy)
        ));
        Ok(Self {
            request_id,
            operation,
            effect,
            started: Instant::now(),
            connect_budget,
            request_budget,
            headers_observed: false,
            correlated_headers: false,
            listener_generation: None,
        })
    }

    pub(crate) fn request_id(&self) -> &RequestId {
        &self.request_id
    }

    /// Header values are evidence only for the matching local request. They
    /// never establish domain acceptance. Call before consuming Response.
    pub(crate) fn observe_headers(&mut self, echoed_id: Option<&str>, generation: Option<&str>) {
        self.headers_observed = true;
        self.correlated_headers = echoed_id == Some(self.request_id.as_str());
        self.listener_generation = if self.correlated_headers {
            generation
                .filter(|value| valid_generation(value))
                .map(|value| ListenerGeneration(value.to_owned()))
        } else {
            None
        };
    }

    /// A fully read exchange (including a refusal or malformed JSON body) is
    /// not a CLI transport failure. Use complete_response for a read HTTP body.
    pub(crate) fn complete(self) -> CompletedAttempt {
        CompletedAttempt {
            request_id: self.request_id,
            operation: self.operation,
            listener_generation: self.listener_generation,
            diagnostic: None,
            receipt: ReceiptAvailability::NotApplicable,
        }
    }

    /// Inspect only the known A timeout envelope, without changing or retaining
    /// it. The renderer still receives the original body. Unknown/mismatched
    /// shapes stay generic; completed HTTP refusals never append a receipt.
    pub(crate) fn complete_response(self, status: u16, encoded: &str) -> CompletedAttempt {
        let diagnostic = self.correlated_db_timeout(status, encoded);
        let mut completed = self.complete();
        completed.diagnostic = diagnostic;
        completed
    }

    fn correlated_db_timeout(&self, status: u16, encoded: &str) -> Option<FailureDiagnostic> {
        use serde_json::Value;
        if status != 503 || !self.correlated_headers {
            return None;
        }
        let body: Value = serde_json::from_str(encoded).ok()?;
        let error = body.get("error")?.as_object()?;
        if error.get("code")?.as_str()? != "db_timeout"
            || error.get("requestId")?.as_str()? != self.request_id.as_str()
            || error.get("gatewayAccepted")?.as_bool()? != true
            || error.get("timeoutSource")?.as_str()? != "otp_db_call"
        {
            return None;
        }

        // A's real DBObservation registry supplies these effect kinds. Generic
        // db.query/db.execute/reference_fence have unknown effects: never copy
        // the CLI effect into a DB diagnostic to fill that missing evidence.
        let (operation, effect_kind, effect_name, effect_state, expected_state) =
            match error.get("operation")?.as_str()? {
                "auth.session_by_cli_token" => (
                    DbOperation("auth.session_by_cli_token"),
                    EffectKind::Read,
                    "read",
                    EffectState::None,
                    "none",
                ),
                "wake.due_scan" => (
                    DbOperation("wake.due_scan"),
                    EffectKind::Read,
                    "read",
                    EffectState::None,
                    "none",
                ),
                "db.transaction" => (
                    DbOperation("db.transaction"),
                    EffectKind::Write,
                    "write",
                    EffectState::Unknown,
                    "unknown",
                ),
                "schema.ensure" => (
                    DbOperation("schema.ensure"),
                    EffectKind::Schema,
                    "schema",
                    EffectState::Unknown,
                    "unknown",
                ),
                _ => return None,
            };
        if error.get("effectState")?.as_str()? != expected_state {
            return None;
        }
        // The current A envelope omits effectKind and cause. If a successor
        // supplies either, contradictions or open vocabulary are not accepted.
        if let Some(kind) = error.get("effectKind") {
            if kind.as_str()? != effect_name {
                return None;
            }
        }
        let cause = match error.get("cause") {
            None | Some(Value::Null) => None,
            Some(Value::String(cause)) if cause == "db_caller_timeout" => {
                Some(AttemptCause::DbCallerTimeout)
            }
            _ => return None,
        };
        let action = match (effect_kind, error.get("action")?.as_str()?) {
            (EffectKind::Read, "retry_safe") => Action::RetrySafe,
            (EffectKind::Write | EffectKind::Schema, "do_not_retry_report") => {
                Action::DoNotRetryReport
            }
            (EffectKind::Write, "retry_same_idempotency_key")
                if matches!(self.effect, EffectContract::WriteWithExistingIdempotency) =>
            {
                Action::RetrySameIdempotencyKey
            }
            _ => return None,
        };
        Some(FailureDiagnostic {
            code: DiagnosticCode::DbTimeout,
            operation: DiagnosticOperation::Database(operation),
            cause,
            elapsed_ms: error.get("elapsedMs")?.as_u64()?,
            timeout: TimeoutBudget::OtpDbCall {
                budget_ms: error.get("budgetMs")?.as_u64()?,
            },
            gateway_accepted: GatewayAccepted::Yes,
            effect_kind,
            effect_state,
            action,
        })
    }

    pub(crate) fn fail_transport(self, error: &ureq::Transport, base: &Path) -> CompletedAttempt {
        self.fail(FailureFact::from_transport(error), base)
    }

    pub(crate) fn fail_body(self, error: &std::io::Error, base: &Path) -> CompletedAttempt {
        let fact = if self.headers_observed {
            FailureFact::after_connect(Some(error.kind()))
        } else {
            FailureFact::Unclassified
        };
        self.fail(fact, base)
    }

    /// Consume once and attempt one append. This never owns or transforms the
    /// request's Result/error: the caller retains it for the fidelity renderer.
    fn fail(self, fact: FailureFact, base: &Path) -> CompletedAttempt {
        let elapsed_ms = millis(self.started.elapsed());
        let effect = match self.effect {
            EffectContract::Unknown => None,
            EffectContract::Read => Some((EffectKind::Read, EffectState::None, Action::RetrySafe)),
            EffectContract::WriteWithoutIdempotency => Some((
                EffectKind::Write,
                EffectState::Unknown,
                Action::DoNotRetryReport,
            )),
            EffectContract::WriteWithExistingIdempotency => Some((
                EffectKind::Write,
                EffectState::Unknown,
                Action::RetrySameIdempotencyKey,
            )),
            EffectContract::Schema => Some((
                EffectKind::Schema,
                EffectState::Unknown,
                Action::DoNotRetryReport,
            )),
        };
        let unavailable = |cause, timeout| {
            Some((
                DiagnosticCode::GatewayUnavailable,
                cause,
                timeout,
                GatewayAccepted::No,
                EffectState::None,
                Action::RetrySafe,
            ))
        };
        let uncertain = |cause, timeout| {
            effect.map(|(_, uncertain_effect, uncertain_action)| {
                (
                    DiagnosticCode::GatewayTransportUncertain,
                    cause,
                    timeout,
                    GatewayAccepted::Unknown,
                    uncertain_effect,
                    uncertain_action,
                )
            })
        };
        let before_exchange = matches!(
            fact,
            FailureFact::DnsBeforeExchange
                | FailureFact::RefusedBeforeExchange
                | FailureFact::ConnectDeadlineBeforeExchange
        );
        let classified = match fact {
            FailureFact::Unclassified => None,
            FailureFact::DnsBeforeExchange => {
                unavailable(AttemptCause::DnsFailed, TimeoutBudget::None)
            }
            FailureFact::RefusedBeforeExchange => {
                unavailable(AttemptCause::ConnectRefused, TimeoutBudget::None)
            }
            FailureFact::ConnectDeadlineBeforeExchange => {
                self.connect_budget.and_then(millis).and_then(|budget_ms| {
                    unavailable(
                        AttemptCause::ConnectTimeout,
                        TimeoutBudget::CliConnect { budget_ms },
                    )
                })
            }
            FailureFact::RequestDeadlineAfterConnect => {
                self.request_budget.and_then(millis).and_then(|budget_ms| {
                    uncertain(
                        AttemptCause::RequestTimeout,
                        TimeoutBudget::CliRequest { budget_ms },
                    )
                })
            }
            FailureFact::ResetAfterConnect => {
                uncertain(AttemptCause::ConnectionReset, TimeoutBudget::None)
            }
            FailureFact::OtherAfterConnect => {
                uncertain(AttemptCause::TransportFailed, TimeoutBudget::None)
            }
        };
        let diagnostic = classified.zip(elapsed_ms).zip(effect).map(
            |(
                ((code, cause, timeout, gateway_accepted, effect_state, action), elapsed_ms),
                (effect_kind, _, _),
            )| {
                FailureDiagnostic {
                    code,
                    operation: DiagnosticOperation::Transport(self.operation),
                    cause: Some(cause),
                    elapsed_ms,
                    timeout,
                    gateway_accepted,
                    effect_kind,
                    effect_state,
                    action,
                }
            },
        );
        // Before-connect facts must never retain a generation from any header.
        let listener_generation = if before_exchange {
            None
        } else {
            self.listener_generation
        };
        let record = receipt_record(
            &self.request_id,
            self.operation,
            listener_generation.as_ref(),
            effect.map(|(kind, _, _)| kind),
            elapsed_ms,
            diagnostic.as_ref(),
        );
        let receipt = if crate::transport_receipt::append(base, &record) {
            ReceiptAvailability::Recorded
        } else {
            ReceiptAvailability::Unavailable
        };
        CompletedAttempt {
            request_id: self.request_id,
            operation: self.operation,
            listener_generation,
            diagnostic,
            receipt,
        }
    }
}

impl CompletedAttempt {
    pub(crate) fn render(&self) -> AttemptRender<'_> {
        AttemptRender {
            request_id: &self.request_id,
            transport_operation: self.operation,
            listener_generation: self.listener_generation.as_ref(),
            diagnostic: self.diagnostic.as_ref(),
            receipt: self.receipt,
        }
    }
}

fn millis(duration: Duration) -> Option<u64> {
    duration.as_millis().try_into().ok()
}

fn valid_generation(value: &str) -> bool {
    value.strip_prefix("lgen_").is_some_and(|suffix| {
        suffix.len() == 22
            && suffix
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    })
}

/// Explicit sink projection from closed local data; never gateway JSON, raw
/// error text, URL, credential, or renderer output. Unknowns stay null.
fn receipt_record(
    request_id: &RequestId,
    operation: TransportOperation,
    generation: Option<&ListenerGeneration>,
    effect: Option<EffectKind>,
    elapsed_ms: Option<u64>,
    diagnostic: Option<&FailureDiagnostic>,
) -> serde_json::Value {
    use serde_json::{Value, json};
    let mut record = json!({
        "observed_at_ms": SystemTime::now().duration_since(UNIX_EPOCH).ok().and_then(millis),
        "request_id": request_id.as_str(),
        "operation": operation.as_str(),
        "listener_generation": generation.map(ListenerGeneration::as_str),
        "effect_kind": effect.map(|kind| match kind { EffectKind::Read => "read", EffectKind::Write => "write", EffectKind::Schema => "schema" }),
        "elapsed_ms": elapsed_ms,
        "code": null, "cause": null, "timeout_source": null, "budget_ms": null,
        "gateway_accepted": "unknown", "effect_state": null, "action": null
    });
    if let Some(d) = diagnostic {
        record["code"] = match d.code() {
            DiagnosticCode::GatewayUnavailable => "gateway_unavailable",
            DiagnosticCode::GatewayTransportUncertain => "gateway_transport_uncertain",
            DiagnosticCode::DbTimeout => {
                unreachable!("CLI transport completion never makes DB diagnostic")
            }
        }
        .into();
        record["cause"] = match d.cause() {
            Some(AttemptCause::DnsFailed) => json!("dns_failed"),
            Some(AttemptCause::ConnectRefused) => json!("connect_refused"),
            Some(AttemptCause::ConnectTimeout) => json!("connect_timeout"),
            Some(AttemptCause::RequestTimeout) => json!("request_timeout"),
            Some(AttemptCause::ConnectionReset) => json!("connection_reset"),
            Some(AttemptCause::TransportFailed) => json!("transport_failed"),
            None => Value::Null,
            Some(AttemptCause::DbCallerTimeout) => {
                unreachable!("no DB cause in transport completion")
            }
        };
        let (source, budget) = match d.timeout() {
            TimeoutBudget::None => ("none", None),
            TimeoutBudget::CliConnect { budget_ms } => ("cli_connect", Some(budget_ms)),
            TimeoutBudget::CliRequest { budget_ms } => ("cli_request", Some(budget_ms)),
            _ => unreachable!("no DB budget in transport completion"),
        };
        record["timeout_source"] = json!(source);
        record["budget_ms"] = json!(budget);
        record["gateway_accepted"] = match d.gateway_accepted() {
            GatewayAccepted::Yes => json!(true),
            GatewayAccepted::No => json!(false),
            GatewayAccepted::Unknown => json!("unknown"),
        };
        record["effect_state"] = json!(match d.effect_state() {
            EffectState::None => "none",
            EffectState::Known => "known",
            EffectState::Unknown => "unknown",
        });
        record["action"] = json!(match d.action() {
            Action::RetrySafe => "retry_safe",
            Action::RetrySameIdempotencyKey => "retry_same_idempotency_key",
            Action::DoNotRetryReport => "do_not_retry_report",
        });
    }
    record
}
