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
    ActivationAuthority, ActivationIntent, DeployAction, ExpectedActive, HostIdentity, Pointer,
    Recovery, RecoveryClass, ServiceSetDigest, TransactionId,
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
        let audits = self.fs.read_audit()?;
        let (audit_records, audit_parse_error) = status::parse_audit_records(&audits);
        let audit_error =
            audit_parse_error.or_else(|| status::audit_conflict(observed.as_ref(), &audit_records));
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
        let prior = value
            .get("prior")
            .and_then(|value| (!value.is_null()).then_some(value));
        let prior = prior.map(|value| parse_pointer(Some(value))).transpose()?;
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
            format!(r#"{{"releaseDigest":"{release_digest}"}}"#).as_bytes(),
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

    fn add_generation(manager: &DeployManager, generation: &str, release: &model::Digest) {
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
                format!(r#"{{"releaseDigest":"{release}"}}"#).as_bytes(),
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

    #[test]
    fn recover_classifies_a_valid_active_pointer_after_process_death() {
        let directory = active_fixture();
        let recovery = DeployManager::open(&directory.0)
            .unwrap()
            .recover()
            .unwrap();
        assert_eq!(recovery.class, RecoveryClass::ActivationCommittedRecovered);
        assert!(recovery.reason.is_none());
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
    fn replace_active_reaches_same_filesystem_rail_before_pointer_mutation() {
        let directory = active_fixture();
        let manager = DeployManager::open(&directory.0).unwrap();
        let current = manager.fs.read_active().unwrap().unwrap();
        add_generation(&manager, "g2", &current.release);
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
        add_generation(&manager, "g2", &current.release);
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
}
