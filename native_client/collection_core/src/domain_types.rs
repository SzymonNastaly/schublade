//! The identities the machines share: times, content digests, folders, directories, entry names,
//! file signatures, documents, and the one timing policy. Every value here is a plain datum;
//! nothing reads a clock, a file, or the network.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::Duration;

use unicode_normalization::UnicodeNormalization;

/// Milliseconds since the Unix epoch. Every time enters the machines as a field of an event;
/// no pure function reads a clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize)]
pub struct Timestamp(pub i64);

impl Timestamp {
    pub fn after(self, duration: Duration) -> Timestamp {
        Timestamp(
            self.0
                .saturating_add(i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)),
        )
    }

    /// Zero when `earlier` lies after `self`, so a wall clock that moved backwards never makes an
    /// interval look elapsed.
    pub fn elapsed_since(self, earlier: Timestamp) -> Duration {
        Duration::from_millis(u64::try_from(self.0.saturating_sub(earlier.0)).unwrap_or(0))
    }
}

/// The SHA-256 of one exact byte sequence, the name of a content in the archive and here.
/// Parsed from lowercase hexadecimal only at the boundaries (the store and the archive client).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ContentDigest([u8; 32]);

impl ContentDigest {
    pub fn from_bytes(bytes: [u8; 32]) -> ContentDigest {
        ContentDigest(bytes)
    }

    /// Accepts exactly 64 lowercase hexadecimal characters, as the server's `sha256Pattern`.
    pub fn parse_hexadecimal(text: &str) -> Option<ContentDigest> {
        if text.len() != 64 {
            return None;
        }
        let mut bytes = [0u8; 32];
        for (index, pair) in text.as_bytes().chunks(2).enumerate() {
            let high = lowercase_hexadecimal_value(pair[0])?;
            let low = lowercase_hexadecimal_value(pair[1])?;
            bytes[index] = high << 4 | low;
        }
        Some(ContentDigest(bytes))
    }

    pub fn hexadecimal(&self) -> String {
        self.0.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

fn lowercase_hexadecimal_value(character: u8) -> Option<u8> {
    match character {
        b'0'..=b'9' => Some(character - b'0'),
        b'a'..=b'f' => Some(character - b'a' + 10),
        _ => None,
    }
}

impl std::fmt::Debug for ContentDigest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "ContentDigest({})", self.hexadecimal())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub struct FolderIdentifier(i64);

impl FolderIdentifier {
    pub const fn new(value: i64) -> FolderIdentifier {
        FolderIdentifier(value)
    }

    pub fn value(self) -> i64 {
        self.0
    }
}

/// A directory relative to its folder root, '/'-separated, in Unicode normalization form C.
/// The root itself is the empty key. Watcher paths and walker paths normalize to the same key,
/// so a decomposed name from FSEvents finds the rows the walker wrote.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DirectoryKey(String);

impl DirectoryKey {
    pub fn root() -> DirectoryKey {
        DirectoryKey(String::new())
    }

    /// Only the store builds a key from its stored text.
    pub fn from_stored_text(text: String) -> DirectoryKey {
        DirectoryKey(text)
    }

    /// Normalizes each component to NFC. Components that are not UTF-8 (Linux only) are escaped
    /// byte by byte so the key stays a lossless function of the path.
    pub fn from_relative_path(relative: &Path) -> DirectoryKey {
        relative.components().fold(DirectoryKey::root(), |key, component| {
            key.child_named(component.as_os_str())
        })
    }

    pub fn child(&self, name: &EntryName) -> DirectoryKey {
        self.child_named(name.as_os_str())
    }

    fn child_named(&self, name: &OsStr) -> DirectoryKey {
        let component = normalize_component(name);
        if self.is_root() {
            DirectoryKey(component)
        } else {
            DirectoryKey(format!("{}/{component}", self.0))
        }
    }

    pub fn is_root(&self) -> bool {
        self.0.is_empty()
    }

