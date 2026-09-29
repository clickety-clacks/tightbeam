//! B-owned observation/receipt contract tests, pending carrier registration.
//! These use the production completion and sink, not fidelity's renderer fixtures.

use super::*;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Temp(std::path::PathBuf);

impl Temp {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "tightbeam-observation-contract-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn records(&self) -> Vec<Value> {
        std::fs::read_to_string(self.0.join("diagnostics/cli-transport-v1.log"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn attempt(effect: EffectContract) -> Attempt {
    Attempt::begin(
        TransportOperation("cli.add_user"),
        effect,
        Some(Duration::from_millis(700)),
        Some(Duration::from_millis(1200)),
    )
    .unwrap_or_else(|_| panic!("test could not obtain request-ID entropy"))
}

fn correlated_attempt(effect: EffectContract) -> Attempt {
    let mut attempt = attempt(effect);
    let id = attempt.request_id().as_str().to_owned();
    attempt.observe_headers(Some(&id), Some("lgen_abcdefghijklmnopqrstuv"));
    attempt
}

#[test]
fn typed_connect_refusal_requires_connect_phase_and_connection_refused_source() {
    let direct_connect = ureq::TransportEvidence {
        phase: ureq::TransportPhase::Connect,
        route: ureq::TransportRoute::Direct,
    };
    let refusal = FailureFact::from_typed_evidence(
        ureq::ErrorKind::Io,
        direct_connect,
        Some(std::io::ErrorKind::ConnectionRefused),
    );
    assert!(matches!(&refusal, FailureFact::RefusedBeforeExchange));
    let temp = Temp::new();
    let refused = attempt(EffectContract::Read).fail(refusal, &temp.0);
    let refused_render = refused.render();
    let refused_diagnostic = refused_render.diagnostic.unwrap();
    assert!(matches!(
        refused_diagnostic.code(),
        DiagnosticCode::GatewayUnavailable
    ));
    assert!(matches!(
        refused_diagnostic.cause(),
        Some(AttemptCause::ConnectRefused)
    ));

    let missing_source =
        FailureFact::from_typed_evidence(ureq::ErrorKind::Io, direct_connect, None);
    assert!(matches!(missing_source, FailureFact::Unclassified));
    let unclassified = attempt(EffectContract::Read).fail(missing_source, &temp.0);
    assert!(unclassified.render().diagnostic.is_none());

    let after_connect = FailureFact::from_typed_evidence(
        ureq::ErrorKind::Io,
        ureq::TransportEvidence {
            phase: ureq::TransportPhase::AwaitResponse,
            route: ureq::TransportRoute::Direct,
        },
        Some(std::io::ErrorKind::ConnectionRefused),
    );
    assert!(matches!(&after_connect, FailureFact::OtherAfterConnect));
    let uncertain = attempt(EffectContract::Read).fail(after_connect, &temp.0);
    let uncertain_render = uncertain.render();
    let uncertain_diagnostic = uncertain_render.diagnostic.unwrap();
    assert!(matches!(
        uncertain_diagnostic.code(),
        DiagnosticCode::GatewayTransportUncertain
    ));
    assert!(matches!(
        uncertain_diagnostic.gateway_accepted(),
        GatewayAccepted::Unknown
    ));
}

fn db_body(attempt: &Attempt) -> Value {
    json!({"error": {
        "code": "db_timeout",
        "requestId": attempt.request_id().as_str(),
        "gatewayAccepted": true,
        "timeoutSource": "otp_db_call",
        "operation": "db.transaction",
        "elapsedMs": 30007,
        "budgetMs": 30000,
        "effectState": "unknown",
        "action": "do_not_retry_report"
    }})
}

#[test]
fn completed_db_refusal_preserves_server_measurements_and_nullable_cause() {
    let attempt = correlated_attempt(EffectContract::WriteWithoutIdempotency);
    let body = db_body(&attempt);
    let completed = attempt.complete_response(503, &body.to_string());
    let rendered = completed.render();
    let diagnostic = rendered.diagnostic.unwrap();
    assert!(matches!(diagnostic.code(), DiagnosticCode::DbTimeout));
    assert!(diagnostic.cause().is_none());
    assert_eq!(diagnostic.elapsed_ms(), 30007);
    assert!(matches!(
        diagnostic.timeout(),
        TimeoutBudget::OtpDbCall { budget_ms: 30000 }
    ));
    assert!(matches!(
        diagnostic.operation(),
        DiagnosticOperation::Database(operation) if operation.as_str() == "db.transaction"
    ));
    assert_eq!(rendered.transport_operation.as_str(), "cli.add_user");
    assert!(matches!(
        rendered.receipt,
        ReceiptAvailability::NotApplicable
    ));
    assert!(matches!(
        diagnostic.gateway_accepted(),
        GatewayAccepted::Yes
    ));
    assert!(matches!(diagnostic.action(), Action::DoNotRetryReport));
}

#[test]
fn untrusted_db_fields_cannot_create_a_typed_diagnostic() {
    for (field, value) in [
        ("requestId", json!("req_foreign")),
        ("gatewayAccepted", json!(false)),
        ("timeoutSource", json!("sqlite_busy")),
        ("operation", json!("db.execute")),
        ("effectKind", json!("read")),
        ("effectState", json!("known")),
        ("cause", json!("invented_cause")),
        ("action", json!("retry_safe")),
        ("elapsedMs", json!(-1)),
        ("budgetMs", json!("30000")),
    ] {
        let attempt = correlated_attempt(EffectContract::WriteWithoutIdempotency);
        let mut body = db_body(&attempt);
        body["error"][field] = value;
        let completed = attempt.complete_response(503, &body.to_string());
        assert!(completed.render().diagnostic.is_none(), "accepted {field}");
        assert!(matches!(
            completed.render().receipt,
            ReceiptAvailability::NotApplicable
        ));
    }
}

#[test]
fn matching_body_without_matching_observed_header_is_not_correlation() {
    for header in [None, Some("req_foreign")] {
        let mut attempt = attempt(EffectContract::WriteWithoutIdempotency);
        let body = db_body(&attempt);
        attempt.observe_headers(header, Some("lgen_abcdefghijklmnopqrstuv"));
        let completed = attempt.complete_response(503, &body.to_string());
        assert!(completed.render().diagnostic.is_none());
        assert!(completed.render().listener_generation.is_none());
    }
}

#[test]
fn listener_generation_requires_matching_id_and_closed_shape() {
    for generation in ["lgen_short", "lgen_abcdefghijklmnopqrstu/", "secret=value"] {
        let mut attempt = attempt(EffectContract::Read);
        let id = attempt.request_id().as_str().to_owned();
        attempt.observe_headers(Some(&id), Some(generation));
        assert!(attempt.complete().render().listener_generation.is_none());
    }
}

#[test]
fn one_completion_appends_once_and_rendering_cannot_append_again() {
    let temp = Temp::new();
    let attempt = correlated_attempt(EffectContract::WriteWithoutIdempotency);
    let id = attempt.request_id().as_str().to_owned();
    assert!(id.starts_with("req_"));
    assert_eq!(id.len(), 26);
    let error = std::io::Error::new(std::io::ErrorKind::TimedOut, "token=PRIVATE_SENTINEL");
    let completed = attempt.fail_body(&error, &temp.0);
    for _ in 0..3 {
        let rendered = completed.render();
        assert_eq!(rendered.request_id.as_str(), id);
        assert!(matches!(rendered.receipt, ReceiptAvailability::Recorded));
        let diagnostic = rendered.diagnostic.unwrap();
        assert!(matches!(
            diagnostic.code(),
            DiagnosticCode::GatewayTransportUncertain
        ));
        assert!(matches!(
            diagnostic.gateway_accepted(),
            GatewayAccepted::Unknown
        ));
        assert!(matches!(diagnostic.action(), Action::DoNotRetryReport));
        assert!(matches!(
            diagnostic.timeout(),
            TimeoutBudget::CliRequest { budget_ms: 1200 }
        ));
    }
    let records = temp.records();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["request_id"], id);
    assert_eq!(
        records[0]["listener_generation"],
        "lgen_abcdefghijklmnopqrstuv"
    );
    assert_eq!(records[0]["effect_state"], "unknown");
    assert!(!records[0].to_string().contains("PRIVATE_SENTINEL"));
    // The completion borrows the original error without replacing or redacting
    // it; only fidelity owns presentation of this existing error input.
    assert_eq!(error.to_string(), "token=PRIVATE_SENTINEL");
}

#[test]
fn failed_append_keeps_original_failure_with_receipt_unavailable() {
    let temp = Temp::new();
    let invalid_base = temp.0.join("not-a-directory");
    std::fs::write(&invalid_base, "unchanged").unwrap();
    let attempt = correlated_attempt(EffectContract::WriteWithoutIdempotency);
    let error = std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "PRIVATE_SENTINEL");
    let completed = attempt.fail_body(&error, &invalid_base);
    let rendered = completed.render();
    assert!(matches!(rendered.receipt, ReceiptAvailability::Unavailable));
    let diagnostic = rendered.diagnostic.unwrap();
    assert!(matches!(
        diagnostic.cause(),
        Some(AttemptCause::ConnectionReset)
    ));
    assert!(matches!(
        diagnostic.gateway_accepted(),
        GatewayAccepted::Unknown
    ));
    assert!(matches!(diagnostic.effect_state(), EffectState::Unknown));
    assert!(matches!(diagnostic.action(), Action::DoNotRetryReport));
    assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof);
    assert_eq!(error.to_string(), "PRIVATE_SENTINEL");
    assert_eq!(std::fs::read_to_string(invalid_base).unwrap(), "unchanged");
}

