//! The core of the Schublade collector: the state machines, their persistence, the archive
//! client, and the coordinator that owns them, as `notes/collector_design.md` describes them.
//! The public surface is `Collector` with its settings, events, and refusals, plus the status.

pub mod archive_client;
pub mod archive_connection;
pub mod candidate_classification;
pub mod clock;
pub mod collection_coordinator;
pub mod content_synchronization;
pub mod directory_reconciliation;
pub mod domain_types;
pub mod file_system_observation;
pub mod folder_admission;
pub mod path_lifecycle;
pub mod scripted_archive;
pub mod state_store;
pub mod status_report;
pub mod work_execution;
pub mod work_planning;

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::JoinHandle;
use std::time::Duration;

pub use archive_client::{ArchiveClient, HttpArchiveClient};
pub use clock::{Clock, ManualClock, SystemClock};
pub use domain_types::{FolderIdentifier, Timestamp, TimingPolicy};
pub use scripted_archive::ScriptedArchive;
pub use status_report::{
    Activity, AttentionItem, BacklogSummary, CollectorStatus, ConnectionStatus, FolderStatus, Receipt, StateCounts,
};

use archive_access::{ArchiveAddress, ArchiveAddressRefusal, ArchiveToken, CredentialStore, FixedCredentialStore};
use archive_connection::ConnectionState;
use collection_coordinator::{CollectionCoordinator, CoordinatorInput, VolatileState};
use file_system_observation::FolderWatcher;
use state_store::{StateStore, StoreOpenFailure};
use work_execution::WorkerLanes;
use work_planning::{LaneCapacity, Reservations};

/// Builds the archive client for an address and token: the HTTP client in production, the
/// scripted archive in a scenario.
pub type ArchiveClientConstructor = Box<dyn Fn(&ArchiveAddress, &ArchiveToken) -> Arc<dyn ArchiveClient> + Send>;

pub struct CollectorSettings {
    pub database_path: PathBuf,
    pub credential_store: Box<dyn CredentialStore>,
    pub archive_clients: ArchiveClientConstructor,
    pub timing: TimingPolicy,
    /// 1 or 2.
    pub submission_concurrency: usize,
    pub clock: Arc<dyn Clock>,
}

impl CollectorSettings {
    /// Production: the intervals of the design, two submissions, the HTTP client, the wall clock.
    pub fn new(database_path: PathBuf, credential_store: Box<dyn CredentialStore>) -> CollectorSettings {
        CollectorSettings {
            database_path,
            credential_store,
            archive_clients: Box::new(|address, token| Arc::new(HttpArchiveClient::new(address, token))),
            timing: TimingPolicy::default(),
            submission_concurrency: 2,
            clock: Arc::new(SystemClock),
        }
    }

    /// A scenario: every address reaches the one given archive, and the clock is the given one.
    pub fn with_fixed_archive(
        database_path: PathBuf,
        archive: Arc<dyn ArchiveClient>,
        clock: Arc<dyn Clock>,
        timing: TimingPolicy,
    ) -> CollectorSettings {
        CollectorSettings {
            database_path,
            credential_store: Box::new(FixedCredentialStore::new(None)),
            archive_clients: Box::new(move |_, _| Arc::clone(&archive)),
            timing,
            submission_concurrency: 2,
            clock,
        }
    }
}

/// Pushed to the app. The window reads `status()` again on `StatusChanged`; the menu bar may
/// show a notification on `DocumentReceived`.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum CollectorEvent {
    StatusChanged { revision: u64 },
    DocumentReceived { document_link: String, file_name: String },
}

