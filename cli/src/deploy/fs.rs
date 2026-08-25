//! Confined, durable filesystem primitives for the deployment root.
//!
//! All mutation helpers operate from directory descriptors and refuse symlinked
//! path components. The public manager is the only caller that should compose
//! these primitives into a deployment transition.

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::model::{Digest, GenerationId, Pointer};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug)]
pub enum FsError {
    Io {
        operation: &'static str,
        path: PathBuf,
        source: std::io::Error,
    },
    InvalidPath(String),
    InvalidPointer(String),
    ImmutableCollision(PathBuf),
    CrossDevice {
        left: PathBuf,
        right: PathBuf,
    },
    Busy,
}

impl std::fmt::Display for FsError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io {
                operation,
                path,
                source,
            } => {
                write!(formatter, "{operation} {}: {source}", path.display())
            }
            Self::InvalidPath(reason) => write!(formatter, "invalid confined path: {reason}"),
            Self::InvalidPointer(reason) => write!(formatter, "invalid active pointer: {reason}"),
            Self::ImmutableCollision(path) => {
                write!(formatter, "immutable name collision: {}", path.display())
            }
            Self::CrossDevice { left, right } => write!(
                formatter,
                "device mismatch between {} and {}; refusing copy/delete fallback",
                left.display(),
                right.display()
            ),
            Self::Busy => formatter.write_str("deployment lock is busy"),
        }
    }
}

impl std::error::Error for FsError {}

fn io(operation: &'static str, path: impl Into<PathBuf>, source: std::io::Error) -> FsError {
    FsError::Io {
        operation,
        path: path.into(),
        source,
    }
}

fn c_string(component: &str) -> Result<CString, FsError> {
    CString::new(component).map_err(|_| FsError::InvalidPath(component.to_owned()))
}

/// Validate a path before any descriptor traversal. The empty relative path is
/// not a file and therefore is never accepted by file helpers.
pub fn relative_components(path: &Path) -> Result<Vec<String>, FsError> {
    if path.is_absolute() {
        return Err(FsError::InvalidPath(format!(
            "absolute path: {}",
            path.display()
        )));
    }
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(value) => {
                let value = value.to_str().ok_or_else(|| {
                    FsError::InvalidPath(format!("non-UTF8 component: {}", path.display()))
                })?;
                if value.is_empty() {
                    return Err(FsError::InvalidPath("empty component".to_owned()));
                }
                components.push(value.to_owned());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(FsError::InvalidPath(format!(
                    "parent component: {}",
                    path.display()
                )));
            }
            _ => {
                return Err(FsError::InvalidPath(format!(
                    "root component: {}",
                    path.display()
                )));
            }
        }
    }
    if components.is_empty() {
        return Err(FsError::InvalidPath("empty path".to_owned()));
    }
    Ok(components)
}

fn open_dir_at(parent: RawFd, component: &str) -> Result<OwnedFd, FsError> {
    let component = c_string(component)?;
    let fd = unsafe {
        libc::openat(
            parent,
            component.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io(
            "open directory",
            component.to_string_lossy().into_owned(),
            std::io::Error::last_os_error(),
        ));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn open_relative_dir(root: RawFd, components: &[String]) -> Result<OwnedFd, FsError> {
    let duplicate = unsafe { libc::dup(root) };
    if duplicate < 0 {
        return Err(io(
            "duplicate root descriptor",
            ".",
            std::io::Error::last_os_error(),
        ));
    }
    let mut current = unsafe { OwnedFd::from_raw_fd(duplicate) };
    for component in components {
        current = open_dir_at(current.as_raw_fd(), component)?;
    }
    Ok(current)
}

fn fsync_fd(fd: RawFd, path: &Path) -> Result<(), FsError> {
    if unsafe { libc::fsync(fd) } != 0 {
        return Err(io("fsync", path, std::io::Error::last_os_error()));
    }
    Ok(())
}

fn fsync_dir(path: &Path) -> Result<(), FsError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| io("open directory for fsync", path, error))?;
    fsync_fd(file.as_raw_fd(), path)
}

trait OpenOptionsExt {
    fn custom_flags(&mut self, flags: i32) -> &mut Self;
}

impl OpenOptionsExt for OpenOptions {
    fn custom_flags(&mut self, flags: i32) -> &mut Self {
        std::os::unix::fs::OpenOptionsExt::custom_flags(self, flags)
    }
}

