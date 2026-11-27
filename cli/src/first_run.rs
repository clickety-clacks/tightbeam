//! The installer invokes this after the Gateway and Chat are ready.

use std::collections::HashSet;
use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use sha2::{Digest, Sha256};
use url::Url;

use crate::args::{Command as CliCommand, Identity, Target};
use crate::dispatch::{self, Endpoint, RequestSpec};
use crate::session_connect::SessionSignalGuard;

const PROMPT: &str = include_str!("first_run_prompt.md");
const PROJECT_WAIT: Duration = Duration::from_secs(30 * 60);
const DONE_MARKER: &str = "first-run-onboarding.done";

fn enabled() -> bool {
    std::env::var("TIGHTBEAM_FIRST_RUN_ONBOARDING").as_deref() == Ok("true")
}

pub(crate) fn pending() -> bool {
    let base = crate::base_dir::resolve();
    let database = base.join("state.db");
    enabled()
        && base
            .join(DONE_MARKER)
            .try_exists()
            .is_ok_and(|exists| !exists)
        && match database.try_exists() {
            Ok(false) => true, // Setup may run the probe before the Gateway starts.
            Ok(true) => tour_target(&database).ok().flatten().is_some(),
            Err(_) => false,
        }
}

// Read the bootstrap receipt from this installation's own DB. A role can be
// rebound later, so the role name cannot identify the recipient of this wake.
fn tour_target(database: &Path) -> rusqlite::Result<Option<(String, Option<String>)>> {
    let db = Connection::open_with_flags(database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    db.query_row(
        "SELECT settings.value, sessions.ownerUserId
           FROM org_settings AS settings
           LEFT JOIN sessions ON sessions.sessionKey=settings.value AND sessions.state='active'
           WHERE settings.key='first-run-tour'
             AND (settings.value='pending' OR sessions.sessionKey IS NOT NULL)",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .optional()
}

pub(crate) fn run() -> Result<(), String> {
    if !enabled() {
        return Ok(());
    }

    let base = crate::base_dir::resolve();
    let done = base.join(DONE_MARKER);
    let lock = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(base.join("first-run-onboarding.lock"))
        .map_err(|error| format!("could not open onboarding lock: {error}"))?;
    // The OS releases the lock even if setup is interrupted.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "could not lock onboarding: {}",
            std::io::Error::last_os_error()
        ));
    }
    if done.try_exists().map_err(|error| error.to_string())? {
        return Ok(());
    }

    let target = tour_target(&base.join("state.db"))
        .map_err(|error| format!("could not read the Tour Guide bootstrap receipt: {error}"))?;
    let Some((session, owner)) = target else {
        return Ok(());
    };
    let owner = owner.ok_or("the Gateway has not initialized the Tour Guide yet")?;
    let session = session.as_str();
    let endpoint = dispatch::discover_from(&base)?;
    let chat = origin(
        &std::env::var("TIGHTBEAM_CHAT_URL")
            .or_else(|_| std::env::var("CHAT_PUBLIC_ORIGIN"))
            .map_err(|_| "setup must supply the configured Chat public origin")?,
    )?;
    let config_url = chat
        .join("chat-config.json")
        .expect("validated Chat origin");
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(5))
        .redirects(0)
        .build()
        .get(config_url.as_str())
        .call()
        .map_err(|_| {
            "could not read Chat's configuration. Start Chat and rerun setup.".to_owned()
        })?;
    let config: Value = serde_json::from_reader(response.into_reader())
        .map_err(|_| "Chat returned invalid configuration".to_owned())?;
    let get = |key| {
        config
            .get(key)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .ok_or_else(|| format!("Chat's configuration is missing {key}"))
    };
    let gateway = origin(get("gateway")?)?;
    let provisioned = origin(&endpoint.base)?;
    let mapped = match std::env::var_os("CHAT_GATEWAY_MAP_FILE") {
        Some(path) => {
            let file = File::open(path)
                .map_err(|error| format!("could not open Chat Gateway map: {error}"))?;
            let map = serde_json::from_reader(file)
                .map_err(|_| "Chat Gateway map contains invalid JSON")?;
            gateway_maps_to_installation(&map, &gateway, &provisioned, &base)
        }
        None => gateway == provisioned,
    };
    if !mapped {
        return Err("Chat's configured Gateway does not map to this installation".into());
    }
    if get("principalKey")? != owner {
        return Err("Chat's configured user does not own this installation's Tour Guide".into());
    }
    let identity = Identity::User(owner);
    let fact_kind = format!(
        "installer.first-run-project-ready.{:x}",
        Sha256::digest(session.as_bytes())
    );
    let fact_read = dispatch::facts_read_request(&identity, &fact_kind);
    let signal = SessionSignalGuard::install()?;
    let tour_link = chat_link(&chat, &gateway, session);
    let opened = base.join("first-run-onboarding.opened");
    if !opened.try_exists().map_err(|error| error.to_string())? {
        // Save the launch before dispatch so a refused wake can be retried without a second tab.
        fs::write(opened, b"")
            .map_err(|error| format!("could not record Tour Guide Chat launch: {error}"))?;
        open_browser(&tour_link);
    }
    println!("Open Tightbeam Chat (Tour Guide): {tour_link}");

    let prompt = welcome_prompt(&chat, &gateway, &fact_kind);
    let wake = dispatch::build_request(&CliCommand::Wake {
        identity,
        target: Target::Session(session.into()),
        prompt,
        after_ms: None,
        at: None,
        cron: None,
        condition_kind: None,
        condition_scope: None,
        predicate: None,
        assignment_id: None,
        after_turn: false,
        wait_reason: None,
        replace_queued: false,
        prod_id: None,
        idempotency_key: Some("installer-first-run-welcome".into()),
        class: None,
    })?;
    let receipt = dispatch::send_to_with_deadline(
        &endpoint,
        &wake,
        Some(Instant::now() + Duration::from_secs(5)),
    );
    if signal.interrupted() {
        return Ok(());
    }
    let receipt = receipt?;
    if receipt
        .as_ref()
        .and_then(|value| value.get("wakeId"))
        .and_then(Value::as_str)
        .is_none()
    {
        return Err("the Gateway did not confirm the onboarding wake".into());
    }
    fs::write(done, b"")
        .map_err(|error| format!("could not record onboarding completion: {error}"))?;
    drop(lock);

    println!("Waiting up to 30 minutes to open your project in Chat. Press Ctrl-C to leave setup.");
    if let Some(project) = wait_for_project(&endpoint, &fact_read, session, &signal, PROJECT_WAIT) {
        show_chat("project exec", &chat, &gateway, &project);
    }
    Ok(())
}

