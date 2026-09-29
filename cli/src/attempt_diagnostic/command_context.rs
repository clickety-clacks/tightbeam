//! Derive bounded request metadata from typed commands without retaining key
//! values, payloads or identity, allocating an attempt, or reading mutable
//! state. The metadata is consumed by the actual gateway request paths.

use super::TransportOperation;
use super::observation::EffectContract;
use crate::args::Command;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Requests {
    Catalog,
    Dispatch,
    CatalogAndDispatch,
    VersionAndDispatch,
    ToolCallObserved,
}

#[derive(Clone, Copy)]
pub(crate) enum CatalogOrigin {
    Help,
    CommandHelp,
    Doctor,
    Spawn,
    Assimilate,
    Onboard,
}

/// Owned, immutable metadata may cross the existing lease-worker boundary.
/// Its presence does not mean a request happened. Allocate an Attempt only
/// inside the worker immediately before its actual HTTP exchange.
#[derive(Clone, Copy)]
pub(crate) struct CommandContext {
    operation: TransportOperation,
    requests: Requests,
    dispatch_effect: EffectContract,
}

impl CommandContext {
    /// Exhaustive over the current typed command enum. Operation names are
    /// literals: no target, free-form verb, argument or payload can enter them.
    /// Local-only commands have no gateway context. Commands with both local
    /// and remote branches still create no attempt on their local branch.
    pub(crate) fn for_command(command: &Command) -> Option<Self> {
        use Command::*;
        use Requests::{Catalog, CatalogAndDispatch, Dispatch as DispatchPath};
        let (operation, requests) = match command {
            // SessionConnect owns a streaming HTTP/WebSocket lifecycle rather
            // than the shared RequestSpec dispatcher and attempt/receipt path.
            // Do not claim that this command has that metadata until its
            // dedicated transport callers are explicitly integrated.
            IdentityCurrent | GithubAuthCheck | SessionConnect { .. } => return None,
            Help => ("cli.help", Catalog),
            CommandHelp(_) => ("cli.command_help", Catalog),
            Doctor { .. } => ("cli.doctor", CatalogAndDispatch),
            Wake { .. } => ("cli.wake", DispatchPath),
            Condition { .. } => ("cli.condition", DispatchPath),
            HarnessHealthObserveOther { .. } => ("cli.harness_health_observe_other", DispatchPath),
            HarnessHealthResolveOther { .. } => ("cli.harness_health_resolve_other", DispatchPath),
            HarnessHealthReviewOther { .. } => ("cli.harness_health_review_other", DispatchPath),
            HarnessHealthClosePromotion { .. } => {
                ("cli.harness_health_close_promotion", DispatchPath)
            }
            HarnessHealthEvidenceOther { .. } => {
                ("cli.harness_health_evidence_other", DispatchPath)
            }
            ArtifactRecord { .. } => ("cli.artifact_record", DispatchPath),
            ArtifactContentFetch { .. } => ("cli.artifact_content_fetch", DispatchPath),
            Artifacts { .. } => ("cli.artifacts", DispatchPath),
            ToolCallObserved => ("cli.tool_call_observed", Requests::ToolCallObserved),
            Spawn { .. } => ("cli.spawn", CatalogAndDispatch),
            List { .. } => ("cli.list", DispatchPath),
            Retire { .. } => ("cli.retire", DispatchPath),
            SessionReparent { .. } => ("cli.session_reparent", DispatchPath),
            SessionPoSet { .. } => ("cli.session_po_set", DispatchPath),
            Tune { .. } => ("cli.tune", DispatchPath),
            Assign { .. } => ("cli.assign", DispatchPath),
            Dispatch { .. } => ("cli.dispatch", DispatchPath),
            EffortRule { .. } => ("cli.effort_rule", DispatchPath),
            Ask { .. } => ("cli.ask", DispatchPath),
            Answer { .. } => ("cli.answer", DispatchPath),
            // Current spelling changed; preserve the existing operation.
            Return { .. } => ("cli.return_request", DispatchPath),
            OperatorAsk { .. } => ("cli.operator_ask", DispatchPath),
            OperatorRule { .. } => ("cli.operator_rule", DispatchPath),
            OperatorWithdraw { .. } => ("cli.operator_withdraw", DispatchPath),
            DecisionRequests { .. } => ("cli.decision_requests", DispatchPath),
            DecisionRequest { .. } => ("cli.decision_request", DispatchPath),
            AssignmentStopTurn { .. } => ("cli.assignment_stop_turn", DispatchPath),
            RevokeAssignment { .. } => ("cli.revoke_assignment", DispatchPath),
            ReopenAssignment { .. } => ("cli.reopen_assignment", DispatchPath),
            RepairAssignment { .. } => ("cli.repair_assignment", DispatchPath),
            AssignmentCommitRefCorrect { .. } => {
                ("cli.assignment_commit_ref_correct", DispatchPath)
            }
            WorkItemCreate { .. } => ("cli.work_item_create", DispatchPath),
            WorkItemUpdate { .. } => ("cli.work_item_update", DispatchPath),
            WorkItemGet { .. } => ("cli.work_item_get", DispatchPath),
            WorkItemTrace { .. } => ("cli.work_item_trace", DispatchPath),
            Attend { .. } => ("cli.attend", DispatchPath),
            Breathing { .. } => ("cli.breathing", DispatchPath),
            Transcript { .. } => ("cli.transcript", DispatchPath),
            Toplines { .. } => ("cli.toplines", DispatchPath),
            Topline { .. } => ("cli.topline", DispatchPath),
            // Includes multiple parsed subcommands. Never copy its free-form
            // verb into the label or infer an effect from the variant name.
            ToplineMutation { .. } => ("cli.topline_mutation", DispatchPath),
            DurableToplines { .. } => ("cli.durable_toplines", DispatchPath),
            DurableTopline { .. } => ("cli.durable_topline", DispatchPath),
            WorkItemIcebox { .. } => ("cli.work_item_icebox", DispatchPath),
            WorkItemReopen { .. } => ("cli.work_item_reopen", DispatchPath),
            WorkItemClose { .. } => ("cli.work_item_close", DispatchPath),
            WorkItemFail { .. } => ("cli.work_item_fail", DispatchPath),
            Attest { .. } => ("cli.attest", DispatchPath),
            Attests { .. } => ("cli.attests", DispatchPath),
            Assignments { .. } => ("cli.assignments", DispatchPath),
            CancelWake { .. } => ("cli.cancel_wake", DispatchPath),
            SettleTurn { .. } => ("cli.settle_turn", Requests::VersionAndDispatch),
            IdentityEdit { .. } => ("cli.identity_edit", DispatchPath),
            IdentityStatus { .. } => ("cli.identity_status", DispatchPath),
            IdentityRelearn { .. } => ("cli.identity_relearn", DispatchPath),
            IdentityRepoint { .. } => ("cli.identity_repoint", DispatchPath),
            Learn { .. } => ("cli.learn", DispatchPath),
            Unlearn { .. } => ("cli.unlearn", DispatchPath),
            KungfuList { .. } => ("cli.kungfu_list", DispatchPath),
            KungfuSetup { .. } => ("cli.kungfu_setup", DispatchPath),
            SentinelEnable { .. } => ("cli.sentinel_enable", DispatchPath),
            SentinelDisable { .. } => ("cli.sentinel_disable", DispatchPath),
            SentinelList { .. } => ("cli.sentinel_list", DispatchPath),
            SentinelEnvSet { .. } => ("cli.sentinel_env_set", DispatchPath),
            SentinelEnvList { .. } => ("cli.sentinel_env_list", DispatchPath),
            SentinelEnvUnset { .. } => ("cli.sentinel_env_unset", DispatchPath),
            IdentityApply { .. } => ("cli.identity_apply", DispatchPath),
            Onboard { .. } => ("cli.onboard", CatalogAndDispatch),
            AddUser { .. } => ("cli.add_user", DispatchPath),
            ConfigGet { .. } => ("cli.config_get", DispatchPath),
            ConfigSet { .. } => ("cli.config_set", DispatchPath),
            HostEnvSet { .. } => ("cli.host_env_set", DispatchPath),
            HostEnvList { .. } => ("cli.host_env_list", DispatchPath),
            HostEnvUnset { .. } => ("cli.host_env_unset", DispatchPath),
            HostToolchainSet { .. } => ("cli.host_toolchain_set", DispatchPath),
            HarnessProcesses { .. } => ("cli.harness_processes", DispatchPath),
            UpdateClients { .. } => ("cli.update_clients", DispatchPath),
            Assimilate(_) => ("cli.assimilate", CatalogAndDispatch),
        };
        Some(Self {
            operation: TransportOperation(operation),
            requests,
            dispatch_effect: dispatch_effect(command),
        })
    }

