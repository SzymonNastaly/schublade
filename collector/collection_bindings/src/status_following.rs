//! Turns the core's `StatusChanged` announcements into the wait of `Collector::status_after`, the
//! one way an application follows the status.
//!
//! A follower waits before it reads, for an announcement above the revision it holds. The core
//! announces at most once per coalescing interval, so the status a follower then reads can be
//! newer than the announcement that woke it, and never older.

use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use collection_core::CollectorEvent;

pub(crate) struct RevisionAnnouncements {
    state: Mutex<AnnouncementState>,
    changed: event_listener::Event,
}

struct AnnouncementState {
    /// The revision the coordinator announced last, which is its highest.
    latest: u64,
    /// The coordinator ended, as it does after `Collector::shutdown`.
    ended: bool,
}

impl RevisionAnnouncements {
    /// Starts the thread that raises the latest revision for each `StatusChanged` and ends the
    /// announcements when the coordinator closes its events.
    pub(crate) fn follow(events: Receiver<CollectorEvent>) -> Arc<RevisionAnnouncements> {
        let announcements = Arc::new(RevisionAnnouncements {
            state: Mutex::new(AnnouncementState {
                latest: 0,
                ended: false,
            }),
            changed: event_listener::Event::new(),
        });
        let raised = Arc::clone(&announcements);
        std::thread::Builder::new()
            .name("collector-announcements".to_owned())
            .spawn(move || {
                for event in events {
                    match event {
                        CollectorEvent::StatusChanged { revision } => {
                            raised.state().latest = revision;
                            raised.changed.notify(usize::MAX);
                        }
                        // The receipts in the status carry the same fact.
                        CollectorEvent::DocumentReceived {
                            document_link: _,
                            file_name: _,
                        } => {}
                    }
                }
                raised.state().ended = true;
                raised.changed.notify(usize::MAX);
            })
            .expect("the system starts the announcement thread");
        announcements
    }

