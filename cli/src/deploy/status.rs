//! Read-only deployment status projection.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::fs::{DeploymentFs, FsError};
use super::model::{
    ActivationAuthority, AuditFactRecord, DeployAction, DeployStatus, DeploymentRootIdentity,
    Digest, ExpectedActive, GenerationId, HostIdentity, NamespaceIdentity, Pointer,
    RestartLoadable, RunningService, ServiceSetDigest, ServiceSetStatus, ServiceStatus,
    TransactionId, TransactionState, TransactionStatus,
};

pub fn default_root() -> PathBuf {
    std::env::var_os("TIGHTBEAM_DEPLOY_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/opt/tightbeam"))
}

pub fn run(json_output: bool) -> Result<(), String> {
    let status = read(&default_root()).map_err(|error| error.to_string())?;
    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(&to_json(&status)).expect("status JSON serializes")
        );
    } else {
        println!(
            "restart_loadable = {}",
            restart_loadable_text(&status.restart_loadable)
        );
        println!("transaction      = {}", status.transaction.as_str());
        println!("audit            = {}", status.audit);
        println!("lock             = {}", status.lock);
        println!("observation      = {}", status.observation);
        println!("gc_hold          = {}", status.gc_hold);
    }
    Ok(())
}

pub fn read(root: &Path) -> Result<DeployStatus, FsError> {
    let fs = DeploymentFs::open(root)?;
    let (active, pointer_error) = match fs.read_active() {
        Ok(active) => (active, None),
        Err(error) => (None, Some(error.to_string())),
    };
    let intents = fs.read_intents()?;
    let audits = fs.read_audit()?;
    let (audit_records, audit_error) = parse_audit_records(&audits);
    let staged = fs.list_staging()?;
    let root_identity = fs.root_identity_digest()?;
    let intent = assess_intent(
        active.as_ref(),
        &intents,
        &root_identity,
        fs.host_identity(),
    );
    let audit_state_error = audit_conflict(active.as_ref(), &audit_records);
    let state_error = pointer_error
        .or(intent.error.clone())
        .or(audit_error)
        .or(audit_state_error);
    let transaction = match state_error.as_deref() {
        Some(reason) => TransactionStatus::Indeterminate {
            reason: reason.to_owned(),
        },
        None => match intent.state {
            IntentState::NotCommitted => TransactionStatus::NotCommitted,
            IntentState::CommittedRecovered => TransactionStatus::CommittedRecovered,
            IntentState::None => match active {
                None => TransactionStatus::VirginReady,
                Some(_) => TransactionStatus::CommittedRecovered,
            },
        },
    };
    let audit = if state_error.is_some() {
        "contradictory"
    } else if audit_records.is_empty() {
        if intent.state == IntentState::CommittedRecovered {
            "recovered-missing-row"
        } else {
            "none"
        }
    } else {
        "complete"
    };
    let restart_loadable = match (active, state_error.as_deref()) {
        (Some(pointer), None) => RestartLoadable::Managed {
            generation: pointer.generation,
            release: pointer.release,
        },
        (Some(pointer), Some(reason)) => RestartLoadable::Unavailable {
            reason: format!(
                "active pointer validation changed while reading generation {}: {reason}",
                pointer.generation
            ),
        },
        (None, Some(reason)) => RestartLoadable::Unavailable {
            reason: format!("active pointer invalid: {reason}"),
        },
        (None, None) => RestartLoadable::Unavailable {
            reason: "virgin deployment root has no managed active pointer".to_owned(),
        },
    };
    let service_set = read_service_set(&fs);
    let services = service_set
        .units
        .iter()
        .map(|unit| ServiceStatus {
            unit: unit.clone(),
            running_release: None,
            unit_state: "unknown".to_owned(),
            version: None,
            readiness: None,
            result: "pending".to_owned(),
        })
        .collect::<Vec<_>>();
    Ok(DeployStatus {
        restart_loadable,
        restart_loadable_verification:
            "unverified: no legacy verification evidence in status slice".to_owned(),
        transaction,
        audit: audit.to_owned(),
        running: services
            .iter()
            .map(|service| RunningService {
                unit: service.unit.clone(),
                root: None,
                release: None,
                state: "unknown".to_owned(),
            })
            .collect(),
        service_set: service_set.status,
        services,
        observation: if state_error.is_some() {
            "held"
        } else {
            "pending"
        }
        .to_owned(),
        prior_known_good: "unavailable: no complete machine observation".to_owned(),
        staged,
        lock: fs.lock_status()?.to_owned(),
        unit_disk: Vec::new(),
        unit_effective: Vec::new(),
        unit_transaction: Vec::new(),
        next_authority: if state_error.is_some() {
            "adjudicate"
        } else if intent.state == IntentState::NotCommitted {
            "resume-activation"
        } else if intent.state == IntentState::CommittedRecovered {
            "restart-or-observe"
        } else {
            "none"
        }
        .to_owned(),
        gc_hold: state_error.is_some() || intent.state != IntentState::None,
        gc_hold_transactions: if let Some(reason) = state_error.as_ref() {
            vec![reason.clone()]
        } else if intent.state == IntentState::None {
            Vec::new()
        } else {
            vec!["unresolved activation intent".to_owned()]
        },
        last_results: Vec::new(),
    })
}

