use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

mod bank;
mod guard;
mod probe;
mod redact;

use bank::{Gh, RealGh};
use redact::Scrubbed;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GithubState {
    Live,
    MissingCli,
    NeedsOnboarding,
    Expired,
    InsufficientScope,
    GitUnready,
    Unknown,
}

impl GithubState {
    fn as_str(&self) -> &'static str {
        match self {
            GithubState::Live => "live",
            GithubState::MissingCli => "missing_cli",
            GithubState::NeedsOnboarding => "needs_onboarding",
            GithubState::Expired => "expired",
            GithubState::InsufficientScope => "insufficient_scope",
            GithubState::GitUnready => "git_unready",
            GithubState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GithubStatus {
    hostname: String,
    state: GithubState,
    failed_phase: &'static str,
    account: Option<String>,
    git_protocol: Option<String>,
    git_remote: Option<Scrubbed>,
    git_ready: Option<bool>,
    detail: Scrubbed,
}

pub fn onboard(
    endpoint: &crate::dispatch::Endpoint,
    identity: &crate::args::Identity,
    hostname: &str,
    profile: &str,
    account: Option<&str>,
    remote: Option<&str>,
    replace: bool,
) -> Result<(), String> {
    let hostname = probe::normalize_hostname(hostname)?;
    validate_profile(profile)?;
    let machine_hint = credential_machine()?;
    let context = credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider": "github",
            "phase": "context",
            "machine": machine_hint,
            "profile": profile,
            "hostname": hostname,
        }),
    )?;
    let machine = required_string(&context, "machine")?;
    let principal = required_string(&context, "principal")?;
    let base_dir = PathBuf::from(
        required_string(&context, "baseDir").or_else(|_| required_string(&context, "base_dir"))?,
    );
    let owner_user_id = context
        .get("ownerUserId")
        .and_then(serde_json::Value::as_str)
        .filter(|owner| !owner.is_empty())
        .map(str::to_owned);
    let binding = context.get("binding").filter(|value| !value.is_null());
    let prior_state = binding
        .and_then(|value| value.get("state"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("needs_onboarding")
        .to_owned();
    let prior_account = binding
        .and_then(|value| value.get("account"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    let operation_class = if replace { "rotation" } else { "onboarding" };
    if base_dir != crate::base_dir::resolve() {
        return Err("GitHub credential base directory does not match this host".to_owned());
    }
    let home = credential_home(&base_dir, &machine, profile);
    let _lock = acquire_writer_lock(&base_dir, &machine, profile, &principal)?;
    let gh = RealGh::using_home(&home);

    if !replace && validate_storage(&home).is_ok() {
        let mut current = probe::probe_with(&hostname, &gh);
        if current.state == GithubState::Live {
            if let Some(remote) = remote {
                current = probe::probe_git_remote(&current, remote, &gh);
            }
            if current.state == GithubState::Live
                && account.is_none_or(|expected| current.account.as_deref() == Some(expected))
            {
                credential_dispatch(
                    endpoint,
                    identity,
                    serde_json::json!({
                        "provider":"github", "phase":"begin", "attempt":operation_class,
                        "machine":machine, "profile":profile, "hostname":hostname,
                    }),
                )?;
                finish_outcome(
                    endpoint,
                    identity,
                    &machine,
                    profile,
                    &hostname,
                    current.account.as_deref(),
                    "live",
                    operation_class,
                    "existing_authority_reconciled",
                )?;
                println!(
                    "{}",
                    serde_json::json!({"status":"live","machine":machine,"profile":profile,"hostname":hostname,"account":current.account})
                );
                return Ok(());
            }
        }
    }

    credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider": "github", "phase": "begin", "machine": machine,
            "profile": profile, "hostname": hostname, "attempt": operation_class,
        }),
    )?;

    let before_authority = authority_fingerprint(&home);
    let gh = match RealGh::banking_into_home(&home) {
        Ok(gh) => gh,
        Err(error) => {
            finish_outcome(
                endpoint,
                identity,
                &machine,
                profile,
                &hostname,
                prior_account.as_deref(),
                &prior_state,
                operation_class,
                "credential_home_prepare_failed",
            )?;
            return Err(error);
        }
    };
    let login = gh.login_device(
        &[
            "auth",
            "login",
            "--hostname",
            &hostname,
            "--web",
            "--git-protocol",
            "https",
            "--insecure-storage",
        ],
        identity,
        endpoint,
        &machine,
        owner_user_id,
    );
    let login = match login {
        Ok(status) => status,
        Err(error) => {
            let changed = authority_fingerprint(&home) != before_authority;
            finish_outcome(
                endpoint,
                identity,
                &machine,
                profile,
                &hostname,
                if changed {
                    None
                } else {
                    prior_account.as_deref()
                },
                if changed {
                    "present_but_unverified"
                } else {
                    &prior_state
                },
                operation_class,
                if error.to_ascii_lowercase().contains("expired") {
                    "device_flow_expired"
                } else if changed {
                    "provider_login_failed_after_write"
                } else {
                    "provider_login_failed_before_write"
                },
            )?;
            return Err(error);
        }
    };
    if !login.success() {
        let changed = authority_fingerprint(&home) != before_authority;
        finish_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            if changed {
                None
            } else {
                prior_account.as_deref()
            },
            if changed {
                "present_but_unverified"
            } else {
                &prior_state
            },
            operation_class,
            if changed {
                "provider_login_failed_after_write"
            } else {
                "provider_login_failed_before_write"
            },
        )?;
        return Err(format!(
            "GitHub device login did not complete. Rerun tightbeam onboard github --profile {profile} --hostname {hostname} --replace"
        ));
    }
    if let Err(error) = gh.secure_banked_files() {
        finish_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            None,
            "present_but_unverified",
            operation_class,
            "banked_storage_permissions_failed",
        )?;
        return Err(error);
    }
    if let Err(cause) = validate_storage(&home) {
        finish_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            None,
            "present_but_unverified",
            operation_class,
            cause,
        )?;
        return Err(format!("GitHub credential home is hollow: {cause}"));
    }
    let mut status = probe::probe_with(&hostname, &gh);
    if status.state == GithubState::Live {
        if let Some(remote) = remote {
            status = probe::probe_git_remote(&status, remote, &gh);
        }
    }
    if status.state != GithubState::Live {
        finish_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            status.account.as_deref(),
            "present_but_unverified",
            operation_class,
            "post_login_probe_failed",
        )?;
        return Err(format!(
            "GitHub onboarding ended in {}. Rerun with --replace; do not paste a PAT into an agent.",
            status.state.as_str()
        ));
    }
    if account.is_some_and(|expected| status.account.as_deref() != Some(expected)) {
        finish_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            status.account.as_deref(),
            "present_but_unverified",
            operation_class,
            "account_mismatch",
        )?;
        return Err(
            "GitHub account did not match --account; the provider home is present but unverified"
                .to_owned(),
        );
    }
    finish_outcome(
        endpoint,
        identity,
        &machine,
        profile,
        &hostname,
        status.account.as_deref(),
        "live",
        operation_class,
        if replace {
            "rotation_completed"
        } else {
            "onboarding_completed"
        },
    )?;
    println!(
        "{}",
        serde_json::json!({"status":"live","machine":machine,"profile":profile,"hostname":hostname,"account":status.account})
    );
    Ok(())
}