#[test]
fn absent_boundary_keeps_diagnostic_unknown_even_with_timeout_error() {
    let temp = Temp::new();
    let attempt = attempt(EffectContract::WriteWithoutIdempotency);
    let error = std::io::Error::new(std::io::ErrorKind::TimedOut, "deadline reached");
    // No headers were observed. A typed IO timeout by itself proves no phase.
    let completed = attempt.fail_body(&error, &temp.0);
    assert!(completed.render().diagnostic.is_none());
    assert!(completed.render().listener_generation.is_none());
    let records = temp.records();
    assert_eq!(records.len(), 1);
    assert!(records[0]["code"].is_null());
    assert!(records[0]["cause"].is_null());
    assert_eq!(records[0]["gateway_accepted"], "unknown");
}

#[test]
fn unknown_effect_keeps_receipt_without_invented_classification_or_retry_advice() {
    let temp = Temp::new();
    let attempt = correlated_attempt(EffectContract::Unknown);
    let id = attempt.request_id().as_str().to_owned();
    let error = std::io::Error::new(std::io::ErrorKind::TimedOut, "PRIVATE_SENTINEL");
    let completed = attempt.fail_body(&error, &temp.0);
    let rendered = completed.render();
    assert_eq!(rendered.request_id.as_str(), id);
    assert!(rendered.diagnostic.is_none());
    assert!(matches!(rendered.receipt, ReceiptAvailability::Recorded));
    let records = temp.records();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["request_id"], id);
    assert_eq!(records[0]["operation"], "cli.add_user");
    for field in ["effect_kind", "effect_state", "action", "code", "cause"] {
        assert!(records[0][field].is_null(), "invented {field}");
    }
    assert!(!records[0].to_string().contains("PRIVATE_SENTINEL"));
    assert_eq!(error.to_string(), "PRIVATE_SENTINEL");
}

