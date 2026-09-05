//! Local visitor credential-key custody.
//!
//! Publication is deliberately expressed in inode operations rather than path
//! convenience helpers. The final name is created by `linkat`, never rename,
//! and every security-sensitive open uses `O_NOFOLLOW` relative to one locked,
//! validated directory descriptor.

use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs::{self, File, Metadata};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};

use base64::Engine;
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use sha2::{Digest, Sha256};

const SCHEMA: &str = "visitor-keyring-v1";
const FINAL_NAME: &str = "visitor-keyring-v1.json";
const LOCK_NAME: &str = ".visitor-keyring-v1.init.lock";
const TEMP_PREFIX: &str = ".visitor-keyring-v1.json.tmp.";
const DERIVATION_PURPOSE: &str = "credential-derivation";
const DIGEST_PURPOSE: &str = "credential-digest";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InitError {
    Busy,
    Exists,
    UnsafeTemp,
    PublishVerification,
    RaceWinnerInvalid,
    Unsupported,
    #[cfg(test)]
    InjectedCrash,
}

impl InitError {
    fn public_code(self) -> &'static str {
        match self {
            Self::Busy => "visitor_keyring_init_busy",
            Self::Exists => "visitor_keyring_exists",
            Self::UnsafeTemp => "visitor_keyring_init_unsafe_temp",
            Self::PublishVerification => "visitor_keyring_publish_verification_failed",
            Self::RaceWinnerInvalid => "visitor_keyring_race_winner_invalid",
            Self::Unsupported => "visitor_keyring_init_unsupported",
            #[cfg(test)]
            Self::InjectedCrash => "visitor_keyring_test_injected_crash",
        }
    }
}

#[derive(Debug)]
struct Generated {
    bytes: Vec<u8>,
    derivation_id: String,
    digest_id: String,
}

#[derive(Debug)]
struct Validated {
    metadata: Metadata,
    bytes: Vec<u8>,
    sha256: [u8; 32],
    derivation_id: String,
    digest_id: String,
}

trait InitHook {
    fn before_publish(
        &self,
        _directory: &Path,
        _temp_name: &CStr,
        _generated: &Generated,
    ) -> Result<(), InitError> {
        Ok(())
    }

    fn after_publish(
        &self,
        _directory: &Path,
        _temp_name: &CStr,
        _generated: &Generated,
    ) -> Result<(), InitError> {
        Ok(())
    }
}

struct NoHook;
impl InitHook for NoHook {}