pub(crate) fn parse_audit_records(records: &[Vec<u8>]) -> (Vec<AuditFactRecord>, Option<String>) {
    let mut parsed = Vec::new();
    for record in records {
        match parse_audit_record(record) {
            Ok(record)
                if parsed.iter().any(|known: &AuditFactRecord| {
                    known.transaction_id == record.transaction_id
                        && known.state == record.state
                        && known.observed == record.observed
                }) => {}
            Ok(record) => parsed.push(record),
            Err(error) => return (Vec::new(), Some(error)),
        }
    }
    (parsed, None)
}

pub(crate) fn audit_conflict(
    active: Option<&Pointer>,
    records: &[AuditFactRecord],
) -> Option<String> {
    for record in records {
        if !matches!(
            record.state,
            TransactionState::Activated | TransactionState::Restarted | TransactionState::Observed
        ) {
            continue;
        }
        let matches_active = match (&record.observed, active) {
            (
                NamespaceIdentity::Generation {
                    generation,
                    release,
                },
                Some(pointer),
            ) => generation == &pointer.generation && release == &pointer.release,
            _ => false,
        };
        if !matches_active {
            return Some(if active.is_none() {
                format!(
                    "durable activation history exists without active pointer (transaction {})",
                    record.transaction_id.as_str()
                )
            } else {
                format!(
                    "audit namespace fact conflicts with active pointer (transaction {})",
                    record.transaction_id.as_str()
                )
            });
        }
    }
    None
}