    /// True for this key and every key below it.
    pub fn contains(&self, other: &DirectoryKey) -> bool {
        self.is_root()
            || other == self
            || (other.0.starts_with(&self.0) && other.0.as_bytes().get(self.0.len()) == Some(&b'/'))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The path below the folder root that this key names. Escaped bytes are restored, so a
    /// non-UTF-8 name round-trips; a normalized name reaches the file system in NFC, which the
    /// macOS file systems treat as the same name.
    pub fn relative_path(&self) -> PathBuf {
        self.0
            .split('/')
            .filter(|component| !component.is_empty())
            .map(|component| os_string_from_bytes(unescape_component(component)))
            .collect()
    }
}

/// A `%` is escaped in every component, so an escaped byte of a non-UTF-8 name can never read
/// as a name that holds a literal `%`.
fn normalize_component(name: &OsStr) -> String {
    match name.to_str() {
        Some(text) => text.nfc().collect::<String>().replace('%', "%25"),
        None => os_str_bytes(name).iter().map(|byte| format!("%{byte:02X}")).collect(),
    }
}

fn unescape_component(component: &str) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(component.len());
    let mut remaining = component.as_bytes();
    while let Some((&first, rest)) = remaining.split_first() {
        match (first, rest.get(..2).and_then(|pair| std::str::from_utf8(pair).ok())) {
            (b'%', Some(pair)) if let Ok(byte) = u8::from_str_radix(pair, 16) => {
                bytes.push(byte);
                remaining = &rest[2..];
            }
            _ => {
                bytes.push(first);
                remaining = rest;
            }
        }
    }
    bytes
}

#[cfg(unix)]
fn os_str_bytes(name: &OsStr) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    name.as_bytes().to_vec()
}

#[cfg(not(unix))]
fn os_str_bytes(name: &OsStr) -> Vec<u8> {
    name.to_string_lossy().into_owned().into_bytes()
}

#[cfg(unix)]
fn os_string_from_bytes(bytes: Vec<u8>) -> OsString {
    use std::os::unix::ffi::OsStringExt;
    OsString::from_vec(bytes)
}

#[cfg(not(unix))]
fn os_string_from_bytes(bytes: Vec<u8>) -> OsString {
    String::from_utf8_lossy(&bytes).into_owned().into()
}

/// The exact name `readdir` returned. It is never normalized, because `open` needs it as is.
/// Existence is judged by the parent's listing containing this name, never by `stat`, so a
/// case-only rename on a case-insensitive volume removes the old row.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EntryName(OsString);

impl EntryName {
    pub fn new(name: impl Into<OsString>) -> EntryName {
        EntryName(name.into())
    }

    pub fn as_os_str(&self) -> &OsStr {
        &self.0
    }

    /// The exact bytes, as the store keeps them.
    pub fn to_bytes(&self) -> Vec<u8> {
        os_str_bytes(&self.0)
    }

    pub fn from_bytes(bytes: Vec<u8>) -> EntryName {
        EntryName(os_string_from_bytes(bytes))
    }
}

/// The identity of a path observation: the primary key of `path_observations`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PathKey {
    pub folder: FolderIdentifier,
    pub directory: DirectoryKey,
    pub name: EntryName,
}

/// What `lstat` says about a regular file. Two equal signatures mean "unchanged" for every
/// purpose of the collector. The status change time catches a rewrite that restores size and
/// modification time. The dataless flag (macOS `SF_DATALESS` in `st_flags`, always false
/// elsewhere) is part of the signature, so an iCloud file that finishes downloading in place is
/// examined again.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FileSignature {
    pub device: u64,
    pub inode: u64,
    pub byte_size: u64,
    pub modification_nanoseconds: i64,
    pub status_change_nanoseconds: i64,
    pub dataless: bool,
}

/// A UUID as the archive writes it, validated against the server's pattern at the boundary.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub struct DocumentIdentifier(String);