pub fn keyring_init(base_dir: Option<String>) -> Result<(), String> {
    let base_dir = base_dir
        .map(PathBuf::from)
        .unwrap_or_else(crate::base_dir::resolve);

    match initialize(&base_dir, &NoHook) {
        Ok(created) => {
            println!(
                "{}",
                serde_json::json!({
                    "path": created.path,
                    "activeDerivationKeyId": created.derivation_id,
                    "activeDigestKeyId": created.digest_id
                })
            );
            Ok(())
        }
        Err(error) => Err(error.public_code().to_owned()),
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Created {
    path: String,
    derivation_id: String,
    digest_id: String,
}

fn initialize(base_dir: &Path, hook: &dyn InitHook) -> Result<Created, InitError> {
    if !platform_supports_protocol() {
        return Err(InitError::Unsupported);
    }
    let directory = base_dir.join("secrets");
    let created_directory = ensure_secrets_directory(&directory)?;
    let directory_file = open_directory(&directory)?;
    if created_directory {
        set_mode(&directory_file, 0o700)?;
    }
    let owner = effective_uid();
    validate_metadata(
        &directory_file
            .metadata()
            .map_err(|_| InitError::Unsupported)?,
        owner,
        0o700,
        true,
    )?;

    let lock = open_lock(&directory_file)?;
    validate_metadata(
        &lock.metadata().map_err(|_| InitError::Unsupported)?,
        owner,
        0o600,
        false,
    )?;
    take_lock(&lock)?;

    // Prove directory fsync before any final target can exist. A platform that
    // cannot supply it must refuse without publishing a name.
    fsync_directory(&directory_file)?;
    let removed_stale = clean_stale_temps(&directory_file, owner)?;

    if entry_exists(directory_file.as_raw_fd(), cstr(FINAL_NAME))? {
        if removed_stale {
            fsync_directory(&directory_file)?;
            return match validate_named_file(&directory_file, cstr(FINAL_NAME), owner, None) {
                Ok(_) => Err(InitError::Exists),
                Err(_) => Err(InitError::RaceWinnerInvalid),
            };
        }
        return Err(InitError::Exists);
    }

    let generated = generate_document()?;
    let (temp_name, mut temporary) = create_temporary(&directory_file, owner)?;
    let result = (|| {
        temporary
            .write_all(&generated.bytes)
            .map_err(|_| InitError::Unsupported)?;
        temporary.sync_all().map_err(|_| InitError::Unsupported)?;
        drop(temporary);

        let validated_temp =
            validate_named_file(&directory_file, &temp_name, owner, Some(&generated.bytes))?;
        if validated_temp.derivation_id != generated.derivation_id
            || validated_temp.digest_id != generated.digest_id
        {
            return Err(InitError::PublishVerification);
        }
        hook.before_publish(&directory, &temp_name, &generated)?;

        let link_result = unsafe {
            libc::linkat(
                directory_file.as_raw_fd(),
                temp_name.as_ptr(),
                directory_file.as_raw_fd(),
                cstr(FINAL_NAME).as_ptr(),
                0,
            )
        };

        if link_result == 0 {
            hook.after_publish(&directory, &temp_name, &generated)?;
            let final_file = validate_named_file(
                &directory_file,
                cstr(FINAL_NAME),
                owner,
                Some(&generated.bytes),
            )
            .map_err(|_| InitError::PublishVerification)?;

            if !same_file(&validated_temp.metadata, &final_file.metadata)
                || validated_temp.metadata.len() != final_file.metadata.len()
                || validated_temp.bytes != final_file.bytes
                || validated_temp.sha256 != final_file.sha256
                || validated_temp.derivation_id != final_file.derivation_id
                || validated_temp.digest_id != final_file.digest_id
            {
                return Err(InitError::PublishVerification);
            }

            fsync_directory(&directory_file).map_err(|_| InitError::PublishVerification)?;
            unlinkat(directory_file.as_raw_fd(), &temp_name)
                .map_err(|_| InitError::PublishVerification)?;
            fsync_directory(&directory_file).map_err(|_| InitError::PublishVerification)?;

            return Ok(Created {
                path: directory.join(FINAL_NAME).display().to_string(),
                derivation_id: final_file.derivation_id,
                digest_id: final_file.digest_id,
            });
        }

        let errno = last_errno();
        if errno == libc::EEXIST {
            let winner = validate_named_file(&directory_file, cstr(FINAL_NAME), owner, None);
            unlinkat(directory_file.as_raw_fd(), &temp_name).map_err(|_| InitError::Unsupported)?;
            fsync_directory(&directory_file)?;
            return match winner {
                Ok(_) => Err(InitError::Exists),
                Err(_) => Err(InitError::RaceWinnerInvalid),
            };
        }

        Err(InitError::Unsupported)
    })();

    #[cfg(test)]
    let should_clean = !matches!(result, Err(InitError::InjectedCrash));
    #[cfg(not(test))]
    let should_clean = true;

    if result.is_err() && should_clean {
        // The final name is never removed here. The only cleanup target is the
        // caller's create-new temporary name, and unlink failure cannot replace
        // the primary, non-secret refusal code.
        let _ = unlinkat(directory_file.as_raw_fd(), &temp_name);
        let _ = fsync_directory(&directory_file);
    }

    result
}

fn ensure_secrets_directory(path: &Path) -> Result<bool, InitError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            match builder.create(path) {
                Ok(()) => Ok(true),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
                Err(_) => Err(InitError::Unsupported),
            }
        }
        Err(_) => Err(InitError::Unsupported),
    }
}