fn parent_and_name(path: &Path) -> Result<(Vec<String>, String), FsError> {
    let components = relative_components(path)?;
    let (name, parent) = components
        .split_last()
        .expect("relative_components returns at least one component");
    Ok((parent.to_vec(), name.clone()))
}

fn read_at(dir: RawFd, name: &str, path: &Path) -> Result<Vec<u8>, FsError> {
    let name = c_string(name)?;
    let fd = unsafe {
        libc::openat(
            dir,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io(
            "open immutable file",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| io("read immutable file", path, error))?;
    Ok(bytes)
}

fn read_link_at(dir: RawFd, name: &str, path: &Path) -> Result<PathBuf, FsError> {
    let name = c_string(name)?;
    let mut buffer = vec![0_u8; 256];
    loop {
        let count = unsafe {
            libc::readlinkat(
                dir,
                name.as_ptr(),
                buffer.as_mut_ptr().cast::<libc::c_char>(),
                buffer.len(),
            )
        };
        if count < 0 {
            return Err(io(
                "read confined symlink",
                path,
                std::io::Error::last_os_error(),
            ));
        }
        let count = count as usize;
        if count < buffer.len() {
            buffer.truncate(count);
            return Ok(PathBuf::from(std::ffi::OsStr::from_bytes(&buffer)));
        }
        buffer.resize(buffer.len() * 2, 0);
        if buffer.len() > 16 * 1024 {
            return Err(FsError::InvalidPointer(format!(
                "symlink target is too long: {}",
                path.display()
            )));
        }
    }
}

#[derive(Debug)]
pub struct DeploymentFs {
    root: PathBuf,
    root_fd: OwnedFd,
}

impl DeploymentFs {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, FsError> {
        let root = root.into();
        if !root.is_absolute() {
            return Err(FsError::InvalidPath(format!(
                "deployment root must be absolute: {}",
                root.display()
            )));
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&root)
            .map_err(|error| io("open deployment root", &root, error))?;
        Ok(Self {
            root,
            root_fd: file.into(),
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn parent_dir(&self, parent: &[String]) -> Result<OwnedFd, FsError> {
        open_relative_dir(self.root_fd.as_raw_fd(), parent)
    }

    pub fn read_confined(&self, path: &Path) -> Result<Vec<u8>, FsError> {
        let (parent, name) = parent_and_name(path)?;
        let dir = self.parent_dir(&parent)?;
        read_at(dir.as_raw_fd(), &name, path)
    }

    pub fn exists_confined(&self, path: &Path) -> Result<bool, FsError> {
        let (parent, name) = parent_and_name(path)?;
        let dir = self.parent_dir(&parent)?;
        let name = c_string(&name)?;
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd >= 0 {
            unsafe { libc::close(fd) };
            return Ok(true);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(io("inspect confined path", path, error))
        }
    }

    pub(crate) fn ensure_dir(&self, path: &Path, mode: u32) -> Result<(), FsError> {
        let components = relative_components(path)?;
        let duplicate = unsafe { libc::dup(self.root_fd.as_raw_fd()) };
        if duplicate < 0 {
            return Err(io(
                "duplicate root descriptor",
                &self.root,
                std::io::Error::last_os_error(),
            ));
        }
        let mut current = unsafe { OwnedFd::from_raw_fd(duplicate) };
        let mut rendered = self.root.clone();
        for component in components {
            rendered.push(&component);
            match open_dir_at(current.as_raw_fd(), &component) {
                Ok(next) => current = next,
                Err(FsError::Io { source, .. })
                    if source.kind() == std::io::ErrorKind::NotFound =>
                {
                    let name = c_string(&component)?;
                    let result = unsafe {
                        libc::mkdirat(current.as_raw_fd(), name.as_ptr(), mode as libc::mode_t)
                    };
                    if result != 0 {
                        return Err(io(
                            "create confined directory",
                            &rendered,
                            std::io::Error::last_os_error(),
                        ));
                    }
                    current = open_dir_at(current.as_raw_fd(), &component)?;
                }
                Err(error) => return Err(error),
            }
        }
        fsync_fd(current.as_raw_fd(), &rendered)
    }

    pub(crate) fn publish_immutable(
        &self,
        path: &Path,
        bytes: &[u8],
        mode: u32,
    ) -> Result<Digest, FsError> {
        let (parent, name) = parent_and_name(path)?;
        let dir = self.parent_dir(&parent)?;
        let temp_name = format!(
            ".{}.partial-{}-{}",
            name,
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let temp = c_string(&temp_name)?;
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                temp.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io(
                "create immutable temporary",
                path,
                std::io::Error::last_os_error(),
            ));
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes)
            .map_err(|error| io("write immutable file", path, error))?;
        file.sync_all()
            .map_err(|error| io("fsync immutable file", path, error))?;
        file.set_permissions(fs::Permissions::from_mode(mode))
            .map_err(|error| io("set immutable file mode", path, error))?;
        file.sync_all()
            .map_err(|error| io("fsync immutable mode", path, error))?;
        drop(file);

        let existing = self.exists_confined(path)?;
        if existing {
            let current = self.read_confined(path)?;
            let _ = unsafe { libc::unlinkat(dir.as_raw_fd(), temp.as_ptr(), 0) };
            if current == bytes {
                return Ok(Digest::from_bytes(bytes));
            }
            return Err(FsError::ImmutableCollision(self.root.join(path)));
        }
        let destination = c_string(&name)?;
        if unsafe {
            libc::renameat(
                dir.as_raw_fd(),
                temp.as_ptr(),
                dir.as_raw_fd(),
                destination.as_ptr(),
            )
        } != 0
        {
            let error = std::io::Error::last_os_error();
            let _ = unsafe { libc::unlinkat(dir.as_raw_fd(), temp.as_ptr(), 0) };
            return Err(io("publish immutable file", path, error));
        }
        fsync_fd(dir.as_raw_fd(), &join_components(&self.root, &parent))?;
        Ok(Digest::from_bytes(bytes))
    }

    pub(crate) fn replace_relative_symlink(
        &self,
        path: &Path,
        target: &Path,
    ) -> Result<(), FsError> {
        let (parent, name) = parent_and_name(path)?;
        let target = relative_link_target(target)?;
        let dir = self.parent_dir(&parent)?;
        let temp_name = format!(
            ".{}.link-{}-{}",
            name,
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let temp = c_string(&temp_name)?;
        let target = c_string(&target)?;
        if unsafe { libc::symlinkat(target.as_ptr(), dir.as_raw_fd(), temp.as_ptr()) } != 0 {
            return Err(io(
                "create pointer temporary",
                path,
                std::io::Error::last_os_error(),
            ));
        }
        fsync_fd(dir.as_raw_fd(), &join_components(&self.root, &parent))?;
        let destination = c_string(&name)?;
        if unsafe {
            libc::renameat(
                dir.as_raw_fd(),
                temp.as_ptr(),
                dir.as_raw_fd(),
                destination.as_ptr(),
            )
        } != 0
        {
            let error = std::io::Error::last_os_error();
            let _ = unsafe { libc::unlinkat(dir.as_raw_fd(), temp.as_ptr(), 0) };
            return Err(io("replace active pointer", path, error));
        }
        fsync_fd(dir.as_raw_fd(), &join_components(&self.root, &parent))
    }

    pub fn read_active(&self) -> Result<Option<Pointer>, FsError> {
        let path = self.root.join("active");
        let link = match read_link_at(self.root_fd.as_raw_fd(), "active", &path) {
            Ok(link) => link,
            Err(FsError::Io { source, .. }) if source.kind() == std::io::ErrorKind::NotFound => {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        let components = relative_components(&link)
            .map_err(|error| FsError::InvalidPointer(error.to_string()))?;
        if components.len() != 2 || components[0] != "generations" {
            return Err(FsError::InvalidPointer(format!(
                "active -> {}",
                link.display()
            )));
        }
        let generation = GenerationId::new(&components[1]).map_err(FsError::InvalidPointer)?;
        let manifest_path = Path::new("generations")
            .join(generation.as_str())
            .join("manifest.json");
        let generations = open_dir_at(self.root_fd.as_raw_fd(), "generations")?;
        let generation_dir = open_dir_at(generations.as_raw_fd(), generation.as_str())?;
        let manifest = read_at(generation_dir.as_raw_fd(), "manifest.json", &manifest_path)?;
        let value: serde_json::Value = serde_json::from_slice(&manifest).map_err(|error| {
            FsError::InvalidPointer(format!("invalid generation manifest: {error}"))
        })?;
        let release = value
            .get("releaseDigest")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                FsError::InvalidPointer("generation manifest has no releaseDigest".to_owned())
            })?;
        let release = Digest::parse(release).map_err(FsError::InvalidPointer)?;
        let root = Path::new("generations")
            .join(generation.as_str())
            .join("root");
        let root_link = read_link_at(generation_dir.as_raw_fd(), "root", &self.root.join(&root))?;
        let expected_prefix = Path::new("../../releases");
        if !root_link.starts_with(expected_prefix)
            || root_link.components().count() != 5
            || root_link.file_name().and_then(|name| name.to_str()) != Some("tightbeam")
        {
            return Err(FsError::InvalidPointer(format!(
                "generation root -> {}",
                root_link.display()
            )));
        }
        let release_name = root_link
            .components()
            .nth(3)
            .and_then(|component| match component {
                Component::Normal(value) => value.to_str(),
                _ => None,
            })
            .ok_or_else(|| {
                FsError::InvalidPointer("generation root has no release name".to_owned())
            })?;
        let expected_release_name = format!("sha256-{release}");
        if release_name != expected_release_name {
            return Err(FsError::InvalidPointer(format!(
                "generation root selects {release_name}, manifest selects {expected_release_name}"
            )));
        }
        let release_components = vec![
            "releases".to_owned(),
            release_name.to_owned(),
            "tightbeam".to_owned(),
        ];
        let _release_dir = open_relative_dir(self.root_fd.as_raw_fd(), &release_components)?;
        Ok(Some(Pointer {
            generation,
            release,
        }))
    }

    pub(crate) fn same_filesystem(&self, other: &Path) -> Result<(), FsError> {
        let left = fs::metadata(&self.root)
            .map_err(|error| io("stat deployment root", &self.root, error))?;
        let right =
            fs::metadata(other).map_err(|error| io("stat filesystem peer", other, error))?;
        if left.dev() != right.dev() {
            return Err(FsError::CrossDevice {
                left: self.root.clone(),
                right: other.to_owned(),
            });
        }
        Ok(())
    }

    pub fn lock_status(&self) -> Result<&'static str, FsError> {
        let path = self.root.join("deploy.lock");
        let name = c_string("deploy.lock")?;
        let fd = unsafe {
            libc::openat(
                self.root_fd.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                return Ok("free");
            }
            return Err(io("open deployment lock", &path, error));
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
            Ok("free")
        } else if std::io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK) {
            Ok("busy")
        } else {
            Err(io(
                "inspect deployment lock",
                &path,
                std::io::Error::last_os_error(),
            ))
        }
    }

    pub fn list_staging(&self) -> Result<Vec<String>, FsError> {
        let path = self.root.join("staging");
        let directory = match fs::read_dir(&path) {
            Ok(directory) => directory,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(io("read staging directory", &path, error)),
        };
        let mut entries = Vec::new();
        for entry in directory {
            let entry = entry.map_err(|error| io("read staging entry", &path, error))?;
            let file_type = entry
                .file_type()
                .map_err(|error| io("inspect staging entry", entry.path(), error))?;
            if file_type.is_dir() {
                entries.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        entries.sort();
        Ok(entries)
    }

    pub fn read_intents(&self) -> Result<Vec<Vec<u8>>, FsError> {
        read_json_entries(&self.root.join("intents"))
    }

    pub fn read_audit(&self) -> Result<Vec<Vec<u8>>, FsError> {
        read_json_entries(&self.root.join("audit"))
    }
}

fn read_json_entries(path: &Path) -> Result<Vec<Vec<u8>>, FsError> {
    let directory = match fs::read_dir(path) {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(io("read deployment directory", path, error)),
    };
    let mut entries = Vec::new();
    for entry in directory {
        let entry = entry.map_err(|error| io("read deployment entry", path, error))?;
        let file_type = entry
            .file_type()
            .map_err(|error| io("inspect deployment entry", entry.path(), error))?;
        if file_type.is_file() {
            entries.push(
                fs::read(entry.path())
                    .map_err(|error| io("read deployment record", entry.path(), error))?,
            );
        }
    }
    entries.sort();
    Ok(entries)
}

fn join_components(root: &Path, components: &[String]) -> PathBuf {
    components
        .iter()
        .fold(root.to_owned(), |path, component| path.join(component))
}

fn relative_link_target(target: &Path) -> Result<String, FsError> {
    if target.is_absolute() {
        return Err(FsError::InvalidPath(format!(
            "absolute symlink target: {}",
            target.display()
        )));
    }
    let rendered = target
        .to_str()
        .ok_or_else(|| FsError::InvalidPath("non-UTF8 symlink target".to_owned()))?;
    if rendered.is_empty() || rendered.contains('\0') {
        return Err(FsError::InvalidPath("empty symlink target".to_owned()));
    }
    let components = target.components().collect::<Vec<_>>();
    let active_target = components.len() == 2
        && components[0] == Component::Normal("generations".as_ref())
        && components[1] != Component::CurDir
        && components[1] != Component::ParentDir;
    let release_target =
        rendered.starts_with("../../releases/") && rendered.ends_with("/tightbeam");
    // `generation/root` is the one intentional parent-link shape in the
    // namespace. It is accepted only as the exact two-parent release path;
    // arbitrary escaping links are never a deployment primitive. `active`
    // itself may only point at one direct generation child.
    if !active_target && !release_target {
        return Err(FsError::InvalidPath(format!(
            "unapproved symlink target: {rendered}"
        )));
    }
    Ok(rendered.to_owned())
}

pub struct DeploymentLock {
    file: File,
}

impl DeploymentLock {
    pub(crate) fn acquire(fs: &DeploymentFs) -> Result<Self, FsError> {
        let path = fs.root.join("deploy.lock");
        let name = c_string("deploy.lock")?;
        let fd = unsafe {
            libc::openat(
                fs.root_fd.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io(
                "open deployment lock",
                &path,
                std::io::Error::last_os_error(),
            ));
        }
        let file = unsafe { File::from_raw_fd(fd) };
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
                return Err(FsError::Busy);
            }
            return Err(io("acquire deployment lock", &path, error));
        }
        Ok(Self { file })
    }
}

impl Drop for DeploymentLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> TempDir {
        let path = std::env::temp_dir().join(format!(
            "tightbeam-deploy-test-{}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        TempDir(path)
    }

    fn fixture() -> (TempDir, DeploymentFs) {
        let directory = tempdir();
        let fs = DeploymentFs::open(&directory.0).unwrap();
        (directory, fs)
    }

    #[test]
    fn relative_paths_reject_absolute_and_parent_components() {
        assert!(relative_components(Path::new("/etc/passwd")).is_err());
        assert!(relative_components(Path::new("safe/../escape")).is_err());
    }

    #[test]
    fn immutable_publication_is_idempotent_but_never_merges_bytes() {
        let (_directory, fs) = fixture();
        fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        let first = fs
            .publish_immutable(Path::new("intents/one.json"), b"one", 0o444)
            .unwrap();
        let second = fs
            .publish_immutable(Path::new("intents/one.json"), b"one", 0o444)
            .unwrap();
        assert_eq!(first, second);
        assert!(matches!(
            fs.publish_immutable(Path::new("intents/one.json"), b"two", 0o444),
            Err(FsError::ImmutableCollision(_))
        ));
    }

    #[test]
    fn active_replacement_is_a_complete_relative_pointer() {
        let (_directory, fs) = fixture();
        fs.ensure_dir(Path::new("generations/g1"), 0o755).unwrap();
        let release = format!("sha256-{}/tightbeam", "a".repeat(64));
        fs.ensure_dir(&Path::new("releases").join(&release), 0o755)
            .unwrap();
        let digest = "a".repeat(64);
        fs.publish_immutable(
            Path::new("generations/g1/manifest.json"),
            format!(r#"{{"releaseDigest":"{digest}"}}"#).as_bytes(),
            0o444,
        )
        .unwrap();
        fs.replace_relative_symlink(
            Path::new("generations/g1/root"),
            &Path::new("../../releases").join(release),
        )
        .unwrap();
        fs.replace_relative_symlink(Path::new("active"), Path::new("generations/g1"))
            .unwrap();
        let pointer = fs.read_active().unwrap().unwrap();
        assert_eq!(pointer.generation.as_str(), "g1");
        assert_eq!(pointer.release.as_str(), digest);
    }
}
