//! The application as Swift sees it: one function that starts the core, one root object that owns
//! the connection flow and system lifecycle, the library with its local copy and in-memory
//! listings, and the optional collector.
//!
//! What this crate keeps from every platform application, so that none repeats it:
//! - following each half's status by revision (`status_following`);
//! - running every blocking core, store, Keychain, and network call on the `blocking` pool so the
//!   thread polling an exported future never blocks;
//! - one connection flow with pre-network archive-origin checks and crash repair at startup;
//! - exhaustive status and refusal conversions (`published_status`, `published_library`, `refusals`).

uniffi::setup_scaffolding!();

#[cfg(test)]
mod application_fixture;
mod published_library;
mod published_status;
mod refusals;
mod status_following;

use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveCondition, ArchiveExchange, ArchiveToken, CredentialStore,
    FixedCredentialStore, PermissionLevel, RememberingCredentialStore, read_authorization,
};
use archive_replica::{Attendance, Replica, ReplicaEvent, ReplicaSettings, WakeReason};
use collection_core::state_store::StoreOpenFailure;
use collection_core::{CollectorEvent, CollectorSettings, StartFailure};

pub use published_library::{
    Amount, CalendarDate, CategoryIdentifier, DetailField, DocumentCondition, DocumentDetail, DocumentIdentifier,
    DocumentListing, DocumentPerson, DocumentRow, FailureReason, FieldValue, IngestionStage, LibraryCopy,
    LibraryCounts, LibraryFacets, LibraryScope, LibraryStatus, ListingAnswer, ListingDifference, ListingHeading,
    ListingOrder, ListingRequest, ListingRow, LocalFile, MemberIdentifier, NamedScope, OriginalKind,
    PublishedPermissionLevel, RowPassage, ScopeCount, SenderIdentifier, TagIdentifier,
};
pub use published_status::{
    Activity, ArchiveConnection, ArchivePermission, AttentionItem, BacklogSummary, CollectionProgress, CollectorStatus,
    ConnectionCondition, FolderAdmission, FolderIdentifier, FolderReference, FolderStatus, FolderUnavailability,
    Receipt, SkipReason, SkippedCount, SuspensionReason,
};
pub use refusals::{
    ApplicationFault, ApplicationStartFailure, ConnectionRefusal, DecisionRefusal, EnrollmentRefusal,
    RepresentationRefusal, WithdrawalRefusal,
};

use published_library::{
    document_detail, library_facets, listing_answer, published_permission_level, to_core_listing_request,
};
use published_status::{origin_host, path_text, publish};
use refusals::{
    application_fault, collector_connection_refusal, decision_refusal, enrollment_refusal, withdrawal_refusal,
};
use status_following::{LibraryAnnouncements, RevisionAnnouncements};

/// Where the application keeps its databases, its downloaded cache, and its credential.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ApplicationConfiguration {
    /// Holds `collector.sqlite` (when enabled) and `replica.sqlite`. Created when missing.
    pub data_directory: String,
    /// Holds `originals/` and `thumbnails/`. Created when missing; the system may empty it.
    pub cache_directory: String,
    /// The most bytes of originals kept on disk, or `None` to keep every downloaded original.
    pub original_storage_limit: Option<u64>,
    pub credential_storage: CredentialStorage,
    pub collection: CollectionPlacement,
}

/// Whether this application includes the local folder collector. An iPhone application starts
/// without one.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum CollectionPlacement {
    Collector,
    Absent,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum CredentialStorage {
    /// One Keychain item per archive origin under this service name.
    #[cfg(target_os = "macos")]
    Keychain { service_name: String },
    /// The token lives only in this process, for runs that must not touch the Keychain.
    ProcessMemory,
}

impl CredentialStorage {
    fn store(&self) -> Box<dyn CredentialStore> {
        match self {
            #[cfg(target_os = "macos")]
            CredentialStorage::Keychain { service_name } => {
                Box::new(archive_access::KeychainCredentialStore::new(service_name))
            }
            CredentialStorage::ProcessMemory => Box::new(FixedCredentialStore::new(None)),
        }
    }
}

/// What a successful `connect_archive` granted, so a screen can report read-only tokens cleanly.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ConnectionGrant {
    pub origin: String,
    pub host: String,
    pub token_description: String,
    pub permission: PublishedPermissionLevel,
    pub restricted: bool,
    pub reads: bool,
    pub collects: bool,
}

