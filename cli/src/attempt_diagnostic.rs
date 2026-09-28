//! Closed, read-only view of one completed CLI gateway attempt.
//!
//! Request observation, validation, construction, and receipt writing belong to
//! the timeout lane. The renderer borrows this data only after an attempt has
//! completed; it never creates an attempt or receipt.

pub(crate) mod command_context;
pub(crate) mod observation;

#[derive(Clone)]
pub(crate) struct RequestId(String);

#[derive(Clone)]
pub(crate) struct ListenerGeneration(String);

#[derive(Clone, Copy)]
pub(crate) struct TransportOperation(&'static str);

#[derive(Clone, Copy)]
pub(crate) struct DbOperation(&'static str);

#[derive(Clone, Copy)]
pub(crate) enum DiagnosticOperation {
    Transport(TransportOperation),
    Database(DbOperation),
}

#[derive(Clone, Copy)]
pub(crate) enum DiagnosticCode {
    DbTimeout,
    GatewayUnavailable,
    GatewayTransportUncertain,
}

#[derive(Clone, Copy)]
pub(crate) enum AttemptCause {
    DbCallerTimeout,
    DnsFailed,
    ConnectRefused,
    ConnectTimeout,
    RequestTimeout,
    ConnectionReset,
    TransportFailed,
}

#[derive(Clone, Copy)]
pub(crate) enum TimeoutBudget {
    None,
    OtpDbCall { budget_ms: u64 },
    SqliteBusy { budget_ms: u64 },
    CliConnect { budget_ms: u64 },
    CliRequest { budget_ms: u64 },
}

#[derive(Clone, Copy)]
pub(crate) enum GatewayAccepted {
    Yes,
    No,
    Unknown,
}

#[derive(Clone, Copy)]
pub(crate) enum EffectKind {
    Read,
    Write,
    Schema,
}

#[derive(Clone, Copy)]
pub(crate) enum EffectState {
    None,
    Known,
    Unknown,
}

#[derive(Clone, Copy)]
pub(crate) enum Action {
    RetrySafe,
    RetrySameIdempotencyKey,
    DoNotRetryReport,
}

#[derive(Clone, Copy)]
pub(crate) enum ReceiptAvailability {
    NotApplicable,
    Recorded,
    Unavailable,
}

#[derive(Clone, Copy)]
pub(crate) enum FailurePresentation {
    Ordinary,
    Tune,
}

pub(crate) struct FailureDiagnostic {
    code: DiagnosticCode,
    operation: DiagnosticOperation,
    cause: Option<AttemptCause>,
    elapsed_ms: u64,
    timeout: TimeoutBudget,
    gateway_accepted: GatewayAccepted,
    effect_kind: EffectKind,
    effect_state: EffectState,
    action: Action,
}

#[derive(Clone, Copy)]
pub(crate) struct AttemptRender<'a> {
    pub request_id: &'a RequestId,
    pub transport_operation: TransportOperation,
    pub listener_generation: Option<&'a ListenerGeneration>,
    pub diagnostic: Option<&'a FailureDiagnostic>,
    pub receipt: ReceiptAvailability,
}

impl RequestId {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl ListenerGeneration {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl TransportOperation {
    pub(crate) fn as_str(&self) -> &str {
        self.0
    }
}

impl DbOperation {
    pub(crate) fn as_str(&self) -> &str {
        self.0
    }
}

impl FailureDiagnostic {
    pub(crate) fn code(&self) -> DiagnosticCode {
        self.code
    }

    pub(crate) fn operation(&self) -> DiagnosticOperation {
        self.operation
    }

    pub(crate) fn cause(&self) -> Option<AttemptCause> {
        self.cause
    }

    pub(crate) fn elapsed_ms(&self) -> u64 {
        self.elapsed_ms
    }

    pub(crate) fn timeout(&self) -> TimeoutBudget {
        self.timeout
    }

    pub(crate) fn gateway_accepted(&self) -> GatewayAccepted {
        self.gateway_accepted
    }

    pub(crate) fn effect_kind(&self) -> EffectKind {
        self.effect_kind
    }

    pub(crate) fn effect_state(&self) -> EffectState {
        self.effect_state
    }

    pub(crate) fn action(&self) -> Action {
        self.action
    }
}

#[cfg(test)]
pub(crate) mod test_fixtures {
    use super::*;

    pub(crate) struct Attempt {
        request_id: RequestId,
        operation: TransportOperation,
        listener_generation: Option<ListenerGeneration>,
        diagnostic: Option<FailureDiagnostic>,
        receipt: ReceiptAvailability,
    }

    impl Attempt {
        pub(crate) fn dns_failure() -> Self {
            Self {
                request_id: RequestId("req_abcdefghijklmnopqrstuv".to_owned()),
                operation: TransportOperation("cli.list"),
                // DNS fails before a listener can correlate this request.
                listener_generation: None,
                diagnostic: Some(FailureDiagnostic {
                    code: DiagnosticCode::GatewayUnavailable,
                    operation: DiagnosticOperation::Transport(TransportOperation("cli.list")),
                    cause: Some(AttemptCause::DnsFailed),
                    elapsed_ms: 12,
                    timeout: TimeoutBudget::None,
                    gateway_accepted: GatewayAccepted::No,
                    effect_kind: EffectKind::Read,
                    effect_state: EffectState::None,
                    action: Action::RetrySafe,
                }),
                receipt: ReceiptAvailability::Recorded,
            }
        }

        pub(crate) fn db_timeout() -> Self {
            Self {
                request_id: RequestId("req_abcdefghijklmnopqrstuv".to_owned()),
                operation: TransportOperation("cli.add_user"),
                listener_generation: None,
                diagnostic: Some(FailureDiagnostic {
                    code: DiagnosticCode::DbTimeout,
                    operation: DiagnosticOperation::Database(DbOperation("db.transaction")),
                    cause: Some(AttemptCause::DbCallerTimeout),
                    elapsed_ms: 5_037,
                    timeout: TimeoutBudget::OtpDbCall { budget_ms: 5_000 },
                    gateway_accepted: GatewayAccepted::Yes,
                    effect_kind: EffectKind::Write,
                    effect_state: EffectState::Unknown,
                    action: Action::DoNotRetryReport,
                }),
                receipt: ReceiptAvailability::NotApplicable,
            }
        }

        pub(crate) fn uncertain_write() -> Self {
            Self {
                request_id: RequestId("req_abcdefghijklmnopqrstuv".to_owned()),
                operation: TransportOperation("cli.add_user"),
                listener_generation: None,
                diagnostic: Some(FailureDiagnostic {
                    code: DiagnosticCode::GatewayTransportUncertain,
                    operation: DiagnosticOperation::Transport(TransportOperation("cli.add_user")),
                    cause: None,
                    elapsed_ms: 12_000,
                    timeout: TimeoutBudget::CliRequest { budget_ms: 12_000 },
                    gateway_accepted: GatewayAccepted::Unknown,
                    effect_kind: EffectKind::Write,
                    effect_state: EffectState::Unknown,
                    action: Action::RetrySameIdempotencyKey,
                }),
                receipt: ReceiptAvailability::Unavailable,
            }
        }

        pub(crate) fn unclassified() -> Self {
            Self {
                request_id: RequestId("req_abcdefghijklmnopqrstuv".to_owned()),
                operation: TransportOperation("cli.tune"),
                listener_generation: None,
                diagnostic: None,
                receipt: ReceiptAvailability::Unavailable,
            }
        }

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
}