    /// These two typed origins are needed at the existing parser catalog
    /// calls, before it can construct the complete Command. Call them only in
    /// their already-selected parser arms; never classify arbitrary text here.
    pub(crate) fn spawn_catalog() -> Self {
        Self::catalog(CatalogOrigin::Spawn)
    }

    pub(crate) fn assimilate_catalog() -> Self {
        Self::catalog(CatalogOrigin::Assimilate)
    }

    /// Doctor's nested SentinelList is a separate read attempt belonging to
    /// Doctor, not a direct invocation of the sentinel-list CLI command.
    pub(crate) fn doctor_sentinels() -> Self {
        Self {
            operation: TransportOperation("cli.doctor"),
            requests: Requests::Dispatch,
            dispatch_effect: EffectContract::Read,
        }
    }

    pub(crate) fn catalog(origin: CatalogOrigin) -> Self {
        let operation = match origin {
            CatalogOrigin::Help => "cli.help",
            CatalogOrigin::CommandHelp => "cli.command_help",
            CatalogOrigin::Doctor => "cli.doctor",
            CatalogOrigin::Spawn => "cli.spawn",
            CatalogOrigin::Assimilate => "cli.assimilate",
            CatalogOrigin::Onboard => "cli.onboard",
        };
        Self {
            operation: TransportOperation(operation),
            requests: Requests::Catalog,
            dispatch_effect: EffectContract::Unknown,
        }
    }