/// Reads `GET /api/v1/authorization` for an archive address and token.
type AuthorizationReader =
    Box<dyn Fn(&ArchiveAddress, &ArchiveToken) -> Result<ArchiveAuthorization, ArchiveCondition> + Send + Sync>;

/// Starts the replica and, when `collection` is `Collector`, the collector over one shared
/// remembering credential store. Repairs a half-completed connection from a prior crash before
/// returning the root object.
#[uniffi::export]
pub async fn start_application_core(
    configuration: ApplicationConfiguration,
) -> Result<Arc<ApplicationCore>, ApplicationStartFailure> {
    blocking::unblock(move || {
        let ApplicationConfiguration {
            data_directory,
            cache_directory,
            original_storage_limit,
            credential_storage,
            collection,
        } = configuration;
        let data_directory = PathBuf::from(data_directory);
        std::fs::create_dir_all(&data_directory).map_err(|error| {
            ApplicationStartFailure::DataDirectoryUnavailable {
                detail: error.to_string(),
            }
        })?;
        let cache_directory = PathBuf::from(cache_directory);
        std::fs::create_dir_all(&cache_directory).map_err(|error| {
            ApplicationStartFailure::CacheDirectoryUnavailable {
                detail: error.to_string(),
            }
        })?;
        let credentials = Arc::new(RememberingCredentialStore::new(credential_storage.store()));

        let started_collector = match collection {
            CollectionPlacement::Collector => {
                let collector_db = data_directory.join("collector.sqlite");
                let settings = || CollectorSettings::new(collector_db.clone(), Box::new(Arc::clone(&credentials)));
                let started = match collection_core::Collector::start(settings()) {
                    // The core renamed the corrupt database aside, so the second start opens a new one.
                    Err(StartFailure::Store(StoreOpenFailure::Unreadable { .. })) => {
                        collection_core::Collector::start(settings())
                    }
                    started => started,
                };
                Some(started?)
            }
            CollectionPlacement::Absent => None,
        };

        let replica_settings = ReplicaSettings {
            database_path: data_directory.join("replica.sqlite"),
            representation_directory: cache_directory,
            original_byte_limit: original_storage_limit,
            credential_store: Box::new(Arc::clone(&credentials)),
            ..ReplicaSettings::new(
                data_directory.join("replica.sqlite"),
                PathBuf::new(),
                Box::new(FixedCredentialStore::new(None)),
            )
        };
        let (replica, replica_events) = Replica::start(replica_settings)?;

        let authorization_reader: AuthorizationReader =
            Box::new(|address, token| read_authorization(&ArchiveExchange::new(address, token)));
        ApplicationCore::assemble(
            started_collector,
            (replica, replica_events),
            credentials,
            authorization_reader,
        )
    })
    .await
}

#[derive(uniffi::Object)]
pub struct ApplicationCore {
    credentials: Arc<RememberingCredentialStore>,
    authorization_reader: AuthorizationReader,
    connect_lock: Mutex<()>,
    collector_core: Arc<RwLock<Option<collection_core::Collector>>>,
    replica_core: Arc<RwLock<Option<Arc<Replica>>>>,
    library: Arc<Library>,
    collector: Option<Arc<Collector>>,
    collector_announcements: Option<Arc<RevisionAnnouncements>>,
    library_announcements: Arc<LibraryAnnouncements>,
}