fn parse_audit_record(record: &[u8]) -> Result<AuditFactRecord, String> {
    let value: Value =
        serde_json::from_slice(record).map_err(|error| format!("invalid audit fact: {error}"))?;
    let transaction_id = TransactionId::new(
        value
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| "audit fact has no transactionId".to_owned())?,
    )?;
    let state = match value
        .get("state")
        .and_then(Value::as_str)
        .ok_or_else(|| "audit fact has no state".to_owned())?
    {
        "received" => TransactionState::Received,
        "staged" => TransactionState::Staged,
        "verified" => TransactionState::Verified,
        "authorized" => TransactionState::Authorized,
        "activated" => TransactionState::Activated,
        "restarted" => TransactionState::Restarted,
        "observed" => TransactionState::Observed,
        other => return Err(format!("audit fact has unsupported state: {other}")),
    };
    let observed_value = value
        .get("observed")
        .ok_or_else(|| "audit fact has no observed namespace".to_owned())?;
    let observed = match observed_value.get("kind").and_then(Value::as_str) {
        Some("virgin") => {
            NamespaceIdentity::Virgin(DeploymentRootIdentity::from_digest(Digest::parse(
                observed_value
                    .get("deploymentRoot")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "virgin audit fact has no deploymentRoot".to_owned())?,
            )?))
        }
        Some("generation") => NamespaceIdentity::Generation {
            generation: GenerationId::new(
                observed_value
                    .get("generation")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "generation audit fact has no generation".to_owned())?,
            )?,
            release: Digest::parse(
                observed_value
                    .get("releaseDigest")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "generation audit fact has no releaseDigest".to_owned())?,
            )?,
        },
        Some(other) => return Err(format!("audit fact has unsupported namespace: {other}")),
        None => return Err("audit fact has no namespace kind".to_owned()),
    };
    let fact_digest = Digest::parse(
        value
            .get("factDigest")
            .and_then(Value::as_str)
            .ok_or_else(|| "audit fact has no factDigest".to_owned())?,
    )?;
    Ok(AuditFactRecord {
        transaction_id,
        state,
        observed,
        fact_digest,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IntentState {
    None,
    NotCommitted,
    CommittedRecovered,
}

struct IntentAssessment {
    state: IntentState,
    error: Option<String>,
}

fn assess_intent(
    active: Option<&Pointer>,
    records: &[Vec<u8>],
    root_identity: &DeploymentRootIdentity,
    host_identity: &HostIdentity,
) -> IntentAssessment {
    if records.len() > 1 {
        return IntentAssessment {
            state: IntentState::None,
            error: Some("multiple unresolved activation intents".to_owned()),
        };
    }
    let Some(record) = records.first() else {
        return IntentAssessment {
            state: IntentState::None,
            error: None,
        };
    };
    let value: Value = match serde_json::from_slice(record) {
        Ok(value) => value,
        Err(error) => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some(format!("invalid activation intent: {error}")),
            };
        }
    };
    let expected = match value.get("expectedActive").and_then(Value::as_str) {
        Some(value) => match ExpectedActive::parse(value) {
            Ok(expected) => expected,
            Err(error) => {
                return IntentAssessment {
                    state: IntentState::None,
                    error: Some(format!("invalid activation intent expectedActive: {error}")),
                };
            }
        },
        None => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some("activation intent has no expectedActive".to_owned()),
            };
        }
    };
    let target = match super::parse_pointer(value.get("target")) {
        Ok(target) => target,
        Err(error) => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some(error.to_string()),
            };
        }
    };
    let authority = match parse_activation_authority(&value) {
        Ok(authority) => authority,
        Err(error) => {
            return IntentAssessment {
                state: IntentState::None,
                error: Some(format!("invalid activation intent authority: {error}")),
            };
        }
    };
    if authority.host != *host_identity {
        return IntentAssessment {
            state: IntentState::None,
            error: Some("activation intent names another host".to_owned()),
        };
    }
    if authority.deployment_root != *root_identity {
        return IntentAssessment {
            state: IntentState::None,
            error: Some(format!(
                "activation intent names deployment root {}, observed {}",
                authority.deployment_root.as_str(),
                root_identity.as_str()
            )),
        };
    }
    if let ExpectedActive::Virgin { deployment_root } = &expected
        && deployment_root != root_identity
    {
        return IntentAssessment {
            state: IntentState::None,
            error: Some(format!(
                "activation intent names deployment root {}, observed {}",
                deployment_root.as_str(),
                root_identity.as_str()
            )),
        };
    }
    let expected_matches = match &expected {
        ExpectedActive::Virgin { .. } => active.is_none(),
        ExpectedActive::Generation {
            generation,
            release,
        } => active.is_some_and(|pointer| {
            pointer.generation == *generation && pointer.release == *release
        }),
    };
    if active.is_some_and(|pointer| pointer == &target) {
        return IntentAssessment {
            state: IntentState::CommittedRecovered,
            error: None,
        };
    }
    if expected_matches {
        return IntentAssessment {
            state: IntentState::NotCommitted,
            error: None,
        };
    }
    IntentAssessment {
        state: IntentState::None,
        error: Some(format!(
            "activation intent expected {} and targets generation:{}:{} but observed {}",
            expected.as_wire(),
            target.generation,
            target.release,
            active
                .map(|pointer| format!("generation:{}:{}", pointer.generation, pointer.release))
                .unwrap_or_else(|| "virgin".to_owned())
        )),
    }
}

