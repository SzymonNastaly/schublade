//! Originals and first-page pictures as files under one directory, which the system may empty
//! at any time. A file is named by the content it belongs to, `originals/<sha256>.<extension>`
//! and `thumbnails/<sha256>`, and the archive never changes the bytes of a content, so a file
//! that is there is never asked for again. The directory is its own index: no table lists the
//! files, so none can disagree with them. A file's modification time is when it was last handed
//! out.

use std::collections::HashSet;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

use archive_access::{ArchiveCondition, ContentDigest, DownloadFailure};
use sha2::{Digest, Sha256};

use crate::ReplicaFault;
use crate::document_detail::OriginalKind;

/// As many downloads as run at once. A further one waits its turn.
const CONCURRENT_DOWNLOADS: usize = 4;

/// A file handed out within this time is being read, so no eviction removes it.
const RECENT_OPENING: Duration = Duration::from_secs(60);

/// The extension of a download that has not been renamed into place.
const PARTIAL_EXTENSION: &str = "partial";

/// Why a representation of a document cannot be shown, as a screen says it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RepresentationRefusal {
    /// The copy holds no such document.
    DocumentUnknown,
    /// The archive has not produced it yet: an email it has not printed, a content it has not
    /// recorded, or a text it has not extracted.
    NotAvailableYet,
    /// It is not on this device, and the archive does not answer.
    ArchiveUnreachable,
    /// It is not on this device, and the archive no longer holds the document.
    NoLongerArchived,
    /// It is not on this device, and the archive refused the token.
    CredentialRefused,
    /// It is not on this device, and the copy follows no archive, because this start found no
    /// token for it.
    NotConnected,
    /// It is not on this device, and the archive is older than the route that serves it.
    ArchiveOutdated,
    /// The archive sent other bytes than the record names. Nothing was kept.
    ContentDiffers,
    StorageFailed {
        detail: String,
    },
    Replica(ReplicaFault),
}

impl From<ArchiveCondition> for RepresentationRefusal {
    fn from(condition: ArchiveCondition) -> RepresentationRefusal {
        match condition {
            ArchiveCondition::CredentialRefused | ArchiveCondition::CredentialInsufficient => {
                RepresentationRefusal::CredentialRefused
            }
            ArchiveCondition::RouteUnknown => RepresentationRefusal::ArchiveOutdated,
            ArchiveCondition::ServiceUnavailable { .. }
            | ArchiveCondition::ConnectionFailed
            | ArchiveCondition::TimedOut
            | ArchiveCondition::ServerError
            | ArchiveCondition::ProtocolViolation { .. } => RepresentationRefusal::ArchiveUnreachable,
        }
    }
}

impl From<DownloadFailure> for RepresentationRefusal {
    fn from(failure: DownloadFailure) -> RepresentationRefusal {
        match failure {
            DownloadFailure::Archive(condition) => condition.into(),
            DownloadFailure::Destination(error) => storage_failed(error),
        }
    }
}

fn storage_failed(error: std::io::Error) -> RepresentationRefusal {
    RepresentationRefusal::StorageFailed {
        detail: error.to_string(),
    }
}

pub struct RepresentationCache {
    originals: PathBuf,
    thumbnails: PathBuf,
    /// The most bytes of originals to keep. `None` keeps every original. A person changes it in
    /// Settings while the cache runs.
    original_byte_limit: Mutex<Option<u64>>,
    /// The files that are being downloaded now.
    downloads: Mutex<HashSet<PathBuf>>,
    download_ended: Condvar,
}

/// A place among the downloads that run. It is given up when the download ends, however it
/// ends.
struct DownloadAdmission<'cache> {
    cache: &'cache RepresentationCache,
    path: &'cache Path,
}

impl Drop for DownloadAdmission<'_> {
    fn drop(&mut self) {
        self.cache.downloads().remove(self.path);
        self.cache.download_ended.notify_all();
    }
}

/// Writes a download to its file and digests it on the way.
struct DigestingFile {
    file: File,
    digest: Sha256,
}