fn welcome_prompt(chat: &Url, gateway: &Url, fact_kind: &str) -> String {
    PROMPT
        .trim_end()
        .replace("{{chat_root}}", chat.as_str())
        .replace(
            "{{gateway_origin}}",
            &gateway.origin().ascii_serialization(),
        )
        .replace("{{project_ready_kind}}", fact_kind)
}

fn gateway_maps_to_installation(
    map: &Value,
    selected: &Url,
    provisioned: &Url,
    base: &Path,
) -> bool {
    if map["version"].as_u64() != Some(1) {
        return false;
    }
    let Some(entries) = map["gateways"].as_array() else {
        return false;
    };
    let Ok(base) = base.canonicalize() else {
        return false;
    };
    let mut mapped = HashSet::new();
    for entry in entries {
        let Some(directory) = entry["baseDir"]
            .as_str()
            .map(Path::new)
            .filter(|path| path.is_absolute())
        else {
            continue;
        };
        let Some(primary) = entry["origin"]
            .as_str()
            .and_then(|value| origin(value).ok())
        else {
            continue;
        };
        let mut keys = HashSet::from([primary]);
        if let Some(aliases) = entry.get("aliases") {
            let Some(aliases) = aliases.as_array() else {
                continue;
            };
            if !aliases.iter().all(|alias| {
                alias
                    .as_str()
                    .and_then(|value| origin(value).ok())
                    .is_some_and(|alias| keys.insert(alias))
            }) {
                continue;
            }
        }
        if !keys.is_disjoint(&mapped) {
            continue;
        }
        if keys.contains(selected) {
            return keys.contains(provisioned)
                && directory
                    .canonicalize()
                    .is_ok_and(|directory| directory == base);
        }
        mapped.extend(keys);
    }
    false
}

fn wait_for_project(
    endpoint: &Endpoint,
    fact_read: &RequestSpec,
    tour_session: &str,
    signal: &SessionSignalGuard,
    window: Duration,
) -> Option<String> {
    let deadline = Instant::now() + window;
    while !signal.interrupted() && Instant::now() < deadline {
        let read_deadline = deadline.min(Instant::now() + Duration::from_secs(2));
        if let Ok(Some(response)) =
            dispatch::send_to_with_deadline(endpoint, fact_read, Some(read_deadline))
        {
            if let Some(session) = ready_project(&response, tour_session) {
                if !signal.interrupted() {
                    return Some(session.to_owned());
                }
            }
        }
        std::thread::sleep(
            Duration::from_secs(1).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    None
}

fn ready_project<'a>(response: &'a Value, tour_session: &str) -> Option<&'a str> {
    let fact = &response["fact"];
    if fact["origin"].as_str()? != format!("agent:{tour_session}") {
        return None;
    }
    fact["scope"]
        .as_str()
        .filter(|session| !session.trim().is_empty() && *session != tour_session)
}

