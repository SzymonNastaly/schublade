//! What the collector reads from disk: the listing of a directory into signatures, the digest of
//! a file read in blocks, the whole read of a submission source, and the watcher that turns file
//! system events into directory hints. Nothing here decides state; every result goes back to the
//! coordinator as a message.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::{File, Metadata};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use notify::{RecursiveMode, Watcher};
use sha2::{Digest, Sha256};

use crate::candidate_classification::{
    EntryKind, LEADING_BYTES_LENGTH, MAXIMUM_CONTENT_BYTES, NameDisposition, ReadableSignature, classify_entry_name,
    identify_content_kind,
};
use crate::clock::Clock;
use crate::directory_reconciliation::{DirectoryListing, ListingOutcome};
use crate::domain_types::{ContentDigest, DirectoryKey, EntryName, FileSignature, FolderIdentifier, Timestamp};
use crate::path_lifecycle::DigestFinding;

/// The SHA-256 of bytes held in memory.
pub fn content_digest_of(bytes: &[u8]) -> ContentDigest {
    ContentDigest::from_bytes(Sha256::digest(bytes).into())
}

/// The bytes of a source, read whole, whose digest was computed from exactly these bytes. The
/// source read proves them against the authorized digest and the file's signature before and
/// after the read; this type keeps bytes and digest together so a PUT can never send other bytes
/// than the digest names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VerifiedContent {
    digest: ContentDigest,
    bytes: Vec<u8>,
}

impl VerifiedContent {
    pub fn from_bytes(bytes: Vec<u8>) -> VerifiedContent {
        VerifiedContent {
            digest: content_digest_of(&bytes),
            bytes,
        }
    }

    pub fn digest(&self) -> ContentDigest {
        self.digest
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

/// The place of an entry on disk, from the folder root, the directory key, and the exact name.
pub fn absolute_path(root: &Path, directory: &DirectoryKey, name: &OsStr) -> PathBuf {
    root.join(directory.relative_path()).join(name)
}

/// `SF_DATALESS` in `st_flags`: the file's bytes live in iCloud and open would download them.
#[cfg(target_os = "macos")]
fn is_dataless(metadata: &Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    const SF_DATALESS: u32 = 0x4000_0000;
    metadata.st_flags() & SF_DATALESS != 0
}

#[cfg(not(target_os = "macos"))]
fn is_dataless(_metadata: &Metadata) -> bool {
    false
}

#[cfg(unix)]
fn signature_of(metadata: &Metadata) -> FileSignature {
    use std::os::unix::fs::MetadataExt;
    const NANOSECONDS_PER_SECOND: i64 = 1_000_000_000;
    FileSignature {
        device: metadata.dev(),
        inode: metadata.ino(),
        byte_size: metadata.size(),
        modification_nanoseconds: metadata.mtime() * NANOSECONDS_PER_SECOND + metadata.mtime_nsec(),
        status_change_nanoseconds: metadata.ctime() * NANOSECONDS_PER_SECOND + metadata.ctime_nsec(),
        dataless: is_dataless(metadata),
    }
}

fn kind_of(metadata: &Metadata) -> EntryKind {
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        EntryKind::SymbolicLink
    } else if file_type.is_dir() {
        EntryKind::Directory
    } else if file_type.is_file() {
        EntryKind::RegularFile
    } else {
        EntryKind::Special
    }
}

/// `lstat` without following links. `Ok(None)` means the path does not exist.
pub fn observe_signature(path: &Path) -> std::io::Result<Option<FileSignature>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(signature_of(&metadata))),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// Lists one directory, or a subtree, below the root of a folder. Entries go through
/// `classify_entry_name`; disregarded directories are not descended, and symbolic links are never
/// followed. One `DirectoryListing` per directory reaches the sink, so a large tree never sits in
/// memory at once.
pub fn list_directory(
    folder: FolderIdentifier,
    root: &Path,
    directory: &DirectoryKey,
    recursive: bool,
    clock: &dyn Clock,
    sink: &mut dyn FnMut(DirectoryListing),
) {
    let absolute = root.join(directory.relative_path());
    let (outcome, subdirectories) = match std::fs::read_dir(&absolute) {
        Ok(entries) => {
            let listed = read_entries(entries);
            let subdirectories = if recursive {
                listed.subdirectories.iter().map(|name| directory.child(name)).collect()
            } else {
                Vec::new()
            };
            (
                ListingOutcome::Listed {
                    files: listed.files,
                    subdirectories: listed.subdirectories,
                    disregarded: listed.disregarded,
                },
                subdirectories,
            )
        }
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            (ListingOutcome::Vanished, Vec::new())
        }
        Err(error) => (
            ListingOutcome::Unreadable {
                cause: error.to_string(),
            },
            Vec::new(),
        ),
    };
    sink(DirectoryListing {
        folder,
        directory: directory.clone(),
        outcome,
        listed_at: clock.now(),
    });
    for subdirectory in subdirectories {
        list_directory(folder, root, &subdirectory, true, clock, sink);
    }
}

