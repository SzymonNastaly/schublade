//! The collector status and the shared archive connection as an application shows them.
//!
//! `publish` and `derive_archive_connection` destructure every core struct without `..` and match
//! every core enum without a wildcard arm, so a field or variant added to a core fails to compile
//! here until this file says what an application shows for it.

use std::time::{Duration, SystemTime};

use archive_access::{ArchiveCondition, Timestamp};
use archive_replica::{ReplicaStatus, SynchronizationState};

/// A record, so that the foreign language gets a distinct type and not an integer.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FolderIdentifier {
    pub value: i64,
}

impl From<collection_core::FolderIdentifier> for FolderIdentifier {
    fn from(folder: collection_core::FolderIdentifier) -> FolderIdentifier {
        FolderIdentifier { value: folder.value() }
    }
}

impl From<FolderIdentifier> for collection_core::FolderIdentifier {
    fn from(folder: FolderIdentifier) -> collection_core::FolderIdentifier {
        collection_core::FolderIdentifier::new(folder.value)
    }
}

/// A folder with its root as the collector keeps it. An application derives the name a person
/// reads from the root.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Hash)]
pub struct FolderReference {
    pub identifier: FolderIdentifier,
    pub root: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct CollectorStatus {
    /// Rises with every change of the fields below and never with a read, so
    /// `Collector::status_after` with it waits for the next change.
    pub revision: u64,
    pub folders: Vec<FolderStatus>,
    pub progress: CollectionProgress,
    /// What is in flight now. Empty while the collector rests.
    pub activities: Vec<Activity>,
    pub attention: Vec<AttentionItem>,
    /// Newest first.
    pub recent_receipts: Vec<Receipt>,
}

/// The one connection to the archive, derived from both the local copy's and the collector's
/// observations and published once in `LibraryStatus`.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum ArchiveConnection {
    NotConfigured,
    Configured {
        /// `https://archive.example.org`, for the address field and the link to the archive.
        origin: String,
        /// `archive.example.org`, with the port when the origin names one, for sentences.
        host: String,
        condition: ConnectionCondition,
        permission: ArchivePermission,
        restricted: bool,
    },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ArchivePermission {
    CollectOnly,
    ReadOnly,
    ReadAndCollect,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum ConnectionCondition {
    Connected,
    Checking,
    Unreachable {
        since: SystemTime,
        next_attempt_at: SystemTime,
    },
    Deferred {
        until: SystemTime,
    },
    Suspended {
        reason: SuspensionReason,
    },
    ArchiveOutdated,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SuspensionReason {
    CredentialRefused,
    CredentialInsufficient,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FolderStatus {
    pub folder: FolderReference,
    pub admission: FolderAdmission,
    /// `None` while the folder can be read.
    pub unavailability: Option<FolderUnavailability>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum FolderAdmission {
    Surveying { files_under_examination: u64 },
    AwaitingDecision { backlog: BacklogSummary },
    Collecting,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FolderUnavailability {
    Missing,
    AccessDenied,
}

/// One folder's survey, as its confirmation states it.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct BacklogSummary {
    pub files_new: u64,
    /// Distinct contents among the new files. Smaller when the folder holds identical copies.
    pub new_contents: u64,
    pub files_already_archived: u64,
    pub files_deleted_from_archive: u64,
    pub files_refused_by_archive: u64,
    /// Excluded, disregarded, and unreadable entries in the order of `SkipReason`, without zero
    /// counts.
    pub skipped: Vec<SkippedCount>,
    pub files_under_examination: u64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SkippedCount {
    pub reason: SkipReason,
    pub count: u64,
}

/// The core's `ExclusionReason`, its unreadable paths, and its `DisregardReason`.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SkipReason {
    UnrecognizedContent,
    EmptyFile,
    ExceedsSizeLimit,
    CloudPlaceholder,
    Unreadable,
    IncompleteDownload,
    HiddenEntry,
    AppleDoubleCompanion,
    PackageDirectory,
    SymbolicLink,
    SpecialFile,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct CollectionProgress {
    /// Distinct contents the collector found that the archive holds as documents, one document
    /// each however many files carry it.
    pub documents_in_archive: u64,
    /// Distinct contents the collector found that the archive lacks, one each however many files
    /// carry it. Each becomes one document when it is submitted, after its folder's decision
    /// while the folder awaits one.
    pub documents_awaiting_submission: u64,
    /// Files still settling or waiting to be read, plus the distinct contents still waiting for
    /// the archive's answer.
    pub files_under_examination: u64,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum Activity {
    Listing { folder: FolderReference, directory: String },
    Digesting { file_name: String },
    LookingUp { content_count: u64 },
    Submitting { file_name: String, byte_size: u64 },
    FollowingDocument,
}

/// The core's attention items without `ArchiveNotConfigured`, which `ArchiveConnection` says,
/// and with one `BacklogAwaitsDecision` per folder, because each folder is confirmed on its own.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum AttentionItem {
    CredentialSuspended {
        reason: SuspensionReason,
    },
    /// The archive is older than the reception of collected documents, so nothing uploads until
    /// the owner updates it. The library goes on reading, because its routes are older.
    ArchiveOutdated,
    FolderUnavailable {
        folder: FolderReference,
        unavailability: FolderUnavailability,
    },
    BacklogAwaitsDecision {
        folder: FolderReference,
    },
    ContentRefused {
        file_name: String,
        reason: ContentRefusalReason,
    },
    ContentFailing {
        file_name: String,
        failures: u32,
    },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ContentRefusalReason {
    TooLarge,
    UnacceptedKind,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub document_identifier: String,
    /// `<archive origin>/documents/<identifier>`.
    pub document_link: String,
    pub file_name: String,
    pub received_at: SystemTime,
    pub outcome: DocumentOutcome,
}

/// The archive's seven document statuses as the three a list shows.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DocumentOutcome {
    Processing,
    Archived,
    Failed,
}

pub(crate) fn publish(status: collection_core::CollectorStatus) -> CollectorStatus {
    let collection_core::CollectorStatus {
        revision,
        connection: _,
        archive_origin: _,
        folders,
        // Every waiting folder summed, for the command-line program. A confirmation is per folder.
        backlog: _,
        counts,
        activities,
        attention,
        recent_receipts,
        next_scheduled_at: _,
    } = status;
    let folders: Vec<FolderStatus> = folders.into_iter().map(folder_status).collect();
    let reference = |folder: collection_core::FolderIdentifier| {
        folders
            .iter()
            .map(|listed| &listed.folder)
            .find(|listed| listed.identifier == folder.into())
            .cloned()
    };
    CollectorStatus {
        revision,
        progress: collection_progress(counts),
        // A listing can still be in flight for a folder that was withdrawn.
        activities: activities
            .into_iter()
            .filter_map(|activity| published_activity(activity, reference))
            .collect(),
        attention: attention
            .into_iter()
            .flat_map(|item| attention_items(item, reference))
            .collect(),
        recent_receipts: recent_receipts.into_iter().map(receipt).collect(),
        folders,
    }
}

pub(crate) fn derive_archive_connection(
    replica: &ReplicaStatus,
    collector: Option<&(Option<String>, collection_core::ConnectionStatus)>,
) -> ArchiveConnection {
    let replica_entry = replica.archive.as_ref().map(|mirrored| {
        let condition = replica_connection_condition(&replica.synchronization);
        (mirrored.origin.clone(), mirrored.restricted, condition)
    });
    let collector_entry = collector.and_then(|(origin, connection)| {
        let condition = collector_connection_condition(connection)?;
        let origin = origin.as_ref()?;
        Some((origin.clone(), condition))
    });

    match (replica_entry, collector_entry) {
        (None, None) => ArchiveConnection::NotConfigured,
        (Some((origin, restricted, condition)), None) => ArchiveConnection::Configured {
            host: origin_host(&origin),
            origin,
            condition,
            permission: ArchivePermission::ReadOnly,
            restricted,
        },
        (None, Some((origin, condition))) => ArchiveConnection::Configured {
            host: origin_host(&origin),
            origin,
            condition,
            permission: ArchivePermission::CollectOnly,
            restricted: false,
        },
        (Some((origin, restricted, replica_condition)), Some((_, collector_condition))) => {
            ArchiveConnection::Configured {
                host: origin_host(&origin),
                origin,
                condition: merge_conditions(replica_condition, collector_condition),
                permission: if restricted {
                    ArchivePermission::ReadOnly
                } else {
                    ArchivePermission::ReadAndCollect
                },
                restricted,
            }
        }
    }
}

fn replica_connection_condition(synchronization: &SynchronizationState) -> ConnectionCondition {
    match synchronization {
        // A mirror row with Disconnected means startup found no matching token for this archive.
        SynchronizationState::Disconnected => ConnectionCondition::Suspended {
            reason: SuspensionReason::CredentialRefused,
        },
        SynchronizationState::Filling { .. }
        | SynchronizationState::Following { .. }
        | SynchronizationState::CatchingUp => ConnectionCondition::Connected,
        SynchronizationState::Unreachable {
            since,
            attempts: _,
            retry_at,
            condition,
        } => match condition {
            ArchiveCondition::ServiceUnavailable { .. } => ConnectionCondition::Deferred {
                until: system_time(*retry_at),
            },
            ArchiveCondition::ConnectionFailed
            | ArchiveCondition::TimedOut
            | ArchiveCondition::ServerError
            | ArchiveCondition::ProtocolViolation { .. }
            | ArchiveCondition::CredentialRefused
            | ArchiveCondition::CredentialInsufficient
            | ArchiveCondition::RouteUnknown => ConnectionCondition::Unreachable {
                since: system_time(*since),
                next_attempt_at: system_time(*retry_at),
            },
        },
        SynchronizationState::Suspended { reason } => ConnectionCondition::Suspended {
            reason: match reason {
                archive_replica::replica_synchronization::SuspensionReason::CredentialRefused => {
                    SuspensionReason::CredentialRefused
                }
                archive_replica::replica_synchronization::SuspensionReason::CredentialInsufficient => {
                    SuspensionReason::CredentialInsufficient
                }
            },
        },
        SynchronizationState::ArchiveOutdated { retry_at: _ } => ConnectionCondition::ArchiveOutdated,
    }
}

fn collector_connection_condition(connection: &collection_core::ConnectionStatus) -> Option<ConnectionCondition> {
    Some(match connection {
        collection_core::ConnectionStatus::Unconfigured => return None,
        collection_core::ConnectionStatus::Connected { archive_origin: _ } => ConnectionCondition::Connected,
        collection_core::ConnectionStatus::Unreachable { since, next_attempt_at } => ConnectionCondition::Unreachable {
            since: system_time(*since),
            next_attempt_at: system_time(*next_attempt_at),
        },
        collection_core::ConnectionStatus::Checking => ConnectionCondition::Checking,
        collection_core::ConnectionStatus::Deferred { until } => ConnectionCondition::Deferred {
            until: system_time(*until),
        },
        collection_core::ConnectionStatus::Suspended { reason, since: _ } => ConnectionCondition::Suspended {
            reason: suspension_reason(*reason),
        },
    })
}

fn condition_rank(condition: &ConnectionCondition) -> u8 {
    match condition {
        ConnectionCondition::Suspended {
            reason: SuspensionReason::CredentialRefused,
        } => 6,
        ConnectionCondition::Suspended {
            reason: SuspensionReason::CredentialInsufficient,
        } => 5,
        ConnectionCondition::ArchiveOutdated => 4,
        ConnectionCondition::Unreachable { .. } => 3,
        ConnectionCondition::Deferred { .. } => 2,
        ConnectionCondition::Checking => 1,
        ConnectionCondition::Connected => 0,
    }
}

fn merge_conditions(first: ConnectionCondition, second: ConnectionCondition) -> ConnectionCondition {
    match (first, second) {
        (
            ConnectionCondition::Unreachable {
                since: first_since,
                next_attempt_at: first_next,
            },
            ConnectionCondition::Unreachable {
                since: second_since,
                next_attempt_at: second_next,
            },
        ) => ConnectionCondition::Unreachable {
            since: first_since.min(second_since),
            next_attempt_at: first_next.min(second_next),
        },
        (
            ConnectionCondition::Deferred { until: first_until },
            ConnectionCondition::Deferred { until: second_until },
        ) => ConnectionCondition::Deferred {
            until: first_until.max(second_until),
        },
        (first, second) => {
            if condition_rank(&first) >= condition_rank(&second) {
                first
            } else {
                second
            }
        }
    }
}

/// `archive.example.org` of `https://archive.example.org`, as a browser's `URL.host` names it.
pub(crate) fn origin_host(origin: &str) -> String {
    origin.split_once("://").map_or(origin, |(_, host)| host).to_owned()
}

fn suspension_reason(reason: collection_core::archive_connection::SuspensionReason) -> SuspensionReason {
    match reason {
        collection_core::archive_connection::SuspensionReason::CredentialRefused => SuspensionReason::CredentialRefused,
        collection_core::archive_connection::SuspensionReason::CredentialInsufficient => {
            SuspensionReason::CredentialInsufficient
        }
    }
}

fn folder_status(status: collection_core::FolderStatus) -> FolderStatus {
    let collection_core::FolderStatus {
        folder,
        root,
        admission,
        availability,
        files_under_examination,
        backlog,
    } = status;
    FolderStatus {
        folder: FolderReference {
            identifier: folder.into(),
            root: path_text(&root),
        },
        admission: match (admission, backlog) {
            (collection_core::folder_admission::FolderAdmission::AwaitingDecision, Some(backlog)) => {
                FolderAdmission::AwaitingDecision {
                    backlog: backlog_summary(backlog),
                }
            }
            // A decision is offered only with its counts, which the core gives every awaiting folder.
            (
                collection_core::folder_admission::FolderAdmission::Surveying
                | collection_core::folder_admission::FolderAdmission::AwaitingDecision,
                _,
            ) => FolderAdmission::Surveying {
                files_under_examination,
            },
            (collection_core::folder_admission::FolderAdmission::Collecting { decided_at: _ }, _) => {
                FolderAdmission::Collecting
            }
        },
        unavailability: folder_unavailability(availability),
    }
}

pub(crate) fn path_text(path: &std::path::Path) -> String {
    path.to_string_lossy().into_owned()
}

fn folder_unavailability(
    availability: collection_core::folder_admission::FolderAvailability,
) -> Option<FolderUnavailability> {
    match availability {
        collection_core::folder_admission::FolderAvailability::Available => None,
        collection_core::folder_admission::FolderAvailability::Missing => Some(FolderUnavailability::Missing),
        collection_core::folder_admission::FolderAvailability::AccessDenied => Some(FolderUnavailability::AccessDenied),
    }
}

fn backlog_summary(backlog: collection_core::BacklogSummary) -> BacklogSummary {
    use collection_core::candidate_classification::{DisregardReason, ExclusionReason};
    let collection_core::BacklogSummary {
        folders: _,
        candidate_files: _,
        files_already_archived,
        files_deleted_from_archive,
        files_refused_by_archive,
        files_new,
        new_contents,
        excluded_files: _,
        excluded_files_by_reason,
        disregarded_files,
        unreadable_files,
        files_under_examination,
    } = backlog;
    let excluded = excluded_files_by_reason
        .into_iter()
        .map(|(reason, count)| SkippedCount {
            reason: match reason {
                ExclusionReason::EmptyFile => SkipReason::EmptyFile,
                ExclusionReason::ExceedsSizeLimit => SkipReason::ExceedsSizeLimit,
                ExclusionReason::CloudPlaceholder => SkipReason::CloudPlaceholder,
                ExclusionReason::UnrecognizedContent => SkipReason::UnrecognizedContent,
            },
            count,
        });
    let disregarded = disregarded_files.into_iter().map(|(reason, count)| SkippedCount {
        reason: match reason {
            DisregardReason::HiddenEntry => SkipReason::HiddenEntry,
            DisregardReason::AppleDoubleCompanion => SkipReason::AppleDoubleCompanion,
            DisregardReason::IncompleteDownload => SkipReason::IncompleteDownload,
            DisregardReason::PackageDirectory => SkipReason::PackageDirectory,
            DisregardReason::SymbolicLink => SkipReason::SymbolicLink,
            DisregardReason::SpecialFile => SkipReason::SpecialFile,
        },
        count,
    });
    let unreadable = SkippedCount {
        reason: SkipReason::Unreadable,
        count: unreadable_files,
    };
    let mut skipped: Vec<SkippedCount> = excluded
        .chain(disregarded)
        .chain([unreadable])
        .filter(|skipped| skipped.count > 0)
        .collect();
    skipped.sort_by_key(|skipped| skipped.reason);
    BacklogSummary {
        files_new,
        new_contents,
        files_already_archived,
        files_deleted_from_archive,
        files_refused_by_archive,
        skipped,
        files_under_examination,
    }
}

fn collection_progress(counts: collection_core::StateCounts) -> CollectionProgress {
    let collection_core::StateCounts {
        paths_stabilizing,
        paths_awaiting_digest,
        paths_digested: _,
        paths_excluded: _,
        paths_unreadable: _,
        contents_unresolved,
        contents_awaiting_submission,
        contents_present,
        contents_deleted: _,
        contents_refused: _,
        contents_failing: _,
    } = counts;
    CollectionProgress {
        documents_in_archive: contents_present,
        documents_awaiting_submission: contents_awaiting_submission,
        files_under_examination: paths_stabilizing + paths_awaiting_digest + contents_unresolved,
    }
}

fn published_activity(
    activity: collection_core::Activity,
    reference: impl Fn(collection_core::FolderIdentifier) -> Option<FolderReference>,
) -> Option<Activity> {
    Some(match activity {
        collection_core::Activity::Listing { folder, directory } => Activity::Listing {
            folder: reference(folder)?,
            directory,
        },
        collection_core::Activity::Digesting { file_name } => Activity::Digesting { file_name },
        collection_core::Activity::LookingUp { content_count } => Activity::LookingUp {
            content_count: u64::try_from(content_count).unwrap_or(u64::MAX),
        },
        collection_core::Activity::Submitting { file_name, byte_size } => Activity::Submitting { file_name, byte_size },
        collection_core::Activity::FollowingDocument => Activity::FollowingDocument,
    })
}

fn attention_items(
    item: collection_core::AttentionItem,
    reference: impl Fn(collection_core::FolderIdentifier) -> Option<FolderReference>,
) -> Vec<AttentionItem> {
    match item {
        collection_core::AttentionItem::ArchiveNotConfigured => Vec::new(),
        collection_core::AttentionItem::CredentialSuspended { reason } => vec![AttentionItem::CredentialSuspended {
            reason: suspension_reason(reason),
        }],
        collection_core::AttentionItem::ArchiveOutdated => vec![AttentionItem::ArchiveOutdated],
        collection_core::AttentionItem::FolderUnavailable { folder, availability } => reference(folder)
            .zip(folder_unavailability(availability))
            .map(|(folder, unavailability)| AttentionItem::FolderUnavailable { folder, unavailability })
            .into_iter()
            .collect(),
        collection_core::AttentionItem::BacklogAwaitsDecision { folders } => folders
            .into_iter()
            .filter_map(reference)
            .map(|folder| AttentionItem::BacklogAwaitsDecision { folder })
            .collect(),
        collection_core::AttentionItem::ContentRefused { file_name, reason } => vec![AttentionItem::ContentRefused {
            file_name,
            reason: match reason {
                collection_core::content_synchronization::RefusalReason::TooLarge => ContentRefusalReason::TooLarge,
                collection_core::content_synchronization::RefusalReason::UnacceptedKind => {
                    ContentRefusalReason::UnacceptedKind
                }
            },
        }],
        collection_core::AttentionItem::ContentFailing { file_name, failures } => {
            vec![AttentionItem::ContentFailing { file_name, failures }]
        }
    }
}

fn receipt(receipt: collection_core::Receipt) -> Receipt {
    use collection_core::domain_types::DocumentStatus;
    let collection_core::Receipt {
        document,
        document_link,
        file_name,
        received_at,
        status,
    } = receipt;
    Receipt {
        document_identifier: document.as_str().to_owned(),
        document_link,
        file_name,
        received_at: system_time(received_at),
        outcome: match status {
            None
            | Some(
                DocumentStatus::AwaitingRendering
                | DocumentStatus::Processing
                | DocumentStatus::Extracting
                | DocumentStatus::RecognizingText
                | DocumentStatus::Classifying,
            ) => DocumentOutcome::Processing,
            Some(DocumentStatus::Archived) => DocumentOutcome::Archived,
            Some(DocumentStatus::Failed { failure_reason: _ }) => DocumentOutcome::Failed,
        },
    }
}

/// The archive and collector clocks never read a time before 1970.
pub(crate) fn system_time(timestamp: Timestamp) -> SystemTime {
    let Timestamp(milliseconds) = timestamp;
    SystemTime::UNIX_EPOCH + Duration::from_millis(u64::try_from(milliseconds).unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use archive_access::PermissionLevel;
    use archive_replica::MirroredArchive;
    use collection_core::archive_connection::SuspensionReason as CoreSuspensionReason;
    use collection_core::candidate_classification::{DisregardReason, ExclusionReason};
    use collection_core::domain_types::{DocumentIdentifier, DocumentStatus};
    use collection_core::folder_admission::{FolderAdmission as CoreFolderAdmission, FolderAvailability};
    use collection_core::{ConnectionStatus, StateCounts, Timestamp};

    use super::*;

    #[test]
    fn a_status_is_published_with_one_list_of_skipped_entries() {
        let downloads = collection_core::FolderIdentifier::new(1);
        let scans = collection_core::FolderIdentifier::new(2);
        let withdrawn = collection_core::FolderIdentifier::new(3);
        let backlog = collection_core::BacklogSummary {
            folders: vec![downloads],
            candidate_files: 9,
            files_already_archived: 3,
            files_deleted_from_archive: 1,
            files_refused_by_archive: 0,
            files_new: 5,
            new_contents: 4,
            excluded_files: 3,
            excluded_files_by_reason: BTreeMap::from([
                (ExclusionReason::EmptyFile, 1),
                (ExclusionReason::UnrecognizedContent, 2),
            ]),
            disregarded_files: BTreeMap::from([
                (DisregardReason::HiddenEntry, 4),
                (DisregardReason::IncompleteDownload, 2),
                (DisregardReason::SymbolicLink, 0),
            ]),
            unreadable_files: 1,
            files_under_examination: 0,
        };
        let status = collection_core::CollectorStatus {
            revision: 12,
            connection: ConnectionStatus::Suspended {
                reason: CoreSuspensionReason::CredentialRefused,
                since: Timestamp(1_700_000_000_000),
            },
            archive_origin: Some("http://localhost:3000".to_owned()),
            folders: vec![
                collection_core::FolderStatus {
                    folder: downloads,
                    root: PathBuf::from("/Users/owner/Downloads"),
                    admission: CoreFolderAdmission::AwaitingDecision,
                    availability: FolderAvailability::Available,
                    files_under_examination: 0,
                    backlog: Some(backlog.clone()),
                },
                collection_core::FolderStatus {
                    folder: scans,
                    root: PathBuf::from("/Volumes/Scans"),
                    admission: CoreFolderAdmission::Collecting {
                        decided_at: Timestamp(1_700_000_000_000),
                    },
                    availability: FolderAvailability::Missing,
                    files_under_examination: 0,
                    backlog: None,
                },
            ],
            backlog: Some(backlog),
            counts: StateCounts {
                paths_stabilizing: 1,
                paths_awaiting_digest: 2,
                paths_digested: 9,
                paths_excluded: 3,
                paths_unreadable: 1,
                contents_unresolved: 4,
                contents_awaiting_submission: 5,
                contents_present: 6,
                contents_deleted: 1,
                contents_refused: 0,
                contents_failing: 0,
            },
            activities: vec![
                collection_core::Activity::Listing {
                    folder: downloads,
                    directory: "Invoices".to_owned(),
                },
                collection_core::Activity::Listing {
                    folder: withdrawn,
                    directory: String::new(),
                },
                collection_core::Activity::LookingUp { content_count: 4 },
            ],
            attention: vec![
                collection_core::AttentionItem::CredentialSuspended {
                    reason: CoreSuspensionReason::CredentialRefused,
                },
                collection_core::AttentionItem::FolderUnavailable {
                    folder: scans,
                    availability: FolderAvailability::Missing,
                },
                collection_core::AttentionItem::BacklogAwaitsDecision {
                    folders: vec![downloads],
                },
            ],
            recent_receipts: vec![collection_core::Receipt {
                document: DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f60718293").unwrap(),
                document_link: "http://localhost:3000/documents/4c5d6e7f-8091-4a2b-9c3d-4e5f60718293".to_owned(),
                file_name: "Invoices/invoice.pdf".to_owned(),
                received_at: Timestamp(1_700_000_060_000),
                status: Some(DocumentStatus::Classifying),
            }],
            next_scheduled_at: None,
        };

        let published = publish(status);

        let downloads = FolderReference {
            identifier: FolderIdentifier { value: 1 },
            root: "/Users/owner/Downloads".to_owned(),
        };
        let scans = FolderReference {
            identifier: FolderIdentifier { value: 2 },
            root: "/Volumes/Scans".to_owned(),
        };
        let skipped = |reason, count| SkippedCount { reason, count };
        assert_eq!(
            published,
            CollectorStatus {
                revision: 12,
                folders: vec![
                    FolderStatus {
                        folder: downloads.clone(),
                        admission: FolderAdmission::AwaitingDecision {
                            backlog: BacklogSummary {
                                files_new: 5,
                                new_contents: 4,
                                files_already_archived: 3,
                                files_deleted_from_archive: 1,
                                files_refused_by_archive: 0,
                                skipped: vec![
                                    skipped(SkipReason::UnrecognizedContent, 2),
                                    skipped(SkipReason::EmptyFile, 1),
                                    skipped(SkipReason::Unreadable, 1),
                                    skipped(SkipReason::IncompleteDownload, 2),
                                    skipped(SkipReason::HiddenEntry, 4),
                                ],
                                files_under_examination: 0,
                            },
                        },
                        unavailability: None,
                    },
                    FolderStatus {
                        folder: scans.clone(),
                        admission: FolderAdmission::Collecting,
                        unavailability: Some(FolderUnavailability::Missing),
                    },
                ],
                progress: CollectionProgress {
                    documents_in_archive: 6,
                    documents_awaiting_submission: 5,
                    files_under_examination: 7,
                },
                activities: vec![
                    Activity::Listing {
                        folder: downloads.clone(),
                        directory: "Invoices".to_owned(),
                    },
                    Activity::LookingUp { content_count: 4 },
                ],
                attention: vec![
                    AttentionItem::CredentialSuspended {
                        reason: SuspensionReason::CredentialRefused
                    },
                    AttentionItem::FolderUnavailable {
                        folder: scans,
                        unavailability: FolderUnavailability::Missing,
                    },
                    AttentionItem::BacklogAwaitsDecision { folder: downloads },
                ],
                recent_receipts: vec![Receipt {
                    document_identifier: "4c5d6e7f-8091-4a2b-9c3d-4e5f60718293".to_owned(),
                    document_link: "http://localhost:3000/documents/4c5d6e7f-8091-4a2b-9c3d-4e5f60718293".to_owned(),
                    file_name: "Invoices/invoice.pdf".to_owned(),
                    received_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_060),
                    outcome: DocumentOutcome::Processing,
                }],
            }
        );
    }

    #[test]
    fn archive_connection_merges_replica_and_collector_observations() {
        let empty = ReplicaStatus {
            revision: 0,
            content_revision: 0,
            documents: 0,
            documents_awaiting_text: 0,
            archive: None,
            synchronization: SynchronizationState::Disconnected,
            fault: None,
        };
        assert_eq!(
            derive_archive_connection(&empty, None),
            ArchiveConnection::NotConfigured
        );

        let collector_connected = (
            Some("https://archive.example.org".to_owned()),
            ConnectionStatus::Connected {
                archive_origin: "https://archive.example.org".to_owned(),
            },
        );
        assert_eq!(
            derive_archive_connection(&empty, Some(&collector_connected)),
            ArchiveConnection::Configured {
                origin: "https://archive.example.org".to_owned(),
                host: "archive.example.org".to_owned(),
                condition: ConnectionCondition::Connected,
                permission: ArchivePermission::CollectOnly,
                restricted: false,
            }
        );

        let outdated_replica = ReplicaStatus {
            revision: 2,
            content_revision: 0,
            documents: 0,
            documents_awaiting_text: 0,
            archive: Some(MirroredArchive {
                origin: "https://archive.example.org".to_owned(),
                permission_level: PermissionLevel::Read,
                restricted: false,
                fill_complete: false,
                synchronized_at: None,
            }),
            synchronization: SynchronizationState::ArchiveOutdated {
                retry_at: Timestamp(1_700_003_600_000),
            },
            fault: None,
        };
        assert_eq!(
            derive_archive_connection(&outdated_replica, Some(&collector_connected)),
            ArchiveConnection::Configured {
                origin: "https://archive.example.org".to_owned(),
                host: "archive.example.org".to_owned(),
                condition: ConnectionCondition::ArchiveOutdated,
                permission: ArchivePermission::ReadAndCollect,
                restricted: false,
            }
        );
    }
}
