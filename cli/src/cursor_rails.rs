use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const CURSOR_DIR: &str = ".cursor";
const RAILS_FILE: &str = "hooks.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Entry {
    dev: libc::dev_t,
    ino: libc::ino_t,
    mode: libc::mode_t,
}

impl Entry {
    fn from_stat(stat: libc::stat) -> Self {
        Self {
            dev: stat.st_dev,
            ino: stat.st_ino,
            mode: stat.st_mode,
        }
    }

    fn is_dir(self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFDIR
    }

    fn is_regular(self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFREG
    }
}

pub fn publish(args: &[String]) -> Result<(), String> {
    if args.len() != 3 {
        return Err(
            "usage: tightbeam cursor-rails-publish <execution-home> <payload> <sha256>".to_owned(),
        );
    }

    let expected = &args[2];
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("Cursor rails publication refused: invalid SHA-256".to_owned());
    }

    let bytes = read_payload(Path::new(&args[1]))?;
    let actual = sha256(&bytes);
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(format!(
            "Cursor rails publication refused: payload digest {actual} did not match {expected}"
        ));
    }

    publish_bytes(Path::new(&args[0]), &bytes, &actual, |_| {})?;
    println!("{actual}");
    Ok(())
}

fn read_payload(path: &Path) -> Result<Vec<u8>, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| refusal(format!("cannot open payload: {error}")))?;

    let metadata = file
        .metadata()
        .map_err(|error| refusal(format!("cannot inspect payload: {error}")))?;
    if !metadata.is_file() {
        return Err(refusal("payload is not a regular file"));
    }

    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| refusal(format!("cannot read payload: {error}")))?;
    Ok(bytes)
}

fn publish_bytes<F>(
    home: &Path,
    bytes: &[u8],
    expected: &str,
    before_commit: F,
) -> Result<(), String>
where
    F: FnOnce(&Path),
{
    publish_bytes_with_after_publish(home, bytes, expected, before_commit, |_| {})
}

