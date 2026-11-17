//! The single owner of all collector state. One thread runs the loop: block on the inbox until
//! the next deadline, drain a batch, apply it in one store transaction through the pure
//! machines, commit, plan work for the free lanes, and answer whoever waits. Every other thread
//! only performs I/O and sends its result here, so no two actors ever write the same row.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::time::{Duration, Instant};

use crate::archive_client::{ArchiveAddress, ArchiveClient, IngestToken};
use crate::archive_connection::{
    ArchiveAnswer, ConnectionEvent, ConnectionState, Consequences, advance_connection, consequences, next_timer,
};
use crate::candidate_classification::{DisregardReason, ReadableSignature};
use crate::clock::Clock;
use crate::content_synchronization::{ContentEvent, SubmissionOutcome, advance_content};
use crate::credential_storage::CredentialStore;
use crate::directory_reconciliation::{DirectoryListing, ListingOutcome, reconcile_directory};
use crate::domain_types::{ContentDigest, DirectoryKey, FolderIdentifier, PathKey, Timestamp, TimingPolicy};
use crate::file_system_observation::{DirectoryHint, FolderWatcher};
use crate::folder_admission::{
    FolderAdmission, FolderAvailability, availability_after_root_listing, conclude_survey, decide,
};
use crate::path_lifecycle::{DigestFinding, PathEvent, advance_path};
use crate::state_store::{FolderRecord, StateStore, StoreTransaction};
use crate::status_report::{Activity, AttentionItem, BacklogSummary, CollectorStatus, ConnectionStatus, FolderStatus};
use crate::work_execution::{Assignment, WorkerLanes};
use crate::work_planning::{ContentReservation, LaneCapacity, LookupBatch, Reservations, Work, plan_work};
use crate::{ArchiveClientConstructor, CollectorCommand, CollectorEvent, CommandRefusal};

/// Everything that reaches the coordinator. Workers and the watcher only send these.
pub enum CoordinatorInput {
    Command(CollectorCommand),
    Listing(DirectoryListing),
    Hint(DirectoryHint),
    Finished(WorkResult),
    SystemResumed,
    Shutdown,
}

/// The result of one unit of work, carrying the key it was planned for. Applying it releases the
/// reservation and runs the owning machine.
pub enum WorkResult {
    ListingFinished {
        folder: FolderIdentifier,
        directory: DirectoryKey,
        recursive: bool,
    },
    Digest {
        path: PathKey,
        based_on: ReadableSignature,
        finding: DigestFinding,
        at: Timestamp,
    },
    Submission {
        content: ContentDigest,
        source: PathKey,
        based_on: ReadableSignature,
        result: SubmissionResult,
        at: Timestamp,
    },
    /// A lookup (with its batch) or a document status read.
    Archive {
        answer: ArchiveAnswer,
        batch: Option<LookupBatch>,
        at: Timestamp,
    },
}

pub enum SubmissionResult {
    SourceFailed {
        current: Option<crate::domain_types::FileSignature>,
    },
    Answered(Result<SubmissionOutcome, crate::archive_connection::ArchiveCondition>),
}

/// How long the loop waits at most before it looks at its timers again, and the jump of the
/// clock beyond the expected wake that counts as a wake from sleep.
const TICK: Duration = Duration::from_secs(60);
const CLOCK_JUMP: Duration = Duration::from_secs(60);
const BATCH_LIMIT: usize = 256;
const RECENT_RECEIPTS: usize = 20;

type StatusReply = Sender<Result<CollectorStatus, CommandRefusal>>;

/// The in-memory half of the coordinator: what is lost at a quit and derived again at the next
/// start. The store holds the resting states.
pub struct VolatileState {
    pub folders: BTreeMap<FolderIdentifier, FolderRecord>,
    pub availability: BTreeMap<FolderIdentifier, FolderAvailability>,
    pub initial_walks_completed: BTreeSet<FolderIdentifier>,
    /// What the latest listing of each directory left without a row, for the backlog summary.
    pub disregarded: BTreeMap<(FolderIdentifier, DirectoryKey), BTreeMap<DisregardReason, u64>>,
    pub connection: ConnectionState,
    pub archive_origin: Option<String>,
    pub archive: Option<Arc<dyn ArchiveClient>>,
    pub reservations: Reservations,
    /// The source and byte size of each submission in flight, for the status and the receipt.
    pub submissions_in_flight: BTreeMap<ContentDigest, (PathKey, u64)>,
    /// Which reserved listings are recursive, so a walk's own listings schedule no second walk.
    pub listing_requests: BTreeMap<(FolderIdentifier, DirectoryKey), bool>,
    pub lookup_batches: u64,
    /// Hints waiting to coalesce, each with the time it may be planned.
    pub pending_hints: BTreeMap<(FolderIdentifier, DirectoryKey), (bool, Timestamp)>,
    /// Listings the coordinator decided on itself, ready for the planner.
    pub scheduled_listings: BTreeMap<(FolderIdentifier, DirectoryKey), bool>,
    pub last_full_walk_at: Timestamp,
    pub watcher: FolderWatcher,
    pub watched: BTreeSet<FolderIdentifier>,
    pub capacity: LaneCapacity,
    pub timing: TimingPolicy,
    pub clock: Arc<dyn Clock>,
    pub credential_store: Box<dyn CredentialStore>,
    pub archive_clients: ArchiveClientConstructor,
    pub revision: u64,
    pub published_revision: u64,
    pub last_status_emitted_at: Option<Timestamp>,
    pub served_deadline: Option<Timestamp>,
    pub idle_waiters: Vec<StatusReply>,
    pub status_requests: Vec<StatusReply>,
}