fn authority_fingerprint(home: &Path) -> Option<(u64, u64, u64, i64, i64, i64, i64)> {
    let metadata = fs::symlink_metadata(home.join("hosts.yml")).ok()?;
    Some((
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    ))
}

#[allow(clippy::too_many_arguments)]
fn finish_outcome(
    endpoint: &crate::dispatch::Endpoint,
    identity: &crate::args::Identity,
    machine: &str,
    profile: &str,
    hostname: &str,
    account: Option<&str>,
    state: &str,
    operation_class: &str,
    cause: &str,
) -> Result<(), String> {
    credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider":"github", "phase":"finish", "machine":machine,
            "profile":profile, "hostname":hostname, "account":account,
            "state":state, "operationClass":operation_class, "cause":cause,
            "dedupeKey":format!("github-{operation_class}:{machine}:{profile}:{hostname}:{}:{cause}", account.unwrap_or("none")),
        }),
    )?;
    Ok(())
}

pub fn revoke(
    endpoint: &crate::dispatch::Endpoint,
    identity: &crate::args::Identity,
    hostname: &str,
    profile: &str,
    account: Option<&str>,
) -> Result<(), String> {
    let hostname = probe::normalize_hostname(hostname)?;
    validate_profile(profile)?;
    let machine_hint = credential_machine()?;
    let context = credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider":"github", "phase":"context", "machine":machine_hint,
            "profile":profile, "hostname":hostname,
        }),
    )?;
    let machine = required_string(&context, "machine")?;
    let principal = required_string(&context, "principal")?;
    let base_dir = PathBuf::from(
        required_string(&context, "baseDir").or_else(|_| required_string(&context, "base_dir"))?,
    );
    if base_dir != crate::base_dir::resolve() {
        return Err("GitHub credential base directory does not match this host".to_owned());
    }
    let binding = context.get("binding").filter(|value| !value.is_null());
    let prior_state = binding
        .and_then(|value| value.get("state"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("needs_onboarding")
        .to_owned();
    if binding
        .and_then(|value| value.get("state"))
        .and_then(serde_json::Value::as_str)
        == Some("revoked")
    {
        println!(
            "{}",
            serde_json::json!({"status":"revoked","machine":machine,"profile":profile,"hostname":hostname})
        );
        return Ok(());
    }
    let account = account
        .map(str::to_owned)
        .or_else(|| {
            binding
                .and_then(|value| value.get("account"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .ok_or_else(|| "github-account-required: pass --account LOGIN".to_owned())?;
    let _lock = acquire_writer_lock(&base_dir, &machine, profile, &principal)?;
    credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider":"github", "phase":"revoke-begin", "machine":machine,
            "profile":profile, "hostname":hostname,
        }),
    )?;
    let home = credential_home(&base_dir, &machine, profile);
    let before_authority = authority_fingerprint(&home);
    let status = RealGh::using_home(&home).status(&[
        "auth",
        "logout",
        "--hostname",
        &hostname,
        "--user",
        &account,
    ]);
    let status = match status {
        Ok(status) => status,
        Err(error) => {
            finish_revocation_outcome(
                endpoint,
                identity,
                &machine,
                profile,
                &hostname,
                Some(&account),
                &prior_state,
                "provider_logout_could_not_start",
            )?;
            return Err(error);
        }
    };
    if !status.success() {
        let changed = authority_fingerprint(&home) != before_authority;
        finish_revocation_outcome(
            endpoint,
            identity,
            &machine,
            profile,
            &hostname,
            Some(&account),
            if changed {
                "present_but_unverified"
            } else {
                &prior_state
            },
            if changed {
                "provider_logout_failed_after_write"
            } else {
                "provider_logout_failed_before_write"
            },
        )?;
        return Err("GitHub CLI could not remove the local login".to_owned());
    }
    credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider":"github", "phase":"revoke-finish", "machine":machine,
            "profile":profile, "hostname":hostname, "account":account,
            "state":"revoked", "cause":"local_logout_completed",
            "dedupeKey":format!("github-revoke:{machine}:{profile}:{hostname}:{account}"),
        }),
    )?;
    println!(
        "{}",
        serde_json::json!({"status":"revoked","machine":machine,"profile":profile,"hostname":hostname,"account":account,"remoteGrant":"revoke separately in GitHub settings if required"})
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn finish_revocation_outcome(
    endpoint: &crate::dispatch::Endpoint,
    identity: &crate::args::Identity,
    machine: &str,
    profile: &str,
    hostname: &str,
    account: Option<&str>,
    state: &str,
    cause: &str,
) -> Result<(), String> {
    credential_dispatch(
        endpoint,
        identity,
        serde_json::json!({
            "provider":"github", "phase":"revoke-finish", "machine":machine,
            "profile":profile, "hostname":hostname, "account":account,
            "state":state, "cause":cause,
            "dedupeKey":format!("github-revocation:{machine}:{profile}:{hostname}:{}:{cause}", account.unwrap_or("none")),
        }),
    )?;
    Ok(())
}

fn credential_dispatch(
    endpoint: &crate::dispatch::Endpoint,
    identity: &crate::args::Identity,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    crate::dispatch::github_dispatch(endpoint, identity, params)
}

fn credential_machine() -> Result<Option<String>, String> {
    if let Some(machine) = std::env::var("TIGHTBEAM_MACHINE")
        .ok()
        .filter(|value| !value.is_empty())
    {
        return Ok(Some(machine));
    }
    match crate::dispatch::provisioned() {
        crate::dispatch::Provisioned::GatewayHost => Ok(None),
        crate::dispatch::Provisioned::Satellite {
            machine: Some(machine),
        } => Ok(Some(machine)),
        crate::dispatch::Provisioned::Satellite { machine: None } => Err(
            "this satellite's gateway.json does not name its registered machine; restart the gateway before GitHub onboarding"
                .to_owned(),
        ),
        crate::dispatch::Provisioned::Absent => Err(
            "this host has no gateway.json; GitHub onboarding requires provisioned host identity"
                .to_owned(),
        ),
    }
}

fn required_string(value: &serde_json::Value, key: &str) -> Result<String, String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("GitHub credential dispatch omitted {key}"))
}

