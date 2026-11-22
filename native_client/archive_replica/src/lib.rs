//! The local copy of one Schublade archive: its records in `replica.sqlite` and the
//! synchronization that keeps them equal to the archive's, as `notes/native_client_design.md`
//! and `notes/client_protocol.md` describe them. It depends on `archive_access` and knows nothing
//! of collecting, so an iPhone links it without the folder machine.
//!
//! The public surface is `Replica` with its settings, events, and status, and what a window
//! reads through it. Behind it:
//! - `replica_records`: the records and a page of the journal as domain types;
//! - `archive_reader`: the seam to the archive, and the only module that knows the wire format;
//! - `replica_store`: the one SQLite file and every statement that writes it, the search rows
//!   included;
//! - `replica_synchronization`: the pure machine that decides when a page is requested;
//! - `replica_coordinator`: the one thread that owns the writing connection and the machine;
//! - `text_retrieval`: the lanes that read the extracted texts for the coordinator to write;
//! - `replica_queries`: a read-only connection with the listing, search, facet, and detail
//!   queries;
//! - `document_listing`, `document_detail`: what those queries answer, as plain data, and the
//!   difference between two listings;
//! - `search_expression`: a person's text as the expressions of the two search tables;
//! - `representation_cache`: originals and pictures as files named by their content.

pub mod archive_reader;
pub mod document_detail;
pub mod document_listing;
pub mod replica_coordinator;
pub mod replica_queries;
pub mod replica_records;
pub mod replica_store;
pub mod replica_synchronization;
mod representation_cache;
mod search_expression;
mod text_retrieval;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveToken, Clock, CredentialStore, DocumentIdentifier, PermissionLevel,
    SystemClock, Timestamp,
};

