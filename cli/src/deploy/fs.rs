//! Confined, durable filesystem primitives for the deployment root.
//!
//! All mutation helpers operate from directory descriptors and refuse symlinked
//! path components. The public manager is the only caller that should compose
//! these primitives into a deployment transition.

use std::ffi::{CStr, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::model::{DeploymentRootIdentity, Digest, GenerationId, HostIdentity, Pointer};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FaultPoint {
    AuditAppend,
}

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

fn open_optional_dir_at(parent: RawFd, component: &str) -> Result<Option<OwnedFd>, FsError> {
    match open_dir_at(parent, component) {
        Ok(directory) => Ok(Some(directory)),
        Err(FsError::Io { source, .. }) if source.kind() == std::io::ErrorKind::NotFound => {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

fn read_dir_names(fd: RawFd, path: &Path) -> Result<Vec<String>, FsError> {
    let duplicate = unsafe { libc::dup(fd) };
    if duplicate < 0 {
        return Err(io(
            "duplicate directory descriptor",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    let directory = unsafe { libc::fdopendir(duplicate) };
    if directory.is_null() {
        let error = std::io::Error::last_os_error();
        unsafe { libc::close(duplicate) };
        return Err(io("open directory stream", path, error));
    }
    let mut names = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(directory) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() == b"." || name.to_bytes() == b".." {
            continue;
        }
        let name = std::str::from_utf8(name.to_bytes()).map_err(|_| {
            FsError::InvalidPath(format!("non-UTF8 directory entry: {}", path.display()))
        })?;
        names.push(name.to_owned());
    }
    let result = unsafe { libc::closedir(directory) };
    if result != 0 {
        return Err(io(
            "close directory stream",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    names.sort();
    Ok(names)
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

fn open_relative_file(root: RawFd, components: &[String], path: &Path) -> Result<File, FsError> {
    let (name, parent) = components
        .split_last()
        .ok_or_else(|| FsError::InvalidPath(format!("empty file path: {}", path.display())))?;
    let directory = open_relative_dir(root, parent)?;
    let name = c_string(name)?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io(
            "open confined payload",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn file_mode(file: &File, path: &Path) -> Result<u32, FsError> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(file.as_raw_fd(), &mut stat) } != 0 {
        return Err(io(
            "stat confined payload",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    Ok(stat.st_mode as u32)
}

fn validate_release_payload(
    release_dir: RawFd,
    release_path: &Path,
    release_digest: &Digest,
) -> Result<(), FsError> {
    let manifest_path = release_path.join("release-manifest.json");
    let manifest = read_at(release_dir, "release-manifest.json", &manifest_path)?;
    if Digest::from_bytes(&manifest) != *release_digest {
        return Err(FsError::InvalidPointer(format!(
            "release manifest digest does not match {}",
            release_path.display()
        )));
    }
    let value: serde_json::Value = serde_json::from_slice(&manifest)
        .map_err(|error| FsError::InvalidPointer(format!("invalid release manifest: {error}")))?;
    let payload = value
        .get("payload")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| FsError::InvalidPointer("release manifest has no payload".to_owned()))?;
    if payload.is_empty() {
        return Err(FsError::InvalidPointer(
            "release manifest payload is empty".to_owned(),
        ));
    }
    let mut expected_files = std::collections::BTreeSet::new();
    for entry in payload {
        let raw_path = entry
            .get("path")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| FsError::InvalidPointer("payload entry has no path".to_owned()))?;
        let raw_path = raw_path.strip_prefix("tightbeam/").unwrap_or(raw_path);
        let payload_components = relative_components(Path::new(raw_path))?;
        let payload_path = Path::new("tightbeam").join(raw_path);
        if kind_is_file(entry) && !expected_files.insert(raw_path.to_owned()) {
            return Err(FsError::InvalidPointer(format!(
                "duplicate payload path: {raw_path}"
            )));
        }
        let kind = entry
            .get("type")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| FsError::InvalidPointer("payload entry has no type".to_owned()))?;
        let mode = entry
            .get("mode")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| FsError::InvalidPointer("payload entry has no mode".to_owned()))?
            as u32;
        match kind {
            "directory" => {
                let directory_components =
                    [vec!["tightbeam".to_owned()], payload_components].concat();
                let directory = open_relative_dir(release_dir, &directory_components)?;
                let actual_mode = file_mode_fd(directory.as_raw_fd(), &payload_path)?;
                if actual_mode & 0o7777 != mode & 0o7777 {
                    return Err(FsError::InvalidPointer(format!(
                        "payload mode mismatch: {}",
                        payload_path.display()
                    )));
                }
            }
            "file" => {
                let file_components = [vec!["tightbeam".to_owned()], payload_components].concat();
                let mut file = open_relative_file(release_dir, &file_components, &payload_path)?;
                let actual_mode = file_mode(&file, &payload_path)?;
                if actual_mode & 0o7777 != mode & 0o7777 {
                    return Err(FsError::InvalidPointer(format!(
                        "payload mode mismatch: {}",
                        payload_path.display()
                    )));
                }
                let expected_size = entry
                    .get("size")
                    .and_then(serde_json::Value::as_u64)
                    .ok_or_else(|| {
                        FsError::InvalidPointer("payload file has no size".to_owned())
                    })?;
                let expected_digest = entry
                    .get("sha256")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| {
                        FsError::InvalidPointer("payload file has no sha256".to_owned())
                    })?;
                let expected_digest =
                    Digest::parse(expected_digest).map_err(FsError::InvalidPointer)?;
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes)
                    .map_err(|error| io("read release payload", &payload_path, error))?;
                if bytes.len() as u64 != expected_size
                    || Digest::from_bytes(&bytes) != expected_digest
                {
                    return Err(FsError::InvalidPointer(format!(
                        "payload content mismatch: {}",
                        payload_path.display()
                    )));
                }
            }
            other => {
                return Err(FsError::InvalidPointer(format!(
                    "unsupported payload type: {other}"
                )));
            }
        }
    }
    let tightbeam = open_dir_at(release_dir, "tightbeam")?;
    let mut actual_files = std::collections::BTreeSet::new();
    collect_payload_files(
        tightbeam.as_raw_fd(),
        Path::new(""),
        &mut actual_files,
        release_path,
    )?;
    if actual_files != expected_files {
        return Err(FsError::InvalidPointer(format!(
            "release payload inventory mismatch in {}",
            release_path.display()
        )));
    }
    Ok(())
}

fn kind_is_file(entry: &serde_json::Value) -> bool {
    entry.get("type").and_then(serde_json::Value::as_str) == Some("file")
}

fn collect_payload_files(
    directory: RawFd,
    prefix: &Path,
    files: &mut std::collections::BTreeSet<String>,
    release_path: &Path,
) -> Result<(), FsError> {
    for name in read_dir_names(directory, release_path)? {
        let child_path = prefix.join(&name);
        match open_dir_at(directory, &name) {
            Ok(child) => {
                collect_payload_files(child.as_raw_fd(), &child_path, files, release_path)?
            }
            Err(FsError::Io { source, .. })
                if source.kind() == std::io::ErrorKind::NotADirectory
                    || source.raw_os_error() == Some(libc::ELOOP) =>
            {
                let child_name = c_string(&name)?;
                let fd = unsafe {
                    libc::openat(
                        directory,
                        child_name.as_ptr(),
                        libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                    )
                };
                if fd < 0 {
                    return Err(io(
                        "open release payload entry",
                        release_path.join(&child_path),
                        std::io::Error::last_os_error(),
                    ));
                }
                let file = unsafe { File::from_raw_fd(fd) };
                let mode = file_mode(&file, &release_path.join(&child_path))?;
                if mode & libc::S_IFMT as u32 != libc::S_IFREG as u32 {
                    return Err(FsError::InvalidPointer(format!(
                        "non-regular release payload entry: {}",
                        child_path.display()
                    )));
                }
                let rendered = child_path
                    .to_str()
                    .ok_or_else(|| FsError::InvalidPath("non-UTF8 payload path".to_owned()))?;
                files.insert(rendered.to_owned());
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn file_mode_fd(fd: RawFd, path: &Path) -> Result<u32, FsError> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return Err(io(
            "stat confined directory",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    Ok(stat.st_mode as u32)
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
    host_identity: HostIdentity,
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
        let root = fs::canonicalize(&root)
            .map_err(|error| io("canonicalize deployment root", &root, error))?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&root)
            .map_err(|error| io("open deployment root", &root, error))?;
        let host_identity = read_host_identity(&host_identity_path(&root))?;
        Ok(Self {
            root,
            root_fd: file.into(),
            host_identity,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn host_identity(&self) -> &HostIdentity {
        &self.host_identity
    }

    pub fn root_identity_digest(&self) -> Result<DeploymentRootIdentity, FsError> {
        let root = self.root.to_str().ok_or_else(|| {
            FsError::InvalidPointer("deployment root is not valid UTF-8".to_owned())
        })?;
        let identity = serde_json::to_vec(&serde_json::json!({
            "hostIdentity": self.host_identity.as_str(),
            "deploymentRoot": root,
        }))
        .map_err(|error| FsError::InvalidPointer(format!("serialize root identity: {error}")))?;
        Ok(DeploymentRootIdentity::from_digest(Digest::from_bytes(
            &identity,
        )))
    }

    fn namespace_identity(&self) -> Result<(HostIdentity, u64, u64), FsError> {
        let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
        if unsafe { libc::fstat(self.root_fd.as_raw_fd(), &mut stat) } != 0 {
            return Err(io(
                "stat deployment root descriptor",
                &self.root,
                std::io::Error::last_os_error(),
            ));
        }
        Ok((
            self.host_identity.clone(),
            stat.st_dev as u64,
            stat.st_ino as u64,
        ))
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
        Ok(Some(self.read_generation(&generation)?))
    }

    pub(crate) fn validate_generation_target(&self, target: &Pointer) -> Result<(), FsError> {
        let observed = self.read_generation(&target.generation)?;
        if observed.release != target.release {
            return Err(FsError::InvalidPointer(format!(
                "target generation {} selects release {}, requested {}",
                target.generation, observed.release, target.release
            )));
        }
        Ok(())
    }

    pub(crate) fn generation_prior(
        &self,
        generation: &GenerationId,
    ) -> Result<Option<GenerationId>, FsError> {
        let manifest_path = Path::new("generations")
            .join(generation.as_str())
            .join("manifest.json");
        let generations = open_dir_at(self.root_fd.as_raw_fd(), "generations")?;
        let generation_dir = open_dir_at(generations.as_raw_fd(), generation.as_str())?;
        let manifest = read_at(generation_dir.as_raw_fd(), "manifest.json", &manifest_path)?;
        let value: serde_json::Value = serde_json::from_slice(&manifest).map_err(|error| {
            FsError::InvalidPointer(format!("invalid generation manifest: {error}"))
        })?;
        match value.get("prior_generation") {
            Some(serde_json::Value::Null) => Ok(None),
            Some(serde_json::Value::String(value)) => GenerationId::new(value)
                .map(Some)
                .map_err(FsError::InvalidPointer),
            Some(_) => Err(FsError::InvalidPointer(format!(
                "generation manifest has invalid prior_generation: {}",
                generation
            ))),
            None => Err(FsError::InvalidPointer(format!(
                "generation manifest has no prior_generation: {}",
                generation
            ))),
        }
    }

    fn read_generation(&self, generation: &GenerationId) -> Result<Pointer, FsError> {
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
        let release_components = vec!["releases".to_owned(), release_name.to_owned()];
        let release_dir = open_relative_dir(self.root_fd.as_raw_fd(), &release_components)?;
        validate_release_payload(
            release_dir.as_raw_fd(),
            &self.root.join("releases").join(release_name),
            &release,
        )?;
        Ok(Pointer {
            generation: generation.clone(),
            release,
        })
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
        let path = Path::new("staging");
        let Some(directory) = open_optional_dir_at(self.root_fd.as_raw_fd(), "staging")? else {
            return Ok(Vec::new());
        };
        let mut entries = Vec::new();
        for name in read_dir_names(directory.as_raw_fd(), path)? {
            let child = open_dir_at(directory.as_raw_fd(), &name)?;
            drop(child);
            entries.push(name);
        }
        Ok(entries)
    }

    pub fn read_intents(&self) -> Result<Vec<Vec<u8>>, FsError> {
        read_json_directory(self.root_fd.as_raw_fd(), "intents", Path::new("intents"))
    }

    pub fn read_audit(&self) -> Result<Vec<Vec<u8>>, FsError> {
        let path = Path::new("audit");
        let Some(directory) = open_optional_dir_at(self.root_fd.as_raw_fd(), "audit")? else {
            return Ok(Vec::new());
        };
        let mut entries = Vec::new();
        for transaction in read_dir_names(directory.as_raw_fd(), path)? {
            let transaction_path = path.join(&transaction);
            let transaction_dir = open_dir_at(directory.as_raw_fd(), &transaction)?;
            for fact in read_dir_names(transaction_dir.as_raw_fd(), &transaction_path)? {
                let fact_path = transaction_path.join(&fact);
                entries.push(read_at(transaction_dir.as_raw_fd(), &fact, &fact_path)?);
            }
        }
        entries.sort();
        Ok(entries)
    }
}

fn host_identity_path(_root: &Path) -> PathBuf {
    #[cfg(test)]
    if _root != Path::new("/opt/tightbeam") {
        return _root.join("deploy-host-id");
    }
    PathBuf::from("/etc/tightbeam/deploy-host-id")
}

fn read_host_identity(path: &Path) -> Result<HostIdentity, FsError> {
    let mut file = open_host_identity_without_following_ancestors(path)?;
    let metadata = file
        .metadata()
        .map_err(|error| io("stat host identity descriptor", path, error))?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o7777 != 0o400 {
        return Err(FsError::InvalidPointer(format!(
            "host identity must be a regular root-owned mode-0400 file: {}",
            path.display()
        )));
    }
    #[cfg(not(test))]
    if metadata.uid() != 0 {
        return Err(FsError::InvalidPointer(format!(
            "host identity is not root-owned: {}",
            path.display()
        )));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| io("read host identity", path, error))?;
    if bytes.len() != 32 {
        return Err(FsError::InvalidPointer(
            "host identity must contain exactly 32 bytes".to_owned(),
        ));
    }
    Ok(HostIdentity::from_bytes(&bytes))
}

fn open_host_identity_without_following_ancestors(path: &Path) -> Result<File, FsError> {
    if !path.is_absolute() {
        return Err(FsError::InvalidPath(format!(
            "host identity must be absolute: {}",
            path.display()
        )));
    }
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(component) => components.push(
                component
                    .to_str()
                    .ok_or_else(|| {
                        FsError::InvalidPath(format!(
                            "host identity has non-UTF8 component: {}",
                            path.display()
                        ))
                    })?
                    .to_owned(),
            ),
            _ => {
                return Err(FsError::InvalidPath(format!(
                    "host identity has non-normal component: {}",
                    path.display()
                )));
            }
        }
    }
    let (name, parents) = components.split_last().ok_or_else(|| {
        FsError::InvalidPath(format!("host identity has no name: {}", path.display()))
    })?;
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open("/")
        .map_err(|error| io("open host identity root descriptor", "/", error))?;
    let mut directory: OwnedFd = root.into();
    let mut traversed = PathBuf::from("/");
    #[cfg(not(test))]
    validate_host_identity_ancestor(directory.as_raw_fd(), &traversed)?;
    for parent in parents {
        directory = open_dir_at(directory.as_raw_fd(), parent)?;
        traversed.push(parent);
        #[cfg(not(test))]
        validate_host_identity_ancestor(directory.as_raw_fd(), &traversed)?;
    }
    let name = c_string(name)?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io(
            "open host identity through confined descriptors",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

#[cfg(not(test))]
fn validate_host_identity_ancestor(fd: RawFd, path: &Path) -> Result<(), FsError> {
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return Err(io(
            "stat host identity ancestor descriptor",
            path,
            std::io::Error::last_os_error(),
        ));
    }
    if stat.st_uid != 0 || (stat.st_mode as u32 & 0o022) != 0 {
        return Err(FsError::InvalidPointer(format!(
            "host identity ancestor must be root-owned and not group/world writable: {}",
            path.display()
        )));
    }
    Ok(())
}

fn read_json_directory(root: RawFd, name: &str, path: &Path) -> Result<Vec<Vec<u8>>, FsError> {
    let Some(directory) = open_optional_dir_at(root, name)? else {
        return Ok(Vec::new());
    };
    let mut entries = Vec::new();
    for name in read_dir_names(directory.as_raw_fd(), path)? {
        let entry_path = path.join(&name);
        let bytes = read_at(directory.as_raw_fd(), &name, &entry_path)?;
        if serde_json::from_slice::<serde_json::Value>(&bytes).is_err() {
            return Err(FsError::InvalidPointer(format!(
                "invalid JSON record: {}",
                entry_path.display()
            )));
        }
        entries.push(bytes);
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
    namespace_identity: (HostIdentity, u64, u64),
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
        Ok(Self {
            file,
            namespace_identity: fs.namespace_identity()?,
        })
    }

    pub(crate) fn belongs_to(&self, fs: &DeploymentFs) -> Result<(), FsError> {
        if self.namespace_identity == fs.namespace_identity()? {
            Ok(())
        } else {
            Err(FsError::InvalidPointer(
                "deployment lock belongs to another namespace".to_owned(),
            ))
        }
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
    use std::sync::Arc;

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
        fs::write(path.join("deploy-host-id"), [7_u8; 32]).unwrap();
        fs::set_permissions(
            path.join("deploy-host-id"),
            fs::Permissions::from_mode(0o400),
        )
        .unwrap();
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
    fn deployment_lock_is_exclusive_and_descriptor_bound() {
        let (directory, fs) = fixture();
        fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        let first = DeploymentLock::acquire(&fs).unwrap();
        assert!(matches!(DeploymentLock::acquire(&fs), Err(FsError::Busy)));
        first.belongs_to(&fs).unwrap();

        let other = DeploymentFs::open(&directory.0).unwrap();
        first.belongs_to(&other).unwrap();
    }

    #[test]
    fn descriptor_readers_refuse_symlinked_staging_and_intent_entries() {
        let (_directory, fs) = fixture();
        fs.ensure_dir(Path::new("staging"), 0o755).unwrap();
        fs.ensure_dir(Path::new("intents"), 0o755).unwrap();
        std::os::unix::fs::symlink("/tmp", fs.root().join("staging/escape")).unwrap();
        std::os::unix::fs::symlink("/tmp/escape.json", fs.root().join("intents/escape.json"))
            .unwrap();
        assert!(fs.list_staging().is_err());
        assert!(fs.read_intents().is_err());
    }

    #[test]
    fn audit_reader_accepts_only_confined_nested_facts() {
        let (_directory, fs) = fixture();
        fs.ensure_dir(Path::new("audit/tx-1"), 0o755).unwrap();
        fs.publish_immutable(
            Path::new("audit/tx-1/fact.json"),
            br#"{"state":"ok"}"#,
            0o444,
        )
        .unwrap();
        assert_eq!(
            fs.read_audit().unwrap(),
            vec![br#"{"state":"ok"}"#.to_vec()]
        );
    }

    #[test]
    fn active_replacement_is_a_complete_relative_pointer() {
        let (_directory, fs) = fixture();
        fs.ensure_dir(Path::new("generations/g1"), 0o755).unwrap();
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":292,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let digest = Digest::from_bytes(release_manifest.as_bytes());
        let release = format!("sha256-{}/tightbeam", digest);
        fs.ensure_dir(&Path::new("releases").join(&release), 0o755)
            .unwrap();
        fs.publish_immutable(
            &Path::new("releases")
                .join(format!("sha256-{digest}"))
                .join("release-manifest.json"),
            release_manifest.as_bytes(),
            0o444,
        )
        .unwrap();
        fs.publish_immutable(
            &Path::new("releases")
                .join(format!("sha256-{digest}"))
                .join("tightbeam/bin"),
            payload,
            0o444,
        )
        .unwrap();
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
        assert_eq!(pointer.release, digest);
    }

    #[test]
    fn same_filesystem_classifies_a_separate_proc_mount_as_cross_device() {
        let (_directory, fs) = fixture();
        assert!(matches!(
            fs.same_filesystem(Path::new("/proc")),
            Err(FsError::CrossDevice { .. })
        ));
    }

    #[test]
    fn host_identity_refuses_a_malformed_fixture_file() {
        let (directory, _fs) = fixture();
        let path = directory.0.join("deploy-host-id");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&path, [3_u8; 31]).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
        assert!(matches!(
            DeploymentFs::open(&directory.0),
            Err(FsError::InvalidPointer(reason)) if reason.contains("exactly 32 bytes")
        ));
    }

    #[test]
    fn host_identity_reader_rejects_a_symlink_even_when_its_target_is_valid() {
        let (directory, _fs) = fixture();
        let real = directory.0.join("real-host-id");
        fs::rename(directory.0.join("deploy-host-id"), &real).unwrap();
        std::os::unix::fs::symlink(&real, directory.0.join("deploy-host-id")).unwrap();
        assert!(matches!(
            DeploymentFs::open(&directory.0),
            Err(FsError::Io { source, .. }) if source.raw_os_error() == Some(libc::ELOOP)
        ));
    }

    #[test]
    fn host_identity_reader_rejects_a_symlinked_ancestor() {
        let (directory, _fs) = fixture();
        let alias = directory.0.parent().unwrap().join(format!(
            "tightbeam-deploy-host-id-alias-{}",
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::os::unix::fs::symlink(&directory.0, &alias).unwrap();
        let result = read_host_identity(&alias.join("deploy-host-id"));
        let _ = fs::remove_file(&alias);
        assert!(matches!(result, Err(FsError::Io { .. })));
    }

    #[test]
    fn deployment_root_identity_is_stable_for_the_same_host_and_path() {
        let (directory, fs) = fixture();
        let other = DeploymentFs::open(&directory.0).unwrap();
        assert_eq!(
            fs.root_identity_digest().unwrap(),
            other.root_identity_digest().unwrap()
        );
    }

    #[test]
    fn concurrent_pointer_readers_see_only_complete_known_generations() {
        let (_directory, fs) = fixture();
        let payload = b"payload";
        let payload_digest = Digest::from_bytes(payload);
        let release_manifest = format!(
            r#"{{"payload":[{{"path":"bin","type":"file","mode":292,"size":{},"sha256":"{}"}}]}}"#,
            payload.len(),
            payload_digest
        );
        let release_digest = Digest::from_bytes(release_manifest.as_bytes());
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
        for generation in ["g1", "g2"] {
            fs.ensure_dir(&Path::new("generations").join(generation), 0o755)
                .unwrap();
            fs.publish_immutable(
                &Path::new("generations")
                    .join(generation)
                    .join("manifest.json"),
                format!(r#"{{"releaseDigest":"{release_digest}"}}"#).as_bytes(),
                0o444,
            )
            .unwrap();
            fs.replace_relative_symlink(
                &Path::new("generations").join(generation).join("root"),
                &Path::new("../../releases").join(&release).join("tightbeam"),
            )
            .unwrap();
        }
        fs.replace_relative_symlink(Path::new("active"), Path::new("generations/g1"))
            .unwrap();

        let fs = Arc::new(fs);
        let writer_fs = Arc::clone(&fs);
        let writer = std::thread::spawn(move || {
            for index in 0..80 {
                let generation = if index % 2 == 0 { "g2" } else { "g1" };
                writer_fs
                    .replace_relative_symlink(
                        Path::new("active"),
                        &Path::new("generations").join(generation),
                    )
                    .unwrap();
            }
        });
        let reader_fs = Arc::clone(&fs);
        let reader = std::thread::spawn(move || {
            for _ in 0..160 {
                let pointer = reader_fs.read_active().unwrap().unwrap();
                assert!(matches!(pointer.generation.as_str(), "g1" | "g2"));
                assert_eq!(pointer.release, release_digest);
            }
        });
        writer.join().unwrap();
        reader.join().unwrap();
    }
}
