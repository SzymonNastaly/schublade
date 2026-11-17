//! collection_core, candidate 2: type sketch.
//!
//! One file stands in for the crate. Each `pub mod` below is one file of the module map in
//! design.md. Bodies are `todo!()`; doc comments state intent and invariants. The pure modules
//! (domain_types, candidate_classification, path_lifecycle, content_synchronization,
//! folder_admission, archive_connection, directory_reconciliation, work_planning) import nothing
//! that performs I/O or reads a clock.

#![allow(dead_code, unused_variables)]

// ===================================================================================================
// domain_types.rs
// ===================================================================================================
pub mod domain_types {
    use std::ffi::OsString;

    /// Milliseconds since the Unix epoch. Every time enters the machines as a field of an event;
    /// no pure function reads a clock.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub struct Timestamp(pub i64);

    impl Timestamp {
        pub fn after(self, duration: std::time::Duration) -> Timestamp {
            Timestamp(self.0 + duration.as_millis() as i64)
        }
        /// Zero when `earlier` lies after `self`, so a wall clock that moved backwards never
        /// makes an interval look elapsed.
        pub fn elapsed_since(self, earlier: Timestamp) -> std::time::Duration {
            std::time::Duration::from_millis((self.0 - earlier.0).max(0) as u64)
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
            todo!()
        }
        pub fn hexadecimal(&self) -> String {
            todo!()
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
        pub fn new(value: i64) -> FolderIdentifier {
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
        /// Normalizes each component to NFC. Components that are not UTF-8 (Linux only) are
        /// escaped byte by byte so the key stays a lossless function of the path.
        pub fn from_relative_path(relative: &std::path::Path) -> DirectoryKey {
            todo!()
        }
        pub fn child(&self, name: &EntryName) -> DirectoryKey {
            todo!()
        }
        /// True for this key and every key below it.
        pub fn contains(&self, other: &DirectoryKey) -> bool {
            todo!()
        }
    }

    /// The exact name `readdir` returned. It is never normalized, because `open` needs it as is.
    /// Existence is judged by the parent's listing containing this name, never by `stat`, so a
    /// case-only rename on a case-insensitive volume removes the old row.
    #[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
    pub struct EntryName(OsString);

    impl EntryName {
        pub fn new(name: OsString) -> EntryName {
            EntryName(name)
        }
        pub fn as_os_str(&self) -> &std::ffi::OsStr {
            &self.0
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
    /// elsewhere) is part of the signature, so an iCloud file that finishes downloading in place
    /// is examined again.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub struct FileSignature {
        pub device: u64,
        pub inode: u64,
        pub byte_size: u64,
        pub modification_nanoseconds: i128,
        pub status_change_nanoseconds: i128,
        pub dataless: bool,
    }

    /// A UUID as the archive writes it. Validated against the server's pattern at the boundary.
    #[derive(Clone, Debug, PartialEq, Eq, Hash, serde::Serialize)]
    pub struct DocumentIdentifier(String);

    impl DocumentIdentifier {
        pub fn parse(text: &str) -> Option<DocumentIdentifier> {
            todo!()
        }
        pub fn as_str(&self) -> &str {
            &self.0
        }
    }

    /// The statuses `GET /api/v1/documents/{id}` reports. `Failed` carries the archive's reason.
    #[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
    pub enum DocumentStatus {
        Processing,
        Extracting,
        RecognizingText,
        Classifying,
        Archived,
        Failed { failure_reason: Option<String> },
    }

    impl DocumentStatus {
        pub fn is_final(&self) -> bool {
            matches!(self, DocumentStatus::Archived | DocumentStatus::Failed { .. })
        }
    }

    /// Every interval the machines and the planner use. One value, so tests can shorten all of
    /// them together.
    #[derive(Clone, Debug)]
    pub struct TimingPolicy {
        /// Two listings this far apart with one signature make a path Stable. Default 5 seconds.
        pub stabilization_interval: std::time::Duration,
        /// An `absent` answer authorizes a submission for this long. Default 10 minutes.
        pub lookup_validity: std::time::Duration,
        /// An Unreadable path is read again after this long without a change. Default 30 minutes.
        pub unreadable_retry_interval: std::time::Duration,
        /// A recursive listing of every available folder. Default 30 minutes.
        pub full_walk_interval: std::time::Duration,
        /// Directory hints from the watcher wait this long to coalesce. Default 500 milliseconds.
        pub hint_coalescing_interval: std::time::Duration,
        /// `StatusChanged` is emitted at most this often. Default 250 milliseconds.
        pub status_coalescing_interval: std::time::Duration,
        /// Documents received this recently are followed until their status is final. Default 2 hours.
        pub document_follow_window: std::time::Duration,
        pub document_follow_interval: std::time::Duration,
        /// Successive delays after a submission failure: 1 min, 5 min, 30 min, 2 h, 6 h, then 24 h.
        pub submission_back_off: &'static [std::time::Duration],
        /// Successive probe delays while Unreachable: 15 s, 30 s, 1, 2, 5, then 15 min.
        pub connection_back_off: &'static [std::time::Duration],
    }
}

// ===================================================================================================
// candidate_classification.rs
// ===================================================================================================
pub mod candidate_classification {
    use crate::domain_types::{EntryName, FileSignature};

    /// The server's `MAXIMUM_DOCUMENT_BYTES`, decimal.
    pub const MAXIMUM_CONTENT_BYTES: u64 = 25_000_000;

    /// What `lstat` says an entry is, before anything is opened. Symbolic links are never followed.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum EntryKind {
        RegularFile,
        Directory,
        SymbolicLink,
        Special,
    }

    /// Why an entry gets no row at all. Decided from its name and kind alone.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum DisregardReason {
        HiddenEntry,
        AppleDoubleCompanion,
        /// `.crdownload`, `.part`, and a `.download` package.
        IncompleteDownload,
        PackageDirectory,
        SymbolicLink,
        SpecialFile,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum NameDisposition {
        Admitted,
        Disregarded(DisregardReason),
    }

    /// The one list of name rules. A directory that is disregarded is never descended into.
    pub fn classify_entry_name(name: &EntryName, kind: EntryKind) -> NameDisposition {
        // TODO: order matters only for the reported reason:
        //   symbolic link, special file, `._` prefix, other leading dot,
        //   `.crdownload` / `.part` files and `.download` directories,
        //   directories whose extension is in PACKAGE_EXTENSIONS.
        todo!()
    }

    /// Directories macOS presents as single files. Open question 6 in design.md.
    pub const PACKAGE_EXTENSIONS: &[&str] =
        &["app", "bundle", "download", "framework", "key", "numbers", "pages", "photoslibrary", "plugin", "rtfd"];

    /// Why a path with a row is no candidate. Stored in `path_observations.exclusion_reason`.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum ExclusionReason {
        EmptyFile,
        ExceedsSizeLimit,
        CloudPlaceholder,
        UnrecognizedContent,
    }

    /// A signature that may be opened: not empty, at most `MAXIMUM_CONTENT_BYTES`, not dataless.
    /// Only `classify_signature` constructs it. Every function that opens a file takes one and
    /// compares a fresh `lstat` with it before `open`, so a placeholder is never read and an
    /// oversized video is never hashed.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct ReadableSignature(FileSignature);