fn validate_profile(profile: &str) -> Result<(), String> {
    if valid_profile(profile) {
        Ok(())
    } else {
        Err("--profile must match ^[a-z0-9][a-z0-9-]{0,62}$".to_owned())
    }
}

fn acquire_writer_lock(
    base_dir: &Path,
    machine: &str,
    profile: &str,
    principal: &str,
) -> Result<std::fs::File, String> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    let dir = base_dir
        .join("credential-homes")
        .join(machine)
        .join("github");
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("could not create GitHub lock directory: {error}"))?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not secure GitHub lock directory: {error}"))?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(dir.join(format!(".{profile}.lock")))
        .map_err(|error| format!("could not open GitHub credential lock: {error}"))?;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        return Err(format!(
            "github-credential-busy: profile {profile} is being changed by {principal}; retry after that process exits"
        ));
    }
    Ok(file)
}

pub fn check_tool_call_stdin() -> Result<(), String> {
    Err(
        "github-auth-check is compatibility-only and cannot authorize a tool call; install the compiled github-network-auth-required rule"
            .to_owned(),
    )
}

pub fn credential_home(base_dir: &Path, machine: &str, profile: &str) -> PathBuf {
    base_dir
        .join("credential-homes")
        .join(machine)
        .join("github")
        .join(profile)
}