pub struct CollectionCoordinator {
    pub store: StateStore,
    pub volatile: VolatileState,
    pub lanes: WorkerLanes,
    pub events: Sender<CollectorEvent>,
}

/// A command's answer, sent only once its batch committed.
enum Reply {
    Unit(Sender<Result<(), CommandRefusal>>, Result<(), CommandRefusal>),
    Folder(
        Sender<Result<FolderIdentifier, CommandRefusal>>,
        Result<FolderIdentifier, CommandRefusal>,
    ),
}

impl Reply {
    fn send(self) {
        match self {
            Reply::Unit(sender, result) => {
                let _ = sender.send(result);
            }
            Reply::Folder(sender, result) => {
                let _ = sender.send(result);
            }
        }
    }

    fn fail(self, refusal: CommandRefusal) {
        match self {
            Reply::Unit(sender, _) => {
                let _ = sender.send(Err(refusal));
            }
            Reply::Folder(sender, _) => {
                let _ = sender.send(Err(refusal));
            }
        }
    }
}

/// What one batch produced besides its writes: replies to send and events to emit after the
/// commit, so neither precedes the state it reports.
#[derive(Default)]
struct BatchOutcome {
    replies: Vec<Reply>,
    events: Vec<CollectorEvent>,
    shutdown: bool,
}

impl CollectionCoordinator {
    pub fn run(mut self, inbox: Receiver<CoordinatorInput>) {
        loop {
            let now = self.volatile.clock.now();
            let deadline = self
                .volatile
                .next_deadline(&self.store)
                .filter(|deadline| Some(*deadline) != self.volatile.served_deadline);
            let wait = match deadline {
                Some(due) if due <= now => Duration::ZERO,
                Some(due) => due.elapsed_since(now).min(TICK),
                None => TICK,
            };
            let started = Instant::now();
            let first = if wait.is_zero() {
                match inbox.try_recv() {
                    Ok(input) => Some(input),
                    Err(TryRecvError::Empty) => None,
                    Err(TryRecvError::Disconnected) => return,
                }
            } else {
                match inbox.recv_timeout(wait) {
                    Ok(input) => Some(input),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            };
            let mut batch = Vec::new();
            let woke_at = self.volatile.clock.now();
            if woke_at > now.after(started.elapsed() + CLOCK_JUMP) {
                batch.push(CoordinatorInput::SystemResumed);
            }
            batch.extend(first);
            while batch.len() < BATCH_LIMIT {
                match inbox.try_recv() {
                    Ok(input) => batch.push(input),
                    Err(_) => break,
                }
            }
            let shutdown = self.round(batch);
            self.volatile.served_deadline = deadline.filter(|due| *due <= woke_at);
            if shutdown {
                return;
            }
        }
    }

    /// One batch: apply, commit, plan, dispatch, answer. Returns whether a shutdown arrived.
    fn round(&mut self, batch: Vec<CoordinatorInput>) -> bool {
        let outcome = match self.apply_batch(batch) {
            Ok(outcome) => outcome,
            Err(error) => {
                eprintln!("collector: a batch failed and was rolled back: {error}");
                BatchOutcome::default()
            }
        };
        for reply in outcome.replies {
            reply.send();
        }
        for event in outcome.events {
            let _ = self.events.send(event);
        }
        if outcome.shutdown {
            return true;
        }
        let assignments = match self.volatile.plan(&self.store) {
            Ok(assignments) => assignments,
            Err(error) => {
                eprintln!("collector: planning failed: {error}");
                Vec::new()
            }
        };
        let planned = !assignments.is_empty();
        for assignment in assignments {
            self.lanes.assign(assignment);
        }
        // A pending hint or a stabilization is work due later, which `next_scheduled_at` reports;
        // idle means nothing can be done now and nothing is in flight.
        let idle = !planned && self.volatile.reservations.is_empty();
        if idle || !self.volatile.status_requests.is_empty() {
            let status = self
                .volatile
                .status(&self.store)
                .map_err(|error| CommandRefusal::StoreFailed {
                    detail: error.to_string(),
                });
            for request in self.volatile.status_requests.drain(..) {
                let _ = request.send(status.clone());
            }
            if idle {
                for waiter in self.volatile.idle_waiters.drain(..) {
                    let _ = waiter.send(status.clone());
                }
            }
        }
        self.publish_status_change();
        false
    }

    fn apply_batch(&mut self, batch: Vec<CoordinatorInput>) -> rusqlite::Result<BatchOutcome> {
        let mut outcome = BatchOutcome::default();
        let transaction = self.store.begin()?;
        let before = self.volatile.revision;
        for input in batch {
            self.volatile
                .apply_input(&self.store, &transaction, input, &mut outcome)?;
        }
        self.volatile.apply_timers(&self.store, &transaction)?;
        self.volatile.conclude_surveys(&self.store, &transaction)?;
        if let Err(error) = transaction.commit() {
            self.volatile.revision = before;
            for reply in outcome.replies {
                reply.fail(CommandRefusal::StoreFailed {
                    detail: error.to_string(),
                });
            }
            return Err(error);
        }
        Ok(outcome)
    }

    /// `StatusChanged` at most once per coalescing interval; a change inside the interval waits
    /// for the next wake, which the deadline brings.
    fn publish_status_change(&mut self) {
        let volatile = &mut self.volatile;
        if volatile.revision == volatile.published_revision {
            return;
        }
        let now = volatile.clock.now();
        let interval_elapsed = volatile
            .last_status_emitted_at
            .is_none_or(|last| now.elapsed_since(last) >= volatile.timing.status_coalescing_interval);
        if interval_elapsed {
            volatile.published_revision = volatile.revision;
            volatile.last_status_emitted_at = Some(now);
            let _ = self.events.send(CollectorEvent::StatusChanged {
                revision: volatile.revision,
            });
        }
    }
}

impl VolatileState {
    fn apply_input(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        input: CoordinatorInput,
        outcome: &mut BatchOutcome,
    ) -> rusqlite::Result<()> {
        match input {
            CoordinatorInput::Command(command) => self.apply_command(store, transaction, command, outcome)?,
            CoordinatorInput::Listing(listing) => self.apply_listing(store, transaction, listing)?,
            CoordinatorInput::Hint(hint) => {
                let due = self.clock.now().after(self.timing.hint_coalescing_interval);
                let entry = self
                    .pending_hints
                    .entry((hint.folder, hint.directory))
                    .or_insert((hint.recursive, due));
                entry.0 |= hint.recursive;
            }
            CoordinatorInput::Finished(result) => self.apply_result(store, transaction, result, outcome)?,
            CoordinatorInput::SystemResumed => {
                let at = self.clock.now();
                self.apply_connection_event(transaction, ConnectionEvent::SystemResumed { at })?;
                self.schedule_full_walk(at);
            }
            CoordinatorInput::Shutdown => outcome.shutdown = true,
        }
        Ok(())
    }

