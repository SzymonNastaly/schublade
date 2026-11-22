//! Why the collector did not start, and why a command was not carried out: one type per command
//! that holds only what the command can answer, so an application words each with a total
//! function. No conversion from the core has a wildcard arm.

use collection_core::archive_connection::ArchiveCondition;
use collection_core::state_store::StoreOpenFailure;
use collection_core::{CommandRefusal, StartFailure};

use crate::published_status::{FolderReference, origin_host, path_text};

/// Why the collector did not start. The application stays open and says so.
#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum CollectorStartFailure {
    DataDirectoryUnavailable { detail: String },
    DatabaseInUse,
    DatabaseNewerThanApplication,
    DatabaseUnusable { detail: String },
    WatcherUnavailable { detail: String },
}

/// What any command can answer, whatever it asked for.
#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum CollectorFault {
    Stopped,
    StoreFailed {
        detail: String,
    },
    /// A refusal the command cannot cause, in the core's own sentence.
    Unexpected {
        detail: String,
    },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum ConnectionRefusal {
    AddressInvalid,
    TokenRefused,
    TokenInsufficient,
    ArchiveUnreachable,
    ArchiveUnavailable,
    ArchiveFailed,
    NotAnArchive,
    /// The collector's records belong to another archive.
    ArchiveDiffers {
        connected_host: String,
    },
    CredentialStorageFailed {
        detail: String,
    },
    Collector {
        fault: CollectorFault,
    },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum EnrollmentRefusal {
    NotADirectory { root: String },
    AlreadyEnrolled { folder: FolderReference },
    OverlapsEnrolledFolder { folder: FolderReference },
    Collector { fault: CollectorFault },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum WithdrawalRefusal {
    FolderUnknown,
    Collector { fault: CollectorFault },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum DecisionRefusal {
    FolderUnknown,
    SurveyIncomplete { folder: FolderReference },
    AlreadyDecided { folder: FolderReference },
    Collector { fault: CollectorFault },
}

impl From<StartFailure> for CollectorStartFailure {
    fn from(failure: StartFailure) -> CollectorStartFailure {
        let detail = failure.to_string();
        match failure {
            StartFailure::Store(StoreOpenFailure::InUse { lock_path: _ }) => CollectorStartFailure::DatabaseInUse,
            StartFailure::Store(StoreOpenFailure::NewerSchema { found: _, supported: _ }) => {
                CollectorStartFailure::DatabaseNewerThanApplication
            }
            StartFailure::Store(
                StoreOpenFailure::Unreadable { renamed_to: _ }
                | StoreOpenFailure::Inaccessible(_)
                | StoreOpenFailure::Database(_),
            ) => CollectorStartFailure::DatabaseUnusable { detail },
            StartFailure::Watcher(_) => CollectorStartFailure::WatcherUnavailable { detail },
        }
    }
}

/// The answer of the credential check.
impl From<ArchiveCondition> for ConnectionRefusal {
    fn from(condition: ArchiveCondition) -> ConnectionRefusal {
        match condition {
            ArchiveCondition::CredentialRefused => ConnectionRefusal::TokenRefused,
            ArchiveCondition::CredentialInsufficient => ConnectionRefusal::TokenInsufficient,
            ArchiveCondition::ServiceUnavailable { retry_after: _ } => ConnectionRefusal::ArchiveUnavailable,
            ArchiveCondition::ConnectionFailed | ArchiveCondition::TimedOut => ConnectionRefusal::ArchiveUnreachable,
            ArchiveCondition::ServerError | ArchiveCondition::DigestDisagreement => ConnectionRefusal::ArchiveFailed,
            ArchiveCondition::ProtocolViolation { detail: _ } => ConnectionRefusal::NotAnArchive,
        }
    }
}

fn unexpected(refusal: &CommandRefusal) -> CollectorFault {
    CollectorFault::Unexpected {
        detail: refusal.to_string(),
    }
}

/// The refusal of a status read.
pub(crate) fn collector_fault(refusal: CommandRefusal) -> CollectorFault {
    match refusal {
        CommandRefusal::CollectorStopped => CollectorFault::Stopped,
        CommandRefusal::StoreFailed { detail } => CollectorFault::StoreFailed { detail },
        refusal @ (CommandRefusal::ArchiveAddressInvalid { .. }
        | CommandRefusal::ArchiveOriginDiffers { .. }
        | CommandRefusal::CredentialStorageFailed { .. }
        | CommandRefusal::FolderRootNotADirectory { .. }
        | CommandRefusal::FolderAlreadyEnrolled { .. }
        | CommandRefusal::FolderOverlapsEnrolledFolder { .. }
        | CommandRefusal::FolderUnknown { .. }
        | CommandRefusal::SurveyIncomplete { .. }
        | CommandRefusal::BacklogAlreadyDecided { .. }
        | CommandRefusal::IdleTimeout) => unexpected(&refusal),
    }
}

pub(crate) fn connection_refusal(refusal: CommandRefusal) -> ConnectionRefusal {
    match refusal {
        CommandRefusal::ArchiveAddressInvalid { detail: _ } => ConnectionRefusal::AddressInvalid,
        CommandRefusal::ArchiveOriginDiffers { connected_origin } => ConnectionRefusal::ArchiveDiffers {
            connected_host: origin_host(&connected_origin),
        },
        CommandRefusal::CredentialStorageFailed { detail } => ConnectionRefusal::CredentialStorageFailed { detail },
        CommandRefusal::CollectorStopped => CollectorFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => CollectorFault::StoreFailed { detail }.into(),
        refusal @ (CommandRefusal::FolderRootNotADirectory { .. }
        | CommandRefusal::FolderAlreadyEnrolled { .. }
        | CommandRefusal::FolderOverlapsEnrolledFolder { .. }
        | CommandRefusal::FolderUnknown { .. }
        | CommandRefusal::SurveyIncomplete { .. }
        | CommandRefusal::BacklogAlreadyDecided { .. }
        | CommandRefusal::IdleTimeout) => unexpected(&refusal).into(),
    }
}

/// `reference` reads the folder a refusal names from the status. Its fault becomes the refusal.
pub(crate) fn enrollment_refusal(
    refusal: CommandRefusal,
    reference: impl Fn(collection_core::FolderIdentifier) -> Result<FolderReference, CollectorFault>,
) -> EnrollmentRefusal {
    match refusal {
        CommandRefusal::FolderRootNotADirectory { root } => EnrollmentRefusal::NotADirectory { root: path_text(&root) },
        CommandRefusal::FolderAlreadyEnrolled { folder } => reference(folder)
            .map_or_else(EnrollmentRefusal::from, |folder| EnrollmentRefusal::AlreadyEnrolled {
                folder,
            }),
        CommandRefusal::FolderOverlapsEnrolledFolder { folder } => reference(folder)
            .map_or_else(EnrollmentRefusal::from, |folder| {
                EnrollmentRefusal::OverlapsEnrolledFolder { folder }
            }),
        CommandRefusal::CollectorStopped => CollectorFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => CollectorFault::StoreFailed { detail }.into(),
        refusal @ (CommandRefusal::ArchiveAddressInvalid { .. }
        | CommandRefusal::ArchiveOriginDiffers { .. }
        | CommandRefusal::CredentialStorageFailed { .. }
        | CommandRefusal::FolderUnknown { .. }
        | CommandRefusal::SurveyIncomplete { .. }
        | CommandRefusal::BacklogAlreadyDecided { .. }
        | CommandRefusal::IdleTimeout) => unexpected(&refusal).into(),
    }
}

pub(crate) fn withdrawal_refusal(refusal: CommandRefusal) -> WithdrawalRefusal {
    match refusal {
        CommandRefusal::FolderUnknown { folder: _ } => WithdrawalRefusal::FolderUnknown,
        CommandRefusal::CollectorStopped => CollectorFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => CollectorFault::StoreFailed { detail }.into(),
        refusal @ (CommandRefusal::ArchiveAddressInvalid { .. }
        | CommandRefusal::ArchiveOriginDiffers { .. }
        | CommandRefusal::CredentialStorageFailed { .. }
        | CommandRefusal::FolderRootNotADirectory { .. }
        | CommandRefusal::FolderAlreadyEnrolled { .. }
        | CommandRefusal::FolderOverlapsEnrolledFolder { .. }
        | CommandRefusal::SurveyIncomplete { .. }
        | CommandRefusal::BacklogAlreadyDecided { .. }
        | CommandRefusal::IdleTimeout) => unexpected(&refusal).into(),
    }
}

/// `reference` reads the folder a refusal names from the status. Its fault becomes the refusal.
pub(crate) fn decision_refusal(
    refusal: CommandRefusal,
    reference: impl Fn(collection_core::FolderIdentifier) -> Result<FolderReference, CollectorFault>,
) -> DecisionRefusal {
    match refusal {
        CommandRefusal::FolderUnknown { folder: _ } => DecisionRefusal::FolderUnknown,
        CommandRefusal::SurveyIncomplete { folder } => reference(folder).map_or_else(DecisionRefusal::from, |folder| {
            DecisionRefusal::SurveyIncomplete { folder }
        }),
        CommandRefusal::BacklogAlreadyDecided { folder } => reference(folder)
            .map_or_else(DecisionRefusal::from, |folder| DecisionRefusal::AlreadyDecided {
                folder,
            }),
        CommandRefusal::CollectorStopped => CollectorFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => CollectorFault::StoreFailed { detail }.into(),
        refusal @ (CommandRefusal::ArchiveAddressInvalid { .. }
        | CommandRefusal::ArchiveOriginDiffers { .. }
        | CommandRefusal::CredentialStorageFailed { .. }
        | CommandRefusal::FolderRootNotADirectory { .. }
        | CommandRefusal::FolderAlreadyEnrolled { .. }
        | CommandRefusal::FolderOverlapsEnrolledFolder { .. }
        | CommandRefusal::IdleTimeout) => unexpected(&refusal).into(),
    }
}

/// UniFFI exports an error only with `Display`. The text is for a log, because an application
/// words each case itself.
macro_rules! exported_error {
    ($($error:ty),+) => {$(
        impl std::fmt::Display for $error {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(formatter, "{self:?}")
            }
        }

        impl std::error::Error for $error {}
    )+};
}

exported_error!(
    CollectorStartFailure,
    CollectorFault,
    ConnectionRefusal,
    EnrollmentRefusal,
    WithdrawalRefusal,
    DecisionRefusal
);

macro_rules! from_collector_fault {
    ($($refusal:ident),+) => {$(
        impl From<CollectorFault> for $refusal {
            fn from(fault: CollectorFault) -> $refusal {
                $refusal::Collector { fault }
            }
        }
    )+};
}

from_collector_fault!(ConnectionRefusal, EnrollmentRefusal, WithdrawalRefusal, DecisionRefusal);