pub(crate) fn check_compiled_rule(
    endpoint: &crate::dispatch::Endpoint,
    identity_sha: &str,
    machine: &str,
    principal: &str,
    input: &crate::dispatch_rule_check::ToolCallInputV1,
) -> Result<Vec<crate::dispatch_rule_check::ToolCheckMaterialV1>, String> {
    if input.abi != 1 || input.tool != crate::dispatch_rule_check::ToolCallToolV1::Bash {
        return Err(runtime_refusal(
            machine,
            principal,
            "normalized_input_invalid",
        ));
    }
    let command = input.command.as_str();

    let mut known_hosts = Vec::new();
    if guard::might_need_hostname_index(command) {
        let result = github_request(
            endpoint,
            "/agent/github/hostnames",
            serde_json::json!({"identitySha": identity_sha}),
        )?;
        known_hosts = result
            .get("hostnames")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| runtime_refusal(machine, principal, "hostname_index_invalid"))?
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| runtime_refusal(machine, principal, "hostname_index_invalid"))
            })
            .collect::<Result<Vec<_>, _>>()?;
    }

    let classifier = guard::classify_command_with(
        command,
        &RealGh::using_home(Path::new("/non-authoritative-classifier-home")),
        &known_hosts,
    )
    .map_err(|_| runtime_refusal(machine, principal, "classifier_failed"))?;

    match classifier {
        guard::Classification::NotApplicable => {
            return Ok(vec![material(
                machine,
                principal,
                None,
                None,
                "not_applicable",
                "not_applicable",
                "classifier",
                "command_not_github_network",
                None,
                vec![],
            )]);
        }
        guard::Classification::ProjectionOverride => {
            return record_and_refuse(
                endpoint,
                identity_sha,
                machine,
                principal,
                None,
                None,
                "gh",
                "projection_override",
                "projection",
                "reserved_environment_override",
            );
        }
        guard::Classification::AmbiguousHostname => {
            return record_and_refuse(
                endpoint,
                identity_sha,
                machine,
                principal,
                None,
                None,
                "gh",
                "ambiguous_hostname",
                "classifier",
                "conflicting_hostname_selectors",
            );
        }
        guard::Classification::MalformedToolCall => {
            return record_and_refuse(
                endpoint,
                identity_sha,
                machine,
                principal,
                None,
                None,
                "gh",
                "malformed_tool_call",
                "classifier",
                "malformed_hostname_selector",
            );
        }
        guard::Classification::Targets(targets) => {
            let profile = std::env::var("TIGHTBEAM_GITHUB_PROFILE")
                .ok()
                .filter(|value| valid_profile(value));
            let Some(profile) = profile else {
                let target = targets.first().expect("classified target");
                return record_and_refuse(
                    endpoint,
                    identity_sha,
                    machine,
                    principal,
                    None,
                    Some(&target.hostname),
                    target.operation_class,
                    "profile_not_elected",
                    "projection",
                    "manifest_profile_not_elected",
                );
            };

            let expected_home = credential_home(&crate::base_dir::resolve(), machine, &profile);
            if std::env::var_os("GH_CONFIG_DIR").as_deref() != Some(expected_home.as_os_str()) {
                let target = targets.first().expect("classified target");
                return record_and_refuse(
                    endpoint,
                    identity_sha,
                    machine,
                    principal,
                    Some(&profile),
                    Some(&target.hostname),
                    target.operation_class,
                    "projection_override",
                    "projection",
                    "credential_home_mismatch",
                );
            }

            let mut materials = Vec::new();
            for target in targets {
                let _probe_lock =
                    match acquire_probe_lock(&crate::base_dir::resolve(), machine, &profile) {
                        Ok(lock) => lock,
                        Err(_) => {
                            return record_and_refuse(
                                endpoint,
                                identity_sha,
                                machine,
                                principal,
                                Some(&profile),
                                Some(&target.hostname),
                                target.operation_class,
                                "unknown",
                                "storage",
                                "credential_writer_active",
                            );
                        }
                    };
                let binding = github_request(
                    endpoint,
                    "/agent/github/binding",
                    serde_json::json!({
                        "identitySha": identity_sha,
                        "profile": profile,
                        "hostname": target.hostname,
                    }),
                )?;
                let binding = binding.get("binding");
                if binding.is_none() || binding == Some(&serde_json::Value::Null) {
                    return record_and_refuse(
                        endpoint,
                        identity_sha,
                        machine,
                        principal,
                        Some(&profile),
                        Some(&target.hostname),
                        target.operation_class,
                        "needs_onboarding",
                        "provider",
                        "profile_binding_absent",
                    );
                }
                let binding = binding.expect("checked binding");
                let binding_state = binding.get("state").and_then(serde_json::Value::as_str);
                let mutation = binding
                    .get("mutation_attempt")
                    .or_else(|| binding.get("mutationAttempt"))
                    .and_then(serde_json::Value::as_str);
                if mutation.is_some() {
                    return record_and_refuse(
                        endpoint,
                        identity_sha,
                        machine,
                        principal,
                        Some(&profile),
                        Some(&target.hostname),
                        target.operation_class,
                        "present_but_unverified",
                        "provider",
                        "provider_mutation_incomplete",
                    );
                }
                if binding_state == Some("revoked") {
                    return record_and_refuse(
                        endpoint,
                        identity_sha,
                        machine,
                        principal,
                        Some(&profile),
                        Some(&target.hostname),
                        target.operation_class,
                        "revoked",
                        "provider",
                        "local_revocation_tombstone",
                    );
                }

                if let Err(cause) = validate_storage(&expected_home) {
                    let state = if cause == "hosts_yml_absent" || cause == "credential_home_absent"
                    {
                        "needs_onboarding"
                    } else {
                        "hollow"
                    };
                    return record_and_refuse(
                        endpoint,
                        identity_sha,
                        machine,
                        principal,
                        Some(&profile),
                        Some(&target.hostname),
                        target.operation_class,
                        state,
                        "storage",
                        cause,
                    );
                }

                let gh = RealGh::using_home(&expected_home);
                let mut status = probe::probe_with(&target.hostname, &gh);
                if status.state == GithubState::Live {
                    if let Some(remote) = &target.remote {
                        status = probe::probe_git_remote(&status, remote, &gh);
                    }
                }
                let state = status.state.as_str();
                let cause = match status.state {
                    GithubState::Live => "current_provider_probe_live",
                    GithubState::MissingCli => "github_cli_missing",
                    GithubState::NeedsOnboarding => "provider_auth_missing",
                    GithubState::Expired => "provider_http_401",
                    GithubState::InsufficientScope => "provider_http_403",
                    GithubState::GitUnready => "git_remote_probe_failed",
                    GithubState::Unknown => "provider_response_unknown",
                };
                let observation_id = record_observation(
                    endpoint,
                    identity_sha,
                    Some(&profile),
                    Some(&target.hostname),
                    target.operation_class,
                    state,
                    if status.state == GithubState::GitUnready {
                        "git"
                    } else {
                        "provider"
                    },
                    cause,
                    target.remote.as_deref(),
                )?;
                if status.state != GithubState::Live {
                    return Ok(vec![material(
                        machine,
                        principal,
                        Some(&profile),
                        Some(&target.hostname),
                        target.operation_class,
                        state,
                        if status.state == GithubState::GitUnready {
                            "git"
                        } else {
                            "provider"
                        },
                        cause,
                        Some(repair_for(Some(&profile), Some(&target.hostname))),
                        vec![observation_id],
                    )]);
                }
                materials.push(material(
                    machine,
                    principal,
                    Some(&profile),
                    Some(&target.hostname),
                    target.operation_class,
                    "live",
                    "provider",
                    cause,
                    None,
                    vec![observation_id],
                ));
            }
            Ok(materials)
        }
    }
}