fn open_directory(path: &Path) -> Result<File, InitError> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| InitError::Unsupported)?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(InitError::Unsupported);
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn openat_file(
    dirfd: RawFd,
    name: &CStr,
    flags: libc::c_int,
    mode: libc::mode_t,
) -> Result<File, InitError> {
    let fd = unsafe { libc::openat(dirfd, name.as_ptr(), flags, mode as libc::c_uint) };
    if fd < 0 {
        return Err(InitError::Unsupported);
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_lock(directory: &File) -> Result<File, InitError> {
    for _ in 0..2 {
        let existing = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                cstr(LOCK_NAME).as_ptr(),
                libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0,
            )
        };
        if existing >= 0 {
            return Ok(unsafe { File::from_raw_fd(existing) });
        }
        if last_errno() != libc::ENOENT {
            return Err(InitError::Unsupported);
        }

        let created = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                cstr(LOCK_NAME).as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if created >= 0 {
            let file = unsafe { File::from_raw_fd(created) };
            if set_mode(&file, 0o600).is_err() {
                drop(file);
                let _ = unlinkat(directory.as_raw_fd(), cstr(LOCK_NAME));
                let _ = fsync_directory(directory);
                return Err(InitError::Unsupported);
            }
            return Ok(file);
        }
        if last_errno() != libc::EEXIST {
            return Err(InitError::Unsupported);
        }
    }
    Err(InitError::Unsupported)
}

fn set_mode(file: &File, mode: libc::mode_t) -> Result<(), InitError> {
    if unsafe { libc::fchmod(file.as_raw_fd(), mode) } == 0 {
        Ok(())
    } else {
        Err(InitError::Unsupported)
    }
}

fn take_lock(file: &File) -> Result<(), InitError> {
    let status = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if status == 0 {
        return Ok(());
    }
    match last_errno() {
        libc::EAGAIN => Err(InitError::Busy),
        _ => Err(InitError::Unsupported),
    }
}

fn clean_stale_temps(directory_file: &File, owner: u32) -> Result<bool, InitError> {
    let mut stale = Vec::new();
    for name in directory_entries(directory_file)? {
        if name.to_bytes().starts_with(TEMP_PREFIX.as_bytes()) {
            stale.push(name);
        }
    }
    stale.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));

    for name in &stale {
        let stat = lstatat(directory_file.as_raw_fd(), name).map_err(|_| InitError::UnsafeTemp)?;
        if file_type(stat.st_mode) != libc::S_IFREG
            || stat.st_uid != owner
            || (stat.st_mode & 0o7777) != 0o600
        {
            return Err(InitError::UnsafeTemp);
        }
    }

    for name in &stale {
        unlinkat(directory_file.as_raw_fd(), name).map_err(|_| InitError::UnsafeTemp)?;
    }
    Ok(!stale.is_empty())
}

fn directory_entries(directory: &File) -> Result<Vec<CString>, InitError> {
    let duplicated = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicated < 0 {
        return Err(InitError::Unsupported);
    }
    let stream = unsafe { libc::fdopendir(duplicated) };
    if stream.is_null() {
        unsafe { libc::close(duplicated) };
        return Err(InitError::Unsupported);
    }

    let mut names = Vec::new();
    loop {
        clear_errno();
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            if last_errno() != 0 {
                unsafe { libc::closedir(stream) };
                return Err(InitError::Unsupported);
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            names.push(CString::new(name.to_bytes()).map_err(|_| InitError::Unsupported)?);
        }
    }

    if unsafe { libc::closedir(stream) } != 0 {
        return Err(InitError::Unsupported);
    }
    Ok(names)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn clear_errno() {
    unsafe { *libc::__errno_location() = 0 };
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "dragonfly",
    target_os = "openbsd",
    target_os = "netbsd"
))]
fn clear_errno() {
    unsafe { *libc::__error() = 0 };
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "dragonfly",
    target_os = "openbsd",
    target_os = "netbsd"
)))]
fn clear_errno() {}

#[cfg(any(
    target_os = "linux",
    target_os = "android",
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "dragonfly",
    target_os = "openbsd",
    target_os = "netbsd"
))]
fn platform_supports_protocol() -> bool {
    true
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "android",
    target_os = "macos",
    target_os = "ios",
    target_os = "freebsd",
    target_os = "dragonfly",
    target_os = "openbsd",
    target_os = "netbsd"
)))]
fn platform_supports_protocol() -> bool {
    false
}