#[derive(Default)]
struct ListedEntries {
    files: Vec<(EntryName, FileSignature)>,
    subdirectories: Vec<EntryName>,
    disregarded: BTreeMap<crate::candidate_classification::DisregardReason, u64>,
}

/// An entry that vanishes between `readdir` and `lstat` is left out; the next listing tells.
fn read_entries(entries: std::fs::ReadDir) -> ListedEntries {
    let mut listed = ListedEntries::default();
    for entry in entries.flatten() {
        let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        let name = EntryName::new(entry.file_name());
        let kind = kind_of(&metadata);
        match classify_entry_name(&name, kind) {
            NameDisposition::Disregarded(reason) => *listed.disregarded.entry(reason).or_default() += 1,
            NameDisposition::Admitted if kind == EntryKind::Directory => listed.subdirectories.push(name),
            NameDisposition::Admitted => listed.files.push((name, signature_of(&metadata))),
        }
    }
    listed.files.sort_by(|(left, _), (right, _)| left.cmp(right));
    listed.subdirectories.sort();
    listed
}

const BLOCK_BYTES: usize = 64 * 1024;

/// What a fresh `lstat` says next to the signature a read is based on.
enum SignatureCheck {
    Unchanged,
    Changed(Option<FileSignature>),
    Refused(std::io::Error),
}

fn check_signature(path: &Path, based_on: &ReadableSignature) -> SignatureCheck {
    match observe_signature(path) {
        Ok(Some(current)) if current == *based_on.signature() => SignatureCheck::Unchanged,
        Ok(current) => SignatureCheck::Changed(current),
        Err(error) => SignatureCheck::Refused(error),
    }
}

/// Reads a file whose signature equals `based_on` before and after the read. `Ok(None)` means the
/// signature differed or the file vanished, with what `lstat` found. Up to `MAXIMUM_CONTENT_BYTES`
/// are read, each block passed to `consume`, which returns false to stop early.
fn read_within_signature(
    path: &Path,
    based_on: &ReadableSignature,
    consume: &mut dyn FnMut(&[u8]) -> bool,
) -> std::io::Result<Option<Option<FileSignature>>> {
    if let SignatureCheck::Changed(current) = check_signature(path, based_on) {
        return Ok(Some(current));
    }
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Some(None)),
        Err(error) => return Err(error),
    };
    let mut block = vec![0u8; BLOCK_BYTES];
    let mut total: u64 = 0;
    loop {
        let read = file.read(&mut block)?;
        if read == 0 {
            break;
        }
        total += read as u64;
        if total > MAXIMUM_CONTENT_BYTES || !consume(&block[..read]) {
            break;
        }
    }
    drop(file);
    match check_signature(path, based_on) {
        SignatureCheck::Unchanged => Ok(None),
        SignatureCheck::Changed(current) => Ok(Some(current)),
        SignatureCheck::Refused(error) => Err(error),
    }
}

