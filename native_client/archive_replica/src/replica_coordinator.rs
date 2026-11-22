//! The replica's coordinator: the one thread that owns the store's writing connection and the
//! synchronization machine. It requests a page itself, so a page is requested and applied in one
//! step, and a command waits at most for the request in flight. The texts of archived documents
//! are read by the lanes of `text_retrieval.rs` and written here. The status is published where
//! a reader finds it without the coordinator.

use std::collections::HashSet;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use archive_access::{ArchiveAddress, ArchiveAuthorization, ArchiveToken, Clock, DocumentIdentifier, Timestamp};

use crate::archive_reader::{ArchiveReader, PageAnswer};
use crate::replica_store::{PageApplication, ReplicaStore};
use crate::replica_synchronization::{
    Attendance, SynchronizationEffect, SynchronizationInput, SynchronizationState, SynchronizationTiming, WakeReason,
    advance_synchronization,
};
use crate::text_retrieval::{
    AwaitedText, RetrievedText, TEXT_LANES, TEXTS_PER_ASSIGNMENT, TextAssignment, TextLanes, TextReport,
};
use crate::{ArchiveReaderConstructor, FollowedArchive, MirroredArchive, ReplicaEvent, ReplicaFault, ReplicaStatus};

/// How long the loop waits at most before it reads the clock again.
const TICK: Duration = Duration::from_secs(60);

pub(crate) enum CoordinatorInput {
    Attach(Box<Attachment>),
    Wake(WakeReason),
    Attendance(Attendance),
    /// A lane ended its assignment.
    TextsRetrieved(TextReport),
    /// A reader of one document's text asked the archive for it, ahead of the lanes.
    TextRead(RetrievedText),
    Shutdown,
}

pub(crate) struct Attachment {
    pub(crate) address: ArchiveAddress,
    pub(crate) token: ArchiveToken,
    pub(crate) authorization: ArchiveAuthorization,
    pub(crate) reply: Sender<Result<(), ReplicaFault>>,
}

/// One request of the page after the copy's cursor, and what the copy made of the answer, as the
/// machine's next input. `None` when another page was applied first, which leaves nothing to say.
pub fn exchange_page(
    store: &mut ReplicaStore,
    reader: &dyn ArchiveReader,
    now: Timestamp,
) -> rusqlite::Result<Option<SynchronizationInput>> {
    let requested_after = store.cursor()?;
    Ok(Some(match reader.read_changes(requested_after.as_ref()) {
        Ok(PageAnswer::Page(page)) => match store.apply_page(requested_after.as_ref(), &page, now)? {
            PageApplication::Applied { unsettled_documents } => SynchronizationInput::PageApplied {
                complete: page.complete,
                fill_complete: store.mirror()?.is_some_and(|mirror| mirror.fill_complete),
                remaining_entries: page.remaining_entries,
                unsettled_documents,
            },
            PageApplication::CursorMoved => return Ok(None),
        },
        Ok(PageAnswer::JournalReplaced) => {
            store.discard()?;
            SynchronizationInput::JournalReplaced
        }
        Err(condition) => SynchronizationInput::RequestFailed(condition),
    }))
}

pub(crate) struct ReplicaCoordinator {
    pub(crate) store: ReplicaStore,
    /// The archive the machine's requests go to. Present from the first connection on.
    pub(crate) reader: Option<Arc<dyn ArchiveReader>>,
    /// The same reader, where a call that downloads a representation finds it.
    pub(crate) followed: FollowedArchive,
    pub(crate) text_lanes: TextLanes,
    /// The assignments the lanes have not reported yet, and their documents.
    pub(crate) text_assignments: usize,
    pub(crate) texts_in_flight: HashSet<DocumentIdentifier>,
    /// A text request failed after the last page was applied. Texts are requested again after
    /// the next page, which shows that the archive answers.
    pub(crate) texts_interrupted: bool,
    pub(crate) state: SynchronizationState,
    pub(crate) effect: Option<SynchronizationEffect>,
    pub(crate) attendance: Attendance,
    pub(crate) timing: SynchronizationTiming,
    pub(crate) clock: Arc<dyn Clock>,
    pub(crate) archive_readers: ArchiveReaderConstructor,
    pub(crate) published: Arc<Mutex<ReplicaStatus>>,
    pub(crate) events: Sender<ReplicaEvent>,
}