fn publish_bytes_with_after_publish<F, G>(
    home: &Path,
    bytes: &[u8],
    expected: &str,
    before_commit: F,
    after_publish: G,
) -> Result<(), String>
where
    F: FnOnce(&Path),
    G: FnOnce(&Path),
{
    let home_fd = open_dir_path(home)
        .map_err(|error| refusal(format!("execution home is not a stable directory: {error}")))?;
    let cursor_name = cstring(CURSOR_DIR)?;

    if unsafe { libc::mkdirat(home_fd.as_raw_fd(), cursor_name.as_ptr(), 0o755) } != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(refusal(format!("cannot create .cursor: {error}")));
        }
    }

    let cursor_fd = open_dir_at(home_fd.as_raw_fd(), &cursor_name)
        .map_err(|error| refusal(format!(".cursor is not a no-follow directory: {error}")))?;
    ensure_same_dir(home_fd.as_raw_fd(), cursor_fd.as_raw_fd(), &cursor_name)?;

    let hooks_name = cstring(RAILS_FILE)?;
    let observed = entry_at(cursor_fd.as_raw_fd(), &hooks_name)?;
    if observed.is_some_and(|entry| !entry.is_regular()) {
        return Err(refusal("hooks.json is not a regular file"));
    }

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| refusal(format!("clock unavailable: {error}")))?
        .as_nanos();
    let temporary_name = cstring(&format!(
        ".hooks.json.tightbeam.{}.{nonce}",
        std::process::id()
    ))?;
    let mut temporary = open_new_at(cursor_fd.as_raw_fd(), &temporary_name)?;
    let mut temporary_present = true;
    let mut recovery_present = false;
    let mut published = false;

    let result = (|| {
        temporary
            .write_all(bytes)
            .map_err(|error| refusal(format!("cannot write staged hooks.json: {error}")))?;
        if unsafe { libc::fchmod(temporary.as_raw_fd(), 0o644) } != 0 {
            return Err(refusal(format!(
                "cannot set staged hooks.json mode: {}",
                io::Error::last_os_error()
            )));
        }
        temporary
            .sync_all()
            .map_err(|error| refusal(format!("cannot sync staged hooks.json: {error}")))?;
        let staged = fstat(temporary.as_raw_fd())?;

        before_commit(&home.join(CURSOR_DIR));

        ensure_same_dir(home_fd.as_raw_fd(), cursor_fd.as_raw_fd(), &cursor_name)?;
        if entry_at(cursor_fd.as_raw_fd(), &hooks_name)? != observed {
            return Err(refusal("hooks.json changed during publication"));
        }

        if let Some(previous) = observed {
            exchange_at(cursor_fd.as_raw_fd(), &temporary_name, &hooks_name)?;
            published = true;
            recovery_present = true;

            if entry_at(cursor_fd.as_raw_fd(), &hooks_name)? != Some(staged)
                || entry_at(cursor_fd.as_raw_fd(), &temporary_name)? != Some(previous)
            {
                return Err(refusal("hooks.json changed while it was secured"));
            }
        } else {
            link_at(
                cursor_fd.as_raw_fd(),
                &temporary_name,
                cursor_fd.as_raw_fd(),
                &hooks_name,
            )?;
            published = true;
        }

        after_publish(&home.join(CURSOR_DIR));

        if entry_at(cursor_fd.as_raw_fd(), &hooks_name)? != Some(staged) {
            return Err(refusal("published hooks.json was replaced"));
        }

        if observed.is_none() {
            unlink_at(cursor_fd.as_raw_fd(), &temporary_name)?;
            temporary_present = false;
        }

        ensure_same_dir(home_fd.as_raw_fd(), cursor_fd.as_raw_fd(), &cursor_name)?;
        verify_published(cursor_fd.as_raw_fd(), &hooks_name, staged, expected)?;
        sync_fd(cursor_fd.as_raw_fd())?;

        if recovery_present {
            if entry_at(cursor_fd.as_raw_fd(), &temporary_name)? != observed {
                return Err(refusal("secured previous hooks.json was replaced"));
            }
            unlink_at(cursor_fd.as_raw_fd(), &temporary_name)?;
            temporary_present = false;
            recovery_present = false;
            published = false;
            sync_fd(cursor_fd.as_raw_fd())?;
        }
        Ok(())
    })();

    if let Err(error) = result {
        let mut recovery_errors = Vec::new();
        let staged = fstat(temporary.as_raw_fd()).ok();

        if published {
            match observed {
                Some(previous) => {
                    let hooks_entry = entry_at(cursor_fd.as_raw_fd(), &hooks_name).ok().flatten();
                    let recovery_entry = entry_at(cursor_fd.as_raw_fd(), &temporary_name)
                        .ok()
                        .flatten();
                    let recovery_path = managed_path(&temporary_name);

                    if hooks_entry == staged && recovery_entry == Some(previous) {
                        match exchange_at(cursor_fd.as_raw_fd(), &temporary_name, &hooks_name) {
                            Ok(()) => {
                                recovery_present = false;
                            }
                            Err(restore_error) => recovery_errors.push(format!(
                                "automatic restore failed ({restore_error}); previous hooks.json \
                                 is preserved at {recovery_path}"
                            )),
                        }
                    } else if recovery_entry == Some(previous) {
                        recovery_errors.push(format!(
                            "automatic restore refused because managed entries changed; previous \
                             hooks.json is preserved at {recovery_path}"
                        ));
                    } else {
                        recovery_errors.push(format!(
                            "automatic restore refused because recovery entry {recovery_path} is \
                             not the secured previous hooks.json"
                        ));
                    }
                }
                None => {
                    if entry_at(cursor_fd.as_raw_fd(), &hooks_name).ok().flatten() == staged {
                        match unlink_at(cursor_fd.as_raw_fd(), &hooks_name) {
                            Ok(()) => {}
                            Err(rollback_error) => recovery_errors.push(format!(
                                "rollback failed to remove published hooks.json \
                                 ({rollback_error})"
                            )),
                        }
                    } else {
                        recovery_errors.push(
                            "rollback refused because published hooks.json identity changed"
                                .to_owned(),
                        );
                    }
                }
            }
        }

        if temporary_present && !recovery_present {
            if entry_at(cursor_fd.as_raw_fd(), &temporary_name)
                .ok()
                .flatten()
                == staged
            {
                if let Err(cleanup_error) = unlink_at(cursor_fd.as_raw_fd(), &temporary_name) {
                    recovery_errors.push(format!(
                        "staged entry cleanup failed at {} ({cleanup_error})",
                        managed_path(&temporary_name)
                    ));
                }
            }
        }

        return Err(with_recovery(error, recovery_errors));
    }

    Ok(())
}