    fn apply_command(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        command: CollectorCommand,
        outcome: &mut BatchOutcome,
    ) -> rusqlite::Result<()> {
        self.revision += 1;
        match command {
            CollectorCommand::ConnectArchive { address, token, reply } => {
                let result = self.connect_archive(store, transaction, address, token);
                outcome.replies.push(Reply::Unit(reply, result));
            }
            CollectorCommand::EnrollFolder { root, reply } => {
                let result = self.enroll_folder(transaction, root);
                outcome.replies.push(Reply::Folder(reply, result));
            }
            CollectorCommand::WithdrawFolder { folder, reply } => {
                let result = self.withdraw_folder(transaction, folder);
                outcome.replies.push(Reply::Unit(reply, result));
            }
            CollectorCommand::DecideBacklog { folders, reply } => {
                let result = self.decide_backlog(transaction, &folders);
                outcome.replies.push(Reply::Unit(reply, result));
            }
            CollectorCommand::ReadStatus { reply } => self.status_requests.push(reply),
            CollectorCommand::WaitUntilIdle { reply } => self.idle_waiters.push(reply),
        }
        Ok(())
    }

    fn connect_archive(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        address: ArchiveAddress,
        token: IngestToken,
    ) -> Result<(), CommandRefusal> {
        let store_failure = |error: rusqlite::Error| CommandRefusal::StoreFailed {
            detail: error.to_string(),
        };
        // Content standings and receipts describe the connected archive, so another archive would
        // never receive a file the first one holds, and old receipts would link into it.
        if let Some(record) = store.connection_record().map_err(store_failure)?
            && record.archive_origin != address.origin()
            && (!self.folders.is_empty() || store.holds_contents().map_err(store_failure)?)
        {
            return Err(CommandRefusal::ArchiveOriginDiffers {
                connected_origin: record.archive_origin,
            });
        }
        self.credential_store
            .write(&address, &token)
            .map_err(|failure| CommandRefusal::CredentialStorageFailed { detail: failure.detail })?;
        transaction
            .store_connection(&address.origin(), &token.fingerprint())
            .map_err(store_failure)?;
        let record = store.connection_record().map_err(store_failure)?;
        self.archive = Some((self.archive_clients)(&address, &token));
        self.archive_origin = Some(address.origin());
        self.connection = match record.and_then(|record| record.suspension) {
            Some((reason, since)) => ConnectionState::Suspended { reason, since },
            None => advance_connection(&self.connection, ConnectionEvent::Configured, &self.timing),
        };
        Ok(())
    }

    fn enroll_folder(
        &mut self,
        transaction: &StoreTransaction<'_>,
        root: PathBuf,
    ) -> Result<FolderIdentifier, CommandRefusal> {
        let root = std::path::absolute(&root).unwrap_or(root);
        if !root.is_dir() {
            return Err(CommandRefusal::FolderRootNotADirectory { root });
        }
        for record in self.folders.values() {
            if record.root == root {
                return Err(CommandRefusal::FolderAlreadyEnrolled { folder: record.folder });
            }
            if root.starts_with(&record.root) || record.root.starts_with(&root) {
                return Err(CommandRefusal::FolderOverlapsEnrolledFolder { folder: record.folder });
            }
        }
        let at = self.clock.now();
        let folder = transaction
            .enroll_folder(&root, at)
            .map_err(|error| CommandRefusal::StoreFailed {
                detail: error.to_string(),
            })?;
        self.folders.insert(
            folder,
            FolderRecord {
                folder,
                root,
                enrolled_at: at,
                admission: FolderAdmission::Surveying,
            },
        );
        self.availability.insert(folder, FolderAvailability::Available);
        self.watch_folder(folder);
        self.scheduled_listings.insert((folder, DirectoryKey::root()), true);
        Ok(folder)
    }