/// Why a command was not carried out. Every variant is a sentence the app can show, and the app
/// receives the variant itself to word it with the folder's name.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub enum CommandRefusal {
    ArchiveAddressInvalid {
        detail: String,
    },
    /// Another archive than the connected one, while the collector holds folders or contents
    /// recorded against the connected one.
    ArchiveOriginDiffers {
        connected_origin: String,
    },
    CredentialStorageFailed {
        detail: String,
    },
    FolderRootNotADirectory {
        root: PathBuf,
    },
    FolderAlreadyEnrolled {
        folder: FolderIdentifier,
    },
    /// A folder inside another enrolled folder, or containing one: its files would be counted
    /// twice.
    FolderOverlapsEnrolledFolder {
        folder: FolderIdentifier,
    },
    FolderUnknown {
        folder: FolderIdentifier,
    },
    SurveyIncomplete {
        folder: FolderIdentifier,
    },
    BacklogAlreadyDecided {
        folder: FolderIdentifier,
    },
    IdleTimeout,
    CollectorStopped,
    StoreFailed {
        detail: String,
    },
}

impl From<ArchiveAddressRefusal> for CommandRefusal {
    fn from(refusal: ArchiveAddressRefusal) -> CommandRefusal {
        CommandRefusal::ArchiveAddressInvalid { detail: refusal.detail }
    }
}

impl std::fmt::Display for CommandRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CommandRefusal::ArchiveAddressInvalid { detail } => {
                write!(formatter, "The archive address is invalid: {detail}")
            }
            CommandRefusal::ArchiveOriginDiffers { connected_origin } => write!(
                formatter,
                "The collector's records belong to {connected_origin}; start over with a new state database to collect into another archive"
            ),
            CommandRefusal::CredentialStorageFailed { detail } => {
                write!(formatter, "The token could not be stored: {detail}")
            }
            CommandRefusal::FolderRootNotADirectory { root } => {
                write!(formatter, "{} is not a directory", root.display())
            }
            CommandRefusal::FolderAlreadyEnrolled { folder } => {
                write!(formatter, "The folder is enrolled already as folder {}", folder.value())
            }
            CommandRefusal::FolderOverlapsEnrolledFolder { folder } => write!(
                formatter,
                "The folder lies inside or contains enrolled folder {}, whose files would be counted twice",
                folder.value()
            ),
            CommandRefusal::FolderUnknown { folder } => {
                write!(formatter, "No folder has the identifier {}", folder.value())
            }
            CommandRefusal::SurveyIncomplete { folder } => {
                write!(formatter, "Folder {} is still being surveyed", folder.value())
            }
            CommandRefusal::BacklogAlreadyDecided { folder } => {
                write!(formatter, "Folder {} already collects", folder.value())
            }
            CommandRefusal::IdleTimeout => formatter.write_str("The collector did not become idle in time"),
            CommandRefusal::CollectorStopped => formatter.write_str("The collector has stopped"),
            CommandRefusal::StoreFailed { detail } => write!(formatter, "The state database failed: {detail}"),
        }
    }
}

impl std::error::Error for CommandRefusal {}

#[derive(Debug)]
pub enum StartFailure {
    Store(StoreOpenFailure),
    Watcher(String),
}

impl std::fmt::Display for StartFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartFailure::Store(StoreOpenFailure::Unreadable { renamed_to }) => write!(
                formatter,
                "The state database was unreadable and was renamed to {}",
                renamed_to.display()
            ),
            StartFailure::Store(StoreOpenFailure::InUse { lock_path }) => write!(
                formatter,
                "Another collector is using the state database; it holds {}",
                lock_path.display()
            ),
            StartFailure::Store(StoreOpenFailure::Inaccessible(error)) => {
                write!(formatter, "The state database is inaccessible: {error}")
            }
            StartFailure::Store(StoreOpenFailure::NewerSchema { found, supported }) => write!(
                formatter,
                "The state database has schema version {found}, newer than the supported {supported}"
            ),
            StartFailure::Store(StoreOpenFailure::Database(error)) => {
                write!(formatter, "The state database failed: {error}")
            }
            StartFailure::Watcher(detail) => write!(formatter, "The file system watcher could not start: {detail}"),
        }
    }
}

impl std::error::Error for StartFailure {}