fn verify_published(
    directory: libc::c_int,
    name: &CStr,
    staged: Entry,
    expected: &str,
) -> Result<(), String> {
    let fd = unsafe {
        libc::openat(
            directory,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(refusal(format!(
            "cannot reopen published hooks.json: {}",
            io::Error::last_os_error()
        )));
    }

    let mut file = unsafe { File::from_raw_fd(fd) };
    if fstat(file.as_raw_fd())? != staged {
        return Err(refusal("published hooks.json identity changed"));
    }

    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| refusal(format!("cannot verify published hooks.json: {error}")))?;
    if sha256(&bytes) != expected {
        return Err(refusal("published hooks.json digest changed"));
    }
    Ok(())
}

fn open_dir_path(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
}

fn open_dir_at(directory: libc::c_int, name: &CStr) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            directory,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn open_new_at(directory: libc::c_int, name: &CStr) -> Result<File, String> {
    let fd = unsafe {
        libc::openat(
            directory,
            name.as_ptr(),
            libc::O_WRONLY | libc::O_CLOEXEC | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
            0o600,
        )
    };
    if fd < 0 {
        Err(refusal(format!(
            "cannot stage hooks.json: {}",
            io::Error::last_os_error()
        )))
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn ensure_same_dir(parent: libc::c_int, opened: libc::c_int, name: &CStr) -> Result<(), String> {
    let opened = fstat(opened)?;
    let current = entry_at(parent, name)?;
    if !opened.is_dir() || current != Some(opened) {
        return Err(refusal(".cursor changed during publication"));
    }
    Ok(())
}

fn fstat(fd: libc::c_int) -> Result<Entry, String> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        Err(refusal(format!(
            "cannot inspect open file: {}",
            io::Error::last_os_error()
        )))
    } else {
        Ok(Entry::from_stat(stat))
    }
}

fn entry_at(directory: libc::c_int, name: &CStr) -> Result<Option<Entry>, String> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe {
        libc::fstatat(
            directory,
            name.as_ptr(),
            &mut stat,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0
    {
        Ok(Some(Entry::from_stat(stat)))
    } else {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) {
            Ok(None)
        } else {
            Err(refusal(format!("cannot inspect managed path: {error}")))
        }
    }
}

