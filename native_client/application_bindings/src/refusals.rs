//! Why the application did not start, and why a command or representation request was not
//! carried out: one type per kind of call that holds only what the call can answer, so an
//! application words each with a total switch. No conversion from a core has a wildcard arm.

use archive_access::ArchiveCondition;
use archive_replica::ReplicaFault;
use collection_core::state_store::StoreOpenFailure;
use collection_core::{CommandRefusal, StartFailure};

use crate::published_status::{FolderReference, origin_host, path_text};

/// Why the application did not start. The application stays open and says so.
#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum ApplicationStartFailure {
    DataDirectoryUnavailable { detail: String },
    CacheDirectoryUnavailable { detail: String },
    DatabaseInUse,
    DatabaseNewerThanApplication,
    DatabaseUnusable { detail: String },
    WatcherUnavailable { detail: String },
    Unexpected { detail: String },
}

/// What any call can answer, whatever it asked for.
#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum ApplicationFault {
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
    ArchiveOutdated,
    /// The collector's records belong to another archive.
    ArchiveDiffers {
        connected_host: String,
    },
    CredentialStorageFailed {
        detail: String,
    },
    Application {
        fault: ApplicationFault,
    },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum EnrollmentRefusal {
    NotADirectory { root: String },
    AlreadyEnrolled { folder: FolderReference },
    OverlapsEnrolledFolder { folder: FolderReference },
    Application { fault: ApplicationFault },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum WithdrawalRefusal {
    FolderUnknown,
    Application { fault: ApplicationFault },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum DecisionRefusal {
    FolderUnknown,
    SurveyIncomplete { folder: FolderReference },
    AlreadyDecided { folder: FolderReference },
    Application { fault: ApplicationFault },
}

#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum RepresentationRefusal {
    DocumentUnknown,
    NotAvailableYet,
    ArchiveUnreachable,
    NoLongerArchived,
    CredentialRefused,
    NotConnected,
    ArchiveOutdated,
    ContentDiffers,
    StorageFailed { detail: String },
    Application { fault: ApplicationFault },
}

impl From<StartFailure> for ApplicationStartFailure {
    fn from(failure: StartFailure) -> ApplicationStartFailure {
        let detail = failure.to_string();
        match failure {
            StartFailure::Store(StoreOpenFailure::InUse { lock_path: _ }) => ApplicationStartFailure::DatabaseInUse,
            StartFailure::Store(StoreOpenFailure::NewerSchema { found: _, supported: _ }) => {
                ApplicationStartFailure::DatabaseNewerThanApplication
            }
            StartFailure::Store(
                StoreOpenFailure::Unreadable { renamed_to: _ }
                | StoreOpenFailure::Inaccessible(_)
                | StoreOpenFailure::Database(_),
            ) => ApplicationStartFailure::DatabaseUnusable { detail },
            StartFailure::Watcher(_) => ApplicationStartFailure::WatcherUnavailable { detail },
        }
    }
}

impl From<ReplicaFault> for ApplicationStartFailure {
    fn from(fault: ReplicaFault) -> ApplicationStartFailure {
        match fault {
            ReplicaFault::Stopped => ApplicationStartFailure::Unexpected {
                detail: "The replica stopped during start".to_owned(),
            },
            ReplicaFault::StoreFailed { detail } => ApplicationStartFailure::DatabaseUnusable { detail },
        }
    }
}

impl From<ReplicaFault> for ApplicationFault {
    fn from(fault: ReplicaFault) -> ApplicationFault {
        match fault {
            ReplicaFault::Stopped => ApplicationFault::Stopped,
            ReplicaFault::StoreFailed { detail } => ApplicationFault::StoreFailed { detail },
        }
    }
}

impl From<archive_replica::RepresentationRefusal> for RepresentationRefusal {
    fn from(refusal: archive_replica::RepresentationRefusal) -> RepresentationRefusal {
        match refusal {
            archive_replica::RepresentationRefusal::DocumentUnknown => RepresentationRefusal::DocumentUnknown,
            archive_replica::RepresentationRefusal::NotAvailableYet => RepresentationRefusal::NotAvailableYet,
            archive_replica::RepresentationRefusal::ArchiveUnreachable => RepresentationRefusal::ArchiveUnreachable,
            archive_replica::RepresentationRefusal::NoLongerArchived => RepresentationRefusal::NoLongerArchived,
            archive_replica::RepresentationRefusal::CredentialRefused => RepresentationRefusal::CredentialRefused,
            archive_replica::RepresentationRefusal::NotConnected => RepresentationRefusal::NotConnected,
            archive_replica::RepresentationRefusal::ArchiveOutdated => RepresentationRefusal::ArchiveOutdated,
            archive_replica::RepresentationRefusal::ContentDiffers => RepresentationRefusal::ContentDiffers,
            archive_replica::RepresentationRefusal::StorageFailed { detail } => {
                RepresentationRefusal::StorageFailed { detail }
            }
            archive_replica::RepresentationRefusal::Replica(fault) => {
                RepresentationRefusal::Application { fault: fault.into() }
            }
        }
    }
}

/// The answer of `GET /api/v1/authorization`.
impl From<ArchiveCondition> for ConnectionRefusal {
    fn from(condition: ArchiveCondition) -> ConnectionRefusal {
        match condition {
            ArchiveCondition::CredentialRefused => ConnectionRefusal::TokenRefused,
            ArchiveCondition::CredentialInsufficient => ConnectionRefusal::TokenInsufficient,
            ArchiveCondition::RouteUnknown => ConnectionRefusal::ArchiveOutdated,
            ArchiveCondition::ServiceUnavailable { retry_after: _ } => ConnectionRefusal::ArchiveUnavailable,
            ArchiveCondition::ConnectionFailed | ArchiveCondition::TimedOut => ConnectionRefusal::ArchiveUnreachable,
            ArchiveCondition::ServerError => ConnectionRefusal::ArchiveFailed,
            ArchiveCondition::ProtocolViolation { detail: _ } => ConnectionRefusal::NotAnArchive,
        }
    }
}

fn unexpected(refusal: &CommandRefusal) -> ApplicationFault {
    ApplicationFault::Unexpected {
        detail: refusal.to_string(),
    }
}

/// The refusal of a status read or locked-origin read.
pub(crate) fn application_fault(refusal: CommandRefusal) -> ApplicationFault {
    match refusal {
        CommandRefusal::CollectorStopped => ApplicationFault::Stopped,
        CommandRefusal::StoreFailed { detail } => ApplicationFault::StoreFailed { detail },
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

pub(crate) fn collector_connection_refusal(refusal: CommandRefusal) -> ConnectionRefusal {
    match refusal {
        CommandRefusal::ArchiveAddressInvalid { detail: _ } => ConnectionRefusal::AddressInvalid,
        CommandRefusal::ArchiveOriginDiffers { connected_origin } => ConnectionRefusal::ArchiveDiffers {
            connected_host: origin_host(&connected_origin),
        },
        CommandRefusal::CredentialStorageFailed { detail } => ConnectionRefusal::CredentialStorageFailed { detail },
        CommandRefusal::CollectorStopped => ApplicationFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => ApplicationFault::StoreFailed { detail }.into(),
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
    reference: impl Fn(collection_core::FolderIdentifier) -> Result<FolderReference, ApplicationFault>,
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
        CommandRefusal::CollectorStopped => ApplicationFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => ApplicationFault::StoreFailed { detail }.into(),
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
        CommandRefusal::CollectorStopped => ApplicationFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => ApplicationFault::StoreFailed { detail }.into(),
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
    reference: impl Fn(collection_core::FolderIdentifier) -> Result<FolderReference, ApplicationFault>,
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
        CommandRefusal::CollectorStopped => ApplicationFault::Stopped.into(),
        CommandRefusal::StoreFailed { detail } => ApplicationFault::StoreFailed { detail }.into(),
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
    ApplicationStartFailure,
    ApplicationFault,
    ConnectionRefusal,
    EnrollmentRefusal,
    WithdrawalRefusal,
    DecisionRefusal,
    RepresentationRefusal
);

macro_rules! from_application_fault {
    ($($refusal:ident),+) => {$(
        impl From<ApplicationFault> for $refusal {
            fn from(fault: ApplicationFault) -> $refusal {
                $refusal::Application { fault }
            }
        }
    )+};
}

from_application_fault!(
    ConnectionRefusal,
    EnrollmentRefusal,
    WithdrawalRefusal,
    DecisionRefusal,
    RepresentationRefusal
);