    fn withdraw_folder(
        &mut self,
        transaction: &StoreTransaction<'_>,
        folder: FolderIdentifier,
    ) -> Result<(), CommandRefusal> {
        let Some(record) = self.folders.remove(&folder) else {
            return Err(CommandRefusal::FolderUnknown { folder });
        };
        transaction
            .withdraw_folder(folder)
            .map_err(|error| CommandRefusal::StoreFailed {
                detail: error.to_string(),
            })?;
        self.availability.remove(&folder);
        self.initial_walks_completed.remove(&folder);
        self.disregarded.retain(|(owner, _), _| *owner != folder);
        self.pending_hints.retain(|(owner, _), _| *owner != folder);
        self.scheduled_listings.retain(|(owner, _), _| *owner != folder);
        self.watcher.unwatch(&record.root);
        self.watched.remove(&folder);
        Ok(())
    }

    fn decide_backlog(
        &mut self,
        transaction: &StoreTransaction<'_>,
        folders: &[FolderIdentifier],
    ) -> Result<(), CommandRefusal> {
        let at = self.clock.now();
        let mut decided = Vec::with_capacity(folders.len());
        for folder in folders {
            let record = self
                .folders
                .get(folder)
                .ok_or(CommandRefusal::FolderUnknown { folder: *folder })?;
            let admission = decide(record.admission, at).map_err(|refusal| match refusal {
                crate::folder_admission::AdmissionRefusal::SurveyIncomplete => {
                    CommandRefusal::SurveyIncomplete { folder: *folder }
                }
                crate::folder_admission::AdmissionRefusal::AlreadyDecided => {
                    CommandRefusal::BacklogAlreadyDecided { folder: *folder }
                }
            })?;
            decided.push((*folder, admission));
        }
        for (folder, admission) in decided {
            transaction
                .store_admission(folder, admission)
                .map_err(|error| CommandRefusal::StoreFailed {
                    detail: error.to_string(),
                })?;
            if let Some(record) = self.folders.get_mut(&folder) {
                record.admission = admission;
            }
        }
        Ok(())
    }

    fn watch_folder(&mut self, folder: FolderIdentifier) {
        let Some(record) = self.folders.get(&folder) else {
            return;
        };
        if self.watcher.watch(folder, &record.root).is_ok() {
            self.watched.insert(folder);
        }
    }

    /// A root listing decides the folder's availability and nothing else. Every other listing
    /// is reconciled with the stored rows of its directory.
    fn apply_listing(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        listing: DirectoryListing,
    ) -> rusqlite::Result<()> {
        if !self.folders.contains_key(&listing.folder) {
            return Ok(());
        }
        self.revision += 1;
        let folder = listing.folder;
        if listing.directory.is_root() {
            let availability = availability_after_root_listing(&listing.outcome);
            let previous = self.availability.insert(folder, availability);
            if availability != FolderAvailability::Available {
                return Ok(());
            }
            if previous.is_some_and(|previous| previous != FolderAvailability::Available) {
                self.scheduled_listings.insert((folder, DirectoryKey::root()), true);
            }
        } else if self.availability.get(&folder) != Some(&FolderAvailability::Available) {
            return Ok(());
        }
        if let ListingOutcome::Listed { disregarded, .. } = &listing.outcome {
            self.disregarded
                .insert((folder, listing.directory.clone()), disregarded.clone());
        }
        let contents = store.directory_contents(folder, &listing.directory)?;
        let reconciliation = reconcile_directory(&listing, &contents.files, &contents.subdirectories);
        for (path, event) in reconciliation.path_events {
            self.apply_path_event(store, transaction, &path, event, listing.listed_at)?;
        }
        transaction.remove_subtrees(folder, &reconciliation.removed_subtrees, listing.listed_at)?;
        for removed in &reconciliation.removed_subtrees {
            self.disregarded
                .retain(|(owner, directory), _| !(*owner == folder && removed.contains(directory)));
        }
        let inside_walk = self.listing_requests.iter().any(|((owner, directory), recursive)| {
            *owner == folder && *recursive && directory.contains(&listing.directory)
        });
        if !inside_walk {
            for unexplored in reconciliation.unexplored_subdirectories {
                self.scheduled_listings.insert((folder, unexplored), true);
            }
        }
        Ok(())
    }

    fn apply_path_event(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        path: &PathKey,
        event: PathEvent,
        at: Timestamp,
    ) -> rusqlite::Result<()> {
        let current = store.path_state(path)?;
        let transition = advance_path(current.as_ref(), event, &self.timing);
        transaction.apply_path(path, &transition, at)
    }

