//! B-owned typed request-context precursor, for the current 1b6fb487 Command
//! enum. Register only with the approved carrier/caller handoff. This module
//! neither starts an attempt nor reads arguments, payloads, identity, or state.

use super::TransportOperation;
use crate::args::Command;

#[derive(Clone, Copy)]
enum Requests {
    Catalog,
    Dispatch,
    CatalogAndDispatch,
    ToolCallObserved,
    Attest,
}

/// Owned, immutable metadata may cross the existing lease-worker boundary.
/// Its presence does not mean a request happened. Allocate an Attempt only
/// inside the worker immediately before its actual HTTP exchange.
#[derive(Clone, Copy)]
pub(crate) struct CommandContext {
    operation: TransportOperation,
    requests: Requests,
}

impl CommandContext {
    /// Exhaustive over the current typed command enum. Operation names are
    /// literals: no target, free-form verb, argument or payload can enter them.
    /// Local-only commands have no gateway context. Commands with both local
    /// and remote branches still create no attempt on their local branch.
    pub(crate) fn for_command(command: &Command) -> Option<Self> {
        use Command::*;
        use Requests::{
            Attest as AttestPaths, Catalog, CatalogAndDispatch, Dispatch as DispatchPath,
        };
        let (operation, requests) = match command {
            IdentityCurrent | GithubAuthCheck => return None,
            Help => ("cli.help", Catalog),
            CommandHelp(_) => ("cli.command_help", Catalog),
            Doctor { .. } => ("cli.doctor", Catalog),
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
            RevokeAssignment { .. } => ("cli.revoke_assignment", DispatchPath),
            ReopenAssignment { .. } => ("cli.reopen_assignment", DispatchPath),
            RepairAssignment { .. } => ("cli.repair_assignment", DispatchPath),
            AssignmentCommitRefCorrect { .. } => {
                ("cli.assignment_commit_ref_correct", DispatchPath)
            }
            WorkItemCreate { .. } => ("cli.work_item_create", DispatchPath),
            WorkItemUpdate { .. } => ("cli.work_item_update", DispatchPath),
            WorkItemGet { .. } => ("cli.work_item_get", DispatchPath),
            WorkItemDeliveryScopeSet { .. } => ("cli.work_item_delivery_scope_set", DispatchPath),
            DeliveryScopeOwnerSet { .. } => ("cli.delivery_scope_owner_set", DispatchPath),
            DeliveryResponsibilityGet { .. } => ("cli.delivery_responsibility_get", DispatchPath),
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
            Attest { .. } => ("cli.attest", AttestPaths),
            Attests { .. } => ("cli.attests", DispatchPath),
            Assignments { .. } => ("cli.assignments", DispatchPath),
            CancelWake { .. } => ("cli.cancel_wake", DispatchPath),
            SettleTurn { .. } => ("cli.settle_turn", DispatchPath),
            IdentityEdit { .. } => ("cli.identity_edit", DispatchPath),
            IdentityStatus { .. } => ("cli.identity_status", DispatchPath),
            IdentityRelearn { .. } => ("cli.identity_relearn", DispatchPath),
            IdentityRepoint { .. } => ("cli.identity_repoint", DispatchPath),
            Learn { .. } => ("cli.learn", DispatchPath),
            Unlearn { .. } => ("cli.unlearn", DispatchPath),
            KungfuList { .. } => ("cli.kungfu_list", DispatchPath),
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
        })
    }

    /// These two typed origins are needed at the existing parser catalog
    /// calls, before it can construct the complete Command. Call them only in
    /// their already-selected parser arms; never classify arbitrary text here.
    pub(crate) fn spawn_catalog() -> Self {
        Self {
            operation: TransportOperation("cli.spawn"),
            requests: Requests::Catalog,
        }
    }

    pub(crate) fn assimilate_catalog() -> Self {
        Self {
            operation: TransportOperation("cli.assimilate"),
            requests: Requests::Catalog,
        }
    }

    /// Check the actual method and literal path before allocating an attempt.
    /// A mismatch supplies no metadata; it must not reject or change the
    /// original request. There is no production /version command in this source.
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
                Requests::Dispatch | Requests::CatalogAndDispatch | Requests::Attest
            ),
            ("POST", "/agent/terminal") => matches!(self.requests, Requests::Attest),
            ("POST", "/agent/tool-call-observed") => {
                matches!(self.requests, Requests::ToolCallObserved)
            }
            _ => false,
        };
        allowed.then_some(self.operation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::Identity;

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
}