    impl ReadableSignature {
        pub fn signature(&self) -> &FileSignature {
            &self.0
        }
    }

    pub fn classify_signature(signature: FileSignature) -> Result<ReadableSignature, ExclusionReason> {
        // TODO: dataless first, then zero bytes, then the size limit.
        todo!()
    }

    /// The kinds the archive accepts, identified by leading bytes exactly as
    /// `identifySourceFile` in src/ingestion/source_file.ts. Open question 5 covers the duplication.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum ContentKind {
        PortableDocument,
        JointPhotographicImage,
        PortableNetworkGraphic,
        WebPicture,
    }

    pub const LEADING_BYTES_LENGTH: usize = 12;

    pub fn identify_content_kind(leading_bytes: &[u8]) -> Option<ContentKind> {
        todo!()
    }
}

// ===================================================================================================
// path_lifecycle.rs
// ===================================================================================================
pub mod path_lifecycle {
    use crate::candidate_classification::{classify_signature, ExclusionReason, ReadableSignature};
    use crate::domain_types::{ContentDigest, FileSignature, Timestamp, TimingPolicy};

    /// The stored state of one path. Every variant is a resting state; "Digesting" is a Stable
    /// path plus a digest reservation held by the coordinator.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum PathState {
        /// The signature last seen and when it was first seen. Stable once the same signature is
        /// listed again `stabilization_interval` later.
        Stabilizing { signature: FileSignature, observed_at: Timestamp },
        /// Unchanged long enough and admissible by metadata; awaits its digest.
        Stable { signature: ReadableSignature },
        /// The path held these bytes when it had this signature. The content row exists.
        Digested { signature: ReadableSignature, content: ContentDigest },
        /// No candidate while the signature holds.
        Excluded { signature: FileSignature, reason: ExclusionReason },
        /// The read was refused (permission, I/O error). Retried on a change or after
        /// `unreadable_retry_interval`.
        Unreadable { signature: ReadableSignature, since: Timestamp, cause: String },
    }

    impl PathState {
        pub fn signature(&self) -> &FileSignature {
            todo!()
        }
    }

    /// What a digest worker found. It always carries the signature its read was based on, so a
    /// result for a signature the path no longer has is recognized as stale.
    #[derive(Clone, Debug)]
    pub enum DigestFinding {
        /// `lstat` before and after the read equalled the reserved signature.
        Digested { content: ContentDigest },
        /// The leading bytes are no accepted kind; the rest was not read.
        Unrecognized,
        /// The signature differed before the read or after it, or the file vanished.
        Changed { current: Option<FileSignature> },
        ReadRefused { cause: String },
    }

    #[derive(Clone, Debug)]
    pub enum PathEvent {
        /// The parent's successful listing contains this entry with this signature.
        Listed { signature: FileSignature, at: Timestamp },
        /// The parent's successful listing lacks this entry. Never produced by a failed listing.
        NotListed,
        DigestFinished { based_on: ReadableSignature, finding: DigestFinding, at: Timestamp },
        /// A submission worker could not read this path back as the digested bytes.
        SourceVerificationFailed { current: Option<FileSignature>, at: Timestamp },
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum PathTransition {
        /// Nothing is written.
        Unchanged,
        /// The row is inserted or replaced with this state.
        Store(PathState),
        /// The row is deleted. Its content row stays.
        Remove,
    }

    /// The whole path machine (design.md, "Path lifecycle"). `current` is None when no row exists.
    ///
    /// Invariants:
    /// - Any signature change from any state leads to Stabilizing with `observed_at = at`.
    /// - A `DigestFinished` or `SourceVerificationFailed` whose `based_on` differs from the
    ///   stored signature is `Unchanged`: the path already moved on.
    /// - An event for a missing row is `Unchanged`, except `Listed`, which creates the row.
    /// - Running the same `Listed` twice yields `Unchanged` the second time unless the
    ///   stabilization interval elapsed in between.
    pub fn advance_path(current: Option<&PathState>, event: PathEvent, timing: &TimingPolicy) -> PathTransition {
        // TODO: the table in design.md. Sketch of the Stabilizing arm:
        //   Listed(s) with s == signature && at.elapsed_since(observed_at) >= interval
        //     => match classify_signature(s) { Ok(r) => Stable(r), Err(reason) => Excluded(s, reason) }
        //   Listed(s) with s != signature => Stabilizing { s, at }
        //   Listed(s) otherwise => Unchanged
        let _ = classify_signature;
        todo!()
    }

    /// When a Stabilizing path should be listed again. The coordinator lists its directory then,
    /// so the second observation never depends on a file-system event.
    pub fn next_observation_due(state: &PathState, timing: &TimingPolicy) -> Option<Timestamp> {
        todo!()
    }
}

