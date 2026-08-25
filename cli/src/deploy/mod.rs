//! Deployment kernel boundary.
//!
//! This card exposes only typed state, confined filesystem primitives, and the
//! read-only status projection. No production mutation command is registered.

pub mod fs;
pub mod model;
pub mod status;

use std::path::Path;

use fs::{DeploymentFs, DeploymentLock, FsError};
use model::{
    ActivationAuthority, ActivationIntent, AuditFactRecord, AuditTransition, DeployAction,
    ExpectedActive, HostIdentity, NamespaceIdentity, Pointer, Recovery, RecoveryClass,
    ServiceSetDigest, TransactionId, TransactionState,
};

#[derive(Debug)]
pub struct DeployManager {
    fs: DeploymentFs,
}

impl DeployManager {
    pub fn open(root: impl Into<std::path::PathBuf>) -> Result<Self, FsError> {
        Ok(Self {
            fs: DeploymentFs::open(root)?,
        })
    }

    pub fn status(&self) -> Result<model::DeployStatus, FsError> {
        status::read(self.fs.root())
    }

    pub fn lock(&self) -> Result<DeploymentLock, FsError> {
        DeploymentLock::acquire(&self.fs)
    }

    pub fn recover(&self) -> Result<Recovery, FsError> {
        self.recover_with_append(|intent| self.append_recovered_commit(intent))
    }

    fn recover_with_append<F>(&self, append: F) -> Result<Recovery, FsError>
    where
        F: FnOnce(&ActivationIntent) -> Result<(), FsError>,
    {
        // Recovery appends a durable fact when it proves a renamed target. Keep the
        // complete read/classify/append sequence in the deployment mutation domain.
        let _lock = self.lock()?;
        let (observed, pointer_error) = match self.fs.read_active() {
            Ok(observed) => (observed, None),
            Err(error) => (None, Some(error.to_string())),
        };
        let (intent, intent_error) = match self.read_activation_intent() {
            Ok(intent) => (intent, None),
            Err(error) => {
                let error = error.to_string();
                let reason = error
                    .strip_prefix("invalid active pointer: ")
                    .unwrap_or(&error)
                    .to_owned();
                (None, Some(reason))
            }
        };
        let mut audits = self.fs.read_audit()?;
        let (mut audit_records, mut audit_error) = status::parse_audit_records(&audits);
        if audit_error.is_none()
            && let (Some(pointer), Some(intent)) = (&observed, &intent)
            && pointer == &intent.target
            && matches!(
                intent.action,
                DeployAction::Activation | DeployAction::FirstCutover
            )
        {
            let (recovered, _) = self.recovered_commit_fact(intent)?;
            let mut prospective = audit_records.clone();
            prospective.push(recovered);
            if status::audit_conflict(&self.fs, observed.as_ref(), &prospective).is_none() {
                append(intent)?;
                audits = self.fs.read_audit()?;
                (audit_records, audit_error) = status::parse_audit_records(&audits);
            }
        }
        let audit_error = audit_error
            .or_else(|| status::audit_conflict(&self.fs, observed.as_ref(), &audit_records));
        let class = match (
            pointer_error.as_deref(),
            intent_error.as_deref(),
            audit_error.as_deref(),
            &observed,
            &intent,
        ) {
            (Some(_), _, _, _, _) | (_, Some(_), _, _, _) | (_, _, Some(_), _, _) => {
                RecoveryClass::ActivationIndeterminate
            }
            (None, None, None, None, None) => RecoveryClass::VirginReady,
            (None, None, None, None, Some(intent))
                if matches!(intent.expected_active, ExpectedActive::Virgin { .. }) =>
            {
                RecoveryClass::ActivationNotCommitted
            }
            (None, None, None, Some(pointer), Some(intent))
                if pointer == &intent.target
                    && matches!(
                        intent.action,
                        DeployAction::Activation | DeployAction::FirstCutover
                    ) =>
            {
                RecoveryClass::ActivationCommittedRecovered
            }
            (None, None, None, Some(pointer), Some(intent))
                if intent.prior.as_ref().is_some_and(|prior| pointer == prior) =>
            {
                RecoveryClass::ActivationNotCommitted
            }
            (None, None, None, Some(_), Some(_)) => RecoveryClass::ActivationIndeterminate,
            (None, None, None, Some(_), None) => RecoveryClass::ActivationCommittedRecovered,
            (None, None, None, None, Some(_)) => RecoveryClass::ActivationIndeterminate,
        };
        let reason = pointer_error.or(intent_error).or(audit_error).or_else(|| {
            (class == RecoveryClass::ActivationIndeterminate)
                .then(|| "active pointer and unresolved intent do not agree".to_owned())
        });
        Ok(Recovery {
            class,
            observed,
            intent,
            reason,
        })
    }