    fn apply_result(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        result: WorkResult,
        outcome: &mut BatchOutcome,
    ) -> rusqlite::Result<()> {
        self.revision += 1;
        match result {
            WorkResult::ListingFinished {
                folder,
                directory,
                recursive,
            } => {
                self.reservations.directories.remove(&(folder, directory.clone()));
                self.listing_requests.remove(&(folder, directory.clone()));
                if recursive && directory.is_root() && self.folders.contains_key(&folder) {
                    self.initial_walks_completed.insert(folder);
                }
            }
            WorkResult::Digest {
                path,
                based_on,
                finding,
                at,
            } => {
                self.reservations.paths.remove(&path);
                if matches!(finding, DigestFinding::Changed { current: None }) {
                    self.scheduled_listings
                        .entry((path.folder, path.directory.clone()))
                        .or_insert(false);
                }
                self.apply_path_event(
                    store,
                    transaction,
                    &path,
                    PathEvent::DigestFinished { based_on, finding, at },
                    at,
                )?;
            }
            WorkResult::Submission {
                content,
                source,
                based_on,
                result,
                at,
            } => {
                self.reservations.contents.remove(&content);
                let file_name = self
                    .submissions_in_flight
                    .remove(&content)
                    .map(|(path, _)| path.name.as_os_str().to_string_lossy().into_owned())
                    .unwrap_or_default();
                match result {
                    SubmissionResult::SourceFailed { current } => {
                        if current.is_none() {
                            self.scheduled_listings
                                .entry((source.folder, source.directory.clone()))
                                .or_insert(false);
                        }
                        self.apply_path_event(
                            store,
                            transaction,
                            &source,
                            PathEvent::SourceVerificationFailed { based_on, current, at },
                            at,
                        )?;
                    }
                    SubmissionResult::Answered(answer) => {
                        let received = matches!(answer, Ok(SubmissionOutcome::Accepted { .. }));
                        let document = match &answer {
                            Ok(SubmissionOutcome::Accepted { document, .. }) => Some(document.clone()),
                            _ => None,
                        };
                        let changed = self.apply_archive_answer(
                            store,
                            transaction,
                            ArchiveAnswer::Submission { content, answer },
                            at,
                        )?;
                        if received
                            && changed.contains(&content)
                            && let (Some(document), Some(origin)) = (document, &self.archive_origin)
                        {
                            outcome.events.push(CollectorEvent::DocumentReceived {
                                document_link: format!("{origin}/documents/{}", document.as_str()),
                                file_name,
                            });
                        }
                    }
                }
            }
            WorkResult::Archive { answer, batch, at } => {
                if let Some(batch) = batch {
                    self.reservations
                        .contents
                        .retain(|_, reservation| *reservation != ContentReservation::LookingUp(batch));
                } else if let ArchiveAnswer::DocumentStatus { content, .. } = &answer {
                    self.reservations.contents.remove(content);
                }
                self.apply_archive_answer(store, transaction, answer, at)?;
            }
        }
        Ok(())
    }

    /// Runs the consequences table: one connection event, and the content events it carries.
    /// Returns the contents whose standing changed.
    fn apply_archive_answer(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        answer: ArchiveAnswer,
        at: Timestamp,
    ) -> rusqlite::Result<BTreeSet<ContentDigest>> {
        let Consequences { connection, contents } = consequences(answer, at);
        self.apply_connection_event(transaction, connection)?;
        let mut changed = BTreeSet::new();
        for (digest, event) in contents {
            if self.apply_content_event(store, transaction, digest, event)? {
                changed.insert(digest);
            }
        }
        Ok(changed)
    }

    fn apply_content_event(
        &mut self,
        store: &StateStore,
        transaction: &StoreTransaction<'_>,
        digest: ContentDigest,
        event: ContentEvent,
    ) -> rusqlite::Result<bool> {
        let Some(record) = store.content_record(&digest)? else {
            return Ok(false);
        };
        let next = advance_content(&record.standing, event, &self.timing);
        if next == record.standing {
            return Ok(false);
        }
        transaction.store_standing(&digest, &next)?;
        Ok(true)
    }

    fn apply_connection_event(
        &mut self,
        transaction: &StoreTransaction<'_>,
        event: ConnectionEvent,
    ) -> rusqlite::Result<()> {
        let next = advance_connection(&self.connection, event, &self.timing);
        if next == self.connection {
            return Ok(());
        }
        if let ConnectionState::Suspended { reason, since } = next {
            transaction.store_suspension(Some((reason, since)))?;
        }
        self.connection = next;
        Ok(())
    }

    /// The timers the deadline wakes the loop for: the connection's probe, hints that coalesced,
    /// and the periodic full walk.
    fn apply_timers(&mut self, _store: &StateStore, transaction: &StoreTransaction<'_>) -> rusqlite::Result<()> {
        let now = self.clock.now();
        if next_timer(&self.connection).is_some_and(|due| due <= now) {
            self.apply_connection_event(transaction, ConnectionEvent::TimerElapsed { at: now })?;
        }
        let due_hints: Vec<_> = self
            .pending_hints
            .iter()
            .filter(|(_, (_, due))| *due <= now)
            .map(|(key, (recursive, _))| (key.clone(), *recursive))
            .collect();
        for (key, recursive) in due_hints {
            self.pending_hints.remove(&key);
            let available = self.availability.get(&key.0) == Some(&FolderAvailability::Available);
            if available || key.1.is_root() {
                *self.scheduled_listings.entry(key).or_insert(false) |= recursive;
            }
        }
        if now.elapsed_since(self.last_full_walk_at) >= self.timing.full_walk_interval {
            self.schedule_full_walk(now);
        }
        Ok(())
    }

    /// A recursive listing of every folder's root, which also probes availability and retries
    /// the watch of a root that could not be watched.
    pub fn schedule_full_walk(&mut self, at: Timestamp) {
        self.last_full_walk_at = at;
        let folders: Vec<FolderIdentifier> = self.folders.keys().copied().collect();
        for folder in folders {
            self.scheduled_listings.insert((folder, DirectoryKey::root()), true);
            if !self.watched.contains(&folder) {
                self.watch_folder(folder);
            }
        }
    }

    fn conclude_surveys(&mut self, store: &StateStore, transaction: &StoreTransaction<'_>) -> rusqlite::Result<()> {
        for record in self.folders.values_mut() {
            if record.admission != FolderAdmission::Surveying {
                continue;
            }
            let mut progress = store.survey_progress(record.folder)?;
            progress.initial_walk_completed = self.initial_walks_completed.contains(&record.folder)
                && self.availability.get(&record.folder) == Some(&FolderAvailability::Available);
            let next = conclude_survey(record.admission, &progress);
            if next != record.admission {
                transaction.store_admission(record.folder, next)?;
                record.admission = next;
                self.revision += 1;
            }
        }
        Ok(())
    }