#[uniffi::export]
impl ApplicationCore {
    /// The one connection flow for both parts. Checks an archive-origin lock before calling the
    /// network, reads `GET /api/v1/authorization` before storing anything, writes the token once,
    /// attaches the library when the token may read, and connects the collector when the token is
    /// unrestricted and this platform collects.
    pub async fn connect_archive(
        self: Arc<Self>,
        address: String,
        token: String,
    ) -> Result<ConnectionGrant, ConnectionRefusal> {
        blocking::unblock(move || {
            let _connect_guard = self.connect_lock.lock().unwrap_or_else(PoisonError::into_inner);
            if self.library_announcements.is_ended() {
                return Err(ApplicationFault::Stopped.into());
            }
            let address = ArchiveAddress::parse(&address).map_err(|_| ConnectionRefusal::AddressInvalid)?;
            let token = ArchiveToken::new(token);

            // Check the collector's locked origin before hitting the network so an unreachable
            // second archive still answers ArchiveDiffers rather than ArchiveUnreachable.
            if self.collector.is_some() {
                let locked_origin = with_collector_core(&self.collector_core, |core| {
                    core.locked_archive_origin().map_err(application_fault)
                })?;
                if let Some(connected_origin) = locked_origin
                    && connected_origin != address.origin()
                {
                    return Err(ConnectionRefusal::ArchiveDiffers {
                        connected_host: origin_host(&connected_origin),
                    });
                }
            }

            let authorization = (self.authorization_reader)(&address, &token)?;
            let reads = authorization.permission_level >= PermissionLevel::Read;
            let collects = self.collector.is_some() && !authorization.restricted;
            if !reads && !collects {
                return Err(ConnectionRefusal::TokenInsufficient);
            }

            self.credentials
                .write(&address, &token)
                .map_err(|failure| ConnectionRefusal::CredentialStorageFailed { detail: failure.detail })?;

            if reads {
                let replica = replica_handle(&self.replica_core)?;
                replica
                    .attach_archive(
                        address.clone(),
                        ArchiveToken::new(token.secret().to_owned()),
                        authorization.clone(),
                    )
                    .map_err(ApplicationFault::from)?;
            }
            if collects {
                with_collector_core(&self.collector_core, |core| {
                    core.connect_archive(address.clone(), token)
                        .map_err(collector_connection_refusal)
                })?;
            }

            let collector_snapshot = if self.collector.is_some() {
                Some(read_collector_connection(&self.collector_core)?)
            } else {
                None
            };
            self.library_announcements
                .refresh(&self.replica_core, collector_snapshot);

            let origin = address.origin();
            Ok(ConnectionGrant {
                host: origin_host(&origin),
                origin,
                token_description: authorization.token_description,
                permission: published_permission_level(authorization.permission_level),
                restricted: authorization.restricted,
                reads,
                collects,
            })
        })
        .await
    }

    pub fn library(&self) -> Arc<Library> {
        Arc::clone(&self.library)
    }

    pub fn collector(&self) -> Option<Arc<Collector>> {
        self.collector.clone()
    }

    /// Whether a window currently shows the library. While attended, the copy refreshes every
    /// minute and wakes immediately.
    pub fn interface_attended(&self, attended: bool) {
        if let Ok(replica) = replica_handle(&self.replica_core) {
            replica.set_attendance(if attended {
                Attendance::Attended
            } else {
                Attendance::Unattended
            });
            if attended {
                replica.wake(WakeReason::ApplicationActivated);
            }
        }
    }

    /// The system woke from sleep: both cores probe and synchronize.
    pub fn system_resumed(&self) {
        if let Ok(core) = self.collector_core.try_read()
            && let Some(core) = core.as_ref()
        {
            core.notify_system_resumed();
        }
        if let Ok(replica) = replica_handle(&self.replica_core) {
            replica.wake(WakeReason::SystemResumed);
        }
    }

    /// Stops both coordinators and ends every waiting read. Idempotent.
    pub async fn shutdown(self: Arc<Self>) {
        blocking::unblock(move || {
            let collector = self
                .collector_core
                .write()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            let replica = self.replica_core.write().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(announcements) = &self.collector_announcements {
                announcements.mark_ended();
            }
            self.library_announcements.mark_stopped();
            if let Some(collector) = collector {
                collector.shutdown();
            }
            if let Some(replica) = replica {
                replica.stop();
            }
        })
        .await;
    }
}