/// Sequence: `lstat` and compare with `based_on` (else Changed, nothing opened); open; read the
/// leading bytes and identify the kind (else Unrecognized, the rest unread); stream the rest
/// through SHA-256 in 64 KiB blocks; `lstat` again and compare (else Changed). A dataless
/// placeholder never reaches `open`, because no `ReadableSignature` is dataless and a signature
/// that gained the flag differs.
pub fn compute_digest(absolute: &Path, based_on: &ReadableSignature) -> DigestFinding {
    let mut digest = Sha256::new();
    let mut leading = Vec::with_capacity(LEADING_BYTES_LENGTH);
    let mut recognized = true;
    let mut read_so_far: u64 = 0;
    let read = read_within_signature(absolute, based_on, &mut |block| {
        read_so_far += block.len() as u64;
        if leading.len() < LEADING_BYTES_LENGTH {
            leading.extend_from_slice(&block[..block.len().min(LEADING_BYTES_LENGTH - leading.len())]);
            let leading_complete =
                leading.len() == LEADING_BYTES_LENGTH || read_so_far >= based_on.signature().byte_size;
            if leading_complete && identify_content_kind(&leading).is_none() {
                recognized = false;
                return false;
            }
        }
        digest.update(block);
        true
    });
    match read {
        Ok(None) if recognized => DigestFinding::Digested {
            content: ContentDigest::from_bytes(digest.finalize().into()),
        },
        Ok(None) => DigestFinding::Unrecognized,
        Ok(Some(current)) => DigestFinding::Changed { current },
        Err(error) => DigestFinding::ReadRefused {
            cause: error.to_string(),
        },
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct SourceVerificationFailure {
    /// What `lstat` found, or `None` when the file vanished.
    pub current: Option<FileSignature>,
    pub at: Timestamp,
}

/// The same before-and-after signature checks as `compute_digest`, with the whole file in memory
/// (at most 25 MB) and its digest compared with `expected`. Other bytes under the same signature
/// fail as if the signature had changed, so the path is examined again.
pub fn read_submission_source(
    absolute: &Path,
    based_on: &ReadableSignature,
    expected: ContentDigest,
    clock: &dyn Clock,
) -> Result<VerifiedContent, SourceVerificationFailure> {
    let failure = |current| SourceVerificationFailure {
        current,
        at: clock.now(),
    };
    let mut bytes = Vec::with_capacity(usize::try_from(based_on.signature().byte_size).unwrap_or(0));
    match read_within_signature(absolute, based_on, &mut |block| {
        bytes.extend_from_slice(block);
        true
    }) {
        Ok(None) => {}
        Ok(Some(current)) => return Err(failure(current)),
        Err(_) => return Err(failure(observe_signature(absolute).ok().flatten())),
    }
    let content = VerifiedContent::from_bytes(bytes);
    if content.digest() != expected {
        return Err(failure(Some(*based_on.signature())));
    }
    Ok(content)
}

/// A directory the watcher says changed. Hints only name directories; the coordinator coalesces
/// them and plans listings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectoryHint {
    pub folder: FolderIdentifier,
    pub directory: DirectoryKey,
    /// FSEvents' rescan flag: the whole folder is listed again.
    pub recursive: bool,
}

/// Owns the `notify` watcher. Maps each event path to its folder and the directory that holds
/// it, so an event on an entry names the directory to list again and nothing else.
pub struct FolderWatcher {
    watcher: notify::RecommendedWatcher,
    roots: Arc<Mutex<BTreeMap<PathBuf, FolderIdentifier>>>,
}

impl FolderWatcher {
    pub fn new(hints: impl Fn(DirectoryHint) + Send + 'static) -> notify::Result<FolderWatcher> {
        let roots: Arc<Mutex<BTreeMap<PathBuf, FolderIdentifier>>> = Arc::default();
        let watched = Arc::clone(&roots);
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else {
                return;
            };
            let roots = watched.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            for hint in hints_of(&event, &roots) {
                hints(hint);
            }
        })?;
        Ok(FolderWatcher { watcher, roots })
    }

    /// Fails while the root is missing; the coordinator tries again at each walk. Events are
    /// matched against the root as given and as canonicalized, because FSEvents reports real
    /// paths (`/private/var/...` for a root named `/var/...`) while inotify reports the watched one.
    pub fn watch(&mut self, folder: FolderIdentifier, root: &Path) -> notify::Result<()> {
        self.watcher.watch(root, RecursiveMode::Recursive)?;
        let mut roots = self.roots.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for spelling in root_spellings(root) {
            roots.insert(spelling, folder);
        }
        Ok(())
    }

    pub fn unwatch(&mut self, root: &Path) {
        let mut roots = self.roots.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        for spelling in root_spellings(root) {
            roots.remove(&spelling);
        }
        drop(roots);
        let _ = self.watcher.unwatch(root);
    }
}

