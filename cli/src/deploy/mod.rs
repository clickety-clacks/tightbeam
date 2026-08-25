//! Deployment kernel boundary.
//!
//! This card exposes only typed state, confined filesystem primitives, and the
//! read-only status projection. No production mutation command is registered.

pub mod fs;
pub mod model;
pub mod status;

use std::path::Path;

use fs::{DeploymentFs, DeploymentLock, FsError};
use model::{ActivationIntent, DeployAction, ExpectedActive, Pointer, Recovery, RecoveryClass};

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
        let intent = self.read_activation_intent()?;
        let class = match (pointer_error.as_deref(), &observed, &intent) {
            (Some(_), _, _) => RecoveryClass::ActivationIndeterminate,
            (None, None, None) => RecoveryClass::VirginReady,
            (None, None, Some(intent))
                if matches!(intent.expected_active, ExpectedActive::Virgin { .. }) =>
            {
                RecoveryClass::ActivationNotCommitted
            }
            (None, Some(pointer), Some(intent))
                if pointer == &intent.target
                    && matches!(
                        intent.action,
                        DeployAction::Activation | DeployAction::FirstCutover
                    ) =>
            {
                RecoveryClass::ActivationCommittedRecovered
            }
            (None, Some(pointer), Some(intent))
                if intent.prior.as_ref().is_some_and(|prior| pointer == prior) =>
            {
                RecoveryClass::ActivationNotCommitted
            }
            (None, Some(_), Some(_)) => RecoveryClass::ActivationIndeterminate,
            (None, Some(_), None) => RecoveryClass::ActivationCommittedRecovered,
            (None, None, Some(_)) => RecoveryClass::ActivationIndeterminate,
        };
        let reason = pointer_error.or_else(|| {
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
            return Ok(None);
        }
        let value: serde_json::Value =
            serde_json::from_slice(&records.remove(0)).map_err(|error| {
                FsError::InvalidPointer(format!("invalid activation intent: {error}"))
            })?;
        let transaction_id = value
            .get("transactionId")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                FsError::InvalidPointer("activation intent has no transactionId".to_owned())
            })?
            .to_owned();
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
        Ok(Some(ActivationIntent {
            transaction_id,
            action,
            expected_active,
            target,
            prior,
        }))
    }

    /// The sole pointer mutation seam in this bounded card. It requires the
    /// observed pointer to match the caller's typed expected-active value and
    /// never falls back to copying or deleting a pointer.
    pub fn replace_active(
        &self,
        expected: &ExpectedActive,
        target: &Pointer,
    ) -> Result<(), FsError> {
        let observed = self.fs.read_active()?;
        let matches = match (expected, observed.as_ref()) {
            (ExpectedActive::Virgin { .. }, None) => true,
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
        let target = Path::new("generations").join(target.generation.as_str());
        self.fs
            .replace_relative_symlink(Path::new("active"), &target)
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