/// A command with its reply channel. Commands are applied in the coordinator's next batch, so a
/// command and the worker results around it never race.
pub enum CollectorCommand {
    ConnectArchive {
        address: ArchiveAddress,
        token: ArchiveToken,
        reply: Sender<Result<(), CommandRefusal>>,
    },
    EnrollFolder {
        root: PathBuf,
        reply: Sender<Result<FolderIdentifier, CommandRefusal>>,
    },
    WithdrawFolder {
        folder: FolderIdentifier,
        reply: Sender<Result<(), CommandRefusal>>,
    },
    DecideBacklog {
        folders: Vec<FolderIdentifier>,
        reply: Sender<Result<(), CommandRefusal>>,
    },
    ReadStatus {
        reply: Sender<Result<CollectorStatus, CommandRefusal>>,
    },
    WaitUntilIdle {
        reply: Sender<Result<CollectorStatus, CommandRefusal>>,
    },
}

/// The handle the app and the command-line program hold. Every method sends one command to the
/// coordinator thread and waits for its reply.
pub struct Collector {
    inbox: Sender<CoordinatorInput>,
    coordinator_thread: Option<JoinHandle<()>>,
}

impl Collector {
    /// Opens the store, starts the watcher, the lanes, and the coordinator, and walks every
    /// enrolled folder. Returns the event stream; dropping it only stops the events.
    pub fn start(settings: CollectorSettings) -> Result<(Collector, Receiver<CollectorEvent>), StartFailure> {
        let CollectorSettings {
            database_path,
            credential_store,
            archive_clients,
            timing,
            submission_concurrency,
            clock,
        } = settings;
        let store = StateStore::open(&database_path).map_err(StartFailure::Store)?;
        let (inbox, inputs) = channel::<CoordinatorInput>();
        let (events, event_stream) = channel::<CollectorEvent>();
        let hints = inbox.clone();
        let watcher = FolderWatcher::new(move |hint| {
            let _ = hints.send(CoordinatorInput::Hint(hint));
        })
        .map_err(|error| StartFailure::Watcher(error.to_string()))?;
        let capacity = LaneCapacity {
            submission: submission_concurrency.clamp(1, 2),
            ..LaneCapacity::default()
        };
        let lanes = WorkerLanes::start(&capacity, inbox.clone(), Arc::clone(&clock));

        let folders: BTreeMap<FolderIdentifier, state_store::FolderRecord> = store
            .folders()
            .map_err(|error| StartFailure::Store(StoreOpenFailure::Database(error)))?
            .into_iter()
            .map(|record| (record.folder, record))
            .collect();
        let mut connection = ConnectionState::Unconfigured;
        let mut archive = None;
        let mut archive_origin = None;
        if let Some(record) = store
            .connection_record()
            .map_err(|error| StartFailure::Store(StoreOpenFailure::Database(error)))?
            && let Ok(address) = ArchiveAddress::parse(&record.archive_origin)
            && let Ok(Some(token)) = credential_store.read(&address)
            && token.fingerprint() == record.credential_fingerprint
        {
            archive = Some(archive_clients(&address, &token));
            archive_origin = Some(address.origin());
            connection = match record.suspension {
                Some((reason, since)) => ConnectionState::Suspended { reason, since },
                None => ConnectionState::Available,
            };
        }
        let now = clock.now();
        let availability = folders
            .keys()
            .map(|folder| (*folder, folder_admission::FolderAvailability::Available))
            .collect();
        let mut volatile = VolatileState {
            folders,
            availability,
            initial_walks_completed: BTreeSet::new(),
            disregarded: BTreeMap::new(),
            connection,
            archive_origin,
            archive,
            reservations: Reservations::default(),
            submissions_in_flight: BTreeMap::new(),
            listing_requests: BTreeMap::new(),
            lookup_batches: 0,
            pending_hints: BTreeMap::new(),
            scheduled_listings: BTreeMap::new(),
            last_full_walk_at: now,
            watcher,
            watched: BTreeSet::new(),
            capacity,
            timing,
            clock,
            credential_store,
            archive_clients,
            revision: 0,
            published_revision: 0,
            last_status_emitted_at: None,
            served_deadline: None,
            idle_waiters: Vec::new(),
            status_requests: Vec::new(),
        };
        volatile.schedule_full_walk(now);
        let coordinator = CollectionCoordinator {
            store,
            volatile,
            lanes,
            events,
        };
        let coordinator_thread = std::thread::Builder::new()
            .name("collector-coordinator".to_owned())
            .spawn(move || coordinator.run(inputs))
            .map_err(|error| StartFailure::Watcher(error.to_string()))?;
        Ok((
            Collector {
                inbox,
                coordinator_thread: Some(coordinator_thread),
            },
            event_stream,
        ))
    }