fn acquire_probe_lock(
    base_dir: &Path,
    machine: &str,
    profile: &str,
) -> Result<std::fs::File, String> {
    use std::os::fd::AsRawFd;

    let path = base_dir
        .join("credential-homes")
        .join(machine)
        .join("github")
        .join(format!(".{profile}.lock"));
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(path)
        .map_err(|_| "github_probe_lock_unavailable".to_owned())?;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) };
    if result != 0 {
        return Err("github_credential_busy".to_owned());
    }
    Ok(file)
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 63
        && profile.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || (byte == b'-' && index > 0)
        })
}

fn validate_storage(home: &Path) -> Result<(), &'static str> {
    let mut directory = home.to_path_buf();
    for _ in 0..4 {
        let metadata = fs::symlink_metadata(&directory).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                "credential_home_absent"
            } else {
                "credential_home_lstat_failed"
            }
        })?;
        if metadata.file_type().is_symlink()
            || !metadata.is_dir()
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err("credential_home_ancestor_not_private_directory");
        }
        directory = directory
            .parent()
            .ok_or("credential_home_ancestor_missing")?
            .to_path_buf();
    }
    let home_meta = fs::symlink_metadata(home).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            "credential_home_absent"
        } else {
            "credential_home_lstat_failed"
        }
    })?;
    if home_meta.file_type().is_symlink()
        || !home_meta.is_dir()
        || home_meta.permissions().mode() & 0o077 != 0
    {
        return Err("credential_home_not_private_directory");
    }
    let hosts = home.join("hosts.yml");
    let hosts_meta = fs::symlink_metadata(hosts).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            "hosts_yml_absent"
        } else {
            "hosts_yml_lstat_failed"
        }
    })?;
    if hosts_meta.file_type().is_symlink() || !hosts_meta.is_file() {
        return Err("hosts_yml_not_regular");
    }
    if hosts_meta.len() == 0 {
        return Err("hosts_yml_empty");
    }
    if hosts_meta.nlink() != 1 {
        return Err("hosts_yml_link_count");
    }
    if hosts_meta.permissions().mode() & 0o077 != 0 {
        return Err("hosts_yml_not_private");
    }
    Ok(())
}