    fn available_folders(&self) -> Vec<FolderIdentifier> {
        self.folders
            .keys()
            .filter(|folder| self.availability.get(folder) == Some(&FolderAvailability::Available))
            .copied()
            .collect()
    }

    /// Candidates from the store plus the listings scheduled here, through the planner, into
    /// assignments with their reservations recorded.
    fn plan(&mut self, store: &StateStore) -> rusqlite::Result<Vec<Assignment>> {
        let now = self.clock.now();
        let available = self.available_folders();
        let mut candidates =
            store.work_candidates(&self.reservations, &self.capacity, &available, now, &self.timing)?;
        let scheduled: Vec<_> = self
            .scheduled_listings
            .iter()
            .map(|((folder, directory), recursive)| (*folder, directory.clone(), *recursive))
            .collect();
        let mut seen = BTreeSet::new();
        candidates.due_directories = scheduled
            .into_iter()
            .chain(candidates.due_directories)
            .filter(|(folder, directory, _)| seen.insert((*folder, directory.clone())))
            .collect();
        let work = plan_work(
            candidates,
            &self.reservations,
            &self.capacity,
            &self.connection,
            now,
            &self.timing,
        );
        Ok(work.into_iter().filter_map(|work| self.assignment_of(work)).collect())
    }

    fn assignment_of(&mut self, work: Work) -> Option<Assignment> {
        match work {
            Work::ListDirectory {
                folder,
                directory,
                recursive,
            } => {
                let root = self.folders.get(&folder)?.root.clone();
                self.reservations.directories.insert((folder, directory.clone()));
                self.listing_requests.insert((folder, directory.clone()), recursive);
                self.scheduled_listings.remove(&(folder, directory.clone()));
                Some(Assignment::ListDirectory {
                    folder,
                    root,
                    directory,
                    recursive,
                })
            }
            Work::ComputeDigest { path, signature } => {
                let root = self.folders.get(&path.folder)?.root.clone();
                self.reservations.paths.insert(path.clone());
                Some(Assignment::ComputeDigest { path, root, signature })
            }
            Work::LookUpContents { digests } => {
                let archive = self.archive.clone()?;
                self.lookup_batches += 1;
                let batch = LookupBatch(self.lookup_batches);
                for digest in &digests {
                    self.reservations
                        .contents
                        .insert(*digest, ContentReservation::LookingUp(batch));
                }
                Some(Assignment::LookUpContents {
                    batch,
                    digests,
                    archive,
                })
            }
            Work::SubmitContent {
                authorization,
                source,
                signature,
            } => {
                let archive = self.archive.clone()?;
                let root = self.folders.get(&source.folder)?.root.clone();
                self.reservations
                    .contents
                    .insert(authorization.digest(), ContentReservation::Submitting);
                self.submissions_in_flight.insert(
                    authorization.digest(),
                    (source.clone(), signature.signature().byte_size),
                );
                Some(Assignment::SubmitContent {
                    authorization,
                    source,
                    root,
                    signature,
                    archive,
                })
            }
            Work::ReadDocumentStatus { content, document } => {
                let archive = self.archive.clone()?;
                self.reservations
                    .contents
                    .insert(content, ContentReservation::FollowingDocument);
                Some(Assignment::ReadDocumentStatus {
                    content,
                    document,
                    archive,
                })
            }
        }
    }

    /// When the loop must wake on its own: the store's deadlines, the connection's timer, a hint
    /// that coalesces, the next full walk, or a status change still to publish.
    fn next_deadline(&self, store: &StateStore) -> Option<Timestamp> {
        let now = self.clock.now();
        let status = (self.revision != self.published_revision).then(|| {
            self.last_status_emitted_at
                .map_or(now, |last| last.after(self.timing.status_coalescing_interval))
        });
        self.scheduled_deadline(store, now).into_iter().chain(status).min()
    }

    /// The deadlines that bring work, as the status reports them.
    fn scheduled_deadline(&self, store: &StateStore, now: Timestamp) -> Option<Timestamp> {
        let stored = store.next_deadline(now, &self.timing).ok().flatten();
        let hints = self.pending_hints.values().map(|(_, due)| *due).min();
        let walk = Some(self.last_full_walk_at.after(self.timing.full_walk_interval));
        [stored, next_timer(&self.connection), hints, walk]
            .into_iter()
            .flatten()
            .min()
    }