    fn command<Answer>(
        &self,
        command: impl FnOnce(Sender<Result<Answer, CommandRefusal>>) -> CollectorCommand,
    ) -> Result<Answer, CommandRefusal> {
        let (reply, answer) = channel();
        self.inbox
            .send(CoordinatorInput::Command(command(reply)))
            .map_err(|_| CommandRefusal::CollectorStopped)?;
        answer.recv().unwrap_or(Err(CommandRefusal::CollectorStopped))
    }

    /// Stores the token in the credential store and the origin with the token's fingerprint in
    /// the database. A different token clears a suspension.
    pub fn connect_archive(&self, address: ArchiveAddress, token: ArchiveToken) -> Result<(), CommandRefusal> {
        self.command(|reply| CollectorCommand::ConnectArchive { address, token, reply })
    }

    /// Starts the folder in Surveying with a recursive listing.
    pub fn enroll_folder(&self, root: PathBuf) -> Result<FolderIdentifier, CommandRefusal> {
        self.command(|reply| CollectorCommand::EnrollFolder { root, reply })
    }

    pub fn withdraw_folder(&self, folder: FolderIdentifier) -> Result<(), CommandRefusal> {
        self.command(|reply| CollectorCommand::WithdrawFolder { folder, reply })
    }

    /// Uploads the backlog of exactly the named folders, each of which must be AwaitingDecision.
    /// All or none.
    pub fn decide_backlog(&self, folders: &[FolderIdentifier]) -> Result<(), CommandRefusal> {
        self.command(|reply| CollectorCommand::DecideBacklog {
            folders: folders.to_vec(),
            reply,
        })
    }

    pub fn status(&self) -> Result<CollectorStatus, CommandRefusal> {
        self.command(|reply| CollectorCommand::ReadStatus { reply })
    }

    /// From the app's wake notification. The coordinator also notices a jump of the clock.
    pub fn notify_system_resumed(&self) {
        let _ = self.inbox.send(CoordinatorInput::SystemResumed);
    }

    /// Returns the status once no work can be planned now and none is in flight. Work due
    /// later, such as a stabilization or a retry, shows in `next_scheduled_at`.
    pub fn wait_until_idle(&self, timeout: Duration) -> Result<CollectorStatus, CommandRefusal> {
        let (reply, answer) = channel();
        self.inbox
            .send(CoordinatorInput::Command(CollectorCommand::WaitUntilIdle { reply }))
            .map_err(|_| CommandRefusal::CollectorStopped)?;
        match answer.recv_timeout(timeout) {
            Ok(status) => status,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(CommandRefusal::IdleTimeout),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(CommandRefusal::CollectorStopped),
        }
    }

    /// Stops the coordinator after its current batch. Work in flight is lost only as
    /// reservations, which the next start derives again.
    pub fn shutdown(mut self) {
        self.stop();
    }

    fn stop(&mut self) {
        let _ = self.inbox.send(CoordinatorInput::Shutdown);
        if let Some(thread) = self.coordinator_thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Collector {
    fn drop(&mut self) {
        self.stop();
    }
}