pub use archive_reader::{ArchiveReader, HttpArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
pub use document_detail::{DetailField, DocumentDetail, DocumentPerson, OriginalKind};
pub use document_listing::{
    Amount, DocumentListing, DocumentRow, LibraryScope, ListingAnswer, ListingDifference, ListingHeading, ListingOrder,
    ListingRequest, ListingRow, NamedScope, ReplicaFacets, RowPassage, ScopeCount, listing_difference,
};
pub use replica_coordinator::exchange_page;
pub use replica_queries::{ReplicaQueries, RepresentationSource, TextStanding};
pub use replica_store::{CopyExtent, Mirror, PageApplication, ReplicaStore, StagedPage};
pub use replica_synchronization::{
    Attendance, SuspensionReason, SynchronizationEffect, SynchronizationInput, SynchronizationState,
    SynchronizationTiming, WakeReason, advance_synchronization,
};
pub use representation_cache::RepresentationRefusal;
pub use text_retrieval::{AwaitedText, RetrievedText};

use replica_coordinator::{Attachment, CoordinatorInput, ReplicaCoordinator};
use representation_cache::RepresentationCache;
use text_retrieval::{TextLanes, retrieve_text};

/// The reader of the archive the copy follows, written by the coordinator at each connection.
pub(crate) type FollowedArchive = Arc<Mutex<Option<Arc<dyn ArchiveReader>>>>;

/// The space of the originals a person has not chosen otherwise.
const DEFAULT_ORIGINAL_BYTE_LIMIT: u64 = 2_000_000_000;

/// Builds the reader for an address and token: the HTTP reader in production, the scripted
/// archive in a scenario.
pub type ArchiveReaderConstructor = Box<dyn Fn(&ArchiveAddress, &ArchiveToken) -> Arc<dyn ArchiveReader> + Send>;

pub struct ReplicaSettings {
    /// `replica.sqlite`, in the application's data directory.
    pub database_path: PathBuf,
    /// Where originals and pictures are kept, in the system's cache directory, which the system
    /// may empty.
    pub representation_directory: PathBuf,
    /// The most bytes of originals to keep. `None` keeps every original.
    pub original_byte_limit: Option<u64>,
    /// Where a start finds the token of the archive the copy mirrors.
    pub credential_store: Box<dyn CredentialStore>,
    pub archive_readers: ArchiveReaderConstructor,
    pub timing: SynchronizationTiming,
    pub clock: Arc<dyn Clock>,
}

impl ReplicaSettings {
    /// Production: the intervals of the design, 2 GB of originals, the HTTP reader, the wall
    /// clock.
    pub fn new(
        database_path: PathBuf,
        representation_directory: PathBuf,
        credential_store: Box<dyn CredentialStore>,
    ) -> ReplicaSettings {
        ReplicaSettings {
            database_path,
            representation_directory,
            original_byte_limit: Some(DEFAULT_ORIGINAL_BYTE_LIMIT),
            credential_store,
            archive_readers: Box::new(|address, token| Arc::new(HttpArchiveReader::new(address, token))),
            timing: SynchronizationTiming::default(),
            clock: Arc::new(SystemClock),
        }
    }
}

/// Pushed to whoever follows the replica. A follower that holds a status waits for a revision
/// above its own and then reads the status, which is that revision or a later one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReplicaEvent {
    StatusChanged { revision: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReplicaFault {
    /// The coordinator ended, after a shutdown or a failure of the store.
    Stopped,
    StoreFailed {
        detail: String,
    },
}

impl From<rusqlite::Error> for ReplicaFault {
    fn from(error: rusqlite::Error) -> ReplicaFault {
        ReplicaFault::StoreFailed {
            detail: error.to_string(),
        }
    }
}

impl From<ReplicaFault> for RepresentationRefusal {
    fn from(fault: ReplicaFault) -> RepresentationRefusal {
        RepresentationRefusal::Replica(fault)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplicaStatus {
    /// Rises exactly when anything else in this status changes.
    pub revision: u64,
    /// Rises exactly when a record or a text of the copy changed, so a listing is read again
    /// only then.
    pub content_revision: u64,
    /// The documents the copy holds. During the first fill, with the entries that remain, this
    /// is how far the fill is.
    pub documents: u64,
    /// The archived documents whose text is not here yet, so a search of the text does not
    /// find them.
    pub documents_awaiting_text: u64,
    /// The archive the copy mirrors, from the store, so it is known before the archive answers.
    pub archive: Option<MirroredArchive>,
    pub synchronization: SynchronizationState,
    /// Set if the coordinator terminated due to a database failure.
    pub fault: Option<ReplicaFault>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MirroredArchive {
    pub origin: String,
    /// What the token may do, as its authorization said when the archive was attached.
    pub permission_level: PermissionLevel,
    /// Whether the token sees only a part of the archive.
    pub restricted: bool,
    /// Whether the copy ever reached the journal's end. False during the first fill.
    pub fill_complete: bool,
    /// When a page last reached the journal's end.
    pub synchronized_at: Option<Timestamp>,
}

/// The handle an application holds. Commands go to the coordinator thread. The status and
/// everything a window reads are answered without it, on the thread that asks.
pub struct Replica {
    inbox: Sender<CoordinatorInput>,
    published: Arc<Mutex<ReplicaStatus>>,
    coordinator_thread: Mutex<Option<JoinHandle<()>>>,
    database_path: PathBuf,
    /// The read connections that no call uses now. A call takes one, or opens one, so a search
    /// never waits for a listing.
    idle_queries: Mutex<Vec<ReplicaQueries>>,
    followed: FollowedArchive,
    representations: RepresentationCache,
    clock: Arc<dyn Clock>,
}

impl Replica {
    /// Opens the copy and starts the coordinator. A copy that mirrors an archive is followed at
    /// once when the credential store holds the token it was attached with. With another token,
    /// or none, the copy stays readable and nothing is requested until `attach_archive`.
    pub fn start(settings: ReplicaSettings) -> Result<(Replica, Receiver<ReplicaEvent>), ReplicaFault> {
        let store = replica_store::ReplicaStore::open(&settings.database_path)?;
        let mirror = store.mirror()?;
        let (inbox, inputs) = channel();
        let (events, event_stream) = channel();
        let published = Arc::new(Mutex::new(ReplicaStatus {
            revision: 0,
            content_revision: 0,
            documents: 0,
            documents_awaiting_text: 0,
            archive: None,
            synchronization: SynchronizationState::Disconnected,
            fault: None,
        }));
        let followed = FollowedArchive::default();
        let mut coordinator = ReplicaCoordinator {
            store,
            reader: None,
            followed: Arc::clone(&followed),
            text_lanes: TextLanes::start(&inbox),
            connection_generation: 0,
            text_assignments: 0,
            texts_in_flight: HashSet::new(),
            texts_interrupted: false,
            state: SynchronizationState::Disconnected,
            effect: None,
            attendance: Attendance::Unattended,
            timing: settings.timing,
            clock: Arc::clone(&settings.clock),
            archive_readers: settings.archive_readers,
            published: Arc::clone(&published),
            events,
        };
        if let Some(mirror) = mirror
            && let Ok(address) = ArchiveAddress::parse(&mirror.archive_origin)
            && let Ok(Some(token)) = settings.credential_store.read(&address)
            && token.fingerprint() == mirror.credential_fingerprint
        {
            coordinator.connect(&address, &token)?;
        }
        *published.lock().unwrap_or_else(PoisonError::into_inner) = coordinator.status()?;
        let coordinator_thread = std::thread::Builder::new()
            .name("replica-coordinator".to_owned())
            .spawn(move || coordinator.run(inputs))
            .expect("the system starts the coordinator thread");
        Ok((
            Replica {
                inbox,
                published,
                coordinator_thread: Mutex::new(Some(coordinator_thread)),
                database_path: settings.database_path,
                idle_queries: Mutex::new(Vec::new()),
                followed,
                representations: RepresentationCache::open(
                    &settings.representation_directory,
                    settings.original_byte_limit,
                ),
                clock: settings.clock,
            },
            event_stream,
        ))
    }

    /// Follows this archive with this token. `authorization` is what the archive answered to the
    /// token, read by the caller before it stored the token. The copy stays when it was filled
    /// from the same origin, journal, and scope, and is emptied and filled again otherwise.
    pub fn attach_archive(
        &self,
        address: ArchiveAddress,
        token: ArchiveToken,
        authorization: ArchiveAuthorization,
    ) -> Result<(), ReplicaFault> {
        let (reply, answer) = channel();
        self.inbox
            .send(CoordinatorInput::Attach(Box::new(Attachment {
                address,
                token,
                authorization,
                reply,
            })))
            .map_err(|_| ReplicaFault::Stopped)?;
        answer.recv().unwrap_or(Err(ReplicaFault::Stopped))
    }

    /// Asks for a synchronization now. Without a followed archive, or with a refused token, it
    /// changes nothing.
    pub fn wake(&self, reason: WakeReason) {
        let _ = self.inbox.send(CoordinatorInput::Wake(reason));
    }

    /// Whether a window shows the library, which sets the interval from the next page on. A
    /// window that appears also wakes with `WakeReason::ApplicationActivated`.
    pub fn set_attendance(&self, attendance: Attendance) {
        let _ = self.inbox.send(CoordinatorInput::Attendance(attendance));
    }

    /// The status the coordinator published last.
    pub fn status(&self) -> ReplicaStatus {
        self.published.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The rows of the request as the copy holds them now, and, when `preceding` is a listing of
    /// the same request, what turns it into the new one.
    pub fn list_documents(
        &self,
        request: &ListingRequest,
        preceding: Option<&DocumentListing>,
    ) -> Result<ListingAnswer, ReplicaFault> {
        let now = self.clock.now();
        let listing = self.query(|queries| queries.list_documents(request, now))?;
        let difference = preceding
            .filter(|preceding| preceding.request() == request)
            .map(|preceding| listing_difference(preceding, &listing));
        Ok(ListingAnswer { listing, difference })
    }

    /// The sidebar's counts.
    pub fn facets(&self) -> Result<ReplicaFacets, ReplicaFault> {
        self.query(ReplicaQueries::facets)
    }

    /// One document as an inspector shows it, or `None` when the copy does not hold it.
    pub fn document(&self, document: &DocumentIdentifier) -> Result<Option<DocumentDetail>, ReplicaFault> {
        self.query(|queries| queries.document(document))
    }

    /// The extracted Markdown of a document, from the copy. A text the lanes have not brought
    /// yet is read from the archive on the calling thread and handed to the coordinator to keep.
    pub fn extracted_text(&self, document: &DocumentIdentifier) -> Result<String, RepresentationRefusal> {
        let standing = self.query(|queries| queries.text_standing(document))?;
        match standing.ok_or(RepresentationRefusal::DocumentUnknown)? {
            TextStanding::Held(markdown) => Ok(markdown),
            TextStanding::ArchiveHoldsNone => Err(RepresentationRefusal::NotAvailableYet),
            TextStanding::NotRetrieved { original } => {
                let awaited = AwaitedText {
                    document: document.clone(),
                    original,
                };
                let retrieved = retrieve_text(self.followed_archive()?.as_ref(), awaited)?;
                let markdown = retrieved.markdown.clone();
                let _ = self.inbox.send(CoordinatorInput::TextRead(retrieved));
                markdown.ok_or(RepresentationRefusal::NotAvailableYet)
            }
        }
    }

    /// The file of a document's original: the kept one, or else downloaded on the calling
    /// thread, verified against the content the record names, and kept.
    pub fn original(&self, document: &DocumentIdentifier) -> Result<PathBuf, RepresentationRefusal> {
        let source = self.representation_source(document)?;
        let content = source.original.ok_or(RepresentationRefusal::NotAvailableYet)?;
        self.representations.original(content, source.kind, |destination| {
            match self.followed_archive()?.download_original(document, destination)? {
                OriginalAnswer::Received => Ok(()),
                OriginalAnswer::DocumentAbsent => Err(RepresentationRefusal::NoLongerArchived),
                OriginalAnswer::NotPrinted => Err(RepresentationRefusal::NotAvailableYet),
            }
        })
    }

    /// The file of the picture of a document's first page, or `None` when the archive has no
    /// picture of it or has not recorded its content yet.
    pub fn thumbnail(&self, document: &DocumentIdentifier) -> Result<Option<PathBuf>, RepresentationRefusal> {
        let Some(content) = self.representation_source(document)?.original else {
            return Ok(None);
        };
        self.representations.thumbnail(content, |destination| {
            let answer = self.followed_archive()?.download_thumbnail(document, destination)?;
            Ok(answer == ThumbnailAnswer::Received)
        })
    }

    /// The bytes the downloaded originals hold, and the most they may hold.
    pub fn original_storage(&self) -> (u64, Option<u64>) {
        self.representations.original_storage()
    }

    /// Takes a new limit for the downloaded originals, `None` for no limit, and brings them under it.
    pub fn set_original_storage_limit(&self, limit: Option<u64>) {
        self.representations.set_original_byte_limit(limit);
    }

    /// Removes the downloaded originals. Each is downloaded again when it is next opened.
    pub fn remove_downloaded_originals(&self) {
        self.representations.remove_originals();
    }

    fn representation_source(
        &self,
        document: &DocumentIdentifier,
    ) -> Result<RepresentationSource, RepresentationRefusal> {
        self.query(|queries| queries.representation_source(document))?
            .ok_or(RepresentationRefusal::DocumentUnknown)
    }

    fn followed_archive(&self) -> Result<Arc<dyn ArchiveReader>, RepresentationRefusal> {
        self.followed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .ok_or(RepresentationRefusal::NotConnected)
    }

    /// Reads on a connection that no other call uses. A connection that failed is not used
    /// again.
    fn query<Answer>(
        &self,
        read: impl FnOnce(&mut ReplicaQueries) -> rusqlite::Result<Answer>,
    ) -> Result<Answer, ReplicaFault> {
        let idle = self.idle_queries.lock().unwrap_or_else(PoisonError::into_inner).pop();
        let mut queries = match idle {
            Some(queries) => queries,
            None => ReplicaQueries::open(&self.database_path)?,
        };
        let answer = read(&mut queries)?;
        self.idle_queries
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(queries);
        Ok(answer)
    }

    /// Stops the coordinator after the request in flight, if one is.
    pub fn shutdown(self) {
        self.stop();
    }

    /// Stops the coordinator without consuming the handle, so callers sharing an `Arc<Replica>`
    /// can shut down without waiting on unrelated representation downloads.
    pub fn stop(&self) {
        let _ = self.inbox.send(CoordinatorInput::Shutdown);
        if let Some(thread) = self
            .coordinator_thread
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            let _ = thread.join();
        }
    }
}

impl Drop for Replica {
    fn drop(&mut self) {
        self.stop();
    }
}