    // The filename derives from the exact transaction/state/namespace fact.
    // Repeating recovery therefore publishes the same immutable bytes or refuses;
    // it cannot create a second recovered-commit authority.
    fn append_recovered_commit(&self, intent: &ActivationIntent) -> Result<(), FsError> {
        let (fact, bytes) = self.recovered_commit_fact(intent)?;
        let transaction = intent.transaction_id.as_str();
        self.fs
            .ensure_dir(&Path::new("audit").join(transaction), 0o755)?;
        self.fs.publish_immutable(
            &Path::new("audit")
                .join(transaction)
                .join(format!("{}.json", fact.fact_digest.as_str())),
            &bytes,
            0o444,
        )?;
        Ok(())
    }

    fn recovered_commit_fact(
        &self,
        intent: &ActivationIntent,
    ) -> Result<(AuditFactRecord, Vec<u8>), FsError> {
        let transaction = intent.transaction_id.as_str();
        let observed = serde_json::json!({
            "kind": "generation",
            "generation": intent.target.generation.as_str(),
            "releaseDigest": intent.target.release.as_str(),
        });
        let transition = serde_json::json!({
            "priorGeneration": intent.prior.as_ref().map(|pointer| pointer.generation.as_str()),
            "targetGeneration": intent.target.generation.as_str(),
        });
        let unsigned = serde_json::json!({
            "transactionId": transaction,
            "state": "activated",
            "observed": observed,
            "transition": transition,
        });
        let unsigned_bytes = serde_json::to_vec(&unsigned).map_err(|error| {
            FsError::InvalidPointer(format!("serialize recovered commit fact: {error}"))
        })?;
        let fact_digest = model::Digest::from_bytes(&unsigned_bytes);
        let fact = serde_json::json!({
            "transactionId": transaction,
            "state": "activated",
            "observed": unsigned["observed"].clone(),
            "transition": unsigned["transition"].clone(),
            "factDigest": fact_digest.as_str(),
        });
        let bytes = serde_json::to_vec(&fact).map_err(|error| {
            FsError::InvalidPointer(format!("serialize recovered commit fact: {error}"))
        })?;
        Ok((
            AuditFactRecord {
                transaction_id: intent.transaction_id.clone(),
                state: TransactionState::Activated,
                observed: NamespaceIdentity::Generation {
                    generation: intent.target.generation.clone(),
                    release: intent.target.release.clone(),
                },
                transition: Some(AuditTransition {
                    prior_generation: intent.prior.as_ref().map(|prior| prior.generation.clone()),
                    target_generation: intent.target.generation.clone(),
                }),
                fact_digest,
            },
            bytes,
        ))
    }

    #[cfg(test)]
    fn recover_with_fault(&self, point: fs::FaultPoint) -> Result<Recovery, FsError> {
        self.recover_with_append(|intent| {
            if point == fs::FaultPoint::BeforeRecoveredAuditPublication {
                return Err(fs::injected_fault(point));
            }
            self.append_recovered_commit_with_fault(intent, point)
        })
    }

    #[cfg(test)]
    fn append_recovered_commit_with_fault(
        &self,
        intent: &ActivationIntent,
        point: fs::FaultPoint,
    ) -> Result<(), FsError> {
        let (fact, bytes) = self.recovered_commit_fact(intent)?;
        let transaction = intent.transaction_id.as_str();
        self.fs
            .ensure_dir(&Path::new("audit").join(transaction), 0o755)?;
        self.fs.publish_immutable_with_fault(
            &Path::new("audit")
                .join(transaction)
                .join(format!("{}.json", fact.fact_digest.as_str())),
            &bytes,
            0o444,
            point,
        )?;
        Ok(())
    }

    pub(crate) fn gc_guard(&self) -> Result<(), FsError> {
        let status = self.status()?;
        if status.gc_hold {
            return Err(FsError::InvalidPointer(format!(
                "GC refused while deployment state is held: {}",
                status
                    .gc_hold_transactions
                    .first()
                    .map(String::as_str)
                    .unwrap_or("unresolved deployment state")
            )));
        }
        Ok(())
    }

