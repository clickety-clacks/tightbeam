use std::process::Command;

pub fn run(args: &[String]) -> Result<i32, String> {
    let exe = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|error| error.to_string())?;
    let status = Command::new("node")
        .args(["--input-type=module", "-e", include_str!("setup.mjs"), "--"])
        .arg(exe)
        .args(args)
        .status()
        .map_err(|error| format!("Setup needs Node.js 24 or later on PATH: {error}"))?;
    Ok(status.code().unwrap_or(1))
}
