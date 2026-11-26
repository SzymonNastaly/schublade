//! The worker lanes: threads that each perform one unit of work and send its result to the
//! coordinator. No lane reads or writes state; everything a unit needs travels with it.

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::archive_client::ArchiveClient;
use crate::archive_connection::ArchiveAnswer;
use crate::candidate_classification::ReadableSignature;
use crate::collection_coordinator::{CoordinatorInput, SubmissionResult, WorkResult};
use crate::content_synchronization::SubmissionAuthorization;
use crate::directory_reconciliation::ListingOutcome;
use crate::document_reading::DocumentReader;
use crate::domain_types::{ContentDigest, DirectoryKey, DocumentIdentifier, FolderIdentifier, PathKey};
use crate::file_system_observation::{
    absolute_path, compute_digest, list_directory, observe_signature, read_submission_source,
};
use crate::work_planning::{LaneCapacity, LookupBatch};
use archive_access::Clock;

/// One planned unit of work with everything its lane needs: the folder root for the disk, the
/// archive client for a request, the document reader for a submission.
pub enum Assignment {
    ListDirectory {
        folder: FolderIdentifier,
        root: PathBuf,
        directory: DirectoryKey,
        recursive: bool,
    },
    ComputeDigest {
        path: PathKey,
        root: PathBuf,
        signature: ReadableSignature,
    },
    LookUpContents {
        batch: LookupBatch,
        digests: Vec<ContentDigest>,
        archive: Arc<dyn ArchiveClient>,
    },
    SubmitContent {
        authorization: SubmissionAuthorization,
        source: PathKey,
        root: PathBuf,
        signature: ReadableSignature,
        archive: Arc<dyn ArchiveClient>,
        reader: Arc<dyn DocumentReader>,
    },
    ReadDocumentStatus {
        content: ContentDigest,
        document: DocumentIdentifier,
        archive: Arc<dyn ArchiveClient>,
    },
}

/// The three thread pools: one for listings, one for digests, one for every archive request.
/// Each pool has as many threads as its lanes have capacity, so a planned unit never queues
/// behind another.
pub struct WorkerLanes {
    listing: Sender<Assignment>,
    digest: Sender<Assignment>,
    archive: Sender<Assignment>,
}

impl WorkerLanes {
    pub fn start(capacity: &LaneCapacity, inbox: Sender<CoordinatorInput>, clock: Arc<dyn Clock>) -> WorkerLanes {
        let pool = |name: &str, threads: usize| {
            let (sender, receiver) = channel::<Assignment>();
            let receiver = Arc::new(Mutex::new(receiver));
            for index in 0..threads.max(1) {
                let receiver = Arc::clone(&receiver);
                let inbox = inbox.clone();
                let clock = Arc::clone(&clock);
                let _ = thread::Builder::new()
                    .name(format!("collector-{name}-{index}"))
                    .spawn(move || {
                        while let Some(assignment) = next_assignment(&receiver) {
                            execute(assignment, &inbox, clock.as_ref());
                        }
                    });
            }
            sender
        };
        WorkerLanes {
            listing: pool("listing", capacity.listing),
            digest: pool("digest", capacity.digest),
            archive: pool(
                "archive",
                capacity.lookup + capacity.submission + capacity.document_status,
            ),
        }
    }

    pub fn assign(&self, assignment: Assignment) {
        let lane = match assignment {
            Assignment::ListDirectory { .. } => &self.listing,
            Assignment::ComputeDigest { .. } => &self.digest,
            Assignment::LookUpContents { .. }
            | Assignment::SubmitContent { .. }
            | Assignment::ReadDocumentStatus { .. } => &self.archive,
        };
        let _ = lane.send(assignment);
    }
}

/// `None` once the coordinator dropped its lanes, which ends the thread.
fn next_assignment(receiver: &Mutex<Receiver<Assignment>>) -> Option<Assignment> {
    receiver
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .recv()
        .ok()
}

fn execute(assignment: Assignment, inbox: &Sender<CoordinatorInput>, clock: &dyn Clock) {
    let send = |input| {
        let _ = inbox.send(input);
    };
    match assignment {
        Assignment::ListDirectory {
            folder,
            root,
            directory,
            recursive,
        } => {
            list_directory(folder, &root, &directory, recursive, clock, &mut |mut listing| {
                // A subdirectory reads as vanished when the whole root is gone, which must reach
                // the availability region and never delete rows, so the root is listed instead.
                if listing.outcome == ListingOutcome::Vanished
                    && !listing.directory.is_root()
                    && observe_signature(&root).ok().flatten().is_none()
                {
                    listing.directory = DirectoryKey::root();
                }
                send(CoordinatorInput::Listing(listing));
            });
            send(CoordinatorInput::Finished(WorkResult::ListingFinished {
                folder,
                directory,
                recursive,
            }));
        }
        Assignment::ComputeDigest { path, root, signature } => {
            let finding = compute_digest(
                &absolute_path(&root, &path.directory, path.name.as_os_str()),
                &signature,
            );
            send(CoordinatorInput::Finished(WorkResult::Digest {
                path,
                based_on: signature,
                finding,
                at: clock.now(),
            }));
        }
        Assignment::LookUpContents {
            batch,
            digests,
            archive,
        } => {
            let answer = archive.look_up(&digests);
            send(CoordinatorInput::Finished(WorkResult::Archive {
                answer: ArchiveAnswer::Lookup { answer },
                batch: Some(batch),
                at: clock.now(),
            }));
        }
        Assignment::SubmitContent {
            authorization,
            source,
            root,
            signature,
            archive,
            reader,
        } => {
            let content = authorization.digest();
            let absolute = absolute_path(&root, &source.directory, source.name.as_os_str());
            let result = match read_submission_source(&absolute, &signature, content, clock) {
                Ok(verified) => {
                    let derived = reader.read(&verified);
                    SubmissionResult::Answered(archive.submit(authorization, verified, derived))
                }
                Err(failure) => SubmissionResult::SourceFailed {
                    current: failure.current,
                },
            };
            send(CoordinatorInput::Finished(WorkResult::Submission {
                content,
                source,
                based_on: signature,
                result,
                at: clock.now(),
            }));
        }
        Assignment::ReadDocumentStatus {
            content,
            document,
            archive,
        } => {
            let answer = archive.read_document_status(&document);
            send(CoordinatorInput::Finished(WorkResult::Archive {
                answer: ArchiveAnswer::DocumentStatus { content, answer },
                batch: None,
                at: clock.now(),
            }));
        }
    }
}