fn create_temporary(directory: &File, owner: u32) -> Result<(CString, File), InitError> {
    for _ in 0..16 {
        let name = CString::new(format!("{TEMP_PREFIX}{}", random_hex(16)?))
            .map_err(|_| InitError::Unsupported)?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd >= 0 {
            let file = unsafe { File::from_raw_fd(fd) };
            let valid = set_mode(&file, 0o600).and_then(|_| {
                validate_metadata(
                    &file.metadata().map_err(|_| InitError::Unsupported)?,
                    owner,
                    0o600,
                    false,
                )
            });
            if let Err(error) = valid {
                drop(file);
                let _ = unlinkat(directory.as_raw_fd(), &name);
                let _ = fsync_directory(directory);
                return Err(error);
            }
            return Ok((name, file));
        }
        if last_errno() != libc::EEXIST {
            return Err(InitError::Unsupported);
        }
    }
    Err(InitError::Unsupported)
}

fn validate_named_file(
    directory: &File,
    name: &CStr,
    owner: u32,
    expected_bytes: Option<&[u8]>,
) -> Result<Validated, InitError> {
    let mut file = openat_file(
        directory.as_raw_fd(),
        name,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0,
    )?;
    let before = file
        .metadata()
        .map_err(|_| InitError::PublishVerification)?;
    validate_metadata(&before, owner, 0o600, false).map_err(|_| InitError::PublishVerification)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|_| InitError::PublishVerification)?;
    let after = file
        .metadata()
        .map_err(|_| InitError::PublishVerification)?;
    if !same_snapshot(&before, &after) {
        return Err(InitError::PublishVerification);
    }
    if expected_bytes.is_some_and(|expected| expected != bytes) {
        return Err(InitError::PublishVerification);
    }
    let (derivation_id, digest_id) = validate_document(&bytes)?;
    let sha256 = Sha256::digest(&bytes).into();
    Ok(Validated {
        metadata: after,
        bytes,
        sha256,
        derivation_id,
        digest_id,
    })
}

fn validate_metadata(
    metadata: &Metadata,
    owner: u32,
    mode: u32,
    directory: bool,
) -> Result<(), InitError> {
    let expected_type = if directory {
        libc::S_IFDIR
    } else {
        libc::S_IFREG
    };
    if file_type(metadata.mode() as libc::mode_t) != expected_type as libc::mode_t
        || metadata.uid() != owner
        || (metadata.mode() & 0o7777) != mode
    {
        return Err(InitError::Unsupported);
    }
    Ok(())
}

fn same_file(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

fn same_snapshot(left: &Metadata, right: &Metadata) -> bool {
    same_file(left, right)
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
}

fn fsync_directory(directory: &File) -> Result<(), InitError> {
    if unsafe { libc::fsync(directory.as_raw_fd()) } == 0 {
        Ok(())
    } else {
        Err(InitError::Unsupported)
    }
}

fn entry_exists(dirfd: RawFd, name: &CStr) -> Result<bool, InitError> {
    match lstatat(dirfd, name) {
        Ok(_) => Ok(true),
        Err(errno) if errno == libc::ENOENT => Ok(false),
        Err(_) => Err(InitError::Unsupported),
    }
}

fn lstatat(dirfd: RawFd, name: &CStr) -> Result<libc::stat, libc::c_int> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    let status =
        unsafe { libc::fstatat(dirfd, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) };
    if status == 0 {
        Ok(stat)
    } else {
        Err(last_errno())
    }
}