impl Write for DigestingFile {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let written = self.file.write(bytes)?;
        self.digest.update(&bytes[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl RepresentationCache {
    /// Removes what a download left that ended with its process. The directories are created
    /// with each download, because the system may remove them at any time.
    pub fn open(directory: &Path, original_byte_limit: Option<u64>) -> RepresentationCache {
        let cache = RepresentationCache {
            originals: directory.join("originals"),
            thumbnails: directory.join("thumbnails"),
            original_byte_limit: Mutex::new(original_byte_limit),
            downloads: Mutex::new(HashSet::new()),
            download_ended: Condvar::new(),
        };
        for kept in [&cache.originals, &cache.thumbnails] {
            for path in files_in(kept) {
                if is_partial(&path) {
                    // One that stays is removed by the next start.
                    let _ = std::fs::remove_file(path);
                }
            }
        }
        cache.evict_originals();
        cache
    }

    /// The file of an original: the kept one, or else what `download` writes, kept only when
    /// its bytes are the content. Afterwards the originals fit their limit again.
    pub fn original(
        &self,
        content: ContentDigest,
        kind: OriginalKind,
        download: impl FnOnce(&mut dyn Write) -> Result<(), RepresentationRefusal>,
    ) -> Result<PathBuf, RepresentationRefusal> {
        let path = self.original_path(content, kind);
        self.retrieve(&path, Some(content), |destination| download(destination).map(|()| true))?;
        Ok(path)
    }

    /// The file of an original when it is kept, which counts as handing it out, and never a
    /// download.
    pub fn kept_original(&self, content: ContentDigest, kind: OriginalKind) -> Option<PathBuf> {
        let path = self.original_path(content, kind);
        let _downloads = self.downloads();
        handed_out(&path).then_some(path)
    }

    fn original_path(&self, content: ContentDigest, kind: OriginalKind) -> PathBuf {
        self.originals
            .join(format!("{}.{}", content.hexadecimal(), kind.file_extension()))
    }

    /// The file of the picture of a document's first page, kept under the document's content.
    /// `download` answers whether the archive has a picture, and without one there is no file.
    pub fn thumbnail(
        &self,
        content: ContentDigest,
        download: impl FnOnce(&mut dyn Write) -> Result<bool, RepresentationRefusal>,
    ) -> Result<Option<PathBuf>, RepresentationRefusal> {
        let path = self.thumbnails.join(content.hexadecimal());
        Ok(self.retrieve(&path, None, download)?.then_some(path))
    }

    fn downloads(&self) -> MutexGuard<'_, HashSet<PathBuf>> {
        self.downloads.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits until fewer downloads run than may, and none of them is of this file. `None` when
    /// the file is there, kept before or left by the download this one waited for.
    fn admit<'cache>(&'cache self, path: &'cache Path) -> Option<DownloadAdmission<'cache>> {
        let mut downloads = self.downloads();
        loop {
            if handed_out(path) {
                return None;
            }
            if downloads.len() < CONCURRENT_DOWNLOADS && !downloads.contains(path) {
                downloads.insert(path.to_owned());
                return Some(DownloadAdmission { cache: self, path });
            }
            downloads = self
                .download_ended
                .wait(downloads)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// Whether the file is there afterwards. `download` answers false when the archive has
    /// nothing to keep. With a content, the file is an original: it is verified against the
    /// content, and the originals are brought back under their limit after it.
    fn retrieve(
        &self,
        path: &Path,
        content: Option<ContentDigest>,
        download: impl FnOnce(&mut dyn Write) -> Result<bool, RepresentationRefusal>,
    ) -> Result<bool, RepresentationRefusal> {
        let Some(admission) = self.admit(path) else {
            return Ok(true);
        };
        let mut partial = path.as_os_str().to_owned();
        partial.push(".");
        partial.push(PARTIAL_EXTENSION);
        let partial = PathBuf::from(partial);
        let written = write_download(&partial, content, download).and_then(|received| {
            if received {
                std::fs::rename(&partial, path).map_err(storage_failed)?;
            }
            Ok(received)
        });
        drop(admission);
        match written {
            Ok(true) if content.is_some() => self.evict_originals(),
            Ok(true) => {}
            Ok(false) | Err(_) => {
                // A file that was never created needs no removal.
                let _ = std::fs::remove_file(&partial);
            }
        }
        written
    }

    /// The bytes the originals hold now, and the most they may hold.
    pub fn original_storage(&self) -> (u64, Option<u64>) {
        let held = files_in(&self.originals)
            .filter(|path| !is_partial(path))
            .filter_map(|path| path.metadata().ok())
            .map(|metadata| metadata.len())
            .sum();
        (
            held,
            *self.original_byte_limit.lock().unwrap_or_else(PoisonError::into_inner),
        )
    }

    /// Takes a new limit and brings the originals under it at once.
    pub fn set_original_byte_limit(&self, limit: Option<u64>) {
        *self.original_byte_limit.lock().unwrap_or_else(PoisonError::into_inner) = limit;
        self.evict_originals();
    }

    /// Removes the originals a person asked to free the space of: every one but those downloading
    /// now and those handed out within the last minute, which Quick Look or another application
    /// may be about to open, as eviction spares them.
    pub fn remove_originals(&self) {
        let downloads = self.downloads();
        let now = SystemTime::now();
        for path in files_in(&self.originals) {
            let recent = path
                .metadata()
                .and_then(|metadata| metadata.modified())
                .map_or(true, |handed_out_at| {
                    now.duration_since(handed_out_at)
                        .map_or(true, |age| age < RECENT_OPENING)
                });
            if !is_partial(&path) && !downloads.contains(&path) && !recent {
                let _ = std::fs::remove_file(path);
            }
        }
    }

    /// Removes originals, the one handed out longest ago first, until they fit the limit. A
    /// file handed out within the last minute (or ahead of a stepped-back clock) stays, so the
    /// originals can exceed the limit for that long. Serialized with `downloads` so eviction
    /// cannot remove a path simultaneously being checked or handed out.
    fn evict_originals(&self) {
        let Some(limit) = *self.original_byte_limit.lock().unwrap_or_else(PoisonError::into_inner) else {
            return;
        };
        let downloads = self.downloads();
        let mut originals: Vec<(SystemTime, u64, PathBuf)> = files_in(&self.originals)
            .filter(|path| !is_partial(path) && !downloads.contains(path))
            .filter_map(|path| {
                let metadata = path.metadata().ok()?;
                Some((metadata.modified().ok()?, metadata.len(), path))
            })
            .collect();
        originals.sort();
        let mut held: u64 = originals.iter().map(|(_, size, _)| size).sum();
        let now = SystemTime::now();
        for (handed_out_at, size, path) in originals {
            let recent = now
                .duration_since(handed_out_at)
                .map_or(true, |age| age < RECENT_OPENING);
            if held <= limit || recent {
                return;
            }
            if std::fs::remove_file(path).is_ok() {
                held -= size;
            }
        }
    }
}

/// The files of a directory, or none for a directory that is not there.
fn files_in(directory: &Path) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .filter_map(|entry| Some(entry.ok()?.path()))
}

fn is_partial(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension == PARTIAL_EXTENSION)
}

/// Whether the file is there. Its modification time then says that it was handed out now.
fn handed_out(path: &Path) -> bool {
    File::open(path)
        .and_then(|file| file.set_modified(SystemTime::now()))
        .is_ok()
}

/// Writes what `download` receives to `partial`. An original is kept only when its bytes are the
/// content the record names, and it is made read-only, because the file a person opens is the
/// one every later reading shows.
fn write_download(
    partial: &Path,
    content: Option<ContentDigest>,
    download: impl FnOnce(&mut dyn Write) -> Result<bool, RepresentationRefusal>,
) -> Result<bool, RepresentationRefusal> {
    if let Some(directory) = partial.parent() {
        std::fs::create_dir_all(directory).map_err(storage_failed)?;
    }
    let mut destination = DigestingFile {
        file: File::create(partial).map_err(storage_failed)?,
        digest: Sha256::new(),
    };
    if !download(&mut destination)? {
        return Ok(false);
    }
    let DigestingFile { file, digest } = destination;
    if content.is_some_and(|content| content != ContentDigest::from_bytes(digest.finalize().into())) {
        return Err(RepresentationRefusal::ContentDiffers);
    }
    let mut permissions = file.metadata().map_err(storage_failed)?.permissions();
    permissions.set_readonly(true);
    file.set_permissions(permissions).map_err(storage_failed)?;
    Ok(true)
}