    /// Check the actual method and literal path before allocating an attempt.
    /// A mismatch supplies no metadata; it must not reject or change the
    /// original request. SettleTurn's capability preflight is a real /version
    /// request and retains the same root operation as its subsequent POST.
    pub(crate) fn operation_for_request(
        self,
        method: &str,
        path: &str,
    ) -> Option<TransportOperation> {
        let allowed = match (method, path) {
            ("GET", "/harnesses") => matches!(
                self.requests,
                Requests::Catalog | Requests::CatalogAndDispatch
            ),
            ("POST", "/agent/dispatch") => matches!(
                self.requests,
                Requests::Dispatch | Requests::CatalogAndDispatch | Requests::VersionAndDispatch
            ),
            ("GET", "/version") => matches!(self.requests, Requests::VersionAndDispatch),
            ("POST", "/agent/tool-call-observed") => {
                matches!(self.requests, Requests::ToolCallObserved)
            }
            _ => false,
        };
        allowed.then_some(self.operation)
    }

    /// Effect belongs to this HTTP exchange, not the whole command/ceremony.
    /// In particular catalog and capability GETs are reads even for commands
    /// whose following POST mutates state. This does not authorize a retry.
    pub(crate) fn metadata_for_request(
        self,
        method: &str,
        path: &str,
    ) -> Option<(TransportOperation, EffectContract)> {
        self.operation_for_request(method, path).map(|operation| {
            let effect = if method == "GET" {
                EffectContract::Read
            } else {
                self.dispatch_effect
            };
            (operation, effect)
        })
    }

    /// Root contexts for the existing internal ceremony builders, which do not
    /// receive a complete Command. These create metadata, never an attempt.
    pub(crate) fn onboard() -> Self {
        Self {
            operation: TransportOperation("cli.onboard"),
            requests: Requests::CatalogAndDispatch,
            dispatch_effect: EffectContract::WriteWithoutIdempotency,
        }
    }