#[cfg(target_os = "linux")]
fn exchange_at(directory: libc::c_int, left: &CStr, right: &CStr) -> Result<(), String> {
    if unsafe {
        libc::renameat2(
            directory,
            left.as_ptr(),
            directory,
            right.as_ptr(),
            libc::RENAME_EXCHANGE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(exchange_refusal(io::Error::last_os_error()))
    }
}

#[cfg(target_os = "macos")]
fn exchange_at(directory: libc::c_int, left: &CStr, right: &CStr) -> Result<(), String> {
    if unsafe {
        libc::renameatx_np(
            directory,
            left.as_ptr(),
            directory,
            right.as_ptr(),
            libc::RENAME_SWAP,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(exchange_refusal(io::Error::last_os_error()))
    }
}

fn exchange_refusal(error: io::Error) -> String {
    let unsupported = error.raw_os_error().is_some_and(|code| {
        [libc::ENOSYS, libc::EOPNOTSUPP, libc::EINVAL, libc::EXDEV].contains(&code)
    });

    if unsupported {
        refusal(format!(
            "atomic hooks.json exchange is unsupported on this filesystem or platform; no \
             non-atomic fallback was attempted: {error}"
        ))
    } else {
        refusal(format!("cannot atomically exchange hooks.json: {error}"))
    }
}

fn link_at(
    from_dir: libc::c_int,
    from: &CStr,
    to_dir: libc::c_int,
    to: &CStr,
) -> Result<(), String> {
    if unsafe { libc::linkat(from_dir, from.as_ptr(), to_dir, to.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(refusal(format!(
            "cannot publish hooks.json without replacement: {}",
            io::Error::last_os_error()
        )))
    }
}

fn unlink_at(directory: libc::c_int, name: &CStr) -> Result<(), String> {
    if unsafe { libc::unlinkat(directory, name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(refusal(format!(
            "cannot remove managed staging entry: {}",
            io::Error::last_os_error()
        )))
    }
}

fn managed_path(name: &CStr) -> String {
    format!("{CURSOR_DIR}/{}", name.to_string_lossy())
}

fn with_recovery(error: String, recovery_errors: Vec<String>) -> String {
    if recovery_errors.is_empty() {
        error
    } else {
        format!("{error}; {}", recovery_errors.join("; "))
    }
}

#[cfg(target_os = "linux")]
fn sync_fd(fd: libc::c_int) -> Result<(), String> {
    if unsafe { libc::fsync(fd) } == 0 {
        Ok(())
    } else {
        Err(refusal(format!(
            "cannot sync .cursor directory: {}",
            io::Error::last_os_error()
        )))
    }
}

// Darwin does not provide a portable directory durability primitive. The file
// itself is already fsync'd before publication; the safety boundary here is
// descriptor anchoring and no-follow publication, which is identical on both
// supported platforms.
#[cfg(target_os = "macos")]
fn sync_fd(_fd: libc::c_int) -> Result<(), String> {
    Ok(())
}

fn cstring(value: &str) -> Result<CString, String> {
    CString::new(value.as_bytes()).map_err(|_| refusal("managed path contains a NUL byte"))
}

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn refusal(detail: impl AsRef<str>) -> String {
    format!("Cursor rails publication refused: {}", detail.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);

    fn fixture() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-cursor-rails-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    fn publish_fixture(home: &Path, before_commit: impl FnOnce(&Path)) -> Result<(), String> {
        let bytes = b"{\"version\":1}";
        publish_bytes(home, bytes, &sha256(bytes), before_commit)
    }

    fn publish_fixture_with_after(
        home: &Path,
        before_commit: impl FnOnce(&Path),
        after_publish: impl FnOnce(&Path),
    ) -> Result<(), String> {
        let bytes = b"{\"version\":1}";
        publish_bytes_with_after_publish(home, bytes, &sha256(bytes), before_commit, after_publish)
    }

    #[test]
    fn normal_delivery_is_exact_and_mode_0644() {
        let home = fixture();
        publish_fixture(&home, |_| {}).unwrap();
        let hooks = home.join(CURSOR_DIR).join(RAILS_FILE);
        assert_eq!(fs::read(&hooks).unwrap(), b"{\"version\":1}");
        assert_eq!(
            fs::metadata(&hooks).unwrap().permissions().mode() & 0o777,
            0o644
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn leaf_symlink_refuses_and_preserves_external_content_and_mode() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        let external = home.join("external");
        fs::write(&external, b"operator bytes").unwrap();
        fs::set_permissions(&external, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&external, cursor.join(RAILS_FILE)).unwrap();

        assert!(
            publish_fixture(&home, |_| {})
                .unwrap_err()
                .contains("not a regular file")
        );
        assert_eq!(fs::read(&external).unwrap(), b"operator bytes");
        assert_eq!(
            fs::metadata(&external).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn parent_symlink_refuses_and_preserves_external_directory() {
        let home = fixture();
        let external = fixture();
        fs::write(external.join(RAILS_FILE), b"operator bytes").unwrap();
        symlink(&external, home.join(CURSOR_DIR)).unwrap();

        assert!(
            publish_fixture(&home, |_| {})
                .unwrap_err()
                .contains("no-follow directory")
        );
        assert_eq!(
            fs::read(external.join(RAILS_FILE)).unwrap(),
            b"operator bytes"
        );
        fs::remove_dir_all(home).unwrap();
        fs::remove_dir_all(external).unwrap();
    }

    #[test]
    fn parent_replacement_race_refuses_without_touching_external_target() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        let external = fixture();
        fs::write(external.join(RAILS_FILE), b"operator bytes").unwrap();

        let error = publish_fixture(&home, |opened| {
            fs::rename(opened, home.join("detached-cursor")).unwrap();
            symlink(&external, opened).unwrap();
        })
        .unwrap_err();

        assert!(error.contains(".cursor changed during publication"));
        assert_eq!(
            fs::read(external.join(RAILS_FILE)).unwrap(),
            b"operator bytes"
        );
        fs::remove_dir_all(home).unwrap();
        fs::remove_dir_all(external).unwrap();
    }

    #[test]
    fn leaf_replacement_race_refuses_without_following_external_target() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        let hooks = cursor.join(RAILS_FILE);
        fs::write(&hooks, b"managed before").unwrap();
        let external = home.join("external");
        fs::write(&external, b"operator bytes").unwrap();
        let external_mode = fs::metadata(&external).unwrap().mode();

        let error = publish_fixture(&home, |_| {
            fs::remove_file(&hooks).unwrap();
            symlink(&external, &hooks).unwrap();
        })
        .unwrap_err();

        assert!(error.contains("hooks.json changed during publication"));
        assert_eq!(fs::read(&external).unwrap(), b"operator bytes");
        assert_eq!(fs::metadata(&external).unwrap().mode(), external_mode);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_second_normal_delivery_replaces_only_the_managed_regular_file() {
        let home = fixture();
        publish_fixture(&home, |_| {}).unwrap();
        let hooks = home.join(CURSOR_DIR).join(RAILS_FILE);
        let first_inode = fs::metadata(&hooks).unwrap().ino();
        publish_fixture(&home, |_| {}).unwrap();
        assert_ne!(fs::metadata(&hooks).unwrap().ino(), first_inode);
        assert_eq!(fs::read(&hooks).unwrap(), b"{\"version\":1}");
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn replacement_commit_has_no_missing_managed_name_checkpoint() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        fs::write(cursor.join(RAILS_FILE), b"managed before").unwrap();

        publish_fixture_with_after(
            &home,
            |_| {},
            |opened| {
                let hooks = opened.join(RAILS_FILE);
                assert!(fs::symlink_metadata(&hooks).unwrap().is_file());
                assert_eq!(fs::read(hooks).unwrap(), b"{\"version\":1}");
            },
        )
        .unwrap();

        assert_eq!(
            fs::read(cursor.join(RAILS_FILE)).unwrap(),
            b"{\"version\":1}"
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn failed_automatic_restore_reports_and_preserves_exact_recovery_path() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        fs::write(cursor.join(RAILS_FILE), b"managed before").unwrap();
        let external = home.join("external");
        fs::write(&external, b"operator bytes").unwrap();
        fs::set_permissions(&external, fs::Permissions::from_mode(0o600)).unwrap();

        let error = publish_fixture_with_after(
            &home,
            |_| {},
            |opened| {
                fs::set_permissions(opened, fs::Permissions::from_mode(0o555)).unwrap();
            },
        )
        .unwrap_err();
        fs::set_permissions(&cursor, fs::Permissions::from_mode(0o755)).unwrap();

        let recovery = fs::read_dir(&cursor)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| path.file_name().unwrap() != RAILS_FILE)
            .unwrap();
        let recovery_name = recovery.file_name().unwrap().to_string_lossy();
        assert!(error.contains("automatic restore failed"));
        assert!(error.contains(&format!(".cursor/{recovery_name}")));
        assert_eq!(fs::read(recovery).unwrap(), b"managed before");
        assert_eq!(fs::read(&external).unwrap(), b"operator bytes");
        assert_eq!(
            fs::metadata(&external).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn failed_new_publication_rollback_reports_the_unremoved_hooks_file() {
        let home = fixture();
        let external = home.join("external");
        fs::write(&external, b"operator bytes").unwrap();
        fs::set_permissions(&external, fs::Permissions::from_mode(0o600)).unwrap();

        let error = publish_fixture_with_after(
            &home,
            |_| {},
            |opened| {
                fs::set_permissions(opened, fs::Permissions::from_mode(0o555)).unwrap();
            },
        )
        .unwrap_err();
        let cursor = home.join(CURSOR_DIR);
        fs::set_permissions(&cursor, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(error.contains("rollback failed to remove published hooks.json"));
        assert_eq!(
            fs::read(cursor.join(RAILS_FILE)).unwrap(),
            b"{\"version\":1}"
        );
        assert_eq!(fs::read(&external).unwrap(), b"operator bytes");
        assert_eq!(
            fs::metadata(&external).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn successful_automatic_restore_returns_the_publication_error_only() {
        let home = fixture();
        let cursor = home.join(CURSOR_DIR);
        fs::create_dir(&cursor).unwrap();
        fs::write(cursor.join(RAILS_FILE), b"managed before").unwrap();
        let external = home.join("external");
        fs::write(&external, b"operator bytes").unwrap();
        let external_mode = fs::metadata(&external).unwrap().permissions().mode();

        let error = publish_fixture_with_after(
            &home,
            |_| {},
            |opened| {
                fs::write(opened.join(RAILS_FILE), b"corrupt staged bytes").unwrap();
            },
        )
        .unwrap_err();

        assert!(error.contains("published hooks.json digest changed"));
        assert!(!error.contains("automatic restore failed"));
        assert!(!error.contains("is preserved at"));
        assert_eq!(
            fs::read(cursor.join(RAILS_FILE)).unwrap(),
            b"managed before"
        );
        assert_eq!(fs::read_dir(&cursor).unwrap().count(), 1);
        assert_eq!(fs::read(&external).unwrap(), b"operator bytes");
        assert_eq!(
            fs::metadata(&external).unwrap().permissions().mode(),
            external_mode
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn payload_digest_mismatch_refuses_before_creating_cursor_state() {
        let home = fixture();
        let payload = home.join("payload");
        fs::write(&payload, b"wrong bytes").unwrap();
        let args = vec![
            home.to_string_lossy().into_owned(),
            payload.to_string_lossy().into_owned(),
            sha256(b"expected bytes"),
        ];

        assert!(publish(&args).unwrap_err().contains("payload digest"));
        assert!(!home.join(CURSOR_DIR).exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn unsupported_atomic_exchange_reports_fail_closed_behavior() {
        let error = exchange_refusal(io::Error::from_raw_os_error(libc::EOPNOTSUPP));

        assert!(error.contains("atomic hooks.json exchange is unsupported"));
        assert!(error.contains("no non-atomic fallback was attempted"));
    }

    #[test]
    fn other_atomic_exchange_errors_keep_the_operating_system_detail() {
        let error = exchange_refusal(io::Error::from_raw_os_error(libc::EACCES));

        assert!(error.contains("cannot atomically exchange hooks.json"));
        assert!(error.contains(&io::Error::from_raw_os_error(libc::EACCES).to_string()));
    }
}