impl DocumentIdentifier {
    /// Accepts `8-4-4-4-12` lowercase hexadecimal groups, as the server's route pattern.
    pub fn parse(text: &str) -> Option<DocumentIdentifier> {
        const GROUP_LENGTHS: [usize; 5] = [8, 4, 4, 4, 12];
        let groups: Vec<&str> = text.split('-').collect();
        let well_formed = groups.len() == GROUP_LENGTHS.len()
            && groups.iter().zip(GROUP_LENGTHS).all(|(group, length)| {
                group.len() == length && group.bytes().all(|byte| lowercase_hexadecimal_value(byte).is_some())
            });
        well_formed.then(|| DocumentIdentifier(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The statuses the archive reports, in the order of the server's `documentStatuses`. `Failed`
/// carries the archive's reason.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum DocumentStatus {
    AwaitingRendering,
    Processing,
    Extracting,
    RecognizingText,
    Classifying,
    Archived,
    Failed { failure_reason: Option<String> },
}

impl DocumentStatus {
    /// The status as the server writes it.
    pub fn parse(status: &str, failure_reason: Option<String>) -> Option<DocumentStatus> {
        Some(match status {
            "awaiting_rendering" => DocumentStatus::AwaitingRendering,
            "processing" => DocumentStatus::Processing,
            "extracting" => DocumentStatus::Extracting,
            "recognizing_text" => DocumentStatus::RecognizingText,
            "classifying" => DocumentStatus::Classifying,
            "archived" => DocumentStatus::Archived,
            "failed" => DocumentStatus::Failed { failure_reason },
            _ => return None,
        })
    }

    pub fn name(&self) -> &'static str {
        match self {
            DocumentStatus::AwaitingRendering => "awaiting_rendering",
            DocumentStatus::Processing => "processing",
            DocumentStatus::Extracting => "extracting",
            DocumentStatus::RecognizingText => "recognizing_text",
            DocumentStatus::Classifying => "classifying",
            DocumentStatus::Archived => "archived",
            DocumentStatus::Failed { .. } => "failed",
        }
    }

    pub fn is_final(&self) -> bool {
        matches!(self, DocumentStatus::Archived | DocumentStatus::Failed { .. })
    }
}

/// Every interval the machines and the planner use. One value, so tests can shorten all of them
/// together.
#[derive(Clone, Debug)]
pub struct TimingPolicy {
    /// Two listings this far apart with one signature make a path Stable.
    pub stabilization_interval: Duration,
    /// An `absent` answer authorizes a submission for this long.
    pub lookup_validity: Duration,
    /// An Unreadable path is read again after this long without a change.
    pub unreadable_retry_interval: Duration,
    /// A recursive listing of every available folder.
    pub full_walk_interval: Duration,
    /// Directory hints from the watcher wait this long to coalesce.
    pub hint_coalescing_interval: Duration,
    /// `StatusChanged` is emitted at most this often.
    pub status_coalescing_interval: Duration,
    /// Documents received this recently are followed until their status is final.
    pub document_follow_window: Duration,
    pub document_follow_interval: Duration,
    /// Successive delays after a submission failure; the last one repeats.
    pub submission_back_off: &'static [Duration],
    /// Successive probe delays while Unreachable; the last one repeats.
    pub connection_back_off: &'static [Duration],
}

pub const SUBMISSION_BACK_OFF: &[Duration] = &[
    Duration::from_secs(60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(30 * 60),
    Duration::from_secs(2 * 60 * 60),
    Duration::from_secs(6 * 60 * 60),
    Duration::from_secs(24 * 60 * 60),
];

pub const CONNECTION_BACK_OFF: &[Duration] = &[
    Duration::from_secs(15),
    Duration::from_secs(30),
    Duration::from_secs(60),
    Duration::from_secs(2 * 60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(15 * 60),
];

impl Default for TimingPolicy {
    /// The production intervals of the design.
    fn default() -> TimingPolicy {
        TimingPolicy {
            stabilization_interval: Duration::from_secs(5),
            lookup_validity: Duration::from_secs(10 * 60),
            unreadable_retry_interval: Duration::from_secs(30 * 60),
            full_walk_interval: Duration::from_secs(30 * 60),
            hint_coalescing_interval: Duration::from_millis(500),
            status_coalescing_interval: Duration::from_millis(250),
            document_follow_window: Duration::from_secs(2 * 60 * 60),
            document_follow_interval: Duration::from_secs(30),
            submission_back_off: SUBMISSION_BACK_OFF,
            connection_back_off: CONNECTION_BACK_OFF,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_content_digest_round_trips_through_lowercase_hexadecimal_only() {
        let text = "b60d823ff8fc9d5e3f8979eb7be7fd57d31bcb959dcc0ec5260c4daf6ec98150";
        let digest = ContentDigest::parse_hexadecimal(text).unwrap();
        assert_eq!(digest.hexadecimal(), text);
        assert_eq!(format!("{digest:?}"), format!("ContentDigest({text})"));
        assert_eq!(ContentDigest::parse_hexadecimal(&text.to_uppercase()), None);
        assert_eq!(ContentDigest::parse_hexadecimal(&text[..63]), None);
        assert_eq!(ContentDigest::parse_hexadecimal(&format!("{text}0")), None);
    }

    #[test]
    fn a_document_identifier_follows_the_route_pattern_of_the_server() {
        assert!(DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f60718293").is_some());
        assert_eq!(DocumentIdentifier::parse("4C5D6E7F-8091-4A2B-9C3D-4E5F60718293"), None);
        assert_eq!(DocumentIdentifier::parse("4c5d6e7f80914a2b9c3d4e5f60718293"), None);
        assert_eq!(DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f6071829"), None);
    }

    #[test]
    fn directory_keys_normalize_to_nfc_and_judge_containment_by_whole_components() {
        let decomposed = DirectoryKey::from_relative_path(Path::new("Vertra\u{0308}ge/2026"));
        let composed = DirectoryKey::root()
            .child(&EntryName::new("Vertr\u{00E4}ge"))
            .child(&EntryName::new("2026"));
        assert_eq!(decomposed, composed);
        assert_eq!(composed.as_str(), "Verträge/2026");

        let parent = DirectoryKey::from_relative_path(Path::new("Scans"));
        assert!(DirectoryKey::root().contains(&parent));
        assert!(parent.contains(&parent));
        assert!(parent.contains(&DirectoryKey::from_relative_path(Path::new("Scans/2026"))));
        assert!(!parent.contains(&DirectoryKey::from_relative_path(Path::new("Scans2"))));
        assert!(!parent.contains(&DirectoryKey::root()));
    }

    #[cfg(unix)]
    #[test]
    fn a_name_that_is_not_utf8_gets_a_lossless_escaped_key() {
        use std::os::unix::ffi::OsStrExt;
        let invalid = EntryName::new(OsStr::from_bytes(b"caf\xE9").to_os_string());
        let literal_percent = EntryName::new("caf%E9");
        assert_eq!(DirectoryKey::root().child(&invalid).as_str(), "%63%61%66%E9");
        assert_eq!(DirectoryKey::root().child(&literal_percent).as_str(), "caf%25E9");
        let nested = DirectoryKey::root().child(&invalid).child(&literal_percent);
        assert_eq!(
            nested.relative_path(),
            PathBuf::from(OsStr::from_bytes(b"caf\xE9")).join("caf%E9")
        );
        assert_eq!(DirectoryKey::root().relative_path(), PathBuf::new());
    }

    #[test]
    fn a_timestamp_never_reports_a_negative_elapsed_interval() {
        let earlier = Timestamp(1_000);
        let later = earlier.after(Duration::from_millis(2_500));
        assert_eq!(later, Timestamp(3_500));
        assert_eq!(later.elapsed_since(earlier), Duration::from_millis(2_500));
        assert_eq!(earlier.elapsed_since(later), Duration::ZERO);
    }

    #[test]
    fn document_statuses_parse_as_the_server_writes_them() {
        let failed = DocumentStatus::parse("failed", Some("unreadable_file".to_owned())).unwrap();
        assert_eq!(
            failed,
            DocumentStatus::Failed {
                failure_reason: Some("unreadable_file".to_owned())
            }
        );
        assert!(failed.is_final());
        assert_eq!(
            DocumentStatus::parse("recognizing_text", None),
            Some(DocumentStatus::RecognizingText)
        );
        assert!(!DocumentStatus::RecognizingText.is_final());
        assert_eq!(DocumentStatus::parse("deleted", None), None);
        assert_eq!(DocumentStatus::Archived.name(), "archived");
    }
}