    pub(crate) fn assimilate_registration() -> Self {
        Self {
            operation: TransportOperation("cli.assimilate"),
            requests: Requests::Dispatch,
            dispatch_effect: EffectContract::WriteWithoutIdempotency,
        }
    }

    pub(crate) fn update_clients() -> Self {
        // The gateway returns host projections. Subsequent SSH work is not
        // this HTTP attempt and must not change its effect kind.
        Self {
            operation: TransportOperation("cli.update_clients"),
            requests: Requests::Dispatch,
            dispatch_effect: EffectContract::Read,
        }
    }
}

// RequestSpec's existing derives can include metadata without changing the
// agreed opaque carrier declaration or exposing identity/key values.
impl std::fmt::Debug for CommandContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommandContext")
            .field("operation", &self.operation.as_str())
            .field("requests", &self.requests)
            .field("dispatch_effect", &self.dispatch_effect)
            .finish()
    }
}

impl PartialEq for CommandContext {
    fn eq(&self, other: &Self) -> bool {
        self.operation.as_str() == other.operation.as_str()
            && self.requests == other.requests
            && self.dispatch_effect == other.dispatch_effect
    }
}
impl Eq for CommandContext {}

/// Finite source-reviewed domain effect map on public a32. Audit/log writes
/// are not promoted into domain mutation. Empty publisher effect-class lists
/// are NOT read evidence. Keys are inspected for presence only, never retained.
fn dispatch_effect(command: &Command) -> EffectContract {
    use Command::*;
    use EffectContract::*;
    match command {
        IdentityCurrent | GithubAuthCheck | SessionConnect { .. } => Unknown,
        Help
        | CommandHelp(_)
        | Doctor { .. }
        | HarnessHealthEvidenceOther { .. }
        | ArtifactContentFetch { .. }
        | Artifacts { .. }
        | List { .. }
        | DecisionRequests { .. }
        | DecisionRequest { .. }
        | WorkItemGet { .. }
        | WorkItemTrace { .. }
        | Breathing { .. }
        | Transcript { .. }
        | Toplines { .. }
        | Topline { .. }
        | DurableToplines { .. }
        | DurableTopline { .. }
        | Attests { .. }
        | Assignments { .. }
        | IdentityStatus { .. }
        | KungfuList { .. }
        | KungfuSetup { .. }
        | SentinelList { .. }
        | SentinelEnvList { .. }
        | ConfigGet { .. }
        | HostEnvList { .. }
        | HarnessProcesses { .. }
        | UpdateClients { .. } => Read,

        Wake {
            idempotency_key, ..
        }
        | Condition {
            idempotency_key, ..
        }
        | Retire {
            idempotency_key, ..
        }
        | Assign {
            idempotency_key, ..
        }
        | Dispatch {
            idempotency_key, ..
        }
        | WorkItemCreate {
            idempotency_key, ..
        } => keyed_write(idempotency_key.as_deref()),

        HarnessHealthObserveOther {
            idempotency_key, ..
        }
        | HarnessHealthResolveOther {
            idempotency_key, ..
        }
        | HarnessHealthReviewOther {
            idempotency_key, ..
        }
        | HarnessHealthClosePromotion {
            idempotency_key, ..
        }
        | Spawn {
            idempotency_key, ..
        }
        | SessionReparent {
            idempotency_key, ..
        }
        | SessionPoSet {
            idempotency_key, ..
        }
        | RepairAssignment {
            idempotency_key, ..
        }
        | AssignmentCommitRefCorrect {
            idempotency_key, ..
        }
        | SettleTurn {
            idempotency_key, ..
        }
        | IdentityEdit {
            idempotency_key, ..
        }
        | Learn {
            idempotency_key, ..
        } => keyed_write(Some(idempotency_key)),

        // Publication's existing key does not prove replay completion for
        // the later sentinel cleanup. Keep the wire key, but no keyed advice.
        Unlearn { .. } => WriteWithoutIdempotency,

        // Relearn's abort/conflict paths do not all establish the durable
        // publication marker; do not generalize its key to the whole command.
        IdentityRelearn { .. } => WriteWithoutIdempotency,

        ToplineMutation { verb, .. } => match verb.as_str() {
            "topline-placement-list" => Read,
            "topline-create"
            | "topline-update"
            | "topline-close"
            | "topline-reopen"
            | "topline-link-work"
            | "topline-unlink-work"
            | "topline-concern-create"
            | "topline-concern-link-work"
            | "topline-concern-unlink-work"
            | "topline-work-leave-unlinked" => WriteWithoutIdempotency,
            _ => Unknown,
        },

        ArtifactRecord { .. }
        | ToolCallObserved
        | Tune { .. }
        | EffortRule { .. }
        | Ask { .. }
        | Answer { .. }
        | Return { .. }
        | OperatorAsk { .. }
        | OperatorRule { .. }
        | OperatorWithdraw { .. }
        | AssignmentStopTurn { .. }
        | RevokeAssignment { .. }
        | ReopenAssignment { .. }
        | WorkItemUpdate { .. }
        | Attend { .. }
        | WorkItemIcebox { .. }
        | WorkItemReopen { .. }
        | WorkItemClose { .. }
        | WorkItemFail { .. }
        | Attest { .. }
        | CancelWake { .. }
        | IdentityRepoint { .. }
        | IdentityApply { .. }
        | Onboard { .. }
        | AddUser { .. }
        | ConfigSet { .. }
        | HostEnvSet { .. }
        | HostEnvUnset { .. }
        | SentinelEnable { .. }
        | SentinelDisable { .. }
        | SentinelEnvSet { .. }
        | SentinelEnvUnset { .. }
        | HostToolchainSet { .. }
        | Assimilate(_) => WriteWithoutIdempotency,
    }
}