// ===================================================================================================
// content_synchronization.rs
// ===================================================================================================
pub mod content_synchronization {
    use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus, Timestamp, TimingPolicy};

    /// What the archive holds for a digest, as far as this collector knows. Resting states only;
    /// "LookingUp" and "Submitting" are content reservations in the coordinator.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum ArchiveStanding {
        Unresolved,
        Absent { looked_up_at: Timestamp, failures: SubmissionFailures },
        Present(PresentDocument),
        /// The owner deleted the document. Terminal: never looked up again, never submitted.
        Deleted,
        /// The archive refused the bytes for good. Terminal.
        Refused(RefusalReason),
    }

    #[derive(Clone, Debug, PartialEq, Eq, Default)]
    pub struct SubmissionFailures {
        pub count: u32,
        pub retry_not_before: Option<Timestamp>,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct PresentDocument {
        pub document: DocumentIdentifier,
        pub status: Option<DocumentStatus>,
        pub status_read_at: Option<Timestamp>,
        /// Set only when this collector's PUT answered 202. Feeds the recent receipts.
        pub received_at: Option<Timestamp>,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum RefusalReason {
        TooLarge,
        UnacceptedKind,
    }

    /// One row of `contents`. `declined_at` is the user's decision and lies outside the archive
    /// machine; `authorize_submission` reads it as a guard.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct ContentRecord {
        pub digest: ContentDigest,
        pub standing: ArchiveStanding,
        pub declined_at: Option<Timestamp>,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum LookupAnswer {
        Absent,
        Present(DocumentIdentifier),
        Deleted,
    }

    /// The domain outcome of a PUT that the archive answered about the content itself.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum SubmissionOutcome {
        /// 202: a new document.
        Accepted { document: DocumentIdentifier, status: DocumentStatus },
        /// 200: the archive held the bytes already.
        AlreadyHeld { document: DocumentIdentifier, status: DocumentStatus },
        /// 413.
        TooLarge,
        /// 415.
        UnacceptedKind,
        /// 422: the body's digest differed from the path's. The bytes were verified locally, so
        /// this is corruption in transit; it counts as a failure and is retried.
        DigestDisagreement,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum SubmissionFailure {
        DigestDisagreement,
        ServerError,
        TimedOut,
    }

    #[derive(Clone, Debug)]
    pub enum ContentEvent {
        LookupAnswered { answer: LookupAnswer, at: Timestamp },
        SubmissionAnswered { outcome: SubmissionOutcome, at: Timestamp },
        SubmissionFailed { failure: SubmissionFailure, at: Timestamp },
        /// `None` is a 404: the document no longer exists.
        DocumentStatusRead { status: Option<DocumentStatus>, at: Timestamp },
    }

    /// The whole content machine (design.md, "Content synchronization").
    ///
    /// Invariants:
    /// - Deleted and Refused never change.
    /// - Present changes only to Present (status) or to Deleted (404, or a lookup that says deleted).
    /// - A failure never leaves Absent and never resets `looked_up_at`.
    /// - An answer for a standing it does not apply to (a late lookup answer for a content that is
    ///   Present meanwhile) leaves the standing as it is.
    pub fn advance_content(current: &ArchiveStanding, event: ContentEvent, timing: &TimingPolicy) -> ArchiveStanding {
        todo!()
    }

    /// Permission for exactly one PUT of one content. Only `authorize_submission` constructs it,
    /// and `ArchiveClient::submit` consumes it. A PUT of a Present, Deleted, Refused, declined, or
    /// stale content therefore does not compile. This is load-bearing: the server revives a deleted
    /// content on PUT (design.md, Problem).
    #[derive(Debug)]
    pub struct SubmissionAuthorization {
        digest: ContentDigest,
        looked_up_at: Timestamp,
    }

    impl SubmissionAuthorization {
        pub fn digest(&self) -> ContentDigest {
            self.digest
        }
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum SubmissionHindrance {
        NotAbsent,
        /// The planner puts the content into the next lookup batch instead.
        LookupStale,
        BackingOff { until: Timestamp },
        Declined,
    }

    pub fn authorize_submission(
        record: &ContentRecord,
        now: Timestamp,
        timing: &TimingPolicy,
    ) -> Result<SubmissionAuthorization, SubmissionHindrance> {
        todo!()
    }

    /// The delay after the n-th consecutive failure, from `timing.submission_back_off`.
    pub fn submission_back_off(failures: u32, timing: &TimingPolicy) -> std::time::Duration {
        todo!()
    }
}

// ===================================================================================================
// folder_admission.rs
// ===================================================================================================
pub mod folder_admission {
    use crate::domain_types::Timestamp;

    /// The consent region of a folder. Stored in `watched_folders.admission`.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
    pub enum FolderAdmission {
        /// Walking, digesting, and looking up; nothing is submitted from this folder.
        Surveying,
        /// The counts are complete; new arrivals still join the backlog.
        AwaitingDecision,
        /// Paths of this folder are submission sources.
        Collecting { decision: BacklogDecision, decided_at: Timestamp },
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
    pub enum BacklogDecision {
        SubmitBacklog,
        /// Marks every content of the folder that is Absent at decision time as declined.
        DeclineBacklog,
    }

    /// The availability region. Never stored; every walk probes the root again.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
    pub enum FolderAvailability {
        Available,
        Missing,
        AccessDenied,
    }

    /// What the store reports about one folder's survey.
    #[derive(Clone, Copy, Debug, Default)]
    pub struct SurveyProgress {
        /// Set by the coordinator when this process finished its first recursive walk.
        pub initial_walk_completed: bool,
        pub paths_stabilizing_or_stable: u64,
        pub contents_unresolved: u64,
    }

    /// Unreadable and Excluded paths never hold the survey back.
    pub fn survey_complete(progress: &SurveyProgress) -> bool {
        progress.initial_walk_completed
            && progress.paths_stabilizing_or_stable == 0
            && progress.contents_unresolved == 0
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum AdmissionRefusal {
        SurveyIncomplete,
        AlreadyDecided,
    }

    /// Surveying to AwaitingDecision, once `survey_complete` holds. Never back.
    pub fn conclude_survey(current: FolderAdmission, progress: &SurveyProgress) -> FolderAdmission {
        todo!()
    }

    /// AwaitingDecision to Collecting. Every other state refuses.
    pub fn decide(
        current: FolderAdmission,
        decision: BacklogDecision,
        at: Timestamp,
    ) -> Result<FolderAdmission, AdmissionRefusal> {
        todo!()
    }

    /// Whether a path in this folder may be a submission source.
    pub fn admits_submission(admission: FolderAdmission, availability: FolderAvailability) -> bool {
        matches!(admission, FolderAdmission::Collecting { .. }) && availability == FolderAvailability::Available
    }
}

// ===================================================================================================
// archive_connection.rs
// ===================================================================================================
pub mod archive_connection {
    use crate::content_synchronization::{ContentEvent, SubmissionFailure};
    use crate::domain_types::{Timestamp, TimingPolicy};

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum ConnectionState {
        Unconfigured,
        Available,
        Unreachable { since: Timestamp, attempt: u32, retry_at: Timestamp },
        /// Half open: exactly one archive request may run, and its answer decides.
        Probing { attempt: u32 },
        /// 503 with Retry-After: the archive still records digests of older documents.
        Deferred { until: Timestamp },
        /// Persisted. Left only by a new token.
        Suspended { reason: SuspensionReason, since: Timestamp },
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
    pub enum SuspensionReason {
        /// 401: the token is unknown or revoked.
        CredentialRefused,
        /// 403: the token lacks the ingest level.
        CredentialInsufficient,
    }

    #[derive(Clone, Debug)]
    pub enum ConnectionEvent {
        Configured,
        /// Any answer that is not one of the conditions below.
        Answered,
        ConnectionFailed { at: Timestamp },
        ServiceUnavailable { retry_after: std::time::Duration, at: Timestamp },
        CredentialRefused { at: Timestamp },
        CredentialInsufficient { at: Timestamp },
        TimerElapsed { at: Timestamp },
        SystemResumed { at: Timestamp },
    }

    /// The whole connection machine (design.md, "Archive connection").
    ///
    /// Invariants:
    /// - Suspended is left only by Configured.
    /// - Answered moves Probing to Available and leaves every other state as it is.
    /// - Unreachable's attempt grows by one per failed probe; the delay is capped.
    pub fn advance_connection(current: &ConnectionState, event: ConnectionEvent, timing: &TimingPolicy) -> ConnectionState {
        todo!()
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum RequestCapacity {
        None,
        /// Probing: one request across the lookup, submission, and status lanes together.
        Single,
        Unlimited,
    }

    pub fn request_capacity(state: &ConnectionState) -> RequestCapacity {
        todo!()
    }

    /// When the coordinator must wake to deliver `TimerElapsed`.
    pub fn next_timer(state: &ConnectionState) -> Option<Timestamp> {
        todo!()
    }

    /// Every way an archive request can fail to produce an answer about its content.
    /// The archive client returns these; it never decides their consequence.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum ArchiveCondition {
        CredentialRefused,
        CredentialInsufficient,
        ServiceUnavailable { retry_after: std::time::Duration },
        ConnectionFailed,
        TimedOut,
        /// 500. On a PUT it counts against the content as well.
        ServerError,
        /// 400, 404 on a route, 405, or a body that does not parse: a bug on one side.
        ProtocolViolation { detail: String },
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum RequestKind {
        Lookup,
        Submission,
        DocumentStatus,
    }

    /// The one table that decides what a condition means (design.md, consequences table).
    /// A PUT timeout and a PUT 500 count against the content so that one file cannot stall the
    /// collector; every condition also updates the connection.
    pub fn consequences(
        condition: &ArchiveCondition,
        request: RequestKind,
        at: Timestamp,
    ) -> (ConnectionEvent, Option<ContentEvent>) {
        let _ = SubmissionFailure::ServerError;
        todo!()
    }
}

// ===================================================================================================
// directory_reconciliation.rs
// ===================================================================================================
pub mod directory_reconciliation {
    use crate::domain_types::{DirectoryKey, EntryName, FileSignature, FolderIdentifier, PathKey, Timestamp};
    use crate::path_lifecycle::{PathEvent, PathState};

    /// The only message through which the file system reaches the state. Produced by the walker,
    /// by listings the coordinator plans (watcher hints, stabilization, rescan flags), and on start.
    #[derive(Clone, Debug)]
    pub struct DirectoryListing {
        pub folder: FolderIdentifier,
        pub directory: DirectoryKey,
        pub outcome: ListingOutcome,
        pub listed_at: Timestamp,
    }

    #[derive(Clone, Debug)]
    pub enum ListingOutcome {
        /// Entries that passed `classify_entry_name`. Disregarded names never appear here.
        Listed { files: Vec<(EntryName, FileSignature)>, subdirectories: Vec<EntryName> },
        /// The directory exists and could not be read. Removes nothing.
        Unreadable { cause: String },
        /// The directory does not exist. Everything stored at and below it is gone.
        Vanished,
    }

    /// The effects of one listing on the stored state.
    #[derive(Clone, Debug, Default)]
    pub struct Reconciliation {
        pub path_events: Vec<(PathKey, PathEvent)>,
        /// Stored rows at or below these keys are deleted (a subdirectory the listing lacks, or
        /// the listed directory itself when it vanished).
        pub removed_subtrees: Vec<DirectoryKey>,
        /// Subdirectories with no stored row below them: the coordinator lists them recursively,
        /// so a directory created while its event was lost is still found.
        pub unexplored_subdirectories: Vec<DirectoryKey>,
    }

    /// Pure and idempotent: reconciling the same listing twice produces events that
    /// `advance_path` turns into `Unchanged`.
    ///
    /// `stored_files` are the rows whose directory is exactly `listing.directory`.
    /// `stored_subdirectories` are the names of child directories that have rows below them.
    pub fn reconcile_directory(
        listing: &DirectoryListing,
        stored_files: &[(EntryName, PathState)],
        stored_subdirectories: &[EntryName],
    ) -> Reconciliation {
        todo!()
    }
}

// ===================================================================================================
// work_planning.rs
// ===================================================================================================
pub mod work_planning {
    use std::collections::{BTreeSet, HashMap};

    use crate::archive_connection::{ConnectionState, RequestCapacity};
    use crate::candidate_classification::ReadableSignature;
    use crate::content_synchronization::{ContentRecord, SubmissionAuthorization};
    use crate::domain_types::{ContentDigest, DirectoryKey, DocumentIdentifier, FolderIdentifier, PathKey, Timestamp, TimingPolicy};

    pub const MAXIMUM_LOOKUP_DIGESTS: usize = 1000;
    pub const MAXIMUM_FOLLOWED_DOCUMENTS: usize = 20;

    /// One unit of I/O for a worker lane. Each carries what it is based on, and its result comes
    /// back as an event through the machine that owns the key.
    #[derive(Debug)]
    pub enum Work {
        ListDirectory { folder: FolderIdentifier, directory: DirectoryKey, recursive: bool },
        ComputeDigest { path: PathKey, signature: ReadableSignature },
        LookUpContents { digests: Vec<ContentDigest> },
        SubmitContent { authorization: SubmissionAuthorization, source: PathKey, signature: ReadableSignature },
        ReadDocumentStatus { content: ContentDigest, document: DocumentIdentifier },
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub enum Lane {
        Listing,
        Digest,
        Lookup,
        Submission,
        DocumentStatus,
    }

    #[derive(Clone, Copy, Debug)]
    pub struct LaneCapacity {
        pub listing: usize,
        pub digest: usize,
        pub lookup: usize,
        /// 1 or 2, from `CollectorSettings::submission_concurrency`.
        pub submission: usize,
        pub document_status: usize,
    }

    /// What content work is in flight. A content holds at most one reservation, so it is never
    /// looked up and submitted at once, and never submitted twice at once.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum ContentReservation {
        LookingUp,
        Submitting,
        FollowingDocument,
    }

    /// Work in flight. Held only in the coordinator's memory and never stored: a crash loses it,
    /// and the planner derives the same work from the stored states.
    #[derive(Debug, Default)]
    pub struct Reservations {
        pub paths: BTreeSet<PathKey>,
        pub contents: HashMap<ContentDigest, ContentReservation>,
        pub directories: BTreeSet<(FolderIdentifier, DirectoryKey)>,
        pub occupied: HashMap<Lane, usize>,
    }

    impl Reservations {
        pub fn free(&self, lane: Lane, capacity: &LaneCapacity) -> usize {
            todo!()
        }
        /// True when no work is in flight. `wait_until_idle` combines it with an empty plan.
        pub fn is_empty(&self) -> bool {
            todo!()
        }
    }

    /// Rows the store returned for planning, each query limited to the free capacity plus the
    /// reserved count of its lane, ordered arrivals first (first observed after the folder's
    /// decision), then backlog by `first_observed_at`.
    #[derive(Debug, Default)]
    pub struct WorkCandidates {
        pub due_directories: Vec<(FolderIdentifier, DirectoryKey, bool)>,
        pub stable_paths: Vec<(PathKey, ReadableSignature)>,
        /// Unresolved contents with any Digested path in an available folder (survey or not),
        /// and Absent contents whose answer is stale and that have an admitted source.
        pub contents_to_look_up: Vec<ContentDigest>,
        /// Absent contents with at least one admitted source, each with its sources in order.
        pub contents_to_submit: Vec<(ContentRecord, Vec<(PathKey, ReadableSignature)>)>,
        pub documents_to_follow: Vec<(ContentDigest, DocumentIdentifier)>,
    }

    /// Pure. Never returns work for a reserved key or beyond a lane's capacity or the connection's
    /// capacity. Calls `authorize_submission` for each submission; a stale content goes into the
    /// lookup batch instead. Returns the same plan for the same inputs.
    pub fn plan_work(
        candidates: WorkCandidates,
        reservations: &Reservations,
        capacity: &LaneCapacity,
        connection: &ConnectionState,
        now: Timestamp,
        timing: &TimingPolicy,
    ) -> Vec<Work> {
        let _ = RequestCapacity::None;
        todo!()
    }
}

// ===================================================================================================
// state_store.rs
// ===================================================================================================
pub mod state_store {
    use std::path::{Path, PathBuf};

    use crate::archive_connection::SuspensionReason;
    use crate::content_synchronization::{ArchiveStanding, ContentRecord};
    use crate::directory_reconciliation::Reconciliation;
    use crate::domain_types::{ContentDigest, DirectoryKey, EntryName, FolderIdentifier, PathKey, Timestamp, TimingPolicy};
    use crate::folder_admission::{FolderAdmission, SurveyProgress};
    use crate::path_lifecycle::{PathState, PathTransition};
    use crate::status_report::{BacklogSummary, Receipt, StateCounts};
    use crate::work_planning::{LaneCapacity, Reservations, WorkCandidates};

    /// The schema of design.md, "Persistence". Migration n is `MIGRATIONS[n - 1]`, applied in one
    /// transaction while `PRAGMA user_version` is below n.
    pub const MIGRATIONS: &[&str] = &[include_str!("migrations/0001_collector_state.sql")];

    /// The only owner of the SQLite connection, used only on the coordinator thread.
    pub struct StateStore {
        connection: rusqlite::Connection,
    }

    #[derive(Debug)]
    pub enum StoreOpenFailure {
        /// The file failed `PRAGMA quick_check` and was renamed aside to this path; a fresh store
        /// was not created, so the caller decides whether to start over.
        Unreadable { renamed_to: PathBuf },
        Inaccessible(std::io::Error),
        NewerSchema { found: u32, supported: u32 },
    }

    pub struct ConnectionRecord {
        pub archive_origin: String,
        pub credential_fingerprint: String,
        pub suspension: Option<(SuspensionReason, Timestamp)>,
    }

    pub struct FolderRecord {
        pub folder: FolderIdentifier,
        pub root: PathBuf,
        pub enrolled_at: Timestamp,
        pub admission: FolderAdmission,
    }

    /// One write transaction. Every transition of a batch goes through one of these, so the
    /// status read after the batch sees all of it or none.
    pub struct StoreTransaction<'store> {
        transaction: rusqlite::Transaction<'store>,
    }

    impl StateStore {
        /// WAL journal, `foreign_keys = ON`, migrations applied.
        pub fn open(path: &Path) -> Result<StateStore, StoreOpenFailure> {
            todo!()
        }
        pub fn begin(&mut self) -> rusqlite::Result<StoreTransaction<'_>> {
            todo!()
        }
        pub fn connection_record(&self) -> rusqlite::Result<Option<ConnectionRecord>> {
            todo!()
        }
        pub fn folders(&self) -> rusqlite::Result<Vec<FolderRecord>> {
            todo!()
        }
        /// Rows of exactly this directory, and child directory names that have rows below them.
        pub fn directory_contents(
            &self,
            folder: FolderIdentifier,
            directory: &DirectoryKey,
        ) -> rusqlite::Result<(Vec<(EntryName, PathState)>, Vec<EntryName>)> {
            todo!()
        }
        pub fn path_state(&self, path: &PathKey) -> rusqlite::Result<Option<PathState>> {
            todo!()
        }
        pub fn content_record(&self, digest: &ContentDigest) -> rusqlite::Result<Option<ContentRecord>> {
            todo!()
        }
        /// Limited by free capacity plus reservations, in planning order (see `WorkCandidates`).
        pub fn work_candidates(
            &self,
            reservations: &Reservations,
            capacity: &LaneCapacity,
            now: Timestamp,
            timing: &TimingPolicy,
        ) -> rusqlite::Result<WorkCandidates> {
            todo!()
        }
        pub fn survey_progress(&self, folder: FolderIdentifier) -> rusqlite::Result<SurveyProgress> {
            todo!()
        }
        /// Counts over the named folders; distinct contents are counted once across them.
        pub fn backlog_summary(&self, folders: &[FolderIdentifier]) -> rusqlite::Result<BacklogSummary> {
            todo!()
        }
        pub fn state_counts(&self) -> rusqlite::Result<StateCounts> {
            todo!()
        }
        pub fn recent_receipts(&self, limit: usize) -> rusqlite::Result<Vec<Receipt>> {
            todo!()
        }
        /// The earliest `observed_at + stabilization_interval` over Stabilizing rows, the earliest
        /// `retry_not_before`, and the earliest Unreadable retry: when the coordinator must wake.
        pub fn next_deadline(&self, timing: &TimingPolicy) -> rusqlite::Result<Option<Timestamp>> {
            todo!()
        }
    }

    impl StoreTransaction<'_> {
        /// Writes a path transition. `Store(Digested { content, .. })` also runs
        /// `INSERT OR IGNORE INTO contents (content_digest, archive_standing) VALUES (?, 'unresolved')`
        /// first, so a Digested path's content row always exists.
        pub fn apply_path(&self, path: &PathKey, transition: &PathTransition, first_observed_at: Timestamp) -> rusqlite::Result<()> {
            todo!()
        }
        pub fn apply_reconciliation_removals(&self, folder: FolderIdentifier, reconciliation: &Reconciliation) -> rusqlite::Result<()> {
            todo!()
        }
        /// Writes only when the standing differs from the stored one.
        pub fn store_standing(&self, digest: &ContentDigest, standing: &ArchiveStanding) -> rusqlite::Result<()> {
            todo!()
        }
        pub fn enroll_folder(&self, root: &Path, at: Timestamp) -> rusqlite::Result<FolderIdentifier> {
            todo!()
        }
        /// For DeclineBacklog it also sets `declined_at` on every Absent content with a path in
        /// this folder, in this transaction.
        pub fn store_admission(&self, folder: FolderIdentifier, admission: FolderAdmission) -> rusqlite::Result<()> {
            todo!()
        }
        /// Cascades to the folder's paths. Contents stay.
        pub fn withdraw_folder(&self, folder: FolderIdentifier) -> rusqlite::Result<()> {
            todo!()
        }
        /// Replaces the singleton; a different fingerprint clears the suspension.
        pub fn store_connection(&self, archive_origin: &str, credential_fingerprint: &str) -> rusqlite::Result<()> {
            todo!()
        }
        pub fn store_suspension(&self, suspension: Option<(SuspensionReason, Timestamp)>) -> rusqlite::Result<()> {
            todo!()
        }
        pub fn commit(self) -> rusqlite::Result<()> {
            todo!()
        }
    }
}

// ===================================================================================================
// file_system_observation.rs
// ===================================================================================================
pub mod file_system_observation {
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::Sender;

    use crate::candidate_classification::ReadableSignature;
    use crate::directory_reconciliation::DirectoryListing;
    use crate::domain_types::{ContentDigest, DirectoryKey, FileSignature, FolderIdentifier, Timestamp};
    use crate::path_lifecycle::DigestFinding;

    /// `lstat` without following links. On macOS `dataless` is `st_flags & SF_DATALESS`
    /// (0x4000_0000); elsewhere false.
    pub fn observe_signature(path: &Path) -> std::io::Result<Option<FileSignature>> {
        todo!()
    }

    /// Lists one directory, or a subtree. Entries go through `classify_entry_name`; disregarded
    /// directories are not descended. Sends one `DirectoryListing` per directory, so a large tree
    /// never sits in memory at once.
    pub fn list_directory(
        folder: FolderIdentifier,
        root: &Path,
        directory: &DirectoryKey,
        recursive: bool,
        clock: &dyn crate::Clock,
        sink: &mut dyn FnMut(DirectoryListing),
    ) {
        todo!()
    }

    /// Sequence: `lstat` and compare with `based_on` (else Changed, nothing opened); open; read
    /// `LEADING_BYTES_LENGTH` bytes and identify the kind (else Unrecognized, rest unread); stream
    /// the rest through SHA-256 in 64 KiB blocks, stopping at `MAXIMUM_CONTENT_BYTES`; `lstat`
    /// again and compare (else Changed). Never opens a file whose fresh signature differs from
    /// `based_on`, which is how a dataless placeholder stays unread.
    pub fn compute_digest(absolute: &Path, based_on: &ReadableSignature) -> DigestFinding {
        todo!()
    }

    /// The bytes of a source, read whole and proven to be the authorized content.
    /// Only `read_submission_source` constructs it.
    pub struct VerifiedContent {
        digest: ContentDigest,
        bytes: Vec<u8>,
    }

    impl VerifiedContent {
        pub fn digest(&self) -> ContentDigest {
            self.digest
        }
        pub fn into_bytes(self) -> Vec<u8> {
            self.bytes
        }
    }

    #[derive(Debug)]
    pub struct SourceVerificationFailure {
        pub current: Option<FileSignature>,
        pub at: Timestamp,
    }

    /// The same before-and-after signature checks as `compute_digest`, with the whole file in
    /// memory (at most 25 MB) and its digest compared with `expected`.
    pub fn read_submission_source(
        absolute: &Path,
        based_on: &ReadableSignature,
        expected: ContentDigest,
        clock: &dyn crate::Clock,
    ) -> Result<VerifiedContent, SourceVerificationFailure> {
        todo!()
    }

    /// A directory the watcher says changed. Hints only name directories; the coordinator
    /// coalesces them and plans listings.
    #[derive(Clone, Debug)]
    pub struct DirectoryHint {
        pub folder: FolderIdentifier,
        pub directory: DirectoryKey,
        /// FSEvents' rescan flag, or an event on a directory itself.
        pub recursive: bool,
    }

    /// Owns the `notify` watcher. Maps each event path to its folder and parent directory key.
    pub struct FolderWatcher {
        watcher: notify::RecommendedWatcher,
    }

    impl FolderWatcher {
        pub fn new(hints: Sender<crate::collection_coordinator::CoordinatorInput>) -> notify::Result<FolderWatcher> {
            todo!()
        }
        /// Fails while the root is missing; the coordinator retries at each walk.
        pub fn watch(&mut self, folder: FolderIdentifier, root: &Path) -> notify::Result<()> {
            todo!()
        }
        pub fn unwatch(&mut self, root: &Path) {
            todo!()
        }
    }

    pub fn absolute_path(root: &Path, directory: &DirectoryKey, name: &std::ffi::OsStr) -> PathBuf {
        todo!()
    }
}

// ===================================================================================================
// archive_client.rs
// ===================================================================================================
pub mod archive_client {
    use crate::archive_connection::ArchiveCondition;
    use crate::content_synchronization::{LookupAnswer, SubmissionAuthorization, SubmissionOutcome};
    use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus};
    use crate::file_system_observation::VerifiedContent;

    /// An archive origin, `https://` (or `http://localhost` for the simulated archive).
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct ArchiveAddress(url::Url);

    impl ArchiveAddress {
        /// Keeps the origin only; a pasted path such as `/settings` is dropped.
        pub fn parse(text: &str) -> Result<ArchiveAddress, crate::CommandRefusal> {
            todo!()
        }
        pub fn origin(&self) -> String {
            todo!()
        }
    }

    /// The bearer token. Never logged, never stored in the database, never serialized.
    pub struct IngestToken(String);

    impl IngestToken {
        pub fn new(token: String) -> IngestToken {
            IngestToken(token)
        }
        /// SHA-256 of the token, the only form the database holds.
        pub fn fingerprint(&self) -> String {
            todo!()
        }
    }

    /// Speaks the three requests of src/collection_protocol/. Parses every answer into domain
    /// types; no wire type leaves this module. Problem details are read for their `detail` only.
    /// Shared by the worker threads; `ureq::Agent` is cheap to clone.
    pub struct ArchiveClient {
        agent: ureq::Agent,
        address: ArchiveAddress,
        authorization_header: String,
    }

    impl ArchiveClient {
        pub fn new(address: ArchiveAddress, token: &IngestToken) -> ArchiveClient {
            todo!()
        }

        /// `POST /api/v1/contents/lookup` with 1 to 1000 digests. Answers in request order; an
        /// answer whose digests differ from the request is a ProtocolViolation.
        pub fn look_up(&self, digests: &[ContentDigest]) -> Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition> {
            todo!()
        }

        /// `PUT /api/v1/contents/{sha256}`. Consumes the authorization; the content's digest must
        /// equal the authorization's (checked, a mismatch is a bug and panics in debug builds).
        /// Timeout: 30 seconds plus one second per 50,000 bytes.
        pub fn submit(
            &self,
            authorization: SubmissionAuthorization,
            content: VerifiedContent,
        ) -> Result<SubmissionOutcome, ArchiveCondition> {
            todo!()
        }

        /// `GET /api/v1/documents/{id}`. `Ok(None)` is a 404.
        pub fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition> {
            todo!()
        }
    }

    /// Seconds only, as the server sends; 900 when missing or unreadable.
    pub fn parse_retry_after(header: Option<&str>) -> std::time::Duration {
        todo!()
    }
}

// ===================================================================================================
// credential_storage.rs
// ===================================================================================================
pub mod credential_storage {
    use crate::archive_client::{ArchiveAddress, IngestToken};

    #[derive(Debug)]
    pub struct CredentialStorageFailure(pub String);

    /// Where the token lives, keyed by the archive origin, so a lost database leaves it findable.
    pub trait CredentialStore: Send {
        fn read(&self, address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure>;
        fn write(&self, address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure>;
    }

    /// The macOS Keychain (and the platform stores of Linux and Windows) through `keyring`.
    pub struct KeychainCredentialStore {
        service: String,
    }

    impl KeychainCredentialStore {
        pub fn new(service: &str) -> KeychainCredentialStore {
            KeychainCredentialStore { service: service.to_owned() }
        }
    }

    impl CredentialStore for KeychainCredentialStore {
        fn read(&self, address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure> {
            todo!()
        }
        fn write(&self, address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure> {
            todo!()
        }
    }

    /// A token from `SCHUBLADE_INGEST_TOKEN` or from a test. `write` keeps it in memory.
    pub struct FixedCredentialStore {
        token: std::sync::Mutex<Option<String>>,
    }

    impl CredentialStore for FixedCredentialStore {
        fn read(&self, address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure> {
            todo!()
        }
        fn write(&self, address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure> {
            todo!()
        }
    }
}

// ===================================================================================================
// status_report.rs
// ===================================================================================================
pub mod status_report {
    use std::path::PathBuf;

    use crate::archive_connection::SuspensionReason;
    use crate::domain_types::{DocumentIdentifier, DocumentStatus, FolderIdentifier, Timestamp};
    use crate::folder_admission::{FolderAdmission, FolderAvailability};

    /// One consistent picture, computed in one read transaction on the coordinator thread.
    /// Every field is derived from stored states and reservations; nothing here is kept separately.
    #[derive(Clone, Debug, serde::Serialize)]
    pub struct CollectorStatus {
        /// Grows with every committed batch. The window compares it to drop stale reads.
        pub revision: u64,
        pub connection: ConnectionStatus,
        pub folders: Vec<FolderStatus>,
        /// Over every folder in AwaitingDecision; None when no folder awaits a decision.
        pub backlog: Option<BacklogSummary>,
        pub counts: StateCounts,
        pub activities: Vec<Activity>,
        pub attention: Vec<AttentionItem>,
        pub recent_receipts: Vec<Receipt>,
    }

    #[derive(Clone, Debug, serde::Serialize)]
    pub enum ConnectionStatus {
        Unconfigured,
        Connected { archive_origin: String },
        Unreachable { since: Timestamp, next_attempt_at: Timestamp },
        Checking,
        Deferred { until: Timestamp },
        Suspended { reason: SuspensionReason, since: Timestamp },
    }

    #[derive(Clone, Debug, serde::Serialize)]
    pub struct FolderStatus {
        pub folder: FolderIdentifier,
        pub root: PathBuf,
        pub admission: FolderAdmission,
        pub availability: FolderAvailability,
        /// Paths still Stabilizing or Stable, and contents still Unresolved: "examining 12 files".
        pub files_under_examination: u64,
    }

    /// "1,240 files: 310 already in the archive, 930 new, holding 902 distinct contents."
    #[derive(Clone, Debug, Default, serde::Serialize)]
    pub struct BacklogSummary {
        pub folders: Vec<FolderIdentifier>,
        pub candidate_files: u64,
        pub files_already_archived: u64,
        pub files_deleted_from_archive: u64,
        pub files_new: u64,
        pub new_contents: u64,
        pub excluded_files: u64,
        pub unreadable_files: u64,
        pub files_under_examination: u64,
    }

    #[derive(Clone, Debug, Default, serde::Serialize)]
    pub struct StateCounts {
        pub paths_stabilizing: u64,
        pub paths_awaiting_digest: u64,
        pub paths_digested: u64,
        pub paths_excluded: u64,
        pub paths_unreadable: u64,
        pub contents_unresolved: u64,
        pub contents_awaiting_submission: u64,
        pub contents_present: u64,
        pub contents_deleted: u64,
        pub contents_refused: u64,
        pub contents_declined: u64,
        pub contents_failing: u64,
    }

    #[derive(Clone, Debug, serde::Serialize)]
    pub enum Activity {
        Listing { folder: FolderIdentifier, directory: String },
        Digesting { file_name: String },
        LookingUp { content_count: usize },
        Submitting { file_name: String, byte_size: u64 },
    }

    #[derive(Clone, Debug, serde::Serialize)]
    pub enum AttentionItem {
        ArchiveNotConfigured,
        CredentialSuspended { reason: SuspensionReason },
        FolderUnavailable { folder: FolderIdentifier, availability: FolderAvailability },
        BacklogAwaitsDecision { folders: Vec<FolderIdentifier> },
        ContentRefused { file_name: String, too_large: bool },
        ContentFailing { file_name: String, failures: u32 },
    }

    #[derive(Clone, Debug, serde::Serialize)]
    pub struct Receipt {
        pub document: DocumentIdentifier,
        /// `<archive origin>/documents/<id>`.
        pub document_link: String,
        pub file_name: String,
        pub received_at: Timestamp,
        pub status: Option<DocumentStatus>,
    }
}

// ===================================================================================================
// collection_coordinator.rs
// ===================================================================================================
pub mod collection_coordinator {
    use std::sync::mpsc::{Receiver, Sender};

    use crate::archive_client::ArchiveClient;
    use crate::archive_connection::{ArchiveCondition, ConnectionState};
    use crate::content_synchronization::{LookupAnswer, SubmissionOutcome};
    use crate::directory_reconciliation::DirectoryListing;
    use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus, FolderIdentifier, PathKey, Timestamp, TimingPolicy};
    use crate::file_system_observation::{DirectoryHint, FolderWatcher, SourceVerificationFailure};
    use crate::folder_admission::FolderAvailability;
    use crate::path_lifecycle::DigestFinding;
    use crate::state_store::StateStore;
    use crate::status_report::CollectorStatus;
    use crate::work_planning::{LaneCapacity, Reservations, Work};
    use crate::{CollectorCommand, CollectorEvent, CommandRefusal};

    /// Everything that reaches the coordinator. Workers and the watcher only send these.
    pub enum CoordinatorInput {
        Command(CollectorCommand),
        Listing(DirectoryListing),
        WalkCompleted { folder: FolderIdentifier, root_availability: FolderAvailability },
        Hint(DirectoryHint),
        Finished(WorkResult),
        SystemResumed,
        Shutdown,
    }

    /// The result of one `Work`, carrying the key it was planned for. Applying it releases the
    /// reservation and runs the owning machine.
    pub enum WorkResult {
        Digest { path: PathKey, based_on: crate::candidate_classification::ReadableSignature, finding: DigestFinding, at: Timestamp },
        Lookup { digests: Vec<ContentDigest>, answer: Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition>, at: Timestamp },
        Submission { content: ContentDigest, source: PathKey, answer: SubmissionResult, at: Timestamp },
        DocumentStatus { content: ContentDigest, answer: Result<Option<DocumentStatus>, ArchiveCondition>, at: Timestamp },
        ListingFinished { folder: FolderIdentifier, directory: crate::domain_types::DirectoryKey },
    }

    pub enum SubmissionResult {
        SourceFailed(SourceVerificationFailure),
        Answered(Result<SubmissionOutcome, ArchiveCondition>),
    }

    /// The single owner of all collector state (design.md, "Four machines, one owner").
    ///
    /// Loop: block on the inbox until the next deadline; drain up to 256 inputs or 50 ms; apply
    /// them in one store transaction through the pure machines; commit; conclude surveys whose
    /// predicate now holds; plan work and dispatch it to the lanes, recording reservations;
    /// publish `StatusChanged` if the coalescing interval allows.
    ///
    /// Invariants:
    /// - Only this thread touches `store`, `reservations`, and `connection`.
    /// - A result is applied and committed before the next plan, so the planner never re-issues
    ///   work whose result is already in the inbox.
    /// - No worker result is trusted beyond the machine's transition: a stale result changes nothing.
    pub struct CollectionCoordinator {
        store: StateStore,
        reservations: Reservations,
        connection: ConnectionState,
        availability: std::collections::HashMap<FolderIdentifier, FolderAvailability>,
        initial_walks_completed: std::collections::BTreeSet<FolderIdentifier>,
        pending_hints: Vec<DirectoryHint>,
        archive: Option<std::sync::Arc<ArchiveClient>>,
        watcher: FolderWatcher,
        lanes: WorkerLanes,
        capacity: LaneCapacity,
        timing: TimingPolicy,
        clock: Box<dyn crate::Clock>,
        events: Sender<CollectorEvent>,
        revision: u64,
        idle_waiters: Vec<(Timestamp, Sender<Result<CollectorStatus, CommandRefusal>>)>,
    }

    /// One thread per lane slot. Each receives `Work` and sends a `CoordinatorInput::Finished`.
    pub struct WorkerLanes {
        listing: Sender<Work>,
        digest: Sender<Work>,
        archive: Sender<Work>,
    }

    impl CollectionCoordinator {
        pub fn run(mut self, inbox: Receiver<CoordinatorInput>) {
            todo!()
        }

        fn apply_batch(&mut self, inputs: Vec<CoordinatorInput>) -> rusqlite::Result<()> {
            // TODO: per input, read the affected rows, call advance_path / advance_content /
            // advance_connection / decide, write through the transaction; release reservations
            // of Finished results; route ArchiveCondition through archive_connection::consequences.
            todo!()
        }

        fn plan_and_dispatch(&mut self) -> rusqlite::Result<()> {
            todo!()
        }

        /// One read transaction over the store plus the reservations.
        fn status(&self) -> rusqlite::Result<CollectorStatus> {
            todo!()
        }

        /// No plannable work, no reservation, no pending hint, and no deadline earlier than now.
        fn is_idle(&self) -> rusqlite::Result<bool> {
            todo!()
        }
    }
}

// ===================================================================================================
// lib.rs: the public surface
// ===================================================================================================
pub use archive_client::{ArchiveAddress, IngestToken};
pub use credential_storage::{CredentialStore, FixedCredentialStore, KeychainCredentialStore};
pub use domain_types::{FolderIdentifier, TimingPolicy};
pub use folder_admission::BacklogDecision;
pub use status_report::{BacklogSummary, CollectorStatus};

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::time::Duration;

/// The wall clock in production and a manual clock in tests. Only the coordinator and the
/// workers read it; the machines receive times inside events.
pub trait Clock: Send {
    fn now(&self) -> domain_types::Timestamp;
}

pub struct CollectorSettings {
    pub database_path: PathBuf,
    pub credential_store: Box<dyn CredentialStore>,
    pub timing: TimingPolicy,
    /// 1 or 2.
    pub submission_concurrency: usize,
    pub clock: Box<dyn Clock>,
}

impl CollectorSettings {
    /// Production defaults: the intervals of design.md, two submissions, the wall clock.
    pub fn new(database_path: PathBuf, credential_store: Box<dyn CredentialStore>) -> CollectorSettings {
        todo!()
    }
}

/// Pushed to the app. The window refetches `status()` on `StatusChanged`; the menu bar may show
/// a notification on `DocumentReceived`. Deliberately small: the status is the data.
#[derive(Clone, Debug, serde::Serialize)]
pub enum CollectorEvent {
    StatusChanged { revision: u64 },
    DocumentReceived { document_link: String, file_name: String },
}

/// Why a command was not carried out. Every variant is a sentence the app can show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandRefusal {
    ArchiveAddressInvalid { detail: String },
    CredentialStorageFailed { detail: String },
    FolderAlreadyEnrolled { folder: FolderIdentifier },
    /// A folder inside another enrolled folder, or containing one: its files would be counted
    /// twice. Refused at enrollment.
    FolderOverlapsEnrolledFolder { folder: FolderIdentifier },
    FolderUnknown { folder: FolderIdentifier },
    SurveyIncomplete { folder: FolderIdentifier },
    BacklogAlreadyDecided { folder: FolderIdentifier },
    IdleTimeout,
    CollectorStopped,
    StoreFailed { detail: String },
}

impl std::fmt::Display for CommandRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        todo!()
    }
}

#[derive(Debug)]
pub enum StartFailure {
    Store(state_store::StoreOpenFailure),
    Watcher(String),
}

impl std::fmt::Display for StartFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        todo!()
    }
}
impl std::error::Error for StartFailure {}

/// A command with its reply channel. Commands are applied in the coordinator's next batch, so
/// a command and the worker results around it never race.
pub enum CollectorCommand {
    ConnectArchive { address: ArchiveAddress, token: IngestToken, reply: Sender<Result<(), CommandRefusal>> },
    EnrollFolder { root: PathBuf, reply: Sender<Result<FolderIdentifier, CommandRefusal>> },
    WithdrawFolder { folder: FolderIdentifier, reply: Sender<Result<(), CommandRefusal>> },
    DecideBacklog { folders: Vec<FolderIdentifier>, decision: BacklogDecision, reply: Sender<Result<(), CommandRefusal>> },
    ReadStatus { reply: Sender<Result<CollectorStatus, CommandRefusal>> },
    WaitUntilIdle { deadline: domain_types::Timestamp, reply: Sender<Result<CollectorStatus, CommandRefusal>> },
}

/// The handle the Tauri app and the command-line program hold. Cheap to share; every method
/// sends one command to the coordinator thread and waits for its reply.
pub struct Collector {
    inbox: Sender<collection_coordinator::CoordinatorInput>,
    coordinator_thread: Option<std::thread::JoinHandle<()>>,
}

impl Collector {
    /// Opens the store, starts the coordinator, the watcher, and the lanes, and lists every
    /// enrolled folder. Returns the event stream; dropping it only stops the events.
    pub fn start(settings: CollectorSettings) -> Result<(Collector, Receiver<CollectorEvent>), StartFailure> {
        todo!()
    }

    /// Stores the token in the credential store and the origin with the token's fingerprint in
    /// the database. A different token clears a suspension.
    pub fn connect_archive(&self, address: ArchiveAddress, token: IngestToken) -> Result<(), CommandRefusal> {
        todo!()
    }

    /// Starts the folder in Surveying with a recursive listing.
    pub fn enroll_folder(&self, root: PathBuf) -> Result<FolderIdentifier, CommandRefusal> {
        todo!()
    }

    pub fn withdraw_folder(&self, folder: FolderIdentifier) -> Result<(), CommandRefusal> {
        todo!()
    }

    /// Applies to exactly the named folders, each of which must be AwaitingDecision. All or none.
    pub fn decide_backlog(&self, folders: &[FolderIdentifier], decision: BacklogDecision) -> Result<(), CommandRefusal> {
        todo!()
    }

    pub fn status(&self) -> CollectorStatus {
        todo!()
    }

    /// From the app's wake notification. The coordinator also detects a jump of the wall clock.
    pub fn notify_system_resumed(&self) {
        todo!()
    }

    /// Returns the status once no work can be planned and none is in flight. Used by
    /// `collect --until-idle`, `survey`, and the scenario tests.
    pub fn wait_until_idle(&self, timeout: Duration) -> Result<CollectorStatus, CommandRefusal> {
        todo!()
    }

    /// Lets in-flight work finish for up to 5 seconds, then stops. Unfinished work is lost only
    /// as reservations, which the next start derives again.
    pub fn shutdown(self) {
        todo!()
    }
}
