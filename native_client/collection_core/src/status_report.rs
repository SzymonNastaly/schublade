//! One consistent picture of the collector, computed by the coordinator from stored states and
//! its reservations in one read. Every field is derived; nothing here is kept separately, so the
//! attention items can never disagree with the states.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::archive_connection::SuspensionReason;
use crate::candidate_classification::{DisregardReason, ExclusionReason};
use crate::content_synchronization::RefusalReason;
use crate::domain_types::{DocumentIdentifier, DocumentStatus, FolderIdentifier, Timestamp};
use crate::folder_admission::{FolderAdmission, FolderAvailability};

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct CollectorStatus {
    /// Rises with every change of the fields below but `next_scheduled_at`, and never with a read,
    /// so two statuses that differ in what they show never share a revision. The window compares
    /// it to drop stale reads.
    pub revision: u64,
    pub connection: ConnectionStatus,
    /// The origin the collector is configured for, in every connection state but Unconfigured, so
    /// a suspended collector can offer to replace the token without asking for the address again.
    pub archive_origin: Option<String>,
    pub folders: Vec<FolderStatus>,
    /// Over every folder in AwaitingDecision; None when no folder awaits a decision.
    pub backlog: Option<BacklogSummary>,
    pub counts: StateCounts,
    pub activities: Vec<Activity>,
    pub attention: Vec<AttentionItem>,
    pub recent_receipts: Vec<Receipt>,
    /// When the coordinator next wakes on its own: a stabilization, a retry, a probe, a walk.
    /// None when only a file system event or a command can bring work.
    pub next_scheduled_at: Option<Timestamp>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum ConnectionStatus {
    Unconfigured,
    Connected {
        archive_origin: String,
    },
    Unreachable {
        since: Timestamp,
        next_attempt_at: Timestamp,
    },
    Checking,
    Deferred {
        until: Timestamp,
    },
    Suspended {
        reason: SuspensionReason,
        since: Timestamp,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct FolderStatus {
    pub folder: FolderIdentifier,
    pub root: PathBuf,
    pub admission: FolderAdmission,
    pub availability: FolderAvailability,
    /// Paths still Stabilizing or Stable, and contents still Unresolved: "examining 12 files".
    pub files_under_examination: u64,
    /// This folder's own counts while it awaits its decision, for a confirmation asked once per
    /// folder; None in every other admission.
    pub backlog: Option<BacklogSummary>,
}

/// "1,240 files: 310 already in the archive, 930 new, holding 902 distinct contents."
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct BacklogSummary {
    pub folders: Vec<FolderIdentifier>,
    /// Digested paths.
    pub candidate_files: u64,
    pub files_already_archived: u64,
    pub files_deleted_from_archive: u64,
    pub files_refused_by_archive: u64,
    pub files_new: u64,
    /// Distinct absent contents across the folders.
    pub new_contents: u64,
    pub excluded_files: u64,
    pub excluded_files_by_reason: BTreeMap<ExclusionReason, u64>,
    /// Entries the name filter left without a row, counted by the latest listing of each
    /// directory of the folders.
    pub disregarded_files: BTreeMap<DisregardReason, u64>,
    pub unreadable_files: u64,
    /// Paths still Stabilizing or Stable, and Digested paths whose content is still Unresolved.
    pub files_under_examination: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
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
    /// Absent contents with three or more submission failures.
    pub contents_failing: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum Activity {
    Listing {
        folder: FolderIdentifier,
        directory: String,
    },
    Digesting {
        file_name: String,
    },
    LookingUp {
        content_count: usize,
    },
    Submitting {
        file_name: String,
        byte_size: u64,
    },
    FollowingDocument,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum AttentionItem {
    ArchiveNotConfigured,
    CredentialSuspended {
        reason: SuspensionReason,
    },
    /// The archive is older than the reception of collected documents, so nothing uploads until
    /// the owner updates it.
    ArchiveOutdated,
    FolderUnavailable {
        folder: FolderIdentifier,
        availability: FolderAvailability,
    },
    BacklogAwaitsDecision {
        folders: Vec<FolderIdentifier>,
    },
    ContentRefused {
        file_name: String,
        reason: RefusalReason,
    },
    ContentFailing {
        file_name: String,
        failures: u32,
    },
}

/// A document this collector's PUT created, newest first.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Receipt {
    pub document: DocumentIdentifier,
    /// `<archive origin>/documents/<identifier>`.
    pub document_link: String,
    /// The relative path of the newest sighting of the content.
    pub file_name: String,
    pub received_at: Timestamp,
    pub status: Option<DocumentStatus>,
}

/// A content that needs attention: refused for good, or failing its submissions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContentAttention {
    pub file_name: String,
    pub refusal: Option<RefusalReason>,
    pub failures: u32,
}