fn github_request(
    endpoint: &crate::dispatch::Endpoint,
    path: &'static str,
    body: serde_json::Value,
) -> Result<serde_json::Value, String> {
    crate::dispatch::send_to(
        endpoint,
        &crate::dispatch::RequestSpec {
            method: "POST",
            path,
            body_json: body.to_string(),
        },
    )
    .map_err(|_| "rule_runtime_failure: authenticated GitHub API unavailable".to_owned())?
    .ok_or_else(|| "rule_runtime_failure: authenticated GitHub API returned no material".to_owned())
}

#[allow(clippy::too_many_arguments)]
fn record_observation(
    endpoint: &crate::dispatch::Endpoint,
    identity_sha: &str,
    profile: Option<&str>,
    hostname: Option<&str>,
    operation_class: &str,
    state: &str,
    phase: &str,
    cause: &str,
    remote: Option<&str>,
) -> Result<String, String> {
    let result = github_request(
        endpoint,
        "/agent/github/observe",
        serde_json::json!({
            "identitySha": identity_sha,
            "profile": profile,
            "hostname": hostname,
            "state": state,
            "operationClass": operation_class,
            "phase": phase,
            "cause": cause,
            "rule": "github-network-auth-required",
            "sanitizedRemote": remote,
        }),
    )?;
    result
        .get("id")
        .and_then(serde_json::Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "rule_runtime_failure: observation response omitted id".to_owned())
}