#[test]
fn before_exchange_drops_generation_even_when_effect_is_unknown() {
    let temp = Temp::new();
    // Adverse state injection exercises the completion invariant, not a real
    // positive generation observation or a possible HTTP exchange sequence.
    let attempt = correlated_attempt(EffectContract::Unknown);
    let completed = attempt.fail(FailureFact::RefusedBeforeExchange, &temp.0);
    assert!(completed.render().diagnostic.is_none());
    assert!(completed.render().listener_generation.is_none());
    let records = temp.records();
    assert_eq!(records.len(), 1);
    assert!(records[0]["listener_generation"].is_null());
    assert!(records[0]["effect_kind"].is_null());
}

#[test]
fn gateway_budgets_match_the_pinned_agent_default_and_actual_lease_override() {
    let context = Some(super::super::command_context::CommandContext::onboard());
    let ordinary = begin_gateway_attempt(context, "GET", "/harnesses", None).unwrap();
    assert_eq!(ordinary.connect_budget, Some(Duration::from_secs(30)));
    assert_eq!(ordinary.request_budget, None);
    let lease = Duration::from_millis(73);
    let bounded = begin_gateway_attempt(context, "POST", "/agent/dispatch", Some(lease)).unwrap();
    assert_eq!(bounded.connect_budget, Some(lease));
    assert_eq!(bounded.request_budget, Some(lease));
    assert!(begin_gateway_attempt(context, "GET", "/foreign", None).is_none());
    assert!(begin_gateway_attempt(None, "GET", "/harnesses", None).is_none());
}

#[test]
fn duplicate_response_correlation_is_not_chosen_by_first_matching_header() {
    let mut attempt = attempt(EffectContract::Read);
    let id = attempt.request_id().as_str().to_owned();
    let response: ureq::Response = format!(
        "HTTP/1.1 200 OK\r\nx-tightbeam-request-id: {id}\r\nx-tightbeam-request-id: req_foreign\r\nx-tightbeam-listener-generation: lgen_abcdefghijklmnopqrstuv\r\nContent-Length: 0\r\n\r\n"
    ).parse().unwrap();
    attempt.observe_response(&response);
    assert!(attempt.complete().render().listener_generation.is_none());
}