    pub fn status(&self, store: &StateStore) -> rusqlite::Result<CollectorStatus> {
        let connection = match &self.connection {
            ConnectionState::Unconfigured => ConnectionStatus::Unconfigured,
            ConnectionState::Available => ConnectionStatus::Connected {
                archive_origin: self.archive_origin.clone().unwrap_or_default(),
            },
            ConnectionState::Unreachable { since, retry_at, .. } => ConnectionStatus::Unreachable {
                since: *since,
                next_attempt_at: *retry_at,
            },
            ConnectionState::Probing { .. } => ConnectionStatus::Checking,
            ConnectionState::Deferred { until } => ConnectionStatus::Deferred { until: *until },
            ConnectionState::Suspended { reason, since } => ConnectionStatus::Suspended {
                reason: *reason,
                since: *since,
            },
        };
        let mut folders = Vec::with_capacity(self.folders.len());
        let mut attention = Vec::new();
        if matches!(self.connection, ConnectionState::Unconfigured) {
            attention.push(AttentionItem::ArchiveNotConfigured);
        }
        if let ConnectionState::Suspended { reason, .. } = &self.connection {
            attention.push(AttentionItem::CredentialSuspended { reason: *reason });
        }
        for record in self.folders.values() {
            let availability = self
                .availability
                .get(&record.folder)
                .copied()
                .unwrap_or(FolderAvailability::Available);
            let progress = store.survey_progress(record.folder)?;
            let backlog = match record.admission {
                FolderAdmission::AwaitingDecision => Some(self.backlog_summary(store, &[record.folder])?),
                FolderAdmission::Surveying | FolderAdmission::Collecting { .. } => None,
            };
            folders.push(FolderStatus {
                folder: record.folder,
                root: record.root.clone(),
                admission: record.admission,
                availability,
                files_under_examination: progress.paths_stabilizing_or_stable + progress.contents_unresolved,
                backlog,
            });
            if availability != FolderAvailability::Available {
                attention.push(AttentionItem::FolderUnavailable {
                    folder: record.folder,
                    availability,
                });
            }
        }
        let awaiting: Vec<FolderIdentifier> = self
            .folders
            .values()
            .filter(|record| record.admission == FolderAdmission::AwaitingDecision)
            .map(|record| record.folder)
            .collect();
        let backlog = if awaiting.is_empty() {
            None
        } else {
            attention.push(AttentionItem::BacklogAwaitsDecision {
                folders: awaiting.clone(),
            });
            Some(self.backlog_summary(store, &awaiting)?)
        };
        for content in store.contents_needing_attention()? {
            attention.push(match content.refusal {
                Some(reason) => AttentionItem::ContentRefused {
                    file_name: content.file_name,
                    reason,
                },
                None => AttentionItem::ContentFailing {
                    file_name: content.file_name,
                    failures: content.failures,
                },
            });
        }
        Ok(CollectorStatus {
            revision: self.revision,
            connection,
            archive_origin: self.archive_origin.clone(),
            folders,
            backlog,
            counts: store.state_counts()?,
            activities: self.activities(),
            attention,
            recent_receipts: store.recent_receipts(RECENT_RECEIPTS)?,
            next_scheduled_at: self.scheduled_deadline(store, self.clock.now()),
        })
    }

    fn backlog_summary(&self, store: &StateStore, folders: &[FolderIdentifier]) -> rusqlite::Result<BacklogSummary> {
        let mut summary = store.backlog_summary(folders)?;
        for ((folder, _), counts) in &self.disregarded {
            if folders.contains(folder) {
                for (reason, count) in counts {
                    *summary.disregarded_files.entry(*reason).or_default() += count;
                }
            }
        }
        Ok(summary)
    }