#[allow(clippy::too_many_arguments)]
fn record_and_refuse(
    endpoint: &crate::dispatch::Endpoint,
    identity_sha: &str,
    machine: &str,
    principal: &str,
    profile: Option<&str>,
    hostname: Option<&str>,
    operation_class: &str,
    state: &str,
    phase: &str,
    cause: &str,
) -> Result<Vec<crate::dispatch_rule_check::ToolCheckMaterialV1>, String> {
    let observation_id = record_observation(
        endpoint,
        identity_sha,
        profile,
        hostname,
        operation_class,
        state,
        phase,
        cause,
        None,
    )?;
    Ok(vec![material(
        machine,
        principal,
        profile,
        hostname,
        operation_class,
        state,
        phase,
        cause,
        Some(repair_for(profile, hostname)),
        vec![observation_id],
    )])
}

#[allow(clippy::too_many_arguments)]
fn material(
    machine: &str,
    principal: &str,
    profile: Option<&str>,
    hostname: Option<&str>,
    operation_class: &str,
    state: &str,
    phase: &str,
    cause: &str,
    repair: Option<String>,
    observation_ids: Vec<String>,
) -> crate::dispatch_rule_check::ToolCheckMaterialV1 {
    crate::dispatch_rule_check::ToolCheckMaterialV1 {
        state: state.to_owned(),
        operation_class: operation_class.to_owned(),
        machine: machine.to_owned(),
        profile: profile.map(str::to_owned),
        hostname: hostname.map(str::to_owned),
        phase: phase.to_owned(),
        cause: cause.to_owned(),
        principal: principal.to_owned(),
        repair,
        observation_ids,
    }
}

fn repair_for(profile: Option<&str>, hostname: Option<&str>) -> String {
    match (profile, hostname) {
        (Some(profile), Some(hostname)) => {
            format!("tightbeam onboard github --profile {profile} --hostname {hostname}")
        }
        _ => "elect provisioning.credentials.github.profile in the pinned archetype manifest"
            .to_owned(),
    }
}

fn render_refusal(
    machine: &str,
    principal: &str,
    profile: Option<&str>,
    hostname: Option<&str>,
    state: &str,
    phase: &str,
    cause: &str,
) -> String {
    let profile = profile.unwrap_or("none");
    let hostname = hostname.unwrap_or("none");
    let repair = repair_for(
        (profile != "none").then_some(profile),
        (hostname != "none").then_some(hostname),
    );
    format!(
        "[gate: github-network-auth-required] state={state} machine={machine} profile={profile} hostname={hostname} phase={phase} cause={cause} principal={principal} repair={repair}"
    )
}

fn runtime_refusal(machine: &str, principal: &str, cause: &str) -> String {
    render_refusal(
        machine,
        principal,
        None,
        None,
        "rule_runtime_failure",
        "classifier",
        cause,
    )
}

#[cfg(test)]
mod storage_tests {
    use super::*;
    use std::io::Write;