    fn read_activation_intent(&self) -> Result<Option<ActivationIntent>, FsError> {
        let mut records = self.fs.read_intents()?;
        if records.is_empty() {
            return Ok(None);
        }
        if records.len() != 1 {
            return Err(FsError::InvalidPointer(
                "multiple unresolved activation intents".to_owned(),
            ));
        }
        let value: serde_json::Value =
            serde_json::from_slice(&records.remove(0)).map_err(|error| {
                FsError::InvalidPointer(format!("invalid activation intent: {error}"))
            })?;
        let transaction_id = TransactionId::new(
            value
                .get("transactionId")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| {
                    FsError::InvalidPointer("activation intent has no transactionId".to_owned())
                })?,
        )
        .map_err(FsError::InvalidPointer)?;
        let action = match value.get("action").and_then(serde_json::Value::as_str) {
            Some("activation") => DeployAction::Activation,
            Some("first-cutover") => DeployAction::FirstCutover,
            Some(action) => {
                return Err(FsError::InvalidPointer(format!(
                    "unsupported intent action: {action}"
                )));
            }
            None => {
                return Err(FsError::InvalidPointer(
                    "activation intent has no action".to_owned(),
                ));
            }
        };
        let expected_active = ExpectedActive::parse(
            value
                .get("expectedActive")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| {
                    FsError::InvalidPointer("activation intent has no expectedActive".to_owned())
                })?,
        )
        .map_err(FsError::InvalidPointer)?;
        let target = parse_pointer(value.get("target"))?;
        self.fs
            .validate_generation_target(&target)
            .map_err(|error| {
                FsError::InvalidPointer(format!("activation intent target is invalid: {error}"))
            })?;
        let prior = value
            .get("prior")
            .and_then(|value| (!value.is_null()).then_some(value));
        let prior = prior.map(|value| parse_pointer(Some(value))).transpose()?;
        match (&expected_active, &prior) {
            (ExpectedActive::Virgin { .. }, None) => {}
            (
                ExpectedActive::Generation {
                    generation,
                    release,
                },
                Some(prior),
            ) if &prior.generation == generation && &prior.release == release => {}
            (ExpectedActive::Virgin { .. }, Some(_)) => {
                return Err(FsError::InvalidPointer(
                    "virgin activation intent names a prior generation".to_owned(),
                ));
            }
            (ExpectedActive::Generation { .. }, None) => {
                return Err(FsError::InvalidPointer(
                    "activation intent omits its expected prior generation".to_owned(),
                ));
            }
            (ExpectedActive::Generation { .. }, Some(_)) => {
                return Err(FsError::InvalidPointer(
                    "activation intent prior disagrees with expectedActive".to_owned(),
                ));
            }
        }
        let manifest_prior = self.fs.generation_prior(&target.generation)?;
        let intent_prior = prior.as_ref().map(|pointer| pointer.generation.clone());
        if manifest_prior != intent_prior {
            return Err(FsError::InvalidPointer(
                "activation intent prior disagrees with target generation prior_generation"
                    .to_owned(),
            ));
        }
        let authority = ActivationAuthority {
            host: HostIdentity::parse(
                value
                    .get("hostIdentity")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| {
                        FsError::InvalidPointer("activation intent has no hostIdentity".to_owned())
                    })?,
            )
            .map_err(FsError::InvalidPointer)?,
            deployment_root: model::DeploymentRootIdentity::from_digest(
                model::Digest::parse(
                    value
                        .get("deploymentRoot")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| {
                            FsError::InvalidPointer(
                                "activation intent has no deploymentRoot".to_owned(),
                            )
                        })?,
                )
                .map_err(FsError::InvalidPointer)?,
            ),
            service_set: ServiceSetDigest::from_digest(
                model::Digest::parse(
                    value
                        .get("serviceSetDigest")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| {
                            FsError::InvalidPointer(
                                "activation intent has no serviceSetDigest".to_owned(),
                            )
                        })?,
                )
                .map_err(FsError::InvalidPointer)?,
            ),
        };
        let observed_root = self.fs.root_identity_digest()?;
        if authority.host != *self.fs.host_identity() {
            return Err(FsError::InvalidPointer(
                "activation intent names another host".to_owned(),
            ));
        }
        if authority.deployment_root != observed_root {
            return Err(FsError::InvalidPointer(format!(
                "activation intent names deployment root {}, observed {}",
                authority.deployment_root.as_str(),
                observed_root.as_str()
            )));
        }
        Ok(Some(ActivationIntent {
            transaction_id,
            action,
            expected_active,
            target,
            prior,
            authority,
        }))
    }

    /// The sole pointer mutation seam in this bounded card. It requires the
    /// observed pointer to match the caller's typed expected-active value and
    /// never falls back to copying or deleting a pointer.
    pub fn replace_active(
        &self,
        lock: &DeploymentLock,
        expected: &ExpectedActive,
        target: &Pointer,
    ) -> Result<(), FsError> {
        self.replace_active_inner(lock, expected, target, &self.fs.root().join("generations"))
    }

    fn replace_active_inner(
        &self,
        lock: &DeploymentLock,
        expected: &ExpectedActive,
        target: &Pointer,
        filesystem_peer: &Path,
    ) -> Result<(), FsError> {
        lock.belongs_to(&self.fs)?;
        let observed = self.fs.read_active()?;
        let matches = match (expected, observed.as_ref()) {
            (ExpectedActive::Virgin { deployment_root }, None) => {
                deployment_root == &self.fs.root_identity_digest()?
            }
            (
                ExpectedActive::Generation {
                    generation,
                    release,
                },
                Some(pointer),
            ) => pointer.generation == *generation && pointer.release == *release,
            _ => false,
        };
        if !matches {
            return Err(FsError::InvalidPointer(format!(
                "expected active {} does not match observed pointer",
                expected.as_wire()
            )));
        }
        self.fs.same_filesystem(filesystem_peer)?;
        self.fs.validate_generation_target(target)?;
        let target = Path::new("generations").join(target.generation.as_str());
        self.fs
            .replace_relative_symlink(Path::new("active"), &target)
    }

    #[cfg(test)]
    fn replace_active_for_test(
        &self,
        lock: &DeploymentLock,
        expected: &ExpectedActive,
        target: &Pointer,
        filesystem_peer: &Path,
    ) -> Result<(), FsError> {
        self.replace_active_inner(lock, expected, target, filesystem_peer)
    }
}

