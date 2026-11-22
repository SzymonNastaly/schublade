//! Turns each core's announcements into the wait of `status_after`: one independent stream for
//! `Collector` and one for `Library`, while forwarding collector connection changes and accepted
//! uploads into the library.

use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};

use archive_replica::{Replica, ReplicaEvent, WakeReason};
use collection_core::{CollectorEvent, ConnectionStatus};

use crate::published_library::{LibraryStatus, publish_library_status};
use crate::refusals::{ApplicationFault, ApplicationStartFailure};
use crate::{read_collector_connection, replica_handle};

pub(crate) struct RevisionAnnouncements {
    state: Mutex<AnnouncementState>,
    changed: event_listener::Event,
}

struct AnnouncementState {
    /// The revision the coordinator announced last, which is its highest.
    latest: u64,
    /// The coordinator ended, as it does after `shutdown`.
    ended: bool,
}

impl RevisionAnnouncements {
    /// Starts the thread that raises the latest revision for each `StatusChanged`, updates the
    /// library's view of the collector's connection only when that observation changes, wakes the
    /// replica when a document is accepted, and ends waiting reads on shutdown.
    pub(crate) fn follow(
        events: Receiver<CollectorEvent>,
        collector_core: Arc<RwLock<Option<collection_core::Collector>>>,
        replica_core: Arc<RwLock<Option<Arc<Replica>>>>,
        library_announcements: Arc<LibraryAnnouncements>,
    ) -> Arc<RevisionAnnouncements> {
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
                            if let Ok(connection) = read_collector_connection(&collector_core) {
                                library_announcements.update_collector_connection(&replica_core, connection);
                            }
                            raised.state().latest = revision;
                            raised.changed.notify(usize::MAX);
                        }
                        CollectorEvent::DocumentReceived {
                            document_link: _,
                            file_name: _,
                        } => {
                            if let Ok(replica) = replica_handle(&replica_core) {
                                replica.wake(WakeReason::DocumentAccepted);
                            }
                        }
                    }
                }
                raised.mark_ended();
            })
            .expect("the system starts the collector announcement thread");
        announcements
    }

    fn state(&self) -> MutexGuard<'_, AnnouncementState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn mark_ended(&self) {
        self.state().ended = true;
        self.changed.notify(usize::MAX);
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

pub(crate) struct LibraryAnnouncements {
    refresh_gate: Mutex<()>,
    state: Mutex<LibraryAnnouncementState>,
    changed: event_listener::Event,
}

struct LibraryAnnouncementState {
    latest: LibraryStatus,
    collector_connection: Option<(Option<String>, ConnectionStatus)>,
    /// `(content_revision, documents_in_ingestion, documents_failed)` cached so `facets()` runs
    /// only when `content_revision` changes.
    cached_facets: Option<(u64, u64, u64)>,
    ended: bool,
    fault: Option<ApplicationFault>,
}

impl LibraryAnnouncements {
    pub(crate) fn follow(
        events: Receiver<ReplicaEvent>,
        replica_core: Arc<RwLock<Option<Arc<Replica>>>>,
        initial_collector_connection: Option<(Option<String>, ConnectionStatus)>,
    ) -> Result<Arc<LibraryAnnouncements>, ApplicationStartFailure> {
        let initial_replica = replica_handle(&replica_core).map_err(|fault| ApplicationStartFailure::Unexpected {
            detail: fault.to_string(),
        })?;
        let replica_status = initial_replica.status();
        let facets = initial_replica.facets()?;
        let initial_status = publish_library_status(
            &replica_status,
            initial_collector_connection.as_ref(),
            facets.documents_in_ingestion,
            facets.documents_failed,
            0,
        );

        let announcements = Arc::new(LibraryAnnouncements {
            refresh_gate: Mutex::new(()),
            state: Mutex::new(LibraryAnnouncementState {
                latest: initial_status,
                collector_connection: initial_collector_connection,
                cached_facets: Some((
                    replica_status.content_revision,
                    facets.documents_in_ingestion,
                    facets.documents_failed,
                )),
                ended: false,
                fault: None,
            }),
            changed: event_listener::Event::new(),
        });
        let raised = Arc::clone(&announcements);
        std::thread::Builder::new()
            .name("replica-announcements".to_owned())
            .spawn(move || {
                for event in events {
                    match event {
                        ReplicaEvent::StatusChanged { revision: _ } => {
                            raised.refresh(&replica_core, None);
                        }
                    }
                }
                raised.mark_ended();
            })
            .expect("the system starts the replica announcement thread");
        Ok(announcements)
    }