    fn fixture_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tightbeam-github-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn storage_requires_every_credential_home_ancestor_to_be_private() {
        let root = fixture_root("ancestor-mode");
        let home = credential_home(&root, "fixture", "work");
        let gh = RealGh::banking_into_home(&home).unwrap();
        let mut hosts = std::fs::File::create(home.join("hosts.yml")).unwrap();
        hosts.write_all(b"fixture-authority").unwrap();
        gh.secure_banked_files().unwrap();
        assert_eq!(validate_storage(&home), Ok(()));

        let ancestor = root.join("credential-homes");
        std::fs::set_permissions(&ancestor, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            validate_storage(&home),
            Err("credential_home_ancestor_not_private_directory")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn probe_lock_refuses_while_the_profile_writer_is_active() {
        let root = fixture_root("probe-lock");
        let writer = acquire_writer_lock(&root, "fixture", "work", "session:writer").unwrap();
        assert!(acquire_probe_lock(&root, "fixture", "work").is_err());
        drop(writer);
        assert!(acquire_probe_lock(&root, "fixture", "work").is_ok());
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod test_support {
    use std::collections::VecDeque;
    use std::os::unix::process::ExitStatusExt;
    use std::path::PathBuf;
    use std::process::Output;
    use std::sync::Mutex;

    use super::bank::Gh;

    pub(super) struct FakeGh {
        present: bool,
        outputs: Mutex<VecDeque<(&'static [&'static str], Output)>>,
        statuses: Mutex<VecDeque<(&'static [&'static str], std::process::ExitStatus)>>,
        git_outputs: Mutex<VecDeque<(&'static str, Output)>>,
        remote_urls: Mutex<VecDeque<(&'static str, Option<&'static str>)>>,
        submodule_urls: Mutex<VecDeque<Vec<&'static str>>>,
        current_remotes: Mutex<VecDeque<Vec<(&'static str, &'static str, bool)>>>,
    }

    impl FakeGh {
        pub(super) fn new(present: bool) -> Self {
            Self {
                present,
                outputs: Mutex::new(VecDeque::new()),
                statuses: Mutex::new(VecDeque::new()),
                git_outputs: Mutex::new(VecDeque::new()),
                remote_urls: Mutex::new(VecDeque::new()),
                submodule_urls: Mutex::new(VecDeque::new()),
                current_remotes: Mutex::new(VecDeque::new()),
            }
        }

        pub(super) fn output(self, args: &'static [&'static str], output: Output) -> Self {
            self.outputs.lock().unwrap().push_back((args, output));
            self
        }

        pub(super) fn status(
            self,
            args: &'static [&'static str],
            status: std::process::ExitStatus,
        ) -> Self {
            self.statuses.lock().unwrap().push_back((args, status));
            self
        }

        pub(super) fn git_output(self, remote: &'static str, output: Output) -> Self {
            self.git_outputs.lock().unwrap().push_back((remote, output));
            self
        }

        pub(super) fn remote_url(self, name: &'static str, url: Option<&'static str>) -> Self {
            self.remote_urls.lock().unwrap().push_back((name, url));
            self
        }

        pub(super) fn submodule_urls(self, urls: Vec<&'static str>) -> Self {
            self.submodule_urls.lock().unwrap().push_back(urls);
            self
        }

        pub(super) fn current_remotes(
            self,
            remotes: Vec<(&'static str, &'static str, bool)>,
        ) -> Self {
            self.current_remotes.lock().unwrap().push_back(remotes);
            self
        }
    }

    impl Gh for FakeGh {
        fn which_gh(&self) -> Option<PathBuf> {
            self.present.then(|| PathBuf::from("/usr/bin/gh"))
        }

        fn output(&self, args: &[&str]) -> Result<Output, String> {
            let (expected, output) = self
                .outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh output call");
            assert_eq!(args, expected);
            Ok(output)
        }

        fn status(&self, args: &[&str]) -> Result<std::process::ExitStatus, String> {
            let (expected, status) = self
                .statuses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected gh status call");
            assert_eq!(args, expected);
            Ok(status)
        }

        fn git_ls_remote(&self, remote: &str) -> Result<Output, String> {
            let (expected, output) = self
                .git_outputs
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected git ls-remote call");
            assert_eq!(remote, expected);
            Ok(output)
        }

        fn git_remote_url(&self, name: &str) -> Result<Option<String>, String> {
            let (expected, url) = self
                .remote_urls
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected git remote lookup");
            assert_eq!(name, expected);
            Ok(url.map(str::to_owned))
        }

        fn git_submodule_urls(&self) -> Result<Vec<String>, String> {
            Ok(self
                .submodule_urls
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_default()
                .into_iter()
                .map(str::to_owned)
                .collect())
        }

        fn git_current_remotes(&self) -> Result<Vec<(String, String, bool)>, String> {
            Ok(self
                .current_remotes
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_default()
                .into_iter()
                .map(|(name, url, base)| (name.to_owned(), url.to_owned(), base))
                .collect())
        }
    }

    pub(super) fn out(code: i32, stdout: &str, stderr: &str) -> Output {
        Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        }
    }
}