    fn state(&self) -> MutexGuard<'_, AnnouncementState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits until the coordinator announced a revision above `known`, or ended.
    pub(crate) async fn announcement_above(&self, known: u64) {
        loop {
            // Registered before the state is read, so no announcement falls between the two.
            let announcement = self.changed.listen();
            {
                let state = self.state();
                if state.latest > known || state.ended {
                    return;
                }
            }
            announcement.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Arc;
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Duration;

    use crate::collector_fixture::{
        ANSWER_LIMIT, ARCHIVE_ADDRESS, CollectorFixture, TOKEN, copy_tree, follow_until, read_after,
    };
    use crate::{
        ArchiveConnection, BacklogSummary, CollectionProgress, CollectorConfiguration, CollectorFault,
        CredentialStorage, FolderAdmission, FolderIdentifier, FolderReference, SkipReason, SkippedCount,
        start_collector,
    };

    const CORPUS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test_fixtures/collection_corpus");
    /// A read still unanswered after this long is taken to wait for an announcement. A read with
    /// nothing to wait for answers within milliseconds.
    const WAITING_INTERVAL: Duration = Duration::from_millis(100);

    #[test]
    fn a_read_for_the_current_revision_waits_for_the_next_commit_and_the_first_read_answers_at_once() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("Scans").to_str().unwrap().to_owned();
        std::fs::create_dir(&root).unwrap();
        let collector = pollster::block_on(start_collector(CollectorConfiguration {
            data_directory: directory.path().join("data").to_str().unwrap().to_owned(),
            credential_storage: CredentialStorage::ProcessMemory,
        }))
        .unwrap();

        let first = pollster::block_on(Arc::clone(&collector).status_after(None)).unwrap();
        let waiting = read_after(&collector, Some(first.revision));
        let answer_before_the_commit = waiting.recv_timeout(WAITING_INTERVAL);
        let enrolled = pollster::block_on(Arc::clone(&collector).enroll_folder(root.clone())).unwrap();
        let next = waiting.recv_timeout(ANSWER_LIMIT).unwrap().unwrap();

        assert_eq!(first.archive, ArchiveConnection::NotConfigured);
        assert_eq!(first.folders, vec![]);
        assert_eq!(answer_before_the_commit, Err(RecvTimeoutError::Timeout));
        let folder = FolderReference {
            identifier: FolderIdentifier { value: 1 },
            root,
        };
        assert_eq!(enrolled, folder);
        assert!(
            next.revision > first.revision,
            "{} after {}",
            next.revision,
            first.revision
        );
        let listed: Vec<FolderReference> = next.folders.into_iter().map(|listed| listed.folder).collect();
        assert_eq!(listed, vec![folder]);
        pollster::block_on(collector.shutdown());
    }

    #[test]
    fn following_a_survey_of_the_corpus_never_goes_back_and_reaches_the_last_status() {
        let fixture = CollectorFixture::start();
        let corpus = fixture.create_directory("corpus");
        copy_tree(Path::new(CORPUS), Path::new(&corpus));
        let collector = &fixture.collector;
        pollster::block_on(Arc::clone(collector).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();
        for folder in ["Downloads", "Desktop", "Documents/Scans", "Cloud Storage"] {
            pollster::block_on(Arc::clone(collector).enroll_folder(format!("{corpus}/{folder}"))).unwrap();
        }

        let followed = follow_until(collector, |status| {
            status.folders.len() == 4
                && status
                    .folders
                    .iter()
                    .all(|folder| matches!(folder.admission, FolderAdmission::AwaitingDecision { .. }))
        });

        let revisions: Vec<u64> = followed.iter().map(|status| status.revision).collect();
        assert!(
            revisions.is_sorted_by(|earlier, later| earlier < later),
            "{revisions:?}"
        );
        let last = followed.last().unwrap();
        let awaiting = |files: u64, skipped: &[(SkipReason, u64)]| FolderAdmission::AwaitingDecision {
            backlog: BacklogSummary {
                files_new: files,
                new_contents: files,
                files_already_archived: 0,
                files_deleted_from_archive: 0,
                files_refused_by_archive: 0,
                skipped: skipped
                    .iter()
                    .map(|&(reason, count)| SkippedCount { reason, count })
                    .collect(),
                files_under_examination: 0,
            },
        };
        let surveyed: Vec<(&str, FolderAdmission)> = last
            .folders
            .iter()
            .map(|folder| (&folder.folder.root[corpus.len()..], folder.admission.clone()))
            .collect();
        assert_eq!(
            surveyed,
            vec![
                (
                    "/Downloads",
                    awaiting(
                        16,
                        &[
                            (SkipReason::UnrecognizedContent, 1),
                            (SkipReason::IncompleteDownload, 2)
                        ]
                    )
                ),
                ("/Desktop", awaiting(3, &[(SkipReason::EmptyFile, 1)])),
                ("/Documents/Scans", awaiting(10, &[])),
                ("/Cloud Storage", awaiting(6, &[])),
            ]
        );
        assert_eq!(
            last.progress,
            CollectionProgress {
                documents_in_archive: 0,
                documents_awaiting_submission: 33,
                files_under_examination: 0,
            }
        );
        pollster::block_on(Arc::clone(collector).shutdown());
    }

    #[test]
    fn two_followers_each_read_a_change_and_then_wait_for_the_next() {
        let fixture = CollectorFixture::start();
        let collector = &fixture.collector;
        let first = pollster::block_on(Arc::clone(collector).status_after(None)).unwrap();
        let waiting = [
            read_after(collector, Some(first.revision)),
            read_after(collector, Some(first.revision)),
        ];
        let answers_before_the_change = waiting.each_ref().map(|waiting| waiting.recv_timeout(WAITING_INTERVAL));

        pollster::block_on(Arc::clone(collector).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();
        let answers = waiting.map(|waiting| waiting.recv_timeout(ANSWER_LIMIT).unwrap().unwrap());
        let resting = answers
            .each_ref()
            .map(|answer| read_after(collector, Some(answer.revision)));
        let answers_without_a_change = resting.map(|resting| resting.recv_timeout(WAITING_INTERVAL));
        pollster::block_on(Arc::clone(collector).shutdown());

        let timed_out = || Err(RecvTimeoutError::Timeout);
        assert_eq!(answers_before_the_change, [timed_out(), timed_out()]);
        for answer in &answers {
            assert!(
                matches!(answer.archive, ArchiveConnection::Configured { .. }),
                "{:?}",
                answer.archive
            );
        }
        assert_eq!(answers_without_a_change, [timed_out(), timed_out()]);
    }

    #[test]
    fn shutdown_ends_every_read() {
        let fixture = CollectorFixture::start();
        let collector = &fixture.collector;
        let first = pollster::block_on(Arc::clone(collector).status_after(None)).unwrap();
        let waiting = [
            read_after(collector, Some(first.revision)),
            read_after(collector, Some(first.revision)),
        ];
        let answer_before_the_shutdown = waiting[0].recv_timeout(WAITING_INTERVAL);

        pollster::block_on(Arc::clone(collector).shutdown());
        let answers = waiting.map(|waiting| waiting.recv_timeout(ANSWER_LIMIT).unwrap());
        let later = pollster::block_on(Arc::clone(collector).status_after(Some(first.revision)));
        let current = pollster::block_on(Arc::clone(collector).status_after(None));
        pollster::block_on(Arc::clone(collector).shutdown());

        assert_eq!(answer_before_the_shutdown, Err(RecvTimeoutError::Timeout));
        assert_eq!(answers, [Err(CollectorFault::Stopped), Err(CollectorFault::Stopped)]);
        assert_eq!(later, Err(CollectorFault::Stopped));
        assert_eq!(current, Err(CollectorFault::Stopped));
    }
}