fn keyed_write(key: Option<&str>) -> EffectContract {
    if key.is_some_and(|key| !key.trim().is_empty()) {
        EffectContract::WriteWithExistingIdempotency
    } else {
        EffectContract::WriteWithoutIdempotency
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::Identity;

    fn effect(context: CommandContext, method: &str, path: &str) -> EffectContract {
        context.metadata_for_request(method, path).unwrap().1
    }

    #[test]
    fn settlement_capability_read_and_keyed_write_have_separate_attempt_metadata() {
        let command = Command::SettleTurn {
            identity: Identity::User("fixture".into()),
            session_key: "session_fixture".into(),
            turn_seq: "1".into(),
            outcome: "failed_unknown".into(),
            reason: "fixture".into(),
            idempotency_key: "PRIVATE_SETTLEMENT_KEY".into(),
        };
        let context = CommandContext::for_command(&command).unwrap();
        assert_eq!(effect(context, "GET", "/version"), EffectContract::Read);
        assert_eq!(
            effect(context, "POST", "/agent/dispatch"),
            EffectContract::WriteWithExistingIdempotency
        );
        assert_eq!(
            context
                .operation_for_request("GET", "/version")
                .unwrap()
                .as_str(),
            "cli.settle_turn"
        );
        assert!(!format!("{context:?}").contains("PRIVATE_SETTLEMENT_KEY"));
        assert!(context.operation_for_request("GET", "/harnesses").is_none());
    }

    #[test]
    fn assignment_stop_turn_is_an_unkeyed_dispatch_write_without_retained_identity() {
        let command = Command::AssignmentStopTurn {
            identity: Identity::User("PRIVATE_USER".into()),
            assignment_id: "PRIVATE_ASSIGNMENT".into(),
            reason: "PRIVATE_REASON".into(),
        };
        let context = CommandContext::for_command(&command).unwrap();
        assert_eq!(
            context
                .operation_for_request("POST", "/agent/dispatch")
                .unwrap()
                .as_str(),
            "cli.assignment_stop_turn"
        );
        assert_eq!(
            effect(context, "POST", "/agent/dispatch"),
            EffectContract::WriteWithoutIdempotency
        );
        let debug = format!("{context:?}");
        assert!(!debug.contains("PRIVATE_USER"));
        assert!(!debug.contains("PRIVATE_ASSIGNMENT"));
        assert!(!debug.contains("PRIVATE_REASON"));
    }

    #[test]
    fn ceremony_http_effect_is_distinct_from_the_whole_ceremony() {
        let onboard = CommandContext::onboard();
        assert_eq!(effect(onboard, "GET", "/harnesses"), EffectContract::Read);
        assert_eq!(
            effect(onboard, "POST", "/agent/dispatch"),
            EffectContract::WriteWithoutIdempotency
        );
        assert_eq!(
            effect(CommandContext::update_clients(), "POST", "/agent/dispatch"),
            EffectContract::Read
        );
        assert_eq!(
            effect(
                CommandContext::assimilate_registration(),
                "POST",
                "/agent/dispatch"
            ),
            EffectContract::WriteWithoutIdempotency
        );
    }

    #[test]
    fn closed_topline_subcommands_do_not_gain_retry_advice_from_the_variant_name() {
        for (verb, expected) in [
            ("topline-placement-list", EffectContract::Read),
            ("topline-create", EffectContract::WriteWithoutIdempotency),
            ("unrecognized-private-verb", EffectContract::Unknown),
        ] {
            let command = Command::ToplineMutation {
                identity: Identity::Session,
                verb: verb.into(),
                params: vec![],
            };
            let context = CommandContext::for_command(&command).unwrap();
            assert_eq!(effect(context, "POST", "/agent/dispatch"), expected);
            assert_eq!(context.operation.as_str(), "cli.topline_mutation");
        }
    }

    #[test]
    fn keyed_advice_requires_the_actual_typed_key_and_never_retains_it() {
        for (key, expected) in [
            (None, EffectContract::WriteWithoutIdempotency),
            (Some(" "), EffectContract::WriteWithoutIdempotency),
            (
                Some("PRIVATE_RETIRE_KEY"),
                EffectContract::WriteWithExistingIdempotency,
            ),
        ] {
            let command = Command::Retire {
                identity: Identity::Session,
                session_key: "PRIVATE_TARGET".into(),
                idempotency_key: key.map(str::to_owned),
            };
            let context = CommandContext::for_command(&command).unwrap();
            assert_eq!(effect(context, "POST", "/agent/dispatch"), expected);
            assert!(!format!("{context:?}").contains("PRIVATE_"));
        }
    }

    #[test]
    fn current_surrender_builder_uses_dispatch_not_the_historical_terminal_route() {
        let command = crate::args::parse(
            [
                "attest",
                "asg_fixture",
                "--kind",
                "surrender",
                "--note",
                "fixture",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        )
        .unwrap();
        let request = crate::dispatch::build_request(&command).unwrap();
        let context = CommandContext::for_command(&command).unwrap();
        assert_eq!(request.path, "/agent/dispatch");
        assert_eq!(
            effect(context, "POST", request.path),
            EffectContract::WriteWithoutIdempotency
        );
        assert!(
            context
                .operation_for_request("POST", "/agent/terminal")
                .is_none()
        );
    }

    #[test]
    fn payload_and_identity_do_not_enter_operation_or_broaden_allowed_paths() {
        let context = CommandContext::for_command(&Command::ToplineMutation {
            identity: Identity::User("PRIVATE_IDENTITY".to_owned()),
            verb: "PRIVATE_VERB".to_owned(),
            params: vec![("PRIVATE_KEY".to_owned(), "PRIVATE_VALUE".to_owned())],
        })
        .unwrap();
        assert_eq!(
            context
                .operation_for_request("POST", "/agent/dispatch")
                .unwrap()
                .as_str(),
            "cli.topline_mutation"
        );
        assert!(
            context
                .operation_for_request("GET", "/agent/dispatch")
                .is_none()
        );
        assert!(
            context
                .operation_for_request("POST", "/agent/terminal")
                .is_none()
        );
        assert!(context.operation_for_request("GET", "/harnesses").is_none());
    }

    #[test]
    fn catalog_context_excludes_dispatch_and_concrete_paths() {
        let context =
            CommandContext::for_command(&Command::CommandHelp("PRIVATE_ARGUMENT".to_owned()))
                .unwrap();
        assert_eq!(
            context
                .operation_for_request("GET", "/harnesses")
                .unwrap()
                .as_str(),
            "cli.command_help"
        );
        for (method, path) in [
            ("POST", "/harnesses"),
            ("GET", "/harnesses?token=secret"),
            ("POST", "/agent/dispatch"),
            ("GET", "/version"),
        ] {
            assert!(context.operation_for_request(method, path).is_none());
        }
        for (context, expected) in [
            (CommandContext::spawn_catalog(), "cli.spawn"),
            (CommandContext::assimilate_catalog(), "cli.assimilate"),
        ] {
            assert_eq!(
                context
                    .operation_for_request("GET", "/harnesses")
                    .unwrap()
                    .as_str(),
                expected
            );
            assert!(
                context
                    .operation_for_request("POST", "/agent/dispatch")
                    .is_none()
            );
        }
    }

    #[test]
    fn local_commands_and_separate_tool_endpoint_cannot_borrow_dispatch_context() {
        assert!(CommandContext::for_command(&Command::IdentityCurrent).is_none());
        assert!(CommandContext::for_command(&Command::GithubAuthCheck).is_none());
        let context = CommandContext::for_command(&Command::ToolCallObserved).unwrap();
        assert_eq!(
            context
                .operation_for_request("POST", "/agent/tool-call-observed")
                .unwrap()
                .as_str(),
            "cli.tool_call_observed"
        );
        assert!(
            context
                .operation_for_request("POST", "/agent/dispatch")
                .is_none()
        );
    }

    #[test]
    fn sentinel_commands_keep_fixed_metadata_and_existing_wire_bodies() {
        let identity = Identity::User("PRIVATE_ACTOR".into());
        let cases = [
            (
                Command::KungfuSetup {
                    identity: identity.clone(),
                    name: "PRIVATE_BUNDLE".into(),
                },
                "cli.kungfu_setup",
                "kungfu-setup",
                EffectContract::Read,
            ),
            (
                Command::SentinelEnable {
                    identity: identity.clone(),
                    name: "PRIVATE_SENTINEL".into(),
                },
                "cli.sentinel_enable",
                "sentinel-enable",
                EffectContract::WriteWithoutIdempotency,
            ),
            (
                Command::SentinelDisable {
                    identity: identity.clone(),
                    name: "PRIVATE_SENTINEL".into(),
                },
                "cli.sentinel_disable",
                "sentinel-disable",
                EffectContract::WriteWithoutIdempotency,
            ),
            (
                Command::SentinelList {
                    identity: identity.clone(),
                },
                "cli.sentinel_list",
                "sentinel-list",
                EffectContract::Read,
            ),
            (
                Command::SentinelEnvSet {
                    identity: identity.clone(),
                    host: Some("PRIVATE_HOST".into()),
                    sentinel: "PRIVATE_SENTINEL".into(),
                    name: "PRIVATE_NAME".into(),
                    value: "PRIVATE_VALUE".into(),
                },
                "cli.sentinel_env_set",
                "host-env-set",
                EffectContract::WriteWithoutIdempotency,
            ),
            (
                Command::SentinelEnvList {
                    identity: identity.clone(),
                    host: None,
                    sentinel: "PRIVATE_SENTINEL".into(),
                },
                "cli.sentinel_env_list",
                "host-env-list",
                EffectContract::Read,
            ),
            (
                Command::SentinelEnvUnset {
                    identity,
                    host: None,
                    sentinel: "PRIVATE_SENTINEL".into(),
                    name: "PRIVATE_NAME".into(),
                },
                "cli.sentinel_env_unset",
                "host-env-unset",
                EffectContract::WriteWithoutIdempotency,
            ),
        ];
        for (command, operation, verb, expected) in cases {
            let context = CommandContext::for_command(&command).unwrap();
            let request = crate::dispatch::build_request(&command).unwrap();
            assert_eq!(request.path, "/agent/dispatch");
            assert_eq!(request.attempt_context, Some(context));
            assert_eq!(context.operation.as_str(), operation);
            assert_eq!(effect(context, "POST", request.path), expected);
            assert!(!format!("{context:?}").contains("PRIVATE_"));
            assert!(context.metadata_for_request("GET", "/harnesses").is_none());
            assert!(
                context
                    .metadata_for_request("GET", "/agent/dispatch")
                    .is_none()
            );
            let body: serde_json::Value = serde_json::from_str(&request.body_json).unwrap();
            assert_eq!(body["asUser"], "PRIVATE_ACTOR");
            assert_eq!(body["verb"], verb);
            assert!(body["params"].get("idempotencyKey").is_none());
            if matches!(command, Command::SentinelEnvSet { .. }) {
                assert_eq!(body["params"]["value"], "PRIVATE_VALUE");
                assert_eq!(body["params"]["host"], "PRIVATE_HOST");
                assert_eq!(body["params"]["sentinel"], "PRIVATE_SENTINEL");
                assert!(body["params"].get("harness").is_none());
            }
        }
    }

    #[test]
    fn unlearn_wire_key_does_not_grant_unproven_cleanup_replay_advice() {
        let command = Command::Unlearn {
            identity: Identity::User("PRIVATE_ACTOR".into()),
            name: "PRIVATE_BUNDLE".into(),
            idempotency_key: "PRIVATE_EXISTING_KEY".into(),
        };
        let request = crate::dispatch::build_request(&command).unwrap();
        let context = request.attempt_context.unwrap();
        assert_eq!(
            effect(context, "POST", request.path),
            EffectContract::WriteWithoutIdempotency
        );
        assert_eq!(context.operation.as_str(), "cli.unlearn");
        assert!(!format!("{context:?}").contains("PRIVATE_"));
        let body: serde_json::Value = serde_json::from_str(&request.body_json).unwrap();
        assert_eq!(body["verb"], "unlearn");
        assert_eq!(body["params"]["idempotencyKey"], "PRIVATE_EXISTING_KEY");
        assert_eq!(body["params"]["name"], "PRIVATE_BUNDLE");
    }

    #[test]
    fn doctor_nested_request_keeps_wire_identity_and_owned_receipt_directory() {
        let direct = crate::dispatch::build_request(&Command::SentinelList {
            identity: Identity::Process("PRIVATE_PROCESS".into()),
        })
        .unwrap();
        let original_body = direct.body_json.clone();
        assert_eq!(
            direct.attempt_context.unwrap().operation.as_str(),
            "cli.sentinel_list"
        );
        assert!(direct.receipt_base_override.is_none());
        let receipt_base = std::path::PathBuf::from("PRIVATE_DOCTOR_BASE");
        let nested = direct.with_doctor_attempt(&receipt_base);
        let worker_request = nested.clone();
        drop(nested);
        drop(receipt_base);
        assert_eq!(worker_request.body_json, original_body);
        assert_eq!(worker_request.path, "/agent/dispatch");
        assert_eq!(
            worker_request.receipt_base_override.as_deref(),
            Some(std::path::Path::new("PRIVATE_DOCTOR_BASE"))
        );
        let context = worker_request.attempt_context.unwrap();
        assert_eq!(context.operation.as_str(), "cli.doctor");
        assert_eq!(
            effect(context, "POST", worker_request.path),
            EffectContract::Read
        );
        assert!(!format!("{context:?}").contains("PRIVATE_"));
        assert!(context.metadata_for_request("GET", "/harnesses").is_none());
        let root = CommandContext::for_command(&Command::Doctor {
            identity: Identity::Session,
            json: true,
            base_dir: Some("PRIVATE_DOCTOR_BASE".into()),
        })
        .unwrap();
        assert_eq!(effect(root, "GET", "/harnesses"), EffectContract::Read);
        assert_eq!(
            effect(root, "POST", "/agent/dispatch"),
            EffectContract::Read
        );
        assert!(root.metadata_for_request("GET", "/version").is_none());
    }
}