    fn state(&self) -> MutexGuard<'_, LibraryAnnouncementState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn mark_ended(&self) {
        self.state().ended = true;
        self.changed.notify(usize::MAX);
    }

    pub(crate) fn is_ended(&self) -> bool {
        self.state().ended
    }

    pub(crate) fn update_collector_connection(
        &self,
        replica_core: &RwLock<Option<Arc<Replica>>>,
        connection: (Option<String>, ConnectionStatus),
    ) {
        let _gate = self.refresh_gate.lock().unwrap_or_else(PoisonError::into_inner);
        let changed = {
            let state = self.state();
            if state.ended {
                return;
            }
            state.collector_connection.as_ref() != Some(&connection)
        };
        if changed {
            self.refresh_locked(replica_core, Some(connection));
        }
    }

    pub(crate) fn refresh(
        &self,
        replica_core: &RwLock<Option<Arc<Replica>>>,
        collector_connection: Option<(Option<String>, ConnectionStatus)>,
    ) {
        let _gate = self.refresh_gate.lock().unwrap_or_else(PoisonError::into_inner);
        self.refresh_locked(replica_core, collector_connection);
    }

    fn refresh_locked(
        &self,
        replica_core: &RwLock<Option<Arc<Replica>>>,
        collector_connection: Option<(Option<String>, ConnectionStatus)>,
    ) {
        let Ok(replica) = replica_handle(replica_core) else {
            return;
        };
        let replica_status = replica.status();
        let (cached_facets, current_collector_connection) = {
            let mut state = self.state();
            if state.ended {
                return;
            }
            if let Some(connection) = collector_connection {
                state.collector_connection = Some(connection);
            }
            (state.cached_facets, state.collector_connection.clone())
        };
        let (content_revision, in_ingestion, failed) = match cached_facets {
            Some((cached_revision, in_ingestion, failed)) if cached_revision == replica_status.content_revision => {
                (cached_revision, in_ingestion, failed)
            }
            _ => match replica.facets() {
                Ok(facets) => (
                    facets.content_revision,
                    facets.documents_in_ingestion,
                    facets.documents_failed,
                ),
                Err(fault) => {
                    let mut state = self.state();
                    state.fault = Some(fault.into());
                    self.changed.notify(usize::MAX);
                    return;
                }
            },
        };

        let mut state = self.state();
        if state.ended {
            return;
        }
        state.fault = None;
        state.cached_facets = Some((content_revision, in_ingestion, failed));
        let mut candidate = publish_library_status(
            &replica_status,
            current_collector_connection.as_ref(),
            in_ingestion,
            failed,
            state.latest.revision,
        );
        if candidate != state.latest {
            candidate.revision += 1;
            state.latest = candidate;
            self.changed.notify(usize::MAX);
        }
    }

    pub(crate) async fn status_after(&self, revision: Option<u64>) -> Result<LibraryStatus, ApplicationFault> {
        let Some(known) = revision else {
            let state = self.state();
            if state.ended {
                return Err(ApplicationFault::Stopped);
            }
            if let Some(fault) = &state.fault {
                return Err(fault.clone());
            }
            return Ok(state.latest.clone());
        };
        loop {
            let announcement = self.changed.listen();
            {
                let state = self.state();
                if state.ended {
                    return Err(ApplicationFault::Stopped);
                }
                if let Some(fault) = &state.fault {
                    return Err(fault.clone());
                }
                if state.latest.revision > known {
                    return Ok(state.latest.clone());
                }
            }
            announcement.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::path::Path;
    use std::sync::Arc;
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::{Duration, SystemTime};

    use archive_access::{ContentDigest, DocumentIdentifier as CoreDocumentIdentifier, Timestamp};
    use archive_replica::replica_records::{
        CalendarDate as CoreCalendarDate, CategoryIdentifier as CoreCategoryIdentifier, CategoryRecord,
        DocumentCondition as CoreDocumentCondition, DocumentRecord, ExtractedField, FieldValue as CoreFieldValue,
        PersonAssignment, SenderIdentifier as CoreSenderIdentifier, SenderRecord,
    };
    use sha2::{Digest, Sha256};

    use crate::application_fixture::{
        ANSWER_LIMIT, ARCHIVE_ADDRESS, ApplicationFixture, TOKEN, copy_tree, follow_collector_until,
        follow_library_until, read_collector_after, read_library_after,
    };
    use crate::{
        Amount, ArchiveConnection, ArchivePermission, BacklogSummary, CalendarDate, CollectionPlacement,
        CollectionProgress, ConnectionCondition, DocumentCondition, DocumentIdentifier, DocumentRow, FolderAdmission,
        FolderIdentifier, FolderReference, LibraryCopy, LibraryScope, ListingHeading, ListingOrder, ListingRequest,
        ListingRow, OriginalKind, RowPassage, SkipReason, SkippedCount,
    };

    const CORPUS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test_fixtures/collection_corpus");
    /// A read still unanswered after this long is taken to wait for an announcement. A read with
    /// nothing to wait for answers within milliseconds.
    const WAITING_INTERVAL: Duration = Duration::from_millis(100);

    #[test]
    fn a_read_for_the_current_revision_waits_for_the_next_commit_and_the_first_read_answers_at_once() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let collector = fixture.core.collector().unwrap();
        let root = fixture.create_directory("Scans");

        let first = pollster::block_on(Arc::clone(&collector).status_after(None)).unwrap();
        let waiting = read_collector_after(&collector, Some(first.revision));
        let answer_before_the_commit = waiting.recv_timeout(WAITING_INTERVAL);
        let enrolled = pollster::block_on(Arc::clone(&collector).enroll_folder(root.clone())).unwrap();
        let next = waiting.recv_timeout(ANSWER_LIMIT).unwrap().unwrap();

        assert_eq!(
            pollster::block_on(fixture.core.library().status_after(None))
                .unwrap()
                .archive,
            ArchiveConnection::NotConfigured
        );
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
        pollster::block_on(Arc::clone(&fixture.core).shutdown());
    }

    #[test]
    fn following_a_survey_of_the_corpus_never_goes_back_and_reaches_the_last_status() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let corpus = fixture.create_directory("corpus");
        copy_tree(Path::new(CORPUS), Path::new(&corpus));
        let collector = fixture.core.collector().unwrap();
        pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();
        for folder in ["Downloads", "Desktop", "Documents/Scans", "Cloud Storage"] {
            pollster::block_on(Arc::clone(&collector).enroll_folder(format!("{corpus}/{folder}"))).unwrap();
        }

        let followed = follow_collector_until(&collector, |status| {
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
        pollster::block_on(Arc::clone(&fixture.core).shutdown());
    }

    #[test]
    fn two_followers_each_read_a_change_and_then_wait_for_the_next() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let collector = fixture.core.collector().unwrap();
        let first = pollster::block_on(Arc::clone(&collector).status_after(None)).unwrap();
        let waiting = [
            read_collector_after(&collector, Some(first.revision)),
            read_collector_after(&collector, Some(first.revision)),
        ];
        let answers_before_the_change = waiting.each_ref().map(|waiting| waiting.recv_timeout(WAITING_INTERVAL));

        pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();
        let answers = waiting.map(|waiting| waiting.recv_timeout(ANSWER_LIMIT).unwrap().unwrap());
        let library_status = pollster::block_on(fixture.core.library().status_after(None)).unwrap();
        let resting = answers
            .each_ref()
            .map(|answer| read_collector_after(&collector, Some(answer.revision)));
        let answers_without_a_change = resting.map(|resting| resting.recv_timeout(WAITING_INTERVAL));
        pollster::block_on(Arc::clone(&fixture.core).shutdown());

        let timed_out = || Err(RecvTimeoutError::Timeout);
        assert_eq!(answers_before_the_change, [timed_out(), timed_out()]);
        assert_eq!(answers.len(), 2);
        assert!(matches!(
            library_status.archive,
            ArchiveConnection::Configured {
                condition: ConnectionCondition::Connected,
                permission: ArchivePermission::ReadAndCollect,
                ..
            }
        ));
        assert_eq!(answers_without_a_change, [timed_out(), timed_out()]);
    }

    #[test]
    fn shutdown_ends_every_read() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let collector = fixture.core.collector().unwrap();
        let library = fixture.core.library();
        let first_collector = pollster::block_on(Arc::clone(&collector).status_after(None)).unwrap();
        let first_library = pollster::block_on(Arc::clone(&library).status_after(None)).unwrap();
        let waiting_collector = [
            read_collector_after(&collector, Some(first_collector.revision)),
            read_collector_after(&collector, Some(first_collector.revision)),
        ];
        let waiting_library = [
            read_library_after(&library, Some(first_library.revision)),
            read_library_after(&library, Some(first_library.revision)),
        ];
        let collector_before_shutdown = waiting_collector[0].recv_timeout(WAITING_INTERVAL);
        let library_before_shutdown = waiting_library[0].recv_timeout(WAITING_INTERVAL);

        pollster::block_on(Arc::clone(&fixture.core).shutdown());
        let collector_answers = waiting_collector.map(|waiting| waiting.recv_timeout(ANSWER_LIMIT).unwrap());
        let library_answers = waiting_library.map(|waiting| waiting.recv_timeout(ANSWER_LIMIT).unwrap());
        let later_collector = pollster::block_on(Arc::clone(&collector).status_after(Some(first_collector.revision)));
        let current_collector = pollster::block_on(Arc::clone(&collector).status_after(None));
        let later_library = pollster::block_on(Arc::clone(&library).status_after(Some(first_library.revision)));
        let current_library = pollster::block_on(Arc::clone(&library).status_after(None));
        // Second shutdown is idempotent.
        pollster::block_on(Arc::clone(&fixture.core).shutdown());

        assert_eq!(collector_before_shutdown, Err(RecvTimeoutError::Timeout));
        assert_eq!(library_before_shutdown, Err(RecvTimeoutError::Timeout));
        assert_eq!(
            collector_answers,
            [
                Err(crate::ApplicationFault::Stopped),
                Err(crate::ApplicationFault::Stopped)
            ]
        );
        assert_eq!(
            library_answers,
            [
                Err(crate::ApplicationFault::Stopped),
                Err(crate::ApplicationFault::Stopped)
            ]
        );
        assert_eq!(later_collector, Err(crate::ApplicationFault::Stopped));
        assert_eq!(current_collector, Err(crate::ApplicationFault::Stopped));
        assert_eq!(later_library, Err(crate::ApplicationFault::Stopped));
        assert_eq!(current_library, Err(crate::ApplicationFault::Stopped));
    }

    #[test]
    fn a_library_follower_sees_the_fill_complete_and_reads_listings_details_and_originals() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Absent);
        assert!(fixture.core.collector().is_none());

        let sender = CoreSenderIdentifier::parse("20000000-0000-4000-8000-000000000001").unwrap();
        fixture.archive.put_sender(SenderRecord {
            identifier: sender.clone(),
            name: "Stadtwerke Talbrück GmbH".to_owned(),
        });
        let category = CoreCategoryIdentifier::parse("30000000-0000-4000-8000-000000000001").unwrap();
        fixture.archive.put_category(CategoryRecord {
            identifier: category.clone(),
            name: "Invoice".to_owned(),
            expected_fields: vec!["amount".to_owned(), "currency".to_owned()],
        });

        let pdf_bytes = b"%PDF-1.7\nElectricity invoice\n%%EOF";
        let pdf_digest = ContentDigest::from_bytes(Sha256::digest(pdf_bytes).into());
        let png_bytes = b"\x89PNG\r\n\x1a\nfake-thumbnail";
        let first_doc = CoreDocumentIdentifier::parse("50000000-0000-4000-8000-000000000001").unwrap();
        let second_doc = CoreDocumentIdentifier::parse("50000000-0000-4000-8000-000000000002").unwrap();

        let mut fields = BTreeMap::new();
        fields.insert(
            "amount".to_owned(),
            ExtractedField {
                value: CoreFieldValue::Number(72.09),
                confidence: Some(0.94),
            },
        );
        fields.insert(
            "currency".to_owned(),
            ExtractedField {
                value: CoreFieldValue::Text("EUR".to_owned()),
                confidence: Some(0.99),
            },
        );
        fixture.archive.put_document(DocumentRecord {
            identifier: first_doc.clone(),
            condition: CoreDocumentCondition::Archived,
            title: Some("Haftpflichtversicherung Rechnung".to_owned()),
            document_date: CoreCalendarDate::parse("2026-09-22"),
            sender: Some(sender),
            category: Some(category),
            person: PersonAssignment::Household,
            summary: Some("Electricity statement".to_owned()),
            media_type: "application/pdf".to_owned(),
            byte_size: u64::try_from(pdf_bytes.len()).unwrap(),
            page_count: Some(1),
            original: Some(pdf_digest),
            arrived_at: Timestamp(1_790_000_000_000),
            tags: BTreeSet::new(),
            fields,
        });
        fixture
            .archive
            .put_text(&first_doc, "Ihr Stromzählerstand beträgt 48213 kWh.");
        fixture.archive.put_original(&first_doc, pdf_bytes);
        fixture.archive.put_thumbnail(&first_doc, png_bytes);

        let library = fixture.core.library();
        pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();

        let statuses = follow_library_until(&library, |status| {
            matches!(status.copy, LibraryCopy::Complete { .. }) && status.counts.documents_awaiting_text == 0
        });
        let revisions: Vec<u64> = statuses.iter().map(|status| status.revision).collect();
        assert!(
            revisions.is_sorted_by(|earlier, later| earlier < later),
            "{revisions:?}"
        );
        let last = statuses.last().unwrap();
        assert_eq!(last.counts.documents, 1);

        let request = ListingRequest::Browse {
            scope: LibraryScope::AllDocuments,
            order: ListingOrder::DocumentDate,
        };
        let first_answer = pollster::block_on(Arc::clone(&library).list_documents(request.clone(), None)).unwrap();
        assert!(first_answer.difference.is_none());
        assert_eq!(first_answer.listing.document_count(), 1);
        assert_eq!(first_answer.listing.row_count(), 2);
        let pub_first_id = DocumentIdentifier {
            value: first_doc.as_str().to_owned(),
        };
        assert_eq!(first_answer.listing.position_of(pub_first_id.clone()), Some(1));
        assert_eq!(
            first_answer.listing.rows(0, 10),
            vec![
                ListingRow::Heading {
                    heading: ListingHeading::Period { year: 2026, month: 9 },
                },
                ListingRow::Document {
                    row: DocumentRow {
                        document: pub_first_id.clone(),
                        condition: DocumentCondition::Archived,
                        title: Some("Haftpflichtversicherung Rechnung".to_owned()),
                        sender_name: Some("Stadtwerke Talbrück GmbH".to_owned()),
                        document_date: Some(CalendarDate {
                            year: 2026,
                            month: 9,
                            day: 22,
                        }),
                        arrived_at: SystemTime::UNIX_EPOCH + Duration::from_millis(1_790_000_000_000),
                        amount: Some(Amount {
                            decimal_text: "72.09".to_owned(),
                            currency: Some("EUR".to_owned()),
                        }),
                        passage: Some(RowPassage::Summary {
                            text: "Electricity statement".to_owned(),
                        }),
                        content_known: true,
                    },
                },
            ]
        );

        let facets = pollster::block_on(Arc::clone(&library).facets()).unwrap();
        assert_eq!(facets.documents, 1);
        assert_eq!(facets.household_documents, 1);
        assert_eq!(facets.categories.len(), 1);

        let detail = pollster::block_on(Arc::clone(&library).document(pub_first_id.clone()))
            .unwrap()
            .unwrap();
        assert_eq!(detail.original_kind, OriginalKind::PortableDocument);
        assert_eq!(
            detail.archive_page,
            "https://archive.example.org/documents/50000000-0000-4000-8000-000000000001"
        );
        assert_eq!(
            pollster::block_on(Arc::clone(&library).extracted_text(pub_first_id.clone())).unwrap(),
            "Ihr Stromzählerstand beträgt 48213 kWh."
        );
        let original = pollster::block_on(Arc::clone(&library).original(pub_first_id.clone())).unwrap();
        assert_eq!(std::fs::read(&original.path).unwrap(), pdf_bytes);
        let thumbnail = pollster::block_on(Arc::clone(&library).thumbnail(pub_first_id))
            .unwrap()
            .unwrap();
        assert_eq!(std::fs::read(&thumbnail.path).unwrap(), png_bytes);

        // A second document added later produces a listing difference against the preceding listing.
        fixture.archive.put_document(DocumentRecord {
            identifier: second_doc.clone(),
            condition: CoreDocumentCondition::Archived,
            title: Some("Follow-up".to_owned()),
            document_date: CoreCalendarDate::parse("2026-09-25"),
            sender: None,
            category: None,
            person: PersonAssignment::Household,
            summary: None,
            media_type: "application/pdf".to_owned(),
            byte_size: 100,
            page_count: Some(1),
            original: None,
            arrived_at: Timestamp(1_790_000_010_000),
            tags: BTreeSet::new(),
            fields: BTreeMap::new(),
        });
        library.synchronize();
        follow_library_until(&library, |status| status.counts.documents == 2);

        let second_answer =
            pollster::block_on(Arc::clone(&library).list_documents(request, Some(first_answer.listing))).unwrap();
        assert_eq!(second_answer.listing.document_count(), 2);
        let difference = second_answer.difference.unwrap();
        assert_eq!(difference.removed_positions, Vec::<u32>::new());
        assert_eq!(difference.inserted_positions, vec![1]);
        pollster::block_on(Arc::clone(&fixture.core).shutdown());
    }

    #[test]
    fn a_collector_upload_appears_in_a_listing_of_the_library() {
        let fixture = ApplicationFixture::start(CollectionPlacement::Collector);
        let root = fixture.create_directory("Inbox");
        let pdf_bytes = b"%PDF-1.7 uploaded via collector";
        std::fs::write(format!("{root}/letter.pdf"), pdf_bytes).unwrap();

        pollster::block_on(Arc::clone(&fixture.core).connect_archive(ARCHIVE_ADDRESS.to_owned(), TOKEN.to_owned()))
            .unwrap();
        let collector = fixture.core.collector().unwrap();
        let library = fixture.core.library();

        let folder = pollster::block_on(Arc::clone(&collector).enroll_folder(root)).unwrap();
        follow_collector_until(&collector, |status| {
            status.folders.iter().any(|listed| {
                listed.folder == folder && matches!(listed.admission, FolderAdmission::AwaitingDecision { .. })
            })
        });
        pollster::block_on(Arc::clone(&collector).decide_backlog(folder.identifier)).unwrap();

        follow_library_until(&library, |status| status.counts.documents == 1);

        let listing = pollster::block_on(Arc::clone(&library).list_documents(
            ListingRequest::Browse {
                scope: LibraryScope::AllDocuments,
                order: ListingOrder::DocumentDate,
            },
            None,
        ))
        .unwrap()
        .listing;
        assert_eq!(listing.document_count(), 1);
        let rows = listing.rows(0, 10);
        let uploaded_id = rows
            .iter()
            .find_map(|row| match row {
                ListingRow::Document { row } => Some(row.document.clone()),
                ListingRow::Heading { .. } => None,
            })
            .expect("the uploaded document is listed");
        let original = pollster::block_on(Arc::clone(&library).original(uploaded_id)).unwrap();
        assert_eq!(std::fs::read(&original.path).unwrap(), pdf_bytes);
        pollster::block_on(Arc::clone(&fixture.core).shutdown());
    }
}