struct ServiceSet {
    status: ServiceSetStatus,
    units: Vec<String>,
}

fn read_service_set(fs: &DeploymentFs) -> ServiceSet {
    let bytes = if fs.root() == Path::new("/opt/tightbeam") {
        std::fs::read("/etc/tightbeam/deploy-services.json").ok()
    } else {
        fs.read_confined(Path::new("deploy-services.json")).ok()
    };
    let Some(bytes) = bytes else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: None,
                units: Vec::new(),
                description: "invalid: service registry unavailable".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: malformed service registry".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let Some(entries) = value.get("services").and_then(Value::as_array) else {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: service registry has no services".to_owned(),
            },
            units: Vec::new(),
        };
    };
    let mut units = Vec::new();
    for entry in entries {
        let Some(unit) = entry.get("unit").and_then(Value::as_str) else {
            return ServiceSet {
                status: ServiceSetStatus {
                    digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                    units: Vec::new(),
                    description: "invalid: service registry entry has no unit".to_owned(),
                },
                units: Vec::new(),
            };
        };
        if units.iter().any(|known| known == unit) {
            return ServiceSet {
                status: ServiceSetStatus {
                    digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                    units: Vec::new(),
                    description: format!("invalid: duplicate service unit {unit}"),
                },
                units: Vec::new(),
            };
        }
        units.push(unit.to_owned());
    }
    if units.is_empty() {
        return ServiceSet {
            status: ServiceSetStatus {
                digest: Some(ServiceSetDigest::from_bytes(&bytes)),
                units: Vec::new(),
                description: "invalid: service registry is empty".to_owned(),
            },
            units: Vec::new(),
        };
    }
    ServiceSet {
        status: ServiceSetStatus {
            digest: Some(ServiceSetDigest::from_bytes(&bytes)),
            units: units.clone(),
            description: format!("valid: {} ordered units", units.len()),
        },
        units,
    }
}

fn parse_activation_authority(value: &Value) -> Result<ActivationAuthority, String> {
    match value.get("action").and_then(Value::as_str) {
        Some("activation") | Some("first-cutover") => {}
        Some(other) => return Err(format!("unsupported activation action: {other}")),
        None => return Err("activation intent has no action".to_owned()),
    }
    let _action = match value.get("action").and_then(Value::as_str) {
        Some("activation") => DeployAction::Activation,
        Some("first-cutover") => DeployAction::FirstCutover,
        _ => unreachable!("action validated above"),
    };
    TransactionId::new(
        value
            .get("transactionId")
            .and_then(Value::as_str)
            .ok_or_else(|| "activation intent has no transactionId".to_owned())?,
    )?;
    Ok(ActivationAuthority {
        host: HostIdentity::parse(
            value
                .get("hostIdentity")
                .and_then(Value::as_str)
                .ok_or_else(|| "activation intent has no hostIdentity".to_owned())?,
        )?,
        deployment_root: DeploymentRootIdentity::from_digest(Digest::parse(
            value
                .get("deploymentRoot")
                .and_then(Value::as_str)
                .ok_or_else(|| "activation intent has no deploymentRoot".to_owned())?,
        )?),
        service_set: ServiceSetDigest::from_digest(Digest::parse(
            value
                .get("serviceSetDigest")
                .and_then(Value::as_str)
                .ok_or_else(|| "activation intent has no serviceSetDigest".to_owned())?,
        )?),
    })
}

fn restart_loadable_text(value: &RestartLoadable) -> String {
    match value {
        RestartLoadable::Managed {
            generation,
            release,
        } => {
            format!("generation:{generation} release:{release}")
        }
        RestartLoadable::Legacy { root, release, .. } => format!("legacy:{root} release:{release}"),
        RestartLoadable::Unavailable { reason } => reason.clone(),
    }
}