fn unlinkat(dirfd: RawFd, name: &CStr) -> Result<(), libc::c_int> {
    if unsafe { libc::unlinkat(dirfd, name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(last_errno())
    }
}

fn generate_document() -> Result<Generated, InitError> {
    let derivation_id = format!("vdk_{}", random_hex(16)?);
    let digest_id = format!("vgk_{}", random_hex(16)?);
    let derivation = random_bytes(32)?;
    let mut digest = random_bytes(32)?;
    while digest == derivation {
        digest = random_bytes(32)?;
    }
    let base64 = base64::engine::general_purpose::STANDARD;
    let mut keys = serde_json::Map::new();
    keys.insert(
        derivation_id.clone(),
        serde_json::json!({
            "purpose": DERIVATION_PURPOSE,
            "bytesBase64": base64.encode(&derivation)
        }),
    );
    keys.insert(
        digest_id.clone(),
        serde_json::json!({
            "purpose": DIGEST_PURPOSE,
            "bytesBase64": base64.encode(&digest)
        }),
    );
    let bytes = serde_json::to_vec(&serde_json::json!({
        "schema": SCHEMA,
        "activeDerivationKeyId": derivation_id,
        "activeDigestKeyId": digest_id,
        "keys": keys
    }))
    .map_err(|_| InitError::Unsupported)?;
    Ok(Generated {
        bytes,
        derivation_id,
        digest_id,
    })
}

fn random_hex(length: usize) -> Result<String, InitError> {
    Ok(random_bytes(length)?
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn random_bytes(length: usize) -> Result<Vec<u8>, InitError> {
    let mut bytes = vec![0; length];
    getrandom::getrandom(&mut bytes).map_err(|_| InitError::Unsupported)?;
    Ok(bytes)
}

fn validate_document(bytes: &[u8]) -> Result<(String, String), InitError> {
    let document: StrictJson =
        serde_json::from_slice(bytes).map_err(|_| InitError::PublishVerification)?;
    let mut root = exact_object(
        document,
        &[
            "schema",
            "activeDerivationKeyId",
            "activeDigestKeyId",
            "keys",
        ],
    )?;
    expect_string(root.remove("schema"))
        .filter(|value| value == SCHEMA)
        .ok_or(InitError::PublishVerification)?;
    let derivation_id = expect_string(root.remove("activeDerivationKeyId"))
        .ok_or(InitError::PublishVerification)?;
    let digest_id =
        expect_string(root.remove("activeDigestKeyId")).ok_or(InitError::PublishVerification)?;
    if derivation_id == digest_id || derivation_id.is_empty() || digest_id.is_empty() {
        return Err(InitError::PublishVerification);
    }
    let keys = match root.remove("keys") {
        Some(StrictJson::Object(entries)) => entries,
        _ => return Err(InitError::PublishVerification),
    };
    if keys.len() < 2 {
        return Err(InitError::PublishVerification);
    }
    let mut decoded = HashMap::new();
    for (id, value) in keys {
        if id.is_empty() {
            return Err(InitError::PublishVerification);
        }
        let mut key = exact_object(value, &["purpose", "bytesBase64"])?;
        let purpose = expect_string(key.remove("purpose")).ok_or(InitError::PublishVerification)?;
        if !matches!(purpose.as_str(), DERIVATION_PURPOSE | DIGEST_PURPOSE) {
            return Err(InitError::PublishVerification);
        }
        let encoded =
            expect_string(key.remove("bytesBase64")).ok_or(InitError::PublishVerification)?;
        let key_bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| InitError::PublishVerification)?;
        if key_bytes.len() != 32 {
            return Err(InitError::PublishVerification);
        }
        decoded.insert(id, (purpose, key_bytes));
    }
    let (derivation_purpose, derivation_bytes) = decoded
        .get(&derivation_id)
        .ok_or(InitError::PublishVerification)?;
    let (digest_purpose, digest_bytes) = decoded
        .get(&digest_id)
        .ok_or(InitError::PublishVerification)?;
    if derivation_purpose != DERIVATION_PURPOSE
        || digest_purpose != DIGEST_PURPOSE
        || derivation_bytes == digest_bytes
    {
        return Err(InitError::PublishVerification);
    }
    Ok((derivation_id, digest_id))
}

fn exact_object(
    value: StrictJson,
    keys: &[&str],
) -> Result<HashMap<String, StrictJson>, InitError> {
    let StrictJson::Object(entries) = value else {
        return Err(InitError::PublishVerification);
    };
    let found = entries
        .iter()
        .map(|(key, _)| key.as_str())
        .collect::<HashSet<_>>();
    let expected = keys.iter().copied().collect::<HashSet<_>>();
    if found != expected {
        return Err(InitError::PublishVerification);
    }
    Ok(entries.into_iter().collect())
}

fn expect_string(value: Option<StrictJson>) -> Option<String> {
    match value {
        Some(StrictJson::String(value)) => Some(value),
        _ => None,
    }
}

#[derive(Debug)]
enum StrictJson {
    Null,
    Bool,
    Number,
    String(String),
    Array,
    Object(Vec<(String, StrictJson)>),
}

impl<'de> Deserialize<'de> for StrictJson {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct StrictVisitor;
        impl<'de> Visitor<'de> for StrictVisitor {
            type Value = StrictJson;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON value without duplicate object keys")
            }
            fn visit_bool<E>(self, _value: bool) -> Result<Self::Value, E> {
                Ok(StrictJson::Bool)
            }
            fn visit_i64<E>(self, _value: i64) -> Result<Self::Value, E> {
                Ok(StrictJson::Number)
            }
            fn visit_u64<E>(self, _value: u64) -> Result<Self::Value, E> {
                Ok(StrictJson::Number)
            }
            fn visit_f64<E>(self, _value: f64) -> Result<Self::Value, E> {
                Ok(StrictJson::Number)
            }
            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(StrictJson::String(value.to_owned()))
            }
            fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
                Ok(StrictJson::String(value))
            }
            fn visit_none<E>(self) -> Result<Self::Value, E> {
                Ok(StrictJson::Null)
            }
            fn visit_unit<E>(self) -> Result<Self::Value, E> {
                Ok(StrictJson::Null)
            }
            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                while sequence.next_element::<StrictJson>()?.is_some() {}
                Ok(StrictJson::Array)
            }
            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: MapAccess<'de>,
            {
                let mut seen = HashSet::new();
                let mut entries = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, StrictJson>()? {
                    if !seen.insert(key.clone()) {
                        return Err(de::Error::custom("duplicate object key"));
                    }
                    entries.push((key, value));
                }
                Ok(StrictJson::Object(entries))
            }
        }
        deserializer.deserialize_any(StrictVisitor)
    }
}