impl ReplicaCoordinator {
    /// Runs until a shutdown, the end of every handle, or a failure of the store. A copy whose
    /// file fails is not written further, and the next start replaces a file it cannot read.
    pub(crate) fn run(mut self, inbox: Receiver<CoordinatorInput>) {
        if let Err(error) = self.follow(&inbox) {
            eprintln!("replica: the local copy failed, and its synchronization stops: {error}");
        }
    }

    fn follow(&mut self, inbox: &Receiver<CoordinatorInput>) -> rusqlite::Result<()> {
        loop {
            // An input that waits is taken before the next page, so a fill of many pages delays
            // a command by one page at most.
            let received = match self.effect {
                Some(SynchronizationEffect::RequestPage) => inbox.try_recv().map_err(|error| match error {
                    TryRecvError::Empty => RecvTimeoutError::Timeout,
                    TryRecvError::Disconnected => RecvTimeoutError::Disconnected,
                }),
                Some(SynchronizationEffect::AwaitDeadline(deadline)) => {
                    inbox.recv_timeout(deadline.elapsed_since(self.clock.now()).min(TICK))
                }
                None => inbox.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match received {
                Ok(CoordinatorInput::Shutdown) | Err(RecvTimeoutError::Disconnected) => return Ok(()),
                Ok(CoordinatorInput::Attach(attachment)) => {
                    let Attachment {
                        address,
                        token,
                        authorization,
                        reply,
                    } = *attachment;
                    // The reply follows the publication, so a caller that reads the status after
                    // its command finds the attachment in it.
                    let attached = self
                        .store
                        .attach(&address.origin(), &authorization, &token.fingerprint())
                        .and_then(|()| self.connect(&address, &token))
                        .and_then(|()| self.publish());
                    let _ = reply.send(
                        attached
                            .as_ref()
                            .map(|_| ())
                            .map_err(|error| ReplicaFault::StoreFailed {
                                detail: error.to_string(),
                            }),
                    );
                    attached?;
                }
                Ok(CoordinatorInput::TextsRetrieved(report)) => {
                    self.text_assignments -= 1;
                    for document in &report.assigned {
                        self.texts_in_flight.remove(document);
                    }
                    self.store.record_texts(&report.retrieved)?;
                    self.texts_interrupted |= report.interruption.is_some();
                }
                Ok(CoordinatorInput::TextRead(text)) => self.store.record_texts(&[text])?,
                Ok(CoordinatorInput::Wake(reason)) => self.advance(SynchronizationInput::Woken(reason)),
                // The deadline that runs was set under the earlier attendance and stays.
                Ok(CoordinatorInput::Attendance(attendance)) => self.attendance = attendance,
                Err(RecvTimeoutError::Timeout) => match self.effect {
                    Some(SynchronizationEffect::RequestPage) => {
                        let reader = Arc::clone(
                            self.reader
                                .as_ref()
                                .expect("the machine requests a page only after a connection"),
                        );
                        if let Some(input) = exchange_page(&mut self.store, reader.as_ref(), self.clock.now())? {
                            if matches!(input, SynchronizationInput::PageApplied { .. }) {
                                self.texts_interrupted = false;
                            }
                            self.advance(input);
                        }
                    }
                    Some(SynchronizationEffect::AwaitDeadline(deadline)) if deadline <= self.clock.now() => {
                        self.advance(SynchronizationInput::DeadlineReached);
                    }
                    Some(SynchronizationEffect::AwaitDeadline(_)) | None => {}
                },
            }
            self.plan_text_retrieval()?;
            self.publish()?;
        }
    }

    /// Gives each free lane the newest documents that await their text, while the archive
    /// answers. What awaits is read from the records each time, so nothing is queued.
    fn plan_text_retrieval(&mut self) -> rusqlite::Result<()> {
        let answering = match self.state {
            SynchronizationState::Filling { .. }
            | SynchronizationState::Following { .. }
            | SynchronizationState::CatchingUp => !self.texts_interrupted,
            SynchronizationState::Disconnected
            | SynchronizationState::Unreachable { .. }
            | SynchronizationState::Suspended { .. }
            | SynchronizationState::ArchiveOutdated { .. } => false,
        };
        let Some(reader) = self.reader.clone().filter(|_| answering) else {
            return Ok(());
        };
        while self.text_assignments < TEXT_LANES {
            let documents: Vec<AwaitedText> = self
                .store
                .documents_awaiting_text(self.texts_in_flight.len() + TEXTS_PER_ASSIGNMENT)?
                .into_iter()
                .filter(|awaited| !self.texts_in_flight.contains(&awaited.document))
                .take(TEXTS_PER_ASSIGNMENT)
                .collect();
            if documents.is_empty() {
                break;
            }
            self.texts_in_flight
                .extend(documents.iter().map(|awaited| awaited.document.clone()));
            self.text_assignments += 1;
            self.text_lanes.assign(TextAssignment {
                reader: Arc::clone(&reader),
                documents,
            });
        }
        Ok(())
    }

    /// Follows the archive with this token from where the copy stands.
    pub(crate) fn connect(&mut self, address: &ArchiveAddress, token: &ArchiveToken) -> rusqlite::Result<()> {
        let reader = (self.archive_readers)(address, token);
        *self.followed.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(&reader));
        self.reader = Some(reader);
        self.texts_interrupted = false;
        let fill_complete = self.store.mirror()?.is_some_and(|mirror| mirror.fill_complete);
        self.advance(SynchronizationInput::ConnectionEstablished { fill_complete });
        Ok(())
    }