impl ApplicationCore {
    fn assemble(
        started_collector: Option<(collection_core::Collector, Receiver<CollectorEvent>)>,
        started_replica: (Replica, Receiver<ReplicaEvent>),
        credentials: Arc<RememberingCredentialStore>,
        authorization_reader: AuthorizationReader,
    ) -> Result<Arc<ApplicationCore>, ApplicationStartFailure> {
        let (replica, replica_events) = started_replica;

        // Crash repair: if the mirror recorded an unrestricted archive whose token is stored
        // and the collector still lacks a connection, connect the collector offline now.
        let (collector, collector_events) = match started_collector {
            Some((collector, events)) => {
                let collector_status = collector
                    .status()
                    .map_err(|refusal| ApplicationStartFailure::Unexpected {
                        detail: refusal.to_string(),
                    })?;
                let replica_status = replica.status();
                if collector_status.archive_origin.is_none()
                    && !matches!(
                        replica_status.synchronization,
                        archive_replica::SynchronizationState::Disconnected
                    )
                    && let Some(mirrored) = replica_status.archive
                    && !mirrored.restricted
                    && let Ok(address) = ArchiveAddress::parse(&mirrored.origin)
                    && let Ok(Some(token)) = credentials.read(&address)
                {
                    let _ = collector.connect_archive(address, token);
                }
                (Some(collector), Some(events))
            }
            None => (None, None),
        };

        let initial_collector_connection = match &collector {
            Some(core) => {
                let status = core.status().map_err(|refusal| ApplicationStartFailure::Unexpected {
                    detail: refusal.to_string(),
                })?;
                Some((status.archive_origin, status.connection))
            }
            None => None,
        };

        let collector_core = Arc::new(RwLock::new(collector));
        let replica_core = Arc::new(RwLock::new(Some(Arc::new(replica))));

        let library_announcements =
            LibraryAnnouncements::follow(replica_events, Arc::clone(&replica_core), initial_collector_connection)?;

        let collector_announcements = collector_events.map(|events| {
            RevisionAnnouncements::follow(
                events,
                Arc::clone(&collector_core),
                Arc::clone(&replica_core),
                Arc::clone(&library_announcements),
            )
        });

        let collector_object = collector_announcements.as_ref().map(|announcements| {
            Arc::new(Collector {
                core: Arc::clone(&collector_core),
                announcements: Arc::clone(announcements),
            })
        });

        let library_object = Arc::new(Library {
            core: Arc::clone(&replica_core),
            announcements: Arc::clone(&library_announcements),
        });

        Ok(Arc::new(ApplicationCore {
            credentials,
            authorization_reader,
            connect_lock: Mutex::new(()),
            collector_core,
            replica_core,
            library: library_object,
            collector: collector_object,
            collector_announcements,
            library_announcements,
        }))
    }
}

#[derive(uniffi::Object)]
pub struct Library {
    core: Arc<RwLock<Option<Arc<Replica>>>>,
    announcements: Arc<LibraryAnnouncements>,
}

#[uniffi::export]
impl Library {
    /// The first library status whose revision exceeds `revision`, or the current status for
    /// `None`. Ends with `ApplicationFault::Stopped` after `shutdown`.
    pub async fn status_after(self: Arc<Self>, revision: Option<u64>) -> Result<LibraryStatus, ApplicationFault> {
        self.announcements.status_after(revision).await
    }

    pub async fn list_documents(
        self: Arc<Self>,
        request: ListingRequest,
        preceding: Option<Arc<DocumentListing>>,
    ) -> Result<ListingAnswer, ApplicationFault> {
        blocking::unblock(move || {
            let core_request = to_core_listing_request(request)?;
            let replica = replica_handle(&self.core)?;
            let answer = replica.list_documents(&core_request, preceding.as_deref().map(DocumentListing::inner))?;
            Ok(listing_answer(answer))
        })
        .await
    }

    pub async fn facets(self: Arc<Self>) -> Result<LibraryFacets, ApplicationFault> {
        blocking::unblock(move || {
            let replica = replica_handle(&self.core)?;
            Ok(library_facets(replica.facets()?))
        })
        .await
    }

    pub async fn document(
        self: Arc<Self>,
        document: DocumentIdentifier,
    ) -> Result<Option<DocumentDetail>, ApplicationFault> {
        blocking::unblock(move || {
            let replica = replica_handle(&self.core)?;
            let Some(identifier) = archive_access::DocumentIdentifier::parse(&document.value) else {
                return Ok(None);
            };
            Ok(replica.document(&identifier)?.map(document_detail))
        })
        .await
    }

    pub async fn extracted_text(
        self: Arc<Self>,
        document: DocumentIdentifier,
    ) -> Result<String, RepresentationRefusal> {
        blocking::unblock(move || {
            let replica = replica_handle(&self.core)?;
            let identifier = archive_access::DocumentIdentifier::parse(&document.value)
                .ok_or(RepresentationRefusal::DocumentUnknown)?;
            replica.extracted_text(&identifier).map_err(RepresentationRefusal::from)
        })
        .await
    }