fn parse_pointer(value: Option<&serde_json::Value>) -> Result<Pointer, FsError> {
    let value =
        value.ok_or_else(|| FsError::InvalidPointer("intent pointer is absent".to_owned()))?;
    let generation = value
        .get("generation")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| FsError::InvalidPointer("intent pointer has no generation".to_owned()))?;
    let release = value
        .get("releaseDigest")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| FsError::InvalidPointer("intent pointer has no releaseDigest".to_owned()))?;
    Ok(Pointer {
        generation: model::GenerationId::new(generation).map_err(FsError::InvalidPointer)?,
        release: model::Digest::parse(release).map_err(FsError::InvalidPointer)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs as stdfs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    struct TempDir(PathBuf);

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = stdfs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-deploy-recovery-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        stdfs::create_dir(&path).unwrap();
        stdfs::write(path.join("deploy-host-id"), [7_u8; 32]).unwrap();
        stdfs::set_permissions(
            path.join("deploy-host-id"),
            stdfs::Permissions::from_mode(0o400),
        )
        .unwrap();
        TempDir(path)
    }

    fn active_fixture() -> TempDir {
        let directory = tempdir();
        let fs = DeploymentFs::open(&directory.0).unwrap();
        let payload = b"payload";
        let payload_digest = model::Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":292,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let release_digest = model::Digest::from_bytes(release_manifest.as_bytes());
        let release = format!("sha256-{release_digest}");
        fs.ensure_dir(
            &Path::new("releases").join(&release).join("tightbeam"),
            0o755,
        )
        .unwrap();
        fs.publish_immutable(
            &Path::new("releases")
                .join(&release)
                .join("release-manifest.json"),
            release_manifest.as_bytes(),
            0o444,
        )
        .unwrap();
        fs.publish_immutable(
            &Path::new("releases").join(&release).join("tightbeam/bin"),
            payload,
            0o444,
        )
        .unwrap();
        fs.ensure_dir(Path::new("generations/g1"), 0o755).unwrap();
        fs.publish_immutable(
            Path::new("generations/g1/manifest.json"),
            format!(r#"{{"prior_generation":null,"releaseDigest":"{release_digest}"}}"#).as_bytes(),
            0o444,
        )
        .unwrap();
        fs.replace_relative_symlink(
            Path::new("generations/g1/root"),
            &Path::new("../../releases").join(&release).join("tightbeam"),
        )
        .unwrap();
        fs.replace_relative_symlink(Path::new("active"), Path::new("generations/g1"))
            .unwrap();
        directory
    }

    fn add_generation(
        manager: &DeployManager,
        generation: &str,
        release: &model::Digest,
        prior: Option<&str>,
    ) {
        manager
            .fs
            .ensure_dir(&Path::new("generations").join(generation), 0o755)
            .unwrap();
        manager
            .fs
            .publish_immutable(
                &Path::new("generations")
                    .join(generation)
                    .join("manifest.json"),
                format!(
                    r#"{{"prior_generation":{},"releaseDigest":"{release}"}}"#,
                    prior
                        .map(|prior| format!("\"{prior}\""))
                        .unwrap_or("null".to_owned())
                )
                .as_bytes(),
                0o444,
            )
            .unwrap();
        let release_name = format!("sha256-{release}");
        manager
            .fs
            .replace_relative_symlink(
                &Path::new("generations").join(generation).join("root"),
                &Path::new("../../releases")
                    .join(release_name)
                    .join("tightbeam"),
            )
            .unwrap();
    }

    fn write_transition_fact(
        manager: &DeployManager,
        transaction: &str,
        prior: Option<&Pointer>,
        target: &Pointer,
    ) {
        let observed = serde_json::json!({
            "kind": "generation",
            "generation": target.generation.as_str(),
            "releaseDigest": target.release.as_str(),
        });
        let transition = serde_json::json!({
            "priorGeneration": prior.map(|pointer| pointer.generation.as_str()),
            "targetGeneration": target.generation.as_str(),
        });
        let unsigned = serde_json::json!({
            "transactionId": transaction,
            "state": "activated",
            "observed": observed,
            "transition": transition,
        });
        let digest = model::Digest::from_bytes(&serde_json::to_vec(&unsigned).unwrap());
        let fact = serde_json::json!({
            "transactionId": transaction,
            "state": "activated",
            "observed": unsigned["observed"].clone(),
            "transition": unsigned["transition"].clone(),
            "factDigest": digest.as_str(),
        });
        manager
            .fs
            .ensure_dir(&Path::new("audit").join(transaction), 0o755)
            .unwrap();
        stdfs::write(
            manager
                .fs
                .root()
                .join("audit")
                .join(transaction)
                .join(format!("{digest}.json")),
            serde_json::to_vec(&fact).unwrap(),
        )
        .unwrap();
    }

    fn activation_intent_bytes(
        manager: &DeployManager,
        transaction: &str,
        action: &str,
        expected: &ExpectedActive,
        prior: Option<&Pointer>,
        target: &Pointer,
    ) -> Vec<u8> {
        let root_identity = manager.fs.root_identity_digest().unwrap();
        let host_identity = manager.fs.host_identity().as_str().to_owned();
        serde_json::to_vec(&serde_json::json!({
            "transactionId": transaction,
            "action": action,
            "expectedActive": expected.as_wire(),
            "prior": prior.map(|pointer| serde_json::json!({
                "generation": pointer.generation.as_str(),
                "releaseDigest": pointer.release.as_str(),
            })),
            "target": {
                "generation": target.generation.as_str(),
                "releaseDigest": target.release.as_str(),
            },
            "hostIdentity": host_identity,
            "deploymentRoot": root_identity.as_str(),
            "serviceSetDigest": model::Digest::from_bytes(b"service-set").as_str(),
        }))
        .unwrap()
    }

    fn write_activation_intent(
        manager: &DeployManager,
        transaction: &str,
        action: &str,
        expected: &ExpectedActive,
        prior: Option<&Pointer>,
        target: &Pointer,
    ) {
        let bytes = activation_intent_bytes(manager, transaction, action, expected, prior, target);
        manager.fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        manager
            .fs
            .publish_immutable(
                &Path::new("intents").join(format!("{transaction}.json")),
                &bytes,
                0o444,
            )
            .unwrap();
    }

    fn write_activation_intent_with_fault(
        manager: &DeployManager,
        transaction: &str,
        action: &str,
        expected: &ExpectedActive,
        prior: Option<&Pointer>,
        target: &Pointer,
        point: fs::FaultPoint,
    ) -> Result<(), FsError> {
        let bytes = activation_intent_bytes(manager, transaction, action, expected, prior, target);
        manager.fs.ensure_dir(Path::new("intents"), 0o755)?;
        manager.fs.publish_immutable_with_fault(
            &Path::new("intents").join(format!("{transaction}.json")),
            &bytes,
            0o444,
            point,
        )?;
        Ok(())
    }

    fn add_generation_with_fault(
        manager: &DeployManager,
        generation: &str,
        release: &model::Digest,
        prior: Option<&str>,
        point: fs::FaultPoint,
    ) -> Result<(), FsError> {
        manager
            .fs
            .ensure_dir(&Path::new("generations").join(generation), 0o755)?;
        manager.fs.publish_immutable_with_fault(
            &Path::new("generations")
                .join(generation)
                .join("manifest.json"),
            format!(
                r#"{{"prior_generation":{},"releaseDigest":"{release}"}}"#,
                prior
                    .map(|prior| format!("\"{prior}\""))
                    .unwrap_or("null".to_owned())
            )
            .as_bytes(),
            0o444,
            point,
        )?;
        let release_name = format!("sha256-{release}");
        manager.fs.replace_relative_symlink(
            &Path::new("generations").join(generation).join("root"),
            &Path::new("../../releases")
                .join(release_name)
                .join("tightbeam"),
        )?;
        Ok(())
    }

    fn assert_protected_transition_objects(directory: &TempDir, transaction: &str) {
        assert!(directory.0.join("generations/g1").is_dir());
        assert!(directory.0.join("generations/g2").is_dir());
        assert!(
            directory
                .0
                .join("intents")
                .join(format!("{transaction}.json"))
                .is_file()
        );
    }

    #[test]
    fn recover_holds_an_active_pointer_without_a_durable_audit_link() {
        let directory = active_fixture();
        let recovery = DeployManager::open(&directory.0)
            .unwrap()
            .recover()
            .unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationIndeterminate);
        assert_eq!(
            recovery.reason.as_deref(),
            Some("audit transition chain has no link for generation: g1")
        );
    }

    #[test]
    fn recover_holds_durable_history_when_active_pointer_is_missing() {
        let directory = tempdir();
        stdfs::create_dir_all(directory.0.join("audit/tx-1")).unwrap();
        let manager = DeployManager::open(&directory.0).unwrap();
        let root_identity = manager.fs.root_identity_digest().unwrap();
        stdfs::write(
            directory.0.join("audit/tx-1/fact.json"),
            format!(
                r#"{{"transactionId":"tx-1","state":"activated","observed":{{"kind":"virgin","deploymentRoot":"{}"}},"factDigest":"{}"}}"#,
                root_identity.as_str(),
                model::Digest::from_bytes(b"fact")
            ),
        )
        .unwrap();
        let recovery = manager.recover().unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationIndeterminate);
        assert_eq!(
            recovery.reason.as_deref(),
            Some("durable activation history exists without active pointer (transaction tx-1)")
        );
    }

    #[test]
    fn recover_holds_multiple_unresolved_intents_instead_of_calling_virgin() {
        let directory = tempdir();
        stdfs::create_dir_all(directory.0.join("intents")).unwrap();
        stdfs::write(directory.0.join("intents/a.json"), b"{}\n").unwrap();
        stdfs::write(directory.0.join("intents/b.json"), b"{}\n").unwrap();
        let recovery = DeployManager::open(&directory.0)
            .unwrap()
            .recover()
            .unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationIndeterminate);
        assert_eq!(
            recovery.reason.as_deref(),
            Some("multiple unresolved activation intents")
        );
    }

    #[test]
    fn recover_holds_an_unresolved_intent_with_an_invalid_target() {
        let directory = tempdir();
        let manager = DeployManager::open(&directory.0).unwrap();
        let root_identity = manager.fs.root_identity_digest().unwrap();
        let host_identity = manager.fs.host_identity().as_str().to_owned();
        stdfs::create_dir_all(directory.0.join("intents")).unwrap();
        stdfs::write(
            directory.0.join("intents/tx-invalid-target.json"),
            format!(
                r#"{{"transactionId":"tx-invalid-target","action":"first-cutover","expectedActive":"virgin:{}","target":{{"generation":"missing","releaseDigest":"{}"}},"hostIdentity":"{}","deploymentRoot":"{}","serviceSetDigest":"{}"}}"#,
                root_identity.as_str(),
                model::Digest::from_bytes(b"missing-release"),
                host_identity,
                root_identity.as_str(),
                model::Digest::from_bytes(b"service-set"),
            ),
        )
        .unwrap();

        let recovery = manager.recover().unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationIndeterminate);
        assert!(
            recovery
                .reason
                .as_deref()
                .is_some_and(|reason| reason.contains("target is invalid"))
        );
    }

    #[test]
    fn recover_refuses_an_ordinary_intent_without_its_manifested_prior_before_audit_append() {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        add_generation(
            &manager,
            "g2",
            &current.release,
            Some(current.generation.as_str()),
        );
        let root_identity = manager.fs.root_identity_digest().unwrap();
        let host_identity = manager.fs.host_identity().as_str().to_owned();
        manager.fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        stdfs::write(
            directory.0.join("intents/tx-missing-prior.json"),
            format!(
                r#"{{"transactionId":"tx-missing-prior","action":"activation","expectedActive":"generation:{}:{}","target":{{"generation":"g2","releaseDigest":"{}"}},"hostIdentity":"{}","deploymentRoot":"{}","serviceSetDigest":"{}"}}"#,
                current.generation,
                current.release,
                current.release,
                host_identity,
                root_identity.as_str(),
                model::Digest::from_bytes(b"service-set"),
            ),
        )
        .unwrap();
        manager
            .fs
            .replace_relative_symlink(Path::new("active"), Path::new("generations/g2"))
            .unwrap();

        let recovery = manager.recover().unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationIndeterminate);
        assert!(
            recovery
                .reason
                .as_deref()
                .is_some_and(|reason| reason.contains("omits its expected prior"))
        );
        assert!(manager.fs.read_audit().unwrap().is_empty());
    }

    #[test]
    fn recover_refuses_to_append_while_the_deployment_lock_is_held() {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let lock = manager.lock().unwrap();
        assert!(matches!(manager.recover(), Err(FsError::Busy)));
        drop(lock);
    }

    #[test]
    fn replace_active_reaches_same_filesystem_rail_before_pointer_mutation() {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        add_generation(&manager, "g2", &current.release, None);
        let lock = manager.lock().unwrap();
        let target = Pointer {
            generation: model::GenerationId::new("g2").unwrap(),
            release: current.release.clone(),
        };
        let expected =
            ExpectedActive::generation(current.generation.clone(), current.release.clone());
        assert!(matches!(
            manager.replace_active_for_test(&lock, &expected, &target, Path::new("/proc")),
            Err(FsError::CrossDevice { .. })
        ));
        assert_eq!(manager.fs.read_active().unwrap(), Some(current));
    }

    #[test]
    fn replace_active_refuses_a_target_release_mismatch() {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        add_generation(&manager, "g2", &current.release, None);
        let wrong_release = model::Digest::from_bytes(b"wrong-release");
        let target = Pointer {
            generation: model::GenerationId::new("g2").unwrap(),
            release: wrong_release,
        };
        let expected =
            ExpectedActive::generation(current.generation.clone(), current.release.clone());
        let lock = manager.lock().unwrap();
        assert!(matches!(
            manager.replace_active(&lock, &expected, &target),
            Err(FsError::InvalidPointer(_))
        ));
        assert_eq!(manager.fs.read_active().unwrap(), Some(current));
    }

    fn assert_recovery_after_barrier(u0: bool, point: fs::FaultPoint) {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        if u0 {
            stdfs::remove_file(directory.0.join("active")).unwrap();
        } else {
            write_transition_fact(&manager, "tx-g1", None, &current);
        }
        let prior = (!u0).then_some(current.clone());
        let target = Pointer {
            generation: model::GenerationId::new("g2").unwrap(),
            release: current.release.clone(),
        };
        let expected = prior.as_ref().map_or_else(
            || ExpectedActive::virgin(manager.fs.root_identity_digest().unwrap()),
            |pointer| {
                ExpectedActive::generation(pointer.generation.clone(), pointer.release.clone())
            },
        );
        let transaction = if u0 { "tx-u0" } else { "tx-ordinary" };
        if point == fs::FaultPoint::AfterTargetGenerationFsync {
            assert!(matches!(
                add_generation_with_fault(
                    &manager,
                    "g2",
                    &target.release,
                    prior.as_ref().map(|pointer| pointer.generation.as_str()),
                    point,
                ),
                Err(FsError::InvalidPointer(reason)) if reason.contains("fault injected")
            ));
        } else {
            add_generation(
                &manager,
                "g2",
                &target.release,
                prior.as_ref().map(|pointer| pointer.generation.as_str()),
            );
            if point == fs::FaultPoint::AfterIntentFsync {
                assert!(matches!(
                    write_activation_intent_with_fault(
                        &manager,
                        transaction,
                        if u0 { "first-cutover" } else { "activation" },
                        &expected,
                        prior.as_ref(),
                        &target,
                        point,
                    ),
                    Err(FsError::InvalidPointer(reason)) if reason.contains("fault injected")
                ));
            } else {
                write_activation_intent(
                    &manager,
                    transaction,
                    if u0 { "first-cutover" } else { "activation" },
                    &expected,
                    prior.as_ref(),
                    &target,
                );
                let replacement = match point {
                    fs::FaultPoint::AfterActiveRename | fs::FaultPoint::AfterRootFsync => {
                        manager.fs.replace_relative_symlink_with_fault(
                            Path::new("active"),
                            Path::new("generations/g2"),
                            point,
                        )
                    }
                    _ => manager
                        .fs
                        .replace_relative_symlink(Path::new("active"), Path::new("generations/g2")),
                };
                if matches!(
                    point,
                    fs::FaultPoint::AfterActiveRename | fs::FaultPoint::AfterRootFsync
                ) {
                    assert!(matches!(
                        replacement,
                        Err(FsError::InvalidPointer(reason)) if reason.contains("fault injected")
                    ));
                } else {
                    replacement.unwrap();
                    if point == fs::FaultPoint::AfterActiveReread {
                        assert!(matches!(
                            manager.fs.read_active_with_fault(point),
                            Err(FsError::InvalidPointer(reason)) if reason.contains("fault injected")
                        ));
                        assert_eq!(manager.fs.read_active().unwrap(), Some(target.clone()));
                    }
                }
            }
        }

        let restarted = DeployManager::open(&directory.0).unwrap();
        let recovery = restarted.recover().unwrap();
        let post_pointer = !matches!(
            point,
            fs::FaultPoint::AfterTargetGenerationFsync | fs::FaultPoint::AfterIntentFsync
        );
        let expected_class = if post_pointer {
            RecoveryClass::ActivationCommittedRecovered
        } else if point == fs::FaultPoint::AfterTargetGenerationFsync && u0 {
            RecoveryClass::VirginReady
        } else if point == fs::FaultPoint::AfterTargetGenerationFsync {
            RecoveryClass::ActivationCommittedRecovered
        } else {
            RecoveryClass::ActivationNotCommitted
        };
        assert_eq!(recovery.class, expected_class, "u0={u0}, point={point:?}");
        assert!(directory.0.join("generations/g2").is_dir());
        if point != fs::FaultPoint::AfterTargetGenerationFsync {
            assert_protected_transition_objects(&directory, transaction);
        }
        let expected_audits = if post_pointer {
            if u0 { 1 } else { 2 }
        } else if u0 {
            0
        } else {
            1
        };
        assert_eq!(restarted.fs.read_audit().unwrap().len(), expected_audits);
        let repeated = restarted.recover().unwrap();
        assert_eq!(repeated.class, expected_class);
        assert_eq!(restarted.fs.read_audit().unwrap().len(), expected_audits);
    }

    #[test]
    fn deterministic_recovery_matrix_runs_ordinary_and_u0_at_every_named_barrier() {
        for u0 in [false, true] {
            for point in [
                fs::FaultPoint::AfterTargetGenerationFsync,
                fs::FaultPoint::AfterIntentFsync,
                fs::FaultPoint::AfterActiveRename,
                fs::FaultPoint::AfterRootFsync,
                fs::FaultPoint::AfterActiveReread,
            ] {
                assert_recovery_after_barrier(u0, point);
            }
        }
    }

    fn target_pointer_recovery_fixture(u0: bool) -> (TempDir, DeployManager, &'static str) {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        if u0 {
            stdfs::remove_file(directory.0.join("active")).unwrap();
        } else {
            write_transition_fact(&manager, "tx-g1", None, &current);
        }
        let target = Pointer {
            generation: model::GenerationId::new("g2").unwrap(),
            release: current.release.clone(),
        };
        add_generation(
            &manager,
            "g2",
            &target.release,
            (!u0).then_some(current.generation.as_str()),
        );
        let transaction = if u0 {
            "tx-audit-u0"
        } else {
            "tx-audit-ordinary"
        };
        write_activation_intent(
            &manager,
            transaction,
            if u0 { "first-cutover" } else { "activation" },
            &if u0 {
                ExpectedActive::virgin(manager.fs.root_identity_digest().unwrap())
            } else {
                ExpectedActive::generation(current.generation.clone(), current.release.clone())
            },
            (!u0).then_some(&current),
            &target,
        );
        manager
            .fs
            .replace_relative_symlink(Path::new("active"), Path::new("generations/g2"))
            .unwrap();
        (directory, manager, transaction)
    }

    #[test]
    fn recovered_audit_publication_matrix_preserves_one_digest_bound_authority() {
        for u0 in [false, true] {
            for point in [
                fs::FaultPoint::BeforeRecoveredAuditPublication,
                fs::FaultPoint::DuringRecoveredAuditPublication,
                fs::FaultPoint::AfterRecoveredAuditPublication,
            ] {
                let (directory, manager, transaction) = target_pointer_recovery_fixture(u0);
                assert!(matches!(
                    manager.recover_with_fault(point),
                    Err(FsError::InvalidPointer(reason)) if reason.contains("fault injected")
                ));
                assert_protected_transition_objects(&directory, transaction);
                let before_restart = manager.fs.read_audit().unwrap().len();
                assert_eq!(
                    before_restart,
                    if point == fs::FaultPoint::BeforeRecoveredAuditPublication {
                        if u0 { 0 } else { 1 }
                    } else if u0 {
                        1
                    } else {
                        2
                    },
                    "u0={u0}, point={point:?}"
                );

                let restarted = DeployManager::open(&directory.0).unwrap();
                assert_eq!(
                    restarted.recover().unwrap().class,
                    RecoveryClass::ActivationCommittedRecovered
                );
                let expected_audits = if u0 { 1 } else { 2 };
                assert_eq!(restarted.fs.read_audit().unwrap().len(), expected_audits);
                assert_eq!(
                    restarted.recover().unwrap().class,
                    RecoveryClass::ActivationCommittedRecovered
                );
                assert_eq!(restarted.fs.read_audit().unwrap().len(), expected_audits);
            }
        }
    }

    #[test]
    fn gc_guard_refuses_before_deletion_when_recovery_has_an_unresolved_intent() {
        let directory = tempdir();
        let manager = DeployManager::open(&directory.0).unwrap();
        manager.fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        stdfs::write(directory.0.join("intents/tx.json"), b"{}\n").unwrap();
        let unrelated = directory.0.join("releases/unrelated-object");
        stdfs::create_dir_all(unrelated.parent().unwrap()).unwrap();
        stdfs::write(&unrelated, b"preserve").unwrap();
        let deletion = (|| -> Result<(), FsError> {
            manager.gc_guard()?;
            stdfs::remove_file(&unrelated)
                .map_err(|error| FsError::InvalidPointer(format!("test GC deletion: {error}")))
        })();
        assert!(matches!(
            deletion,
            Err(FsError::InvalidPointer(reason)) if reason.contains("GC refused")
        ));
        assert!(directory.0.join("intents/tx.json").exists());
        assert!(unrelated.exists());
    }
}
