//! The installer invokes this after the Gateway and Chat are ready.

use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::Value;
use url::Url;

use crate::args::{Command as CliCommand, Identity, Target};

const PROMPT: &str = include_str!("first_run_prompt.md");
const DEFAULT_CHAT_ORIGIN: &str = "http://127.0.0.1:4178";

pub(crate) fn run() -> Result<(), String> {
    if std::env::var("TIGHTBEAM_FIRST_RUN_ONBOARDING").as_deref() != Ok("true") {
        return Ok(());
    }

    let base = crate::base_dir::resolve();
    let done = base.join("first-run-onboarding.done");
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

    let endpoint = crate::dispatch::discover_from(&base)?;
    let chat = origin(
        &std::env::var("TIGHTBEAM_CHAT_URL").unwrap_or_else(|_| DEFAULT_CHAT_ORIGIN.into()),
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
    if gateway != origin(&endpoint.base)? {
        return Err("Chat points to a different Gateway than this installation".into());
    }
    let session = get("sessionKey")?;
    let principal = get("principalKey")?;
    let mut link = chat.clone();
    link.query_pairs_mut()
        .append_pair("gateway", gateway.origin().ascii_serialization().as_str())
        .append_pair("session", session);
    if !open_browser(&link) {
        println!("Open Tightbeam Chat: {link}");
    }

    let prompt = format!(
        "{}\n\nThis installation's Chat root is {} and its Gateway origin is {}. In your reply, use a Markdown link to the new exec using that Chat root and the query parameters gateway and session. URL-encode both values and use the exact newly created exec session key. Chat opens clicked links in a separate tab.",
        PROMPT.trim_end(),
        chat,
        gateway.origin().ascii_serialization()
    );
    let wake = crate::dispatch::build_request(&CliCommand::Wake {
        identity: Identity::User(principal.into()),
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
    let receipt = crate::dispatch::send_to(&endpoint, &wake)?;
    if receipt
        .as_ref()
        .and_then(|value| value.get("wakeId"))
        .and_then(Value::as_str)
        .is_none()
    {
        return Err("the Gateway did not confirm the onboarding wake".into());
    }
    fs::write(done, b"").map_err(|error| format!("could not record onboarding completion: {error}"))
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

fn open_browser(link: &Url) -> bool {
    if std::env::var_os("SSH_CONNECTION").is_some() {
        return false;
    }
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(not(target_os = "macos"))]
    let opener = {
        if std::env::var_os("DISPLAY").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_none() {
            return false;
        }
        "xdg-open"
    };
    Command::new(opener)
        .arg(link.as_str())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}