    pub async fn original(self: Arc<Self>, document: DocumentIdentifier) -> Result<LocalFile, RepresentationRefusal> {
        blocking::unblock(move || {
            let replica = replica_handle(&self.core)?;
            let identifier = archive_access::DocumentIdentifier::parse(&document.value)
                .ok_or(RepresentationRefusal::DocumentUnknown)?;
            let path = replica.original(&identifier).map_err(RepresentationRefusal::from)?;
            Ok(LocalFile { path: path_text(&path) })
        })
        .await
    }

    pub async fn thumbnail(
        self: Arc<Self>,
        document: DocumentIdentifier,
    ) -> Result<Option<LocalFile>, RepresentationRefusal> {
        blocking::unblock(move || {
            let replica = replica_handle(&self.core)?;
            let identifier = archive_access::DocumentIdentifier::parse(&document.value)
                .ok_or(RepresentationRefusal::DocumentUnknown)?;
            let path = replica.thumbnail(&identifier).map_err(RepresentationRefusal::from)?;
            Ok(path.map(|path| LocalFile { path: path_text(&path) }))
        })
        .await
    }

    /// Synchronizes the copy now, for the Refresh command.
    pub fn synchronize(&self) {
        if let Ok(replica) = replica_handle(&self.core) {
            replica.wake(WakeReason::PersonRequested);
        }
    }
}

#[derive(uniffi::Object)]
pub struct Collector {
    core: Arc<RwLock<Option<collection_core::Collector>>>,
    announcements: Arc<RevisionAnnouncements>,
}

#[uniffi::export]
impl Collector {
    /// The first collector status whose revision exceeds `revision`, or the current status for
    /// `None`. Ends with `ApplicationFault::Stopped` after `shutdown`.
    pub async fn status_after(self: Arc<Self>, revision: Option<u64>) -> Result<CollectorStatus, ApplicationFault> {
        if let Some(known) = revision {
            self.announcements.announcement_above(known).await;
        }
        blocking::unblock(move || with_collector_core(&self.core, read_collector_status)).await
    }

    /// Starts the survey of a folder. Nothing in it uploads before `decide_backlog`.
    pub async fn enroll_folder(self: Arc<Self>, root: String) -> Result<FolderReference, EnrollmentRefusal> {
        blocking::unblock(move || {
            with_collector_core(&self.core, |core| match core.enroll_folder(PathBuf::from(root)) {
                Ok(folder) => Ok(folder_reference(core, folder)?),
                Err(refusal) => Err(enrollment_refusal(refusal, |folder| folder_reference(core, folder))),
            })
        })
        .await
    }

    /// Stops collecting from a folder. The archive keeps what it received.
    pub async fn withdraw_folder(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), WithdrawalRefusal> {
        blocking::unblock(move || {
            with_collector_core(&self.core, |core| {
                core.withdraw_folder(folder.into()).map_err(withdrawal_refusal)
            })
        })
        .await
    }

    /// Uploads the backlog of exactly this folder and collects from it from then on.
    pub async fn decide_backlog(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), DecisionRefusal> {
        blocking::unblock(move || {
            with_collector_core(&self.core, |core| {
                core.decide_backlog(&[folder.into()])
                    .map_err(|refusal| decision_refusal(refusal, |folder| folder_reference(core, folder)))
            })
        })
        .await
    }
}

fn replica_handle(core: &RwLock<Option<Arc<Replica>>>) -> Result<Arc<Replica>, ApplicationFault> {
    core.read()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .cloned()
        .ok_or(ApplicationFault::Stopped)
}

fn with_collector_core<Answer, Refusal: From<ApplicationFault>>(
    core: &RwLock<Option<collection_core::Collector>>,
    call: impl FnOnce(&collection_core::Collector) -> Result<Answer, Refusal>,
) -> Result<Answer, Refusal> {
    match core.read().unwrap_or_else(PoisonError::into_inner).as_ref() {
        Some(core) => call(core),
        None => Err(ApplicationFault::Stopped.into()),
    }
}

pub(crate) fn read_collector_connection(
    core: &RwLock<Option<collection_core::Collector>>,
) -> Result<(Option<String>, collection_core::ConnectionStatus), ApplicationFault> {
    with_collector_core(core, |collector| {
        let status = collector.status().map_err(application_fault)?;
        Ok((status.archive_origin, status.connection))
    })
}