    fn advance(&mut self, input: SynchronizationInput) {
        let (state, effect) = advance_synchronization(
            self.state.clone(),
            input,
            self.attendance,
            self.clock.now(),
            &self.timing,
        );
        self.state = state;
        self.effect = effect;
    }

    /// What a status shows now, with the revision still to be given.
    pub(crate) fn status(&self) -> rusqlite::Result<ReplicaStatus> {
        let mirror = self.store.mirror()?;
        let extent = self.store.extent()?;
        Ok(ReplicaStatus {
            revision: 0,
            content_revision: mirror.as_ref().map_or(0, |mirror| mirror.content_revision),
            documents: extent.documents,
            documents_awaiting_text: extent.documents_awaiting_text,
            archive: mirror.map(|mirror| MirroredArchive {
                origin: mirror.archive_origin,
                permission_level: mirror.permission_level,
                restricted: mirror.scope_digest != archive_access::UNRESTRICTED_SCOPE_DIGEST,
                fill_complete: mirror.fill_complete,
                synchronized_at: mirror.synchronized_at,
            }),
            synchronization: self.state.clone(),
        })
    }

    /// Publishes the status under the next revision, and announces it, exactly when it shows
    /// something else than the published one.
    fn publish(&mut self) -> rusqlite::Result<()> {
        let mut status = self.status()?;
        let mut published = self.published.lock().unwrap_or_else(PoisonError::into_inner);
        status.revision = published.revision;
        if status != *published {
            status.revision += 1;
            let revision = status.revision;
            *published = status;
            drop(published);
            // An application that follows no events still reads the status.
            let _ = self.events.send(ReplicaEvent::StatusChanged { revision });
        }
        Ok(())
    }
}