fn chat_link(chat: &Url, gateway: &Url, session: &str) -> Url {
    let mut link = chat.clone();
    link.query_pairs_mut()
        .append_pair("gateway", &gateway.origin().ascii_serialization())
        .append_pair("session", session);
    link
}

fn show_chat(label: &str, chat: &Url, gateway: &Url, session: &str) {
    let link = chat_link(chat, gateway, session);
    open_browser(&link);
    println!("Open Tightbeam Chat ({label}): {link}");
}

fn origin(value: &str) -> Result<Url, String> {
    Url::parse(value)
        .ok()
        .filter(|url| {
            matches!(url.scheme(), "http" | "https")
                && url.username().is_empty()
                && url.password().is_none()
                && url.path() == "/"
                && url.query().is_none()
                && url.fragment().is_none()
        })
        .ok_or_else(|| "Chat and Gateway addresses must be HTTP(S) origins".into())
}

fn open_browser(link: &Url) {
    if std::env::var_os("SSH_CONNECTION").is_some() {
        return;
    }
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(not(target_os = "macos"))]
    let opener = {
        if std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_none() {
            return;
        }
        "xdg-open"
    };
    let child = Command::new(opener)
        .arg(link.as_str())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        // Some desktop launchers remain running as long as the browser.
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn chat_links_preserve_the_exact_target_and_exclude_credentials() {
        assert!(origin("https://user:secret@chat.example").is_err());
        assert!(origin("https://chat.example/?token=test").is_err());
        assert!(origin("file:///").is_err());
        let chat = origin("https://chat.example").unwrap();
        let gateway = origin("http://127.0.0.1:4321").unwrap();
        let session = "agent:exec:sample /+?#";
        let link = chat_link(&chat, &gateway, session);
        assert_eq!(link.origin(), chat.origin());
        assert_eq!(
            link.query_pairs().collect::<Vec<_>>(),
            vec![
                ("gateway".into(), "http://127.0.0.1:4321".into()),
                ("session".into(), session.into())
            ]
        );
    }

    #[test]
    fn welcome_renders_every_placeholder_and_allows_fact_correction() {
        let chat = origin("https://chat.example").unwrap();
        let gateway = origin("http://127.0.0.1:4321").unwrap();
        let kind = "installer.first-run-project-ready.example";
        let prompt = welcome_prompt(&chat, &gateway, kind);
        assert!(!prompt.contains("{{"));
        assert!(prompt.contains(chat.as_str()));
        assert!(prompt.contains(&gateway.origin().ascii_serialization()));
        assert!(prompt.contains(&format!("tightbeam condition --kind {kind} --scope")));
        assert!(!prompt.contains("--key"));
    }

    #[test]
    fn an_alias_must_map_to_the_provisioned_origin_and_installation() {
        let base = std::env::temp_dir().canonicalize().unwrap();
        let alias = origin("https://gateway.example").unwrap();
        let local = origin("http://127.0.0.1:4321").unwrap();
        let other = origin("http://127.0.0.1:4322").unwrap();
        let map = json!({"version": 1, "gateways": [{
            "origin": "https://gateway.example",
            "baseDir": base,
            "aliases": ["http://127.0.0.1:4321"]
        }]});
        assert!(gateway_maps_to_installation(&map, &alias, &local, &base));
        assert!(!gateway_maps_to_installation(&map, &alias, &other, &base));
        assert!(!gateway_maps_to_installation(
            &map,
            &alias,
            &local,
            Path::new("/")
        ));
    }

    #[test]
    fn project_ready_uses_the_exec_scope_only_when_main_filed_it() {
        let main = "agent:main:sample";
        let exec = "agent:exec:sample";
        let fact = |origin: &str, scope: &str| json!({"fact": {"origin": origin, "scope": scope}});
        assert_eq!(
            ready_project(&fact("agent:agent:main:sample", exec), main),
            Some(exec)
        );
        assert_eq!(
            ready_project(&fact("agent:another-agent", exec), main),
            None
        );
        assert_eq!(
            ready_project(&fact("agent:agent:main:sample", main), main),
            None
        );
        assert_eq!(ready_project(&json!({"fact": null}), main), None);
    }
}