fn read_collector_status(core: &collection_core::Collector) -> Result<CollectorStatus, ApplicationFault> {
    core.status().map(publish).map_err(application_fault)
}

/// The folder as the status lists it, for an answer that names a folder.
fn folder_reference(
    core: &collection_core::Collector,
    folder: collection_core::FolderIdentifier,
) -> Result<FolderReference, ApplicationFault> {
    read_collector_status(core)?
        .folders
        .into_iter()
        .map(|listed| listed.folder)
        .find(|listed| listed.identifier == folder.into())
        .ok_or_else(|| ApplicationFault::Unexpected {
            detail: format!("Folder {} is no longer enrolled", folder.value()),
        })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use archive_access::{ArchiveCondition, PermissionLevel};
    use archive_replica::ArchiveReader;

    use super::*;
    use crate::application_fixture::{
        ARCHIVE_ADDRESS, ApplicationFixture, TOKEN, follow_collector_until, follow_library_until,
    };

    #[test]
    fn every_refusal_of_the_core_reaches_the_command_that_caused_it() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let core = || Arc::clone(&fixture.core);
        let collector = || fixture.core.collector().unwrap();
        let library = || fixture.core.library();
        let connect = |address: &str| pollster::block_on(core().connect_archive(address.to_owned(), TOKEN.to_owned()));
        let enroll = |root: &str| pollster::block_on(collector().enroll_folder(root.to_owned()));
        let withdraw = |value: i64| pollster::block_on(collector().withdraw_folder(FolderIdentifier { value }));
        let decide = |value: i64| pollster::block_on(collector().decide_backlog(FolderIdentifier { value }));
        let root = fixture.create_directory("Scans");
        let inner = fixture.create_directory("Scans/2026");
        let absent = format!("{root}/absent");
        std::fs::write(format!("{root}/letter.pdf"), b"%PDF-1.7 a letter").unwrap();
        let folder = FolderReference {
            identifier: FolderIdentifier { value: 1 },
            root: root.clone(),
        };

        assert_eq!(connect("archive.example.org"), Err(ConnectionRefusal::AddressInvalid));
        fixture.archive.fail_next(ArchiveCondition::CredentialRefused);
        assert_eq!(connect(ARCHIVE_ADDRESS), Err(ConnectionRefusal::TokenRefused));
        assert_eq!(
            pollster::block_on(library().status_after(None)).unwrap().archive,
            ArchiveConnection::NotConfigured
        );

        assert_eq!(
            enroll(&absent),
            Err(EnrollmentRefusal::NotADirectory { root: absent.clone() })
        );
        assert_eq!(enroll(&root), Ok(folder.clone()));
        assert_eq!(
            enroll(&root),
            Err(EnrollmentRefusal::AlreadyEnrolled { folder: folder.clone() })
        );
        assert_eq!(
            enroll(&inner),
            Err(EnrollmentRefusal::OverlapsEnrolledFolder { folder: folder.clone() })
        );

        // Without an archive no content is resolved, so the survey cannot end before this.
        assert_eq!(
            decide(1),
            Err(DecisionRefusal::SurveyIncomplete { folder: folder.clone() })
        );
        assert_eq!(decide(7), Err(DecisionRefusal::FolderUnknown));
        assert_eq!(withdraw(7), Err(WithdrawalRefusal::FolderUnknown));

        assert!(connect(ARCHIVE_ADDRESS).is_ok());
        assert_eq!(
            connect("https://other.example.org"),
            Err(ConnectionRefusal::ArchiveDiffers {
                connected_host: "archive.example.org".to_owned()
            })
        );
        follow_collector_until(&collector(), |status| {
            matches!(status.folders[0].admission, FolderAdmission::AwaitingDecision { .. })
        });
        assert_eq!(decide(1), Ok(()));
        assert_eq!(decide(1), Err(DecisionRefusal::AlreadyDecided { folder }));

        pollster::block_on(core().shutdown());
        let stopped = ApplicationFault::Stopped;
        assert_eq!(
            connect(ARCHIVE_ADDRESS),
            Err(ConnectionRefusal::Application { fault: stopped.clone() })
        );
        assert_eq!(
            enroll(&root),
            Err(EnrollmentRefusal::Application { fault: stopped.clone() })
        );
        assert_eq!(
            withdraw(1),
            Err(WithdrawalRefusal::Application { fault: stopped.clone() })
        );
        assert_eq!(decide(1), Err(DecisionRefusal::Application { fault: stopped }));
    }

    #[test]
    fn connect_archive_handles_grants_origin_locks_idempotency_and_crash_repair() {
        // 1. Read token connects both library and collector; origin check precedes the network;
        //    idempotent second connection changes nothing.
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let root = fixture.create_directory("Letters");
        pollster::block_on(fixture.core.collector().unwrap().enroll_folder(root)).unwrap();

        let grant =
            pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
                .unwrap();
        assert_eq!(
            grant,
            ConnectionGrant {
                origin: ARCHIVE_ADDRESS.to_owned(),
                host: "archive.example.org".to_owned(),
                token_description: "Scripted token".to_owned(),
                permission: PublishedPermissionLevel::Read,
                restricted: false,
                reads: true,
                collects: true,
            }
        );
        let library_status = follow_library_until(&fixture.core.library(), |status| {
            matches!(status.copy, LibraryCopy::Complete { .. })
        });
        assert!(matches!(
            library_status.last().unwrap().archive,
            ArchiveConnection::Configured {
                permission: ArchivePermission::ReadAndCollect,
                restricted: false,
                ..
            }
        ));

        // Even when the archive fails its next request, switching to another archive is refused
        // before the network because the collector holds an enrolled folder.
        fixture.archive.fail_next(ArchiveCondition::ConnectionFailed);
        assert_eq!(
            pollster::block_on(
                Arc::clone(&fixture.core).connect_archive("https://other.example.org".to_owned(), TOKEN.to_owned())
            ),
            Err(ConnectionRefusal::ArchiveDiffers {
                connected_host: "archive.example.org".to_owned(),
            })
        );
        // Consume the still-unused scripted failure through read_authorization to prove
        // connect_archive never called the archive for the refused origin switch.
        assert_eq!(
            fixture.archive.read_authorization(),
            Err(ArchiveCondition::ConnectionFailed)
        );

        let repeated =
            pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
                .unwrap();
        assert_eq!(repeated, grant);
        assert_eq!(
            pollster::block_on(fixture.core.collector().unwrap().status_after(None))
                .unwrap()
                .folders
                .len(),
            1
        );
        pollster::block_on(Arc::clone(&fixture.core).shutdown());

        // 2. An ingest-only token connects the collector alone and leaves the library unattached.
        let ingest_only = ApplicationFixture::start(CollectionPlacement::Collector);
        ingest_only.archive.set_permission_level(PermissionLevel::Ingest);
        let ingest_grant = pollster::block_on(
            Arc::clone(&ingest_only.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()),
        )
        .unwrap();
        assert_eq!(
            ingest_grant,
            ConnectionGrant {
                origin: ARCHIVE_ADDRESS.to_owned(),
                host: "archive.example.org".to_owned(),
                token_description: "Scripted token".to_owned(),
                permission: PublishedPermissionLevel::Ingest,
                restricted: false,
                reads: false,
                collects: true,
            }
        );
        let ingest_library = pollster::block_on(ingest_only.core.library().status_after(None)).unwrap();
        assert_eq!(ingest_library.copy, LibraryCopy::Absent);
        assert!(matches!(
            ingest_library.archive,
            ArchiveConnection::Configured {
                permission: ArchivePermission::CollectOnly,
                ..
            }
        ));
        pollster::block_on(Arc::clone(&ingest_only.core).shutdown());

        // 3. Crash repair: a replica with a mirrored archive and stored credential connects an
        //    unconfigured collector on the next start without a network call.
        let repaired = ApplicationFixture::start_crash_repair();
        let collector_status = pollster::block_on(repaired.core.collector().unwrap().status_after(None)).unwrap();
        assert_eq!(collector_status.folders.len(), 0);
        let repaired_library = pollster::block_on(repaired.core.library().status_after(None)).unwrap();
        assert!(matches!(
            repaired_library.archive,
            ArchiveConnection::Configured {
                permission: ArchivePermission::ReadAndCollect,
                ..
            }
        ));
        pollster::block_on(Arc::clone(&repaired.core).shutdown());
    }
}