    fn activities(&self) -> Vec<Activity> {
        let file_name = |path: &PathKey| path.name.as_os_str().to_string_lossy().into_owned();
        let mut activities: Vec<Activity> = self
            .reservations
            .directories
            .iter()
            .map(|(folder, directory)| Activity::Listing {
                folder: *folder,
                directory: directory.as_str().to_owned(),
            })
            .collect();
        activities.extend(self.reservations.paths.iter().map(|path| Activity::Digesting {
            file_name: file_name(path),
        }));
        let mut batches: BTreeMap<LookupBatch, usize> = BTreeMap::new();
        for reservation in self.reservations.contents.values() {
            match reservation {
                ContentReservation::LookingUp(batch) => *batches.entry(*batch).or_default() += 1,
                ContentReservation::Submitting => {}
                ContentReservation::FollowingDocument => activities.push(Activity::FollowingDocument),
            }
        }
        activities.extend(
            batches
                .into_values()
                .map(|content_count| Activity::LookingUp { content_count }),
        );
        activities.extend(
            self.submissions_in_flight
                .values()
                .map(|(path, byte_size)| Activity::Submitting {
                    file_name: file_name(path),
                    byte_size: *byte_size,
                }),
        );
        activities
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::clock::ManualClock;
    use crate::scripted_archive::ScriptedArchive;
    use crate::{Collector, CollectorSettings};

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn timing() -> TimingPolicy {
        TimingPolicy {
            full_walk_interval: HOUR,
            document_follow_window: Duration::ZERO,
            ..TimingPolicy::default()
        }
    }

    fn start(
        database: &Path,
        archive: &Arc<ScriptedArchive>,
        clock: &Arc<ManualClock>,
    ) -> (Collector, Receiver<CollectorEvent>) {
        let archive: Arc<dyn ArchiveClient> = archive.clone();
        let clock: Arc<dyn Clock> = clock.clone();
        Collector::start(CollectorSettings::with_fixed_archive(
            database.to_path_buf(),
            archive,
            clock,
            timing(),
        ))
        .unwrap()
    }

    /// Waits until nothing can be done now, then moves the clock to the next deadline within the
    /// horizon and waits again, until no deadline within the horizon remains.
    fn settle(collector: &Collector, clock: &ManualClock, horizon: Duration) -> CollectorStatus {
        let limit = clock.now().after(horizon);
        loop {
            let status = collector.wait_until_idle(Duration::from_secs(30)).unwrap();
            match status.next_scheduled_at {
                Some(at) if at > clock.now() && at <= limit => clock.set(at),
                _ => return status,
            }
        }
    }

    #[test]
    fn one_file_is_surveyed_then_submitted_once_after_the_decision() {
        let temporary = tempfile::tempdir().unwrap();
        let folder_root = temporary.path().join("Downloads");
        std::fs::create_dir(&folder_root).unwrap();
        std::fs::write(folder_root.join("Invoice.pdf"), b"%PDF-1.7 one invoice").unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
        let (collector, events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);
        collector
            .connect_archive(
                ArchiveAddress::parse("https://archive.example.org").unwrap(),
                IngestToken::new("token".to_owned()),
            )
            .unwrap();
        let folder = collector.enroll_folder(folder_root.clone()).unwrap();

        let surveyed = settle(&collector, &clock, Duration::from_secs(60));

        let digest = crate::file_system_observation::content_digest_of(b"%PDF-1.7 one invoice");
        assert_eq!(archive.submission_count(&digest), 0);
        assert_eq!(surveyed.folders[0].admission, FolderAdmission::AwaitingDecision);
        let backlog = surveyed.backlog.clone().expect("the folder awaits its decision");
        assert_eq!(
            (backlog.candidate_files, backlog.files_new, backlog.new_contents),
            (1, 1, 1)
        );
        assert_eq!(surveyed.folders[0].backlog.as_ref(), Some(&backlog));
        assert_eq!(surveyed.archive_origin.as_deref(), Some("https://archive.example.org"));
        assert_eq!(
            surveyed.attention,
            vec![AttentionItem::BacklogAwaitsDecision { folders: vec![folder] }]
        );

        collector.decide_backlog(&[folder]).unwrap();
        let collected = settle(&collector, &clock, Duration::from_secs(60));

        assert_eq!(archive.submission_count(&digest), 1);
        assert_eq!(collected.counts.contents_present, 1);
        assert_eq!(collected.backlog, None);
        assert_eq!(collected.recent_receipts.len(), 1);
        assert_eq!(collected.recent_receipts[0].file_name, "Invoice.pdf");
        let received = events
            .try_iter()
            .find(|event| matches!(event, CollectorEvent::DocumentReceived { .. }));
        assert_eq!(
            received,
            Some(CollectorEvent::DocumentReceived {
                document_link: format!(
                    "https://archive.example.org/documents/{}",
                    ScriptedArchive::document_of(&digest).as_str()
                ),
                file_name: "Invoice.pdf".to_owned(),
            })
        );
    }

    #[test]
    fn the_commands_refuse_overlapping_folders_and_an_early_decision() {
        let temporary = tempfile::tempdir().unwrap();
        let downloads = temporary.path().join("Downloads");
        std::fs::create_dir_all(downloads.join("Scans")).unwrap();
        std::fs::write(downloads.join("Invoice.pdf"), b"%PDF-1.7 still stabilizing").unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
        let (collector, _events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);

        let folder = collector.enroll_folder(downloads.clone()).unwrap();
        assert_eq!(
            collector.enroll_folder(downloads.join("Scans")),
            Err(CommandRefusal::FolderOverlapsEnrolledFolder { folder })
        );
        assert_eq!(
            collector.enroll_folder(temporary.path().to_path_buf()),
            Err(CommandRefusal::FolderOverlapsEnrolledFolder { folder })
        );
        assert_eq!(
            collector.enroll_folder(downloads.clone()),
            Err(CommandRefusal::FolderAlreadyEnrolled { folder })
        );
        assert!(matches!(
            collector.enroll_folder(temporary.path().join("Missing")),
            Err(CommandRefusal::FolderRootNotADirectory { .. })
        ));
        assert_eq!(
            collector.decide_backlog(&[folder]),
            Err(CommandRefusal::SurveyIncomplete { folder })
        );
        assert_eq!(
            collector.decide_backlog(&[FolderIdentifier::new(99)]),
            Err(CommandRefusal::FolderUnknown {
                folder: FolderIdentifier::new(99)
            })
        );
        let status = collector.status().unwrap();
        assert_eq!(status.attention, vec![AttentionItem::ArchiveNotConfigured]);
        collector.withdraw_folder(folder).unwrap();
        assert_eq!(
            collector.withdraw_folder(folder),
            Err(CommandRefusal::FolderUnknown { folder })
        );
        assert!(collector.status().unwrap().folders.is_empty());
    }

    #[test]
    fn another_archive_is_refused_once_the_collector_holds_records_of_the_connected_one() {
        let temporary = tempfile::tempdir().unwrap();
        let downloads = temporary.path().join("Downloads");
        std::fs::create_dir(&downloads).unwrap();
        std::fs::write(downloads.join("Invoice.pdf"), b"%PDF-1.7 one invoice").unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
        let (collector, _events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);
        let connected = || ArchiveAddress::parse("https://archive.example.org").unwrap();
        let other = || ArchiveAddress::parse("https://other.example.org").unwrap();
        let token = |secret: &str| IngestToken::new(secret.to_owned());
        let refused = Err(CommandRefusal::ArchiveOriginDiffers {
            connected_origin: "https://archive.example.org".to_owned(),
        });

        collector.connect_archive(other(), token("first")).unwrap();
        collector.connect_archive(connected(), token("first")).unwrap();
        let folder = collector.enroll_folder(downloads).unwrap();
        assert_eq!(collector.connect_archive(other(), token("first")), refused);

        settle(&collector, &clock, Duration::from_secs(60));
        collector.withdraw_folder(folder).unwrap();
        assert_eq!(collector.connect_archive(other(), token("first")), refused);

        collector.connect_archive(connected(), token("second")).unwrap();
        assert_eq!(
            collector.status().unwrap().archive_origin.as_deref(),
            Some("https://archive.example.org")
        );
    }
}