fn root_spellings(root: &Path) -> Vec<PathBuf> {
    let mut spellings = vec![root.to_path_buf()];
    if let Ok(canonical) = root.canonicalize()
        && canonical != root
    {
        spellings.push(canonical);
    }
    spellings
}

/// The directory to list for each event path: the path itself when it is a watched root, else
/// its parent. A rescan flag lists every watched folder recursively.
fn hints_of(event: &notify::Event, roots: &BTreeMap<PathBuf, FolderIdentifier>) -> Vec<DirectoryHint> {
    if event.need_rescan() {
        return roots
            .values()
            .map(|folder| DirectoryHint {
                folder: *folder,
                directory: DirectoryKey::root(),
                recursive: true,
            })
            .collect();
    }
    // A read of a file (inotify reports opens and closes) changes no listing.
    if matches!(event.kind, notify::EventKind::Access(_)) {
        return Vec::new();
    }
    let mut hints = Vec::new();
    for path in &event.paths {
        let Some((root, folder)) = roots.iter().find(|(root, _)| path.starts_with(root)) else {
            continue;
        };
        let directory = match path.strip_prefix(root).ok().and_then(Path::parent) {
            Some(parent) => DirectoryKey::from_relative_path(parent),
            None => DirectoryKey::root(),
        };
        let hint = DirectoryHint {
            folder: *folder,
            directory,
            recursive: false,
        };
        if !hints.contains(&hint) {
            hints.push(hint);
        }
    }
    hints
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::mpsc;
    use std::time::Duration;

    use super::*;
    use crate::candidate_classification::{DisregardReason, classify_signature};
    use crate::clock::ManualClock;

    const FOLDER: FolderIdentifier = FolderIdentifier::new(4);

    fn name(text: &str) -> EntryName {
        EntryName::new(text)
    }

    fn readable(path: &Path) -> ReadableSignature {
        classify_signature(observe_signature(path).unwrap().unwrap()).unwrap()
    }

    fn write(path: &Path, bytes: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn the_digest_is_the_sha256_of_the_bytes() {
        let content = VerifiedContent::from_bytes(b"Hello".to_vec());
        assert_eq!(
            content.digest().hexadecimal(),
            "185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969"
        );
        assert_eq!(content.bytes(), b"Hello");
    }

    #[test]
    fn a_recursive_listing_reports_admitted_entries_per_directory_and_counts_the_rest() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        write(&root.join("Invoice.pdf"), b"%PDF-1.7 invoice");
        write(&root.join(".DS_Store"), b"");
        write(&root.join("Unconfirmed 1.crdownload"), b"partial");
        write(&root.join("Kontoauszug.pdf.download/Info.plist"), b"<plist/>");
        write(&root.join("Scans/scan_0001.pdf"), b"%PDF-1.7 scan");
        write(&root.join("Scans/2025/scan_0002.pdf"), b"%PDF-1.7 older scan");
        #[cfg(unix)]
        std::os::unix::fs::symlink(root.join("Invoice.pdf"), root.join("Link.pdf")).unwrap();
        let clock = ManualClock::starting_at(Timestamp(500));

        let mut listings = Vec::new();
        list_directory(FOLDER, root, &DirectoryKey::root(), true, &clock, &mut |listing| {
            listings.push(listing)
        });

        let directories: Vec<&str> = listings.iter().map(|listing| listing.directory.as_str()).collect();
        assert_eq!(directories, vec!["", "Scans", "Scans/2025"]);
        let ListingOutcome::Listed {
            files,
            subdirectories,
            disregarded,
        } = &listings[0].outcome
        else {
            panic!("the root is readable: {:?}", listings[0].outcome)
        };
        assert_eq!(listings[0].listed_at, Timestamp(500));
        let signature = observe_signature(&root.join("Invoice.pdf")).unwrap().unwrap();
        assert_eq!(files, &vec![(name("Invoice.pdf"), signature)]);
        assert_eq!(signature.byte_size, 16);
        assert!(!signature.dataless);
        assert_eq!(subdirectories, &vec![name("Scans")]);
        let mut expected = BTreeMap::from([
            (DisregardReason::HiddenEntry, 1),
            (DisregardReason::IncompleteDownload, 2),
        ]);
        #[cfg(unix)]
        expected.insert(DisregardReason::SymbolicLink, 1);
        assert_eq!(disregarded, &expected);
        let ListingOutcome::Listed { files, .. } = &listings[2].outcome else {
            panic!("Scans/2025 is readable")
        };
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].0, name("scan_0002.pdf"));
    }

    #[test]
    fn a_missing_directory_vanishes_and_only_the_named_directory_is_listed_without_recursion() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        write(&root.join("Scans/scan_0001.pdf"), b"%PDF-1.7 scan");
        write(&root.join("Scans/2025/scan_0002.pdf"), b"%PDF-1.7 older scan");
        let clock = ManualClock::starting_at(Timestamp(1));

        let mut listings = Vec::new();
        let scans = DirectoryKey::from_relative_path(Path::new("Scans"));
        list_directory(FOLDER, root, &scans, false, &clock, &mut |listing| {
            listings.push(listing)
        });
        let gone = DirectoryKey::from_relative_path(Path::new("Gone"));
        list_directory(FOLDER, root, &gone, true, &clock, &mut |listing| listings.push(listing));

        assert_eq!(listings.len(), 2);
        assert!(
            matches!(&listings[0].outcome, ListingOutcome::Listed { subdirectories, .. }
            if subdirectories == &vec![name("2025")])
        );
        assert_eq!(listings[1].directory, gone);
        assert_eq!(listings[1].outcome, ListingOutcome::Vanished);
    }

    #[test]
    fn the_digest_read_recognizes_the_kind_first_and_notices_a_change_or_a_vanished_file() {
        let temporary = tempfile::tempdir().unwrap();
        let invoice = temporary.path().join("Invoice.pdf");
        let bytes: Vec<u8> = b"%PDF-1.7 "
            .iter()
            .copied()
            .chain((0..200_000u32).map(|index| index as u8))
            .collect();
        write(&invoice, &bytes);
        let signature = readable(&invoice);

        assert_eq!(
            compute_digest(&invoice, &signature),
            DigestFinding::Digested {
                content: content_digest_of(&bytes)
            }
        );

        let letter = temporary.path().join("Letter.txt");
        write(&letter, b"Dear reader, this is no document the archive accepts.");
        assert_eq!(compute_digest(&letter, &readable(&letter)), DigestFinding::Unrecognized);

        let short = temporary.path().join("Short.pdf");
        write(&short, b"%PD");
        assert_eq!(compute_digest(&short, &readable(&short)), DigestFinding::Unrecognized);
        let brief = temporary.path().join("Brief.pdf");
        write(&brief, b"%PDF-1");
        assert_eq!(
            compute_digest(&brief, &readable(&brief)),
            DigestFinding::Digested {
                content: content_digest_of(b"%PDF-1")
            }
        );

        let stale = readable(&letter);
        assert_eq!(
            compute_digest(&invoice, &stale),
            DigestFinding::Changed {
                current: Some(*signature.signature())
            }
        );

        std::fs::remove_file(&invoice).unwrap();
        assert_eq!(
            compute_digest(&invoice, &signature),
            DigestFinding::Changed { current: None }
        );
    }

    #[test]
    fn the_source_read_proves_the_bytes_against_the_digest_and_the_signature() {
        let temporary = tempfile::tempdir().unwrap();
        let invoice = temporary.path().join("Invoice.pdf");
        write(&invoice, b"%PDF-1.7 invoice");
        let signature = readable(&invoice);
        let expected = content_digest_of(b"%PDF-1.7 invoice");
        let clock = ManualClock::starting_at(Timestamp(77));

        let verified = read_submission_source(&invoice, &signature, expected, &clock).unwrap();
        assert_eq!(verified.digest(), expected);
        assert_eq!(verified.bytes(), b"%PDF-1.7 invoice");

        let other = content_digest_of(b"other bytes");
        assert_eq!(
            read_submission_source(&invoice, &signature, other, &clock),
            Err(SourceVerificationFailure {
                current: Some(*signature.signature()),
                at: Timestamp(77)
            })
        );

        let mut file = std::fs::OpenOptions::new().append(true).open(&invoice).unwrap();
        file.write_all(b" and more").unwrap();
        drop(file);
        let current = observe_signature(&invoice).unwrap();
        assert_ne!(current, Some(*signature.signature()));
        assert_eq!(
            read_submission_source(&invoice, &signature, expected, &clock),
            Err(SourceVerificationFailure {
                current,
                at: Timestamp(77)
            })
        );

        std::fs::remove_file(&invoice).unwrap();
        assert_eq!(
            read_submission_source(&invoice, &signature, expected, &clock),
            Err(SourceVerificationFailure {
                current: None,
                at: Timestamp(77)
            })
        );
    }

    /// The root is watched through a symbolic link, so the platform may report the link's path
    /// (inotify) or the real one (FSEvents); both must find the folder.
    #[test]
    fn the_watcher_turns_an_event_into_a_hint_naming_the_directory_of_the_entry() {
        let temporary = tempfile::tempdir().unwrap();
        let real = temporary.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let root = temporary.path().join("link");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real, &root).unwrap();
        #[cfg(not(unix))]
        let root = real;
        std::fs::create_dir(root.join("Scans")).unwrap();
        let (sender, receiver) = mpsc::channel();
        let mut watcher = FolderWatcher::new(move |hint| {
            let _ = sender.send(hint);
        })
        .unwrap();
        watcher.watch(FOLDER, &root).unwrap();

        write(&root.join("Scans/scan_0001.pdf"), b"%PDF-1.7 scan");

        // The platform may also report the directory's own change, a hint for the root, so the
        // hints are judged as a set: the entry's directory is among them, and nothing else is.
        let expected = DirectoryHint {
            folder: FOLDER,
            directory: DirectoryKey::from_relative_path(Path::new("Scans")),
            recursive: false,
        };
        let mut hints = Vec::new();
        while !hints.contains(&expected) {
            hints.push(
                receiver
                    .recv_timeout(Duration::from_secs(10))
                    .expect("a hint for the write"),
            );
        }
        assert!(
            hints.iter().all(|hint| {
                hint.folder == FOLDER && !hint.recursive && ["", "Scans"].contains(&hint.directory.as_str())
            }),
            "{hints:?}"
        );

        watcher.unwatch(&root);
        write(&root.join("Invoice.pdf"), b"%PDF-1.7 invoice");
        while let Ok(late) = receiver.recv_timeout(Duration::from_millis(300)) {
            assert_ne!(late.directory.as_str(), "", "no hint for the write after the unwatch");
        }
    }

    #[test]
    fn a_rescan_flag_lists_every_folder_recursively_and_a_path_outside_the_roots_gives_no_hint() {
        let roots = BTreeMap::from([
            (PathBuf::from("/Users/anna/Downloads"), FolderIdentifier::new(1)),
            (PathBuf::from("/Users/anna/Desktop"), FolderIdentifier::new(2)),
        ]);
        let mut event = notify::Event::new(notify::EventKind::Any)
            .add_path(PathBuf::from("/Users/anna/Downloads/Invoice.pdf"))
            .add_path(PathBuf::from("/Users/anna/Downloads/Rechnung.pdf"))
            .add_path(PathBuf::from("/Users/anna/Downloads"))
            .add_path(PathBuf::from("/Users/anna/Documents/Other.pdf"));
        assert_eq!(
            hints_of(&event, &roots),
            vec![DirectoryHint {
                folder: FolderIdentifier::new(1),
                directory: DirectoryKey::root(),
                recursive: false,
            }]
        );
        event = event.set_flag(notify::event::Flag::Rescan);
        let rescan = hints_of(&event, &roots);
        assert_eq!(rescan.len(), 2);
        assert!(rescan.iter().all(|hint| hint.recursive && hint.directory.is_root()));
    }
}