pub fn to_json(status: &DeployStatus) -> Value {
    let restart_loadable = match &status.restart_loadable {
        RestartLoadable::Managed {
            generation,
            release,
        } => json!({
            "kind": "generation",
            "generation": generation.as_str(),
            "releaseDigest": release.as_str(),
        }),
        RestartLoadable::Legacy {
            root,
            release,
            verified,
            reason,
        } => json!({
            "kind": "legacy",
            "root": root,
            "releaseDigest": release.as_str(),
            "verification": if *verified { "verified" } else { "unverified" },
            "reason": reason,
        }),
        RestartLoadable::Unavailable { reason } => json!({
            "kind": "unavailable",
            "reason": reason,
        }),
    };
    json!({
        "restartLoadable": restart_loadable,
        "restartLoadableVerification": status.restart_loadable_verification,
        "transaction": status.transaction.as_str(),
        "transactionReason": match &status.transaction {
            TransactionStatus::Indeterminate { reason } => Some(reason),
            _ => None,
        },
        "audit": status.audit,
        "running": status.running.iter().map(|service| json!({
            "unit": service.unit,
            "root": service.root,
            "releaseDigest": service.release.as_ref().map(|digest| digest.as_str()),
            "state": service.state,
        })).collect::<Vec<_>>(),
        "serviceSet": {
            "digest": status.service_set.digest.as_ref().map(|digest| digest.as_str()),
            "units": &status.service_set.units,
            "status": &status.service_set.description,
        },
        "services": status.services.iter().map(|service| json!({
            "unit": service.unit,
            "runningDigest": service.running_release.as_ref().map(|digest| digest.as_str()),
            "unitState": service.unit_state,
            "version": service.version,
            "readiness": service.readiness,
            "result": service.result,
        })).collect::<Vec<_>>(),
        "observation": status.observation,
        "priorKnownGood": status.prior_known_good,
        "staged": status.staged,
        "lock": status.lock,
        "unitDisk": status.unit_disk,
        "unitEffective": status.unit_effective,
        "unitTransaction": status.unit_transaction,
        "nextAuthority": status.next_authority,
        "gcHold": status.gc_hold,
        "gcHoldTransactions": status.gc_hold_transactions,
        "lastResults": status.last_results,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deploy::model::Digest;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    struct TempDir(PathBuf);

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-deploy-status-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        fs::write(path.join("deploy-host-id"), [7_u8; 32]).unwrap();
        fs::set_permissions(
            path.join("deploy-host-id"),
            fs::Permissions::from_mode(0o400),
        )
        .unwrap();
        TempDir(path)
    }

    #[test]
    fn status_reads_active_pointer_as_restart_loadable_truth() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":420,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let digest = Digest::from_bytes(release_manifest.as_bytes()).to_string();
        fs::create_dir_all(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam")),
        )
        .unwrap();
        fs::write(
            directory
                .0
                .join(format!("releases/sha256-{digest}/release-manifest.json")),
            release_manifest,
        )
        .unwrap();
        fs::write(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam/bin")),
            payload,
        )
        .unwrap();
        fs::write(
            directory.0.join("generations/g1/manifest.json"),
            format!(r#"{{"releaseDigest":"{digest}"}}"#),
        )
        .unwrap();
        std::os::unix::fs::symlink(
            format!("../../releases/sha256-{digest}/tightbeam"),
            directory.0.join("generations/g1/root"),
        )
        .unwrap();
        std::os::unix::fs::symlink("generations/g1", directory.0.join("active")).unwrap();
        let status = read(&directory.0).unwrap();
        assert!(matches!(
            status.restart_loadable,
            RestartLoadable::Managed { .. }
        ));
        assert_eq!(status.transaction.as_str(), "committed-recovered");
        assert_eq!(status.audit, "none");

        fs::create_dir_all(directory.0.join("audit/tx-old")).unwrap();
        let fact_digest = Digest::from_bytes(b"old-fact");
        fs::write(
            directory.0.join("audit/tx-old/fact.json"),
            format!(
                r#"{{"transactionId":"tx-old","state":"activated","observed":{{"kind":"generation","generation":"g-other","releaseDigest":"{}"}},"factDigest":"{}"}}"#,
                digest, fact_digest
            ),
        )
        .unwrap();
        let held = read(&directory.0).unwrap();
        assert_eq!(held.transaction.as_str(), "indeterminate");
        assert_eq!(held.audit, "contradictory");
        assert_eq!(held.observation, "held");
        assert!(held.gc_hold);
    }

    #[test]
    fn status_uses_target_pointer_truth_after_active_rename() {
        let directory = tempdir();
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":420,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let digest = Digest::from_bytes(release_manifest.as_bytes()).to_string();
        let release_root = directory.0.join(format!("releases/sha256-{digest}"));
        fs::create_dir_all(release_root.join("tightbeam")).unwrap();
        fs::write(release_root.join("release-manifest.json"), release_manifest).unwrap();
        fs::write(release_root.join("tightbeam/bin"), payload).unwrap();
        for generation in ["g1", "g2"] {
            let generation_root = directory.0.join(format!("generations/{generation}"));
            fs::create_dir_all(&generation_root).unwrap();
            fs::write(
                generation_root.join("manifest.json"),
                format!(r#"{{"releaseDigest":"{digest}"}}"#),
            )
            .unwrap();
            std::os::unix::fs::symlink(
                format!("../../releases/sha256-{digest}/tightbeam"),
                generation_root.join("root"),
            )
            .unwrap();
        }
        let deployment_fs = DeploymentFs::open(&directory.0).unwrap();
        let root_identity = deployment_fs.root_identity_digest().unwrap();
        let host_identity = deployment_fs.host_identity().as_str().to_owned();
        let service_set_digest = Digest::from_bytes(b"service-set");
        fs::create_dir_all(directory.0.join("intents")).unwrap();
        fs::write(
            directory.0.join("intents/tx.json"),
            format!(
                r#"{{"transactionId":"tx-1","action":"activation","expectedActive":"generation:g1:{digest}","target":{{"generation":"g2","releaseDigest":"{digest}"}},"hostIdentity":"{host_identity}","deploymentRoot":"{}","serviceSetDigest":"{}"}}"#,
                root_identity.as_str(),
                service_set_digest
            ),
        )
        .unwrap();
        std::os::unix::fs::symlink("generations/g2", directory.0.join("active")).unwrap();

        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "committed-recovered");
        assert_eq!(status.audit, "recovered-missing-row");
        assert_eq!(status.observation, "pending");
        assert!(status.gc_hold);
    }

    #[test]
    fn status_holds_unresolved_intent_during_gc_recovery() {
        let directory = tempdir();
        let deployment_fs = DeploymentFs::open(&directory.0).unwrap();
        let root_identity = deployment_fs.root_identity_digest().unwrap();
        let host_identity = deployment_fs.host_identity().as_str().to_owned();
        let service_set_digest = Digest::from_bytes(b"service-set");
        fs::create_dir_all(directory.0.join("intents")).unwrap();
        fs::write(
            directory.0.join("intents/tx.json"),
            format!(
                r#"{{"transactionId":"tx-1","action":"first-cutover","expectedActive":"virgin:{}","target":{{"generation":"g1","releaseDigest":"{}"}},"hostIdentity":"{}","deploymentRoot":"{}","serviceSetDigest":"{}"}}"#,
                root_identity.as_str(),
                Digest::from_bytes(b"release"),
                host_identity,
                root_identity.as_str(),
                service_set_digest
            ),
        )
        .unwrap();

        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "not-committed");
        assert_eq!(status.next_authority, "resume-activation");
        assert!(status.gc_hold);
        assert_eq!(
            status.gc_hold_transactions,
            vec!["unresolved activation intent"]
        );

        fs::create_dir_all(directory.0.join("audit/tx-old")).unwrap();
        fs::write(
            directory.0.join("audit/tx-old/fact.json"),
            format!(
                r#"{{"transactionId":"tx-old","state":"activated","observed":{{"kind":"generation","generation":"g-old","releaseDigest":"{}"}},"factDigest":"{}"}}"#,
                Digest::from_bytes(b"old-release"),
                Digest::from_bytes(b"old-fact")
            ),
        )
        .unwrap();
        let held = read(&directory.0).unwrap();
        assert_eq!(held.transaction.as_str(), "indeterminate");
        assert_eq!(held.audit, "contradictory");
        assert_eq!(held.observation, "held");
        assert_eq!(held.next_authority, "adjudicate");
    }

    #[test]
    fn status_holds_an_empty_release_tree_instead_of_claiming_restart_loadable() {
        let directory = tempdir();
        let digest = "a".repeat(64);
        fs::create_dir_all(
            directory
                .0
                .join(format!("releases/sha256-{digest}/tightbeam")),
        )
        .unwrap();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
        fs::write(
            directory.0.join("generations/g1/manifest.json"),
            format!(r#"{{"releaseDigest":"{digest}"}}"#),
        )
        .unwrap();
        std::os::unix::fs::symlink(
            format!("../../releases/sha256-{digest}/tightbeam"),
            directory.0.join("generations/g1/root"),
        )
        .unwrap();
        std::os::unix::fs::symlink("generations/g1", directory.0.join("active")).unwrap();

        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert!(matches!(
            status.restart_loadable,
            RestartLoadable::Unavailable { .. }
        ));
        assert_eq!(status.observation, "held");
        assert!(status.gc_hold);
    }

    #[test]
    fn status_keeps_invalid_pointer_truth_readable_and_held() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("generations/g1")).unwrap();
        std::os::unix::fs::symlink("generations/g1", directory.0.join("active")).unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.audit, "contradictory");
        assert_eq!(status.observation, "held");
        assert_eq!(status.next_authority, "adjudicate");
        assert!(status.gc_hold);
    }

    #[test]
    fn status_holds_durable_history_without_an_active_pointer() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("audit/tx-1")).unwrap();
        let deployment_fs = DeploymentFs::open(&directory.0).unwrap();
        let root_identity = deployment_fs.root_identity_digest().unwrap();
        let fact_digest = Digest::from_bytes(b"fact");
        fs::write(
            directory.0.join("audit/tx-1/fact.json"),
            format!(
                r#"{{"transactionId":"tx-1","state":"activated","observed":{{"kind":"virgin","deploymentRoot":"{}"}},"factDigest":"{}"}}"#,
                root_identity.as_str(), fact_digest
            ),
        )
        .unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.audit, "contradictory");
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.observation, "held");
        assert!(status.gc_hold);

        fs::write(
            directory.0.join("audit/tx-1/fact.json"),
            br#"{"state":"broken"}"#,
        )
        .unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.audit, "contradictory");
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.observation, "held");
    }

    #[test]
    fn status_holds_multiple_intents_instead_of_claiming_virgin() {
        let directory = tempdir();
        fs::create_dir_all(directory.0.join("intents")).unwrap();
        fs::write(directory.0.join("intents/a.json"), b"{}\n").unwrap();
        fs::write(directory.0.join("intents/b.json"), b"{}\n").unwrap();
        let status = read(&directory.0).unwrap();
        assert_eq!(status.transaction.as_str(), "indeterminate");
        assert_eq!(status.observation, "held");
        assert_eq!(status.next_authority, "adjudicate");
        assert!(status.gc_hold);
    }

    #[test]
    fn duplicate_audit_facts_are_idempotent() {
        let fact = br#"{"transactionId":"tx-1","state":"activated","observed":{"kind":"generation","generation":"g1","releaseDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"factDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#;
        let mut second = fact.to_vec();
        second.splice(
            second.len() - 64 - 2..second.len() - 2,
            b"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                .iter()
                .copied(),
        );
        let (records, error) = parse_audit_records(&[fact.to_vec(), second]);
        assert!(error.is_none());
        assert_eq!(records.len(), 1);
    }
}
