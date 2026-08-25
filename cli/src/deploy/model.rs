//! Typed data at the deployment boundary.
//!
//! The deployer keeps action authority and observed filesystem state separate.
//! These types deliberately do not contain a catch-all "deployment command";
//! callers must name the operation they are asking the mutation seam to run.

use sha2::{Digest as ShaDigest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Digest(String);

impl Digest {
    pub fn parse(value: &str) -> Result<Self, String> {
        if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(format!("invalid sha256 digest: {value}"));
        }
        Ok(Self(value.to_ascii_lowercase()))
    }

    pub fn from_bytes(bytes: &[u8]) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        Self(format!("{:x}", hasher.finalize()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Digest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerationId(String);

impl GenerationId {
    pub fn new(value: &str) -> Result<Self, String> {
        if value.is_empty()
            || value == "."
            || value == ".."
            || value.contains('/')
            || value.contains('\\')
            || value.contains(':')
            || value.bytes().any(|byte| byte.is_ascii_whitespace())
        {
            return Err(format!("invalid generation id: {value}"));
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for GenerationId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExpectedActive {
    Virgin {
        deployment_root: Digest,
    },
    Generation {
        generation: GenerationId,
        release: Digest,
    },
}

impl ExpectedActive {
    pub fn virgin(deployment_root: Digest) -> Self {
        Self::Virgin { deployment_root }
    }

    pub fn generation(generation: GenerationId, release: Digest) -> Self {
        Self::Generation {
            generation,
            release,
        }
    }

    pub fn as_wire(&self) -> String {
        match self {
            Self::Virgin { deployment_root } => format!("virgin:{deployment_root}"),
            Self::Generation {
                generation,
                release,
            } => format!("generation:{generation}:{release}"),
        }
    }

    pub fn parse(value: &str) -> Result<Self, String> {
        if let Some(digest) = value.strip_prefix("virgin:") {
            return Ok(Self::Virgin {
                deployment_root: Digest::parse(digest)?,
            });
        }
        let Some(value) = value.strip_prefix("generation:") else {
            return Err(format!("invalid expected-active value: {value}"));
        };
        let (generation, release) = value
            .rsplit_once(':')
            .ok_or_else(|| format!("invalid expected-active value: generation:{value}"))?;
        Ok(Self::Generation {
            generation: GenerationId::new(generation)?,
            release: Digest::parse(release)?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeployAction {
    Activation,
    Rollback,
    GarbageCollection,
    FirstCutover,
    UnitRollback,
    Restart,
}

impl DeployAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Activation => "activation",
            Self::Rollback => "rollback",
            Self::GarbageCollection => "gc",
            Self::FirstCutover => "first-cutover",
            Self::UnitRollback => "unit-rollback",
            Self::Restart => "restart",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionState {
    Received,
    Staged,
    Verified,
    Authorized,
    Activated,
    Restarted,
    Observed,
}

impl TransactionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::Staged => "staged",
            Self::Verified => "verified",
            Self::Authorized => "authorized",
            Self::Activated => "activated",
            Self::Restarted => "restarted",
            Self::Observed => "observed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryClass {
    VirginReady,
    ActivationNotCommitted,
    ActivationCommittedRecovered,
    ActivationIndeterminate,
}

impl RecoveryClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::VirginReady => "virgin-ready",
            Self::ActivationNotCommitted => "activation-not-committed",
            Self::ActivationCommittedRecovered => "activation-committed-recovered",
            Self::ActivationIndeterminate => "activation-indeterminate",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pointer {
    pub generation: GenerationId,
    pub release: Digest,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivationIntent {
    pub transaction_id: String,
    pub action: DeployAction,
    pub expected_active: ExpectedActive,
    pub target: Pointer,
    pub prior: Option<Pointer>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recovery {
    pub class: RecoveryClass,
    pub observed: Option<Pointer>,
    pub intent: Option<ActivationIntent>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestartLoadable {
    Managed {
        generation: GenerationId,
        release: Digest,
    },
    Legacy {
        root: String,
        release: Digest,
        verified: bool,
        reason: Option<String>,
    },
    Unavailable {
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransactionStatus {
    VirginReady,
    NotCommitted,
    Committed,
    CommittedRecovered,
    Indeterminate { reason: String },
}

impl TransactionStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::VirginReady => "virgin-ready",
            Self::NotCommitted => "not-committed",
            Self::Committed => "committed",
            Self::CommittedRecovered => "committed-recovered",
            Self::Indeterminate { .. } => "indeterminate",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningService {
    pub unit: String,
    pub root: Option<String>,
    pub release: Option<Digest>,
    pub state: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceStatus {
    pub unit: String,
    pub running_release: Option<Digest>,
    pub unit_state: String,
    pub version: Option<String>,
    pub readiness: Option<String>,
    pub result: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeployStatus {
    pub restart_loadable: RestartLoadable,
    pub restart_loadable_verification: String,
    pub transaction: TransactionStatus,
    pub audit: String,
    pub running: Vec<RunningService>,
    pub service_set: String,
    pub services: Vec<ServiceStatus>,
    pub observation: String,
    pub prior_known_good: String,
    pub staged: Vec<String>,
    pub lock: String,
    pub unit_disk: Vec<String>,
    pub unit_effective: Vec<String>,
    pub unit_transaction: Vec<String>,
    pub next_authority: String,
    pub gc_hold: bool,
    pub gc_hold_transactions: Vec<String>,
    pub last_results: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expected_active_round_trips_without_losing_the_variant() {
        let value = ExpectedActive::generation(
            GenerationId::new("g-1").unwrap(),
            Digest::parse(&"a".repeat(64)).unwrap(),
        );
        assert_eq!(ExpectedActive::parse(&value.as_wire()), Ok(value));
    }

    #[test]
    fn path_identity_types_reject_escape_components() {
        assert!(GenerationId::new("../escape").is_err());
        assert!(GenerationId::new("nested/id").is_err());
        assert!(Digest::parse("not-a-digest").is_err());
    }
}