fn file_type(mode: libc::mode_t) -> libc::mode_t {
    mode & libc::S_IFMT
}
fn effective_uid() -> u32 {
    unsafe { libc::geteuid() }
}
fn last_errno() -> libc::c_int {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}
fn cstr(value: &str) -> &CStr {
    CStr::from_bytes_with_nul(match value {
        FINAL_NAME => b"visitor-keyring-v1.json\0",
        LOCK_NAME => b".visitor-keyring-v1.init.lock\0",
        _ => unreachable!("only fixed names use cstr"),
    })
    .expect("fixed names have one trailing nul")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::sync::{Arc, Barrier};
    use std::thread;

    fn root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tightbeam-visitor-keyring-{name}-{}-{}",
            std::process::id(),
            random_hex(8).unwrap()
        ))
    }

    fn cleanup(path: &Path) {
        let _ = fs::remove_dir_all(path);
    }

    fn write_mode(path: &Path, bytes: &[u8], mode: u32) {
        fs::write(path, bytes).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn publication_is_exact_mode_valid_and_never_reports_key_bytes() {
        let base = root("publication");
        fs::create_dir(&base).unwrap();
        let created = initialize(&base, &NoHook).unwrap();
        let directory = base.join("secrets");
        let path = directory.join(FINAL_NAME);
        let bytes = fs::read(&path).unwrap();
        let (derivation_id, digest_id) = validate_document(&bytes).unwrap();

        assert_eq!(created.derivation_id, derivation_id);
        assert_eq!(created.digest_id, digest_id);
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o7777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o7777,
            0o600
        );
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
        assert!(!format!("{created:?}").contains("bytesBase64"));
        assert_eq!(initialize(&base, &NoHook), Err(InitError::Exists));
        assert_eq!(fs::read(&path).unwrap(), bytes);
        cleanup(&base);
    }

    #[test]
    fn strict_validation_rejects_duplicate_ids_and_equal_active_keys() {
        let duplicate = br#"{"schema":"visitor-keyring-v1","activeDerivationKeyId":"vdk_x","activeDigestKeyId":"vgk_x","keys":{"vdk_x":{"purpose":"credential-derivation","bytesBase64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},"vdk_x":{"purpose":"credential-derivation","bytesBase64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},"vgk_x":{"purpose":"credential-digest","bytesBase64":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}}}"#;
        assert_eq!(
            validate_document(duplicate),
            Err(InitError::PublishVerification)
        );

        let equal = br#"{"schema":"visitor-keyring-v1","activeDerivationKeyId":"vdk_x","activeDigestKeyId":"vgk_x","keys":{"vdk_x":{"purpose":"credential-derivation","bytesBase64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},"vgk_x":{"purpose":"credential-digest","bytesBase64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}}"#;
        assert_eq!(
            validate_document(equal),
            Err(InitError::PublishVerification)
        );
    }

    struct CrashBefore;
    impl InitHook for CrashBefore {
        fn before_publish(
            &self,
            _directory: &Path,
            _temp_name: &CStr,
            _generated: &Generated,
        ) -> Result<(), InitError> {
            Err(InitError::InjectedCrash)
        }
    }

    #[test]
    fn a_crash_before_publication_leaves_no_target_and_the_next_run_succeeds() {
        let base = root("crash-before");
        fs::create_dir(&base).unwrap();
        assert_eq!(
            initialize(&base, &CrashBefore),
            Err(InitError::InjectedCrash)
        );
        let directory = base.join("secrets");
        assert!(!directory.join(FINAL_NAME).exists());
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            1
        );
        assert!(initialize(&base, &NoHook).is_ok());
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            0
        );
        cleanup(&base);
    }

    struct CrashAfter;
    impl InitHook for CrashAfter {
        fn after_publish(
            &self,
            _directory: &Path,
            _temp_name: &CStr,
            _generated: &Generated,
        ) -> Result<(), InitError> {
            Err(InitError::InjectedCrash)
        }
    }

    #[test]
    fn a_crash_after_publication_leaves_a_complete_inode_and_retry_removes_only_the_alias() {
        let base = root("crash-after");
        fs::create_dir(&base).unwrap();
        assert_eq!(
            initialize(&base, &CrashAfter),
            Err(InitError::InjectedCrash)
        );
        let directory = base.join("secrets");
        let final_bytes = fs::read(directory.join(FINAL_NAME)).unwrap();
        assert!(validate_document(&final_bytes).is_ok());
        assert_eq!(initialize(&base, &NoHook), Err(InitError::Exists));
        assert_eq!(fs::read(directory.join(FINAL_NAME)).unwrap(), final_bytes);
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            0
        );
        cleanup(&base);
    }

    #[test]
    fn a_crash_after_publication_retry_rejects_an_invalid_final_without_modifying_it() {
        let base = root("crash-after-invalid-final");
        fs::create_dir(&base).unwrap();
        assert_eq!(
            initialize(&base, &CrashAfter),
            Err(InitError::InjectedCrash)
        );
        let directory = base.join("secrets");
        let final_path = directory.join(FINAL_NAME);
        write_mode(&final_path, b"invalid", 0o600);

        assert_eq!(
            initialize(&base, &NoHook),
            Err(InitError::RaceWinnerInvalid)
        );
        assert_eq!(fs::read(&final_path).unwrap(), b"invalid");
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            0
        );
        cleanup(&base);
    }

    struct HoldLock {
        entered: Arc<Barrier>,
        release: Arc<Barrier>,
    }
    impl InitHook for HoldLock {
        fn before_publish(
            &self,
            _directory: &Path,
            _temp_name: &CStr,
            _generated: &Generated,
        ) -> Result<(), InitError> {
            self.entered.wait();
            self.release.wait();
            Ok(())
        }
    }

    #[test]
    fn a_concurrent_initializer_refuses_busy_without_changing_the_winner() {
        let base = root("busy");
        fs::create_dir(&base).unwrap();
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let worker_base = base.clone();
        let hook = HoldLock {
            entered: entered.clone(),
            release: release.clone(),
        };
        let worker = thread::spawn(move || initialize(&worker_base, &hook));
        entered.wait();
        assert_eq!(initialize(&base, &NoHook), Err(InitError::Busy));
        release.wait();
        assert!(worker.join().unwrap().is_ok());
        cleanup(&base);
    }

    #[test]
    fn an_unsafe_orphan_is_never_removed() {
        let base = root("unsafe-orphan");
        let directory = base.join("secrets");
        fs::create_dir_all(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let orphan = directory.join(format!("{TEMP_PREFIX}unsafe"));
        fs::write(&orphan, b"not ours").unwrap();
        fs::set_permissions(&orphan, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(initialize(&base, &NoHook), Err(InitError::UnsafeTemp));
        assert!(orphan.exists());
        assert!(!directory.join(FINAL_NAME).exists());
        cleanup(&base);
    }

    #[test]
    fn an_unsafe_orphan_symlink_is_never_followed_or_removed() {
        let base = root("unsafe-orphan-symlink");
        let directory = base.join("secrets");
        fs::create_dir_all(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let outside = base.join("outside");
        write_mode(&outside, b"outside", 0o600);
        let orphan = directory.join(format!("{TEMP_PREFIX}unsafe-link"));
        symlink(&outside, &orphan).unwrap();

        assert_eq!(initialize(&base, &NoHook), Err(InitError::UnsafeTemp));
        assert!(orphan.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(fs::read(&outside).unwrap(), b"outside");
        cleanup(&base);
    }

    struct InstallWinner {
        valid: bool,
    }
    impl InitHook for InstallWinner {
        fn before_publish(
            &self,
            directory: &Path,
            _temp_name: &CStr,
            generated: &Generated,
        ) -> Result<(), InitError> {
            let path = directory.join(FINAL_NAME);
            let bytes = if self.valid {
                generated.bytes.as_slice()
            } else {
                b"not-json"
            };
            write_mode(&path, bytes, 0o600);
            Ok(())
        }
    }

    #[test]
    fn a_link_loser_validates_a_winner_and_removes_only_its_temporary_name() {
        let base = root("valid-race-winner");
        fs::create_dir(&base).unwrap();
        assert_eq!(
            initialize(&base, &InstallWinner { valid: true }),
            Err(InitError::Exists)
        );
        let directory = base.join("secrets");
        assert!(validate_document(&fs::read(directory.join(FINAL_NAME)).unwrap()).is_ok());
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            0
        );
        cleanup(&base);
    }

    #[test]
    fn an_invalid_link_race_winner_is_preserved_and_no_ids_escape() {
        let base = root("invalid-race-winner");
        fs::create_dir(&base).unwrap();
        let result = initialize(&base, &InstallWinner { valid: false });
        assert_eq!(result, Err(InitError::RaceWinnerInvalid));
        assert_eq!(
            fs::read(base.join("secrets").join(FINAL_NAME)).unwrap(),
            b"not-json"
        );
        assert_eq!(format!("{:?}", result.unwrap_err()), "RaceWinnerInvalid");
        cleanup(&base);
    }

    struct CorruptPublishedName;
    impl InitHook for CorruptPublishedName {
        fn after_publish(
            &self,
            directory: &Path,
            _temp_name: &CStr,
            _generated: &Generated,
        ) -> Result<(), InitError> {
            let final_path = directory.join(FINAL_NAME);
            fs::remove_file(&final_path).unwrap();
            write_mode(&final_path, b"corrupt-published-name", 0o600);
            Ok(())
        }
    }

    #[test]
    fn failed_post_link_verification_preserves_the_final_name_and_reports_no_ids() {
        let base = root("publish-verification");
        fs::create_dir(&base).unwrap();
        let result = initialize(&base, &CorruptPublishedName);
        assert_eq!(result, Err(InitError::PublishVerification));
        assert_eq!(
            fs::read(base.join("secrets").join(FINAL_NAME)).unwrap(),
            b"corrupt-published-name"
        );
        assert_eq!(format!("{:?}", result.unwrap_err()), "PublishVerification");
        cleanup(&base);
    }

    struct UnsupportedBeforePublish;
    impl InitHook for UnsupportedBeforePublish {
        fn before_publish(
            &self,
            _directory: &Path,
            _temp_name: &CStr,
            _generated: &Generated,
        ) -> Result<(), InitError> {
            Err(InitError::Unsupported)
        }
    }

    #[test]
    fn a_missing_publication_guarantee_removes_its_safe_temp_and_publishes_nothing() {
        let base = root("unsupported");
        fs::create_dir(&base).unwrap();
        assert_eq!(
            initialize(&base, &UnsupportedBeforePublish),
            Err(InitError::Unsupported)
        );
        let directory = base.join("secrets");
        assert!(!directory.join(FINAL_NAME).exists());
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry
                    .file_name()
                    .as_bytes()
                    .starts_with(TEMP_PREFIX.as_bytes()))
                .count(),
            0
        );
        cleanup(&base);
    }

    #[test]
    fn metadata_validation_rejects_the_wrong_owner_without_needing_privilege_to_chown() {
        let base = root("wrong-owner");
        fs::create_dir(&base).unwrap();
        let metadata = fs::metadata(&base).unwrap();
        assert_eq!(
            validate_metadata(&metadata, effective_uid().wrapping_add(1), 0o700, true),
            Err(InitError::Unsupported)
        );
        cleanup(&base);
    }
}
