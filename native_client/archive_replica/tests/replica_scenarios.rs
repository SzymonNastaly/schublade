//! The copy against the scripted archive, which keeps records and a journal by the server's rules.
//! The first scenario drives the store and the reader directly, page by page, so that a script
//! can stop between any two pages. The second runs the whole `Replica`.

mod scenario_support;

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Debug;
use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveCondition, ArchiveToken, DocumentIdentifier, DownloadFailure,
    FixedCredentialStore, ManualClock, PermissionLevel, Timestamp,
};
use archive_replica::replica_records::{
    ArchiveRecords, CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord,
    ExtractedField, FailureReason, FieldValue, IngestionStage, JournalCursor, JournalPage, MemberIdentifier,
    MemberRecord, PersonAssignment, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use archive_replica::{
    ArchiveReader, LibraryScope, ListingHeading, ListingRequest, ListingRow, MirroredArchive, OriginalAnswer,
    PageAnswer, Replica, ReplicaEvent, ReplicaFault, ReplicaSettings, ReplicaStatus, ReplicaStore, RowPassage,
    SuspensionReason, SynchronizationInput, SynchronizationState, SynchronizationTiming, ThumbnailAnswer,
    exchange_page,
};
use scenario_support::{ARCHIVE_ORIGIN, Generator, START, TOKEN, attach, identifier, start_replica, status_after};
use scripted_archive::{ArchiveScope, ScriptedArchive};

impl Generator {
    fn subset<Item: Clone + Ord>(&mut self, items: &[Item]) -> BTreeSet<Item> {
        items.iter().filter(|_| self.chance(40)).cloned().collect()
    }
}

/// What a seeded script does to an archive, and what it knows of it.
struct Script {
    generator: Generator,
    archive: Arc<ScriptedArchive>,
    members: Vec<MemberIdentifier>,
    senders: Vec<SenderIdentifier>,
    categories: Vec<CategoryIdentifier>,
    tags: Vec<TagIdentifier>,
    documents: Vec<DocumentIdentifier>,
    scope: ArchiveScope,
    records_created: usize,
}

impl Script {
    fn seeded(seed: u64) -> Script {
        let mut script = Script {
            generator: Generator(seed),
            archive: Arc::new(ScriptedArchive::with_page_entries(3)),
            members: Vec::new(),
            senders: Vec::new(),
            categories: Vec::new(),
            tags: Vec::new(),
            documents: Vec::new(),
            scope: ArchiveScope::default(),
            records_created: 0,
        };
        for number in 0..2 {
            let member = MemberIdentifier::parse(&identifier(1, number)).unwrap();
            script.archive.put_member(MemberRecord {
                identifier: member.clone(),
                display_name: format!("Member {number}"),
            });
            script.members.push(member);
        }
        for number in 0..3 {
            let sender = SenderIdentifier::parse(&identifier(2, number)).unwrap();
            script.rename_sender(&sender);
            script.senders.push(sender);
            let category = CategoryIdentifier::parse(&identifier(3, number)).unwrap();
            script.archive.put_category(CategoryRecord {
                identifier: category.clone(),
                name: format!("Category {number}"),
                expected_fields: vec!["amount".to_owned(), "due_date".to_owned()],
            });
            script.categories.push(category);
            script.create_tag();
        }
        script
    }

    fn next_number(&mut self) -> usize {
        self.records_created += 1;
        self.records_created
    }

    fn rename_sender(&mut self, sender: &SenderIdentifier) {
        let name = format!("Sender named {}", self.next_number());
        self.archive.put_sender(SenderRecord {
            identifier: sender.clone(),
            name,
        });
    }

    fn create_tag(&mut self) {
        let number = self.next_number();
        let tag = TagIdentifier::parse(&identifier(4, number)).unwrap();
        self.archive.put_tag(TagRecord {
            identifier: tag.clone(),
            name: format!("tag {number}"),
            color_hex: self.generator.chance(50).then(|| "#2f6fde".to_owned()),
        });
        self.tags.push(tag);
    }

    /// A state a document can have in the archive: in ingestion, failed, or archived with what
    /// classification assigns.
    fn document_state(&mut self, identifier: DocumentIdentifier) -> DocumentRecord {
        let number = self.next_number();
        let generator = &mut self.generator;
        let condition = match generator.below(10) {
            0 => DocumentCondition::Arriving(IngestionStage::Processing),
            1 => DocumentCondition::Arriving(IngestionStage::Classifying),
            2 => DocumentCondition::Failed(FailureReason::UnreadablePage),
            _ => DocumentCondition::Archived,
        };
        let archived = condition == DocumentCondition::Archived;
        let mut fields = BTreeMap::new();
        if archived && generator.chance(60) {
            let confidence = generator.chance(50).then_some(0.5);
            let amount = FieldValue::Number(generator.below(100_000) as f64 / 100.0);
            fields.insert(
                "amount".to_owned(),
                ExtractedField {
                    value: amount,
                    confidence,
                },
            );
            let due = FieldValue::Date(CalendarDate::parse("2026-10-06").unwrap());
            fields.insert(
                "due_date".to_owned(),
                ExtractedField {
                    value: due,
                    confidence: None,
                },
            );
            let currency = FieldValue::Text("EUR".to_owned());
            fields.insert(
                "currency".to_owned(),
                ExtractedField {
                    value: currency,
                    confidence,
                },
            );
        }
        DocumentRecord {
            identifier,
            title: archived.then(|| format!("Document as written {number}")),
            document_date: generator.chance(70).then(|| CalendarDate::parse("2026-09-22").unwrap()),
            sender: generator
                .chance(70)
                .then(|| generator.pick(&self.senders).cloned())
                .flatten(),
            category: generator
                .chance(70)
                .then(|| generator.pick(&self.categories).cloned())
                .flatten(),
            person: match (archived, generator.pick(&self.members)) {
                (true, Some(member)) if generator.chance(40) => PersonAssignment::Member(member.clone()),
                (true, _) => PersonAssignment::Household,
                (false, _) => PersonAssignment::Unassigned,
            },
            summary: archived.then(|| format!("Summary {number}")),
            media_type: "application/pdf".to_owned(),
            byte_size: 184_233,
            page_count: generator.chance(80).then_some(2),
            original: None,
            arrived_at: START,
            tags: generator.subset(&self.tags),
            fields,
            condition,
        }
    }

    /// One change of the archive: a document created, revised, given other tags, or deleted, a
    /// sender renamed, or two tags merged.
    fn change_archive(&mut self) {
        let chosen = self.generator.pick(&self.documents).cloned();
        match (self.generator.below(10), chosen) {
            (0..=2, _) | (_, None) => {
                let number = self.next_number();
                let created = DocumentIdentifier::parse(&identifier(5, number)).unwrap();
                let document = self.document_state(created.clone());
                self.archive.put_document(document);
                self.documents.push(created);
            }
            (3..=4, Some(document)) => {
                let revised = self.document_state(document);
                self.archive.put_document(revised);
            }
            (5, Some(document)) => {
                let mut retagged = self
                    .archive
                    .records()
                    .documents
                    .into_iter()
                    .find(|held| held.identifier == document)
                    .unwrap();
                retagged.tags = self.generator.subset(&self.tags);
                self.archive.put_document(retagged);
            }
            (6..=7, Some(document)) => {
                self.archive.delete_document(&document);
                self.documents.retain(|held| *held != document);
            }
            (8, Some(_)) => {
                let sender = self.generator.pick(&self.senders).cloned().unwrap();
                self.rename_sender(&sender);
            }
            (_, Some(_)) => self.merge_tags(),
        }
    }

    /// Merges two tags, and creates one when few are left. A tag the scope excludes is never
    /// merged away, because the archive then refuses the token, which is another scenario.
    fn merge_tags(&mut self) {
        let excluded = self.scope.denied_tags.clone().unwrap_or_default();
        let mergeable: Vec<TagIdentifier> = self
            .tags
            .iter()
            .filter(|tag| !excluded.contains(tag))
            .cloned()
            .collect();
        match (self.generator.pick(&mergeable).cloned(), self.tags.len()) {
            (Some(merged), 3..) => {
                let others: Vec<TagIdentifier> = self.tags.iter().filter(|tag| **tag != merged).cloned().collect();
                let into = self.generator.pick(&others).cloned().unwrap();
                self.archive.merge_tags(&merged, &into);
                self.tags.retain(|tag| *tag != merged);
            }
            _ => self.create_tag(),
        }
    }

    /// Gives the token another scope: none, or one of the four lists.
    fn restrict_scope(&mut self) {
        let generator = &mut self.generator;
        self.scope = match generator.below(5) {
            0 => ArchiveScope::default(),
            1 => ArchiveScope {
                allowed_categories: Some(generator.subset(&self.categories)),
                ..ArchiveScope::default()
            },
            2 => ArchiveScope {
                allowed_senders: Some(generator.subset(&self.senders)),
                ..ArchiveScope::default()
            },
            3 => ArchiveScope {
                allowed_tags: Some(generator.subset(&self.tags)),
                ..ArchiveScope::default()
            },
            _ => ArchiveScope {
                denied_tags: Some(generator.subset(&self.tags)),
                ..ArchiveScope::default()
            },
        };
        self.archive.restrict_scope(self.scope.clone());
    }
}

/// The archive as a reader that keeps the page it answered last, so a scenario can apply a page
/// a second time.
struct RecordingReader {
    archive: Arc<ScriptedArchive>,
    last_page: Mutex<Option<(Option<JournalCursor>, JournalPage)>>,
}

impl ArchiveReader for RecordingReader {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        self.archive.read_authorization()
    }

    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        let answer = self.archive.read_changes(after)?;
        if let PageAnswer::Page(page) = &answer {
            *self.last_page.lock().unwrap() = Some((after.cloned(), page.clone()));
        }
        Ok(answer)
    }

    fn read_text(&self, document: &DocumentIdentifier) -> Result<Option<String>, ArchiveCondition> {
        self.archive.read_text(document)
    }

    fn download_original(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<OriginalAnswer, DownloadFailure> {
        self.archive.download_original(document, destination)
    }

    fn download_thumbnail(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<ThumbnailAnswer, DownloadFailure> {
        self.archive.download_thumbnail(document, destination)
    }
}

/// A copy in a temporary directory, synchronized one page at a time.
struct CopyUnderTest {
    seed: u64,
    directory: tempfile::TempDir,
    store: ReplicaStore,
    reader: RecordingReader,
    /// A page of the current fill, kept to be applied again later. A copy that starts over drops
    /// it, as the coordinator, which requests and applies a page in one step, holds no page then.
    retained_page: Option<(Option<JournalCursor>, JournalPage)>,
}

impl CopyUnderTest {
    fn of(archive: &Arc<ScriptedArchive>, seed: u64) -> CopyUnderTest {
        let directory = tempfile::tempdir().unwrap();
        let store = ReplicaStore::open(&directory.path().join("replica.sqlite")).unwrap();
        let mut copy = CopyUnderTest {
            seed,
            directory,
            store,
            reader: RecordingReader {
                archive: Arc::clone(archive),
                last_page: Mutex::new(None),
            },
            retained_page: None,
        };
        copy.connect();
        copy
    }

    fn failed<Failure: Debug>(&self, failure: Failure) -> ! {
        panic!("seed {}: {failure:?}", self.seed)
    }

    /// The connection flow of an application: read what the token may do, then attach.
    fn connect(&mut self) {
        let authorization = self.reader.read_authorization().unwrap();
        let fingerprint = ArchiveToken::new(TOKEN.to_owned()).fingerprint();
        if let Err(error) = self.store.attach(ARCHIVE_ORIGIN, &authorization, &fingerprint) {
            self.failed(error);
        }
        self.retained_page = None;
    }

    /// Requests and applies one page, and answers whether it reached the journal's end.
    fn request_page(&mut self) -> bool {
        match exchange_page(&mut self.store, &self.reader, START) {
            Ok(Some(SynchronizationInput::PageApplied { complete, .. })) => complete,
            Ok(Some(SynchronizationInput::JournalReplaced)) => {
                self.retained_page = None;
                false
            }
            other => self.failed(other),
        }
    }

    fn request_pages(&mut self, count: usize, retain_last: bool) {
        for _ in 0..count {
            self.request_page();
        }
        if retain_last {
            self.retained_page = self.reader.last_page.lock().unwrap().clone();
        }
    }

    fn request_pages_until_complete(&mut self) {
        for _ in 0..1_000 {
            if self.request_page() {
                return;
            }
        }
        self.failed("the copy did not reach the journal's end within 1000 pages");
    }

    /// A page that arrives a second time, possibly long after later pages were applied. Unless
    /// the copy still stands where the page was requested, the page must change nothing.
    fn apply_retained_page_again(&mut self) {
        let Some((requested_after, page)) = &self.retained_page else {
            return;
        };
        let state = |store: &ReplicaStore| (store.cursor().unwrap(), store.records().unwrap());
        let (cursor_before, records_before) = state(&self.store);
        if let Err(error) = self.store.apply_page(requested_after.as_ref(), page, START) {
            self.failed(error);
        }
        let (cursor_after, records_after) = state(&self.store);
        if cursor_before != *requested_after && (&cursor_after, &records_after) != (&cursor_before, &records_before) {
            let brought_back: Vec<&str> = records_after
                .documents
                .iter()
                .filter(|document| !records_before.documents.contains(document))
                .map(|document| document.identifier.as_str())
                .collect();
            self.failed(format!(
                "a page requested after {requested_after:?} changed a copy that stood at {cursor_before:?}: \
                 the copy went back to {cursor_after:?} and to the former states of the documents {brought_back:?}"
            ));
        }
    }

    /// The process ends after it wrote a page and before it committed, and starts again.
    fn restart_discarding_the_open_transaction(&mut self) {
        let path = self.directory.path().join("replica.sqlite");
        let requested_after = self.store.cursor().unwrap();
        if let Ok(PageAnswer::Page(page)) = self.reader.read_changes(requested_after.as_ref()) {
            drop(self.store.stage_page(requested_after.as_ref(), &page, START).unwrap());
        }
        self.store = ReplicaStore::open(&path).unwrap();
        self.retained_page = None;
    }
}

/// What keeps the copy from being the archive as the token sees it. The documents must be the
/// admitted ones exactly. A restricted token keeps a sender, category, tag, or member whose last
/// admitted document left, so those must cover what the admitted documents refer to and hold
/// nothing the archive does not hold in the same state.
fn differences(held: &ArchiveRecords, admitted: &ArchiveRecords, archive: &ArchiveRecords) -> Vec<String> {
    fn compare<Record: PartialEq + Debug>(
        found: &mut Vec<String>,
        held: &[Record],
        admitted: &[Record],
        archive: &[Record],
    ) {
        found.extend(
            admitted
                .iter()
                .filter(|record| !held.contains(record))
                .map(|record| format!("the copy lacks {record:?}")),
        );
        found.extend(
            held.iter()
                .filter(|record| !archive.contains(record))
                .map(|record| format!("the copy holds {record:?}, which the archive does not hold so")),
        );
    }
    let mut found = Vec::new();
    compare(&mut found, &held.documents, &admitted.documents, &admitted.documents);
    compare(&mut found, &held.members, &admitted.members, &archive.members);
    compare(&mut found, &held.senders, &admitted.senders, &archive.senders);
    compare(&mut found, &held.categories, &admitted.categories, &archive.categories);
    compare(&mut found, &held.tags, &admitted.tags, &archive.tags);
    for document in &held.documents {
        let sender_held = document
            .sender
            .as_ref()
            .is_none_or(|sender| held.senders.iter().any(|held| held.identifier == *sender));
        let category_held = document
            .category
            .as_ref()
            .is_none_or(|category| held.categories.iter().any(|held| held.identifier == *category));
        let member_held = match &document.person {
            PersonAssignment::Member(member) => held.members.iter().any(|held| held.identifier == *member),
            PersonAssignment::Household | PersonAssignment::Unassigned => true,
        };
        let tags_held = document
            .tags
            .iter()
            .all(|tag| held.tags.iter().any(|held| held.identifier == *tag));
        if !(sender_held && category_held && member_held && tags_held) {
            found.push(format!("a reference of {document:?} does not resolve in the copy"));
        }
    }
    found
}

/// One seeded script: changes of the archive, with a copy that synchronizes at arbitrary points,
/// applies a page twice, restarts inside a transaction, and meets a replaced journal and another
/// scope. After a last synchronization the copy must be the archive as the token sees it.
fn follow_seeded_script(seed: u64) {
    let mut script = Script::seeded(seed);
    let mut copy = CopyUnderTest::of(&script.archive, seed);
    let mut token_replaced = false;
    for _ in 0..SCRIPT_STEPS {
        match script.generator.below(1_000) {
            0..550 => script.change_archive(),
            550..830 => {
                if std::mem::take(&mut token_replaced) {
                    copy.connect();
                }
                let (count, retain_last) = (1 + script.generator.below(3), script.generator.chance(25));
                copy.request_pages(count, retain_last);
            }
            830..920 => copy.apply_retained_page_again(),
            920..970 => copy.restart_discarding_the_open_transaction(),
            970..982 => script.archive.replace_journal(),
            _ => {
                script.restrict_scope();
                token_replaced = true;
            }
        }
    }
    if token_replaced {
        copy.connect();
    }
    copy.request_pages_until_complete();

    let found = differences(
        &copy.store.records().unwrap(),
        &script.archive.admitted_records(),
        &script.archive.records(),
    );
    assert!(found.is_empty(), "seed {seed}: {found:#?}");
}

const SCRIPT_SEEDS: u64 = 60;
const SCRIPT_STEPS: usize = 60;

#[test]
fn a_copy_equals_the_archive_after_any_interleaving() {
    (0..SCRIPT_SEEDS).for_each(follow_seeded_script);
}

#[test]
fn a_follower_sees_the_fill_complete_with_every_text_and_never_an_older_revision() {
    let archive = Arc::new(ScriptedArchive::with_page_entries(2));
    let sender = SenderIdentifier::parse(&identifier(2, 1)).unwrap();
    let tag = TagIdentifier::parse(&identifier(4, 1)).unwrap();
    archive.put_sender(SenderRecord {
        identifier: sender.clone(),
        name: "Stadtwerke Talbrück GmbH".to_owned(),
    });
    archive.put_tag(TagRecord {
        identifier: tag.clone(),
        name: "strom".to_owned(),
        color_hex: None,
    });
    for number in 1..=5 {
        let document = DocumentIdentifier::parse(&identifier(5, number)).unwrap();
        archive.put_document(DocumentRecord {
            identifier: document.clone(),
            condition: DocumentCondition::Archived,
            title: Some(format!("Electricity Statement {number}")),
            document_date: CalendarDate::parse("2026-09-22"),
            sender: Some(sender.clone()),
            category: None,
            person: PersonAssignment::Household,
            summary: None,
            media_type: "application/pdf".to_owned(),
            byte_size: 184_233,
            page_count: Some(1),
            original: None,
            arrived_at: START,
            tags: BTreeSet::from([tag.clone()]),
            fields: BTreeMap::new(),
        });
        archive.put_text(
            &document,
            &format!("# Abrechnung\n\nIhr Zählerstand beträgt 4821{number} kWh."),
        );
    }
    let directory = tempfile::tempdir().unwrap();
    let (replica, events) = start_replica(&archive, directory.path(), None);

    let mut followed = vec![replica.status()];
    attach(&replica, &archive);
    while !matches!(
        followed.last().unwrap(),
        ReplicaStatus {
            synchronization: SynchronizationState::Following { .. },
            documents_awaiting_text: 0,
            ..
        }
    ) {
        let held_revision = followed.last().unwrap().revision;
        followed.push(status_after(&replica, &events, held_revision));
    }
    // The texts arrived after their documents, and the search reads nothing but the copy.
    let found = replica
        .list_documents(
            &ListingRequest::Search {
                scope: LibraryScope::AllDocuments,
                text: "48213".to_owned(),
            },
            None,
        )
        .unwrap();
    replica.shutdown();

    assert_eq!(
        followed.first(),
        Some(&ReplicaStatus {
            revision: 0,
            content_revision: 0,
            documents: 0,
            documents_awaiting_text: 0,
            archive: None,
            synchronization: SynchronizationState::Disconnected,
            fault: None,
        })
    );
    let revisions: Vec<u64> = followed.iter().map(|status| status.revision).collect();
    assert!(
        revisions.is_sorted_by(|earlier, later| earlier < later),
        "{revisions:?}"
    );
    // Four pages of two journal entries each, the last with one, changed the records, and the
    // texts came in one transaction or several, as the two lanes happened to report.
    let last = followed.last().unwrap();
    assert!((5..=9).contains(&last.content_revision), "{last:?}");
    assert_eq!(
        last,
        &ReplicaStatus {
            revision: last.revision,
            content_revision: last.content_revision,
            documents: 5,
            documents_awaiting_text: 0,
            archive: Some(MirroredArchive {
                origin: ARCHIVE_ORIGIN.to_owned(),
                permission_level: PermissionLevel::Read,
                restricted: false,
                fill_complete: true,
                synchronized_at: Some(START),
            }),
            synchronization: SynchronizationState::Following {
                next_request_at: Timestamp(START.0 + 15 * 60 * 1_000),
            },
            fault: None,
        }
    );
    let found: Vec<(Option<ListingHeading>, Option<RowPassage>)> = found
        .listing
        .rows(0, usize::MAX)
        .iter()
        .map(|row| match row {
            ListingRow::Heading(heading) => (Some(*heading), None),
            ListingRow::Document(row) => (None, row.passage.clone()),
        })
        .collect();
    assert_eq!(
        found,
        [
            (Some(ListingHeading::TextMatched), None),
            (
                None,
                Some(RowPassage::Excerpt("Ihr Zählerstand beträgt 48213 kWh.".to_owned()))
            )
        ]
    );
    assert_eq!(
        ReplicaStore::open(&directory.path().join("replica.sqlite"))
            .unwrap()
            .records()
            .unwrap(),
        archive.records()
    );
}

#[test]
fn open_preserves_a_locked_database_and_coordinator_fault_reaches_status() {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("replica.sqlite");
    let archive = ScriptedArchive::with_page_entries(4);
    archive.put_document(DocumentRecord {
        identifier: DocumentIdentifier::parse(&identifier(5, 1)).unwrap(),
        condition: DocumentCondition::Archived,
        title: Some("Kept across lock".to_owned()),
        document_date: CalendarDate::parse("2026-09-22"),
        sender: None,
        category: None,
        person: PersonAssignment::Household,
        summary: None,
        media_type: "application/pdf".to_owned(),
        byte_size: 128,
        page_count: Some(1),
        original: None,
        arrived_at: START,
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    });
    {
        let mut store = ReplicaStore::open(&path).unwrap();
        let fingerprint = ArchiveToken::new(TOKEN.to_owned()).fingerprint();
        store
            .attach(ARCHIVE_ORIGIN, &archive.read_authorization().unwrap(), &fingerprint)
            .unwrap();
        assert!(matches!(
            exchange_page(&mut store, &archive, START).unwrap(),
            Some(SynchronizationInput::PageApplied { .. })
        ));
    }
    #[cfg(unix)]
    let original_inode = std::fs::metadata(&path).unwrap().ino();

    let blocker = rusqlite::Connection::open(&path).unwrap();
    blocker
        .execute_batch("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE mirror SET fill_complete = fill_complete; COMMIT;")
        .unwrap();
    assert!(ReplicaStore::open(&path).is_err());
    drop(blocker);

    let reopened = ReplicaStore::open(&path).unwrap();
    #[cfg(unix)]
    assert_eq!(std::fs::metadata(&path).unwrap().ino(), original_inode);
    assert_eq!(reopened.records().unwrap().documents.len(), 1);
    drop(reopened);

    // A write failure inside the coordinator publishes fault and Disconnected, then announces.
    let fault_directory = tempfile::tempdir().unwrap();
    let fault_path = fault_directory.path().join("replica.sqlite");
    let scripted = Arc::new(ScriptedArchive::with_page_entries(4));
    let reader: Arc<dyn ArchiveReader> = scripted.clone();
    let (replica, events) = Replica::start(ReplicaSettings {
        database_path: fault_path.clone(),
        representation_directory: fault_directory.path().join("representations"),
        original_byte_limit: None,
        credential_store: Box::new(FixedCredentialStore::new(None)),
        archive_readers: Box::new(move |_, _| Arc::clone(&reader)),
        timing: SynchronizationTiming::default(),
        clock: Arc::new(ManualClock::starting_at(START)),
    })
    .unwrap();
    let blocker = rusqlite::Connection::open(&fault_path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE;").unwrap();
    let authorization = scripted.read_authorization().unwrap();
    let attach_result = replica.attach_archive(
        ArchiveAddress::parse(ARCHIVE_ORIGIN).unwrap(),
        ArchiveToken::new(TOKEN.to_owned()),
        authorization,
    );
    assert!(matches!(attach_result, Err(ReplicaFault::StoreFailed { .. })));
    let ReplicaEvent::StatusChanged { .. } = events
        .recv_timeout(Duration::from_secs(10))
        .expect("fault status change announced");
    let status = replica.status();
    assert!(
        matches!(status.fault, Some(ReplicaFault::StoreFailed { .. })),
        "{status:?}"
    );
    assert_eq!(status.synchronization, SynchronizationState::Disconnected);
    drop(blocker);
    replica.shutdown();
}

struct BlockingFirstConnectionReader {
    archive: Arc<ScriptedArchive>,
    blocked_document: DocumentIdentifier,
    mode: u8,
    entered: Mutex<Option<Sender<()>>>,
    release: Mutex<Option<Receiver<()>>>,
}

impl ArchiveReader for BlockingFirstConnectionReader {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        self.archive.read_authorization()
    }

    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        self.archive.read_changes(after)
    }

    fn read_text(&self, document: &DocumentIdentifier) -> Result<Option<String>, ArchiveCondition> {
        if self.mode == 1 && document == &self.blocked_document {
            if let Some(entered) = self.entered.lock().unwrap().take() {
                let _ = entered.send(());
            }
            if let Some(release) = self.release.lock().unwrap().take() {
                let _ = release.recv();
            }
            return Err(ArchiveCondition::CredentialRefused);
        }
        if self.mode == 2 {
            return Err(ArchiveCondition::CredentialRefused);
        }
        self.archive.read_text(document)
    }

    fn download_original(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<OriginalAnswer, DownloadFailure> {
        self.archive.download_original(document, destination)
    }

    fn download_thumbnail(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<ThumbnailAnswer, DownloadFailure> {
        self.archive.download_thumbnail(document, destination)
    }
}

#[test]
fn a_stale_text_lane_failure_never_stalls_a_new_connection_while_a_current_auth_failure_suspends() {
    let first_archive = Arc::new(ScriptedArchive::with_page_entries(10));
    let doc_1 = DocumentIdentifier::parse(&identifier(5, 1)).unwrap();
    first_archive.put_document(DocumentRecord {
        identifier: doc_1.clone(),
        condition: DocumentCondition::Archived,
        title: Some("First connection".to_owned()),
        document_date: CalendarDate::parse("2026-09-20"),
        sender: None,
        category: None,
        person: PersonAssignment::Household,
        summary: None,
        media_type: "application/pdf".to_owned(),
        byte_size: 100,
        page_count: Some(1),
        original: None,
        arrived_at: START,
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    });
    first_archive.put_text(&doc_1, "First text");

    let second_archive = Arc::new(ScriptedArchive::with_page_entries(10));
    let doc_2 = DocumentIdentifier::parse(&identifier(5, 2)).unwrap();
    second_archive.put_document(DocumentRecord {
        identifier: doc_2.clone(),
        condition: DocumentCondition::Archived,
        title: Some("Second connection".to_owned()),
        document_date: CalendarDate::parse("2026-09-21"),
        sender: None,
        category: None,
        person: PersonAssignment::Household,
        summary: None,
        media_type: "application/pdf".to_owned(),
        byte_size: 100,
        page_count: Some(1),
        original: None,
        arrived_at: START,
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    });
    second_archive.put_text(&doc_2, "Second text");

    let (entered_tx, entered_rx) = channel();
    let (release_tx, release_rx) = channel();
    let entered_tx = Mutex::new(Some(entered_tx));
    let release_rx = Mutex::new(Some(release_rx));
    let calls = Arc::new(AtomicUsize::new(0));
    let first_reader = Arc::new(BlockingFirstConnectionReader {
        archive: Arc::clone(&first_archive),
        blocked_document: doc_1.clone(),
        mode: 1,
        entered: Mutex::new(entered_tx.lock().unwrap().take()),
        release: Mutex::new(release_rx.lock().unwrap().take()),
    });
    let second_reader = Arc::new(BlockingFirstConnectionReader {
        archive: Arc::clone(&second_archive),
        blocked_document: doc_1,
        mode: 0,
        entered: Mutex::new(None),
        release: Mutex::new(None),
    });
    let third_reader = Arc::new(BlockingFirstConnectionReader {
        archive: Arc::clone(&second_archive),
        blocked_document: doc_2.clone(),
        mode: 2,
        entered: Mutex::new(None),
        release: Mutex::new(None),
    });

    let directory = tempfile::tempdir().unwrap();
    let (replica, events) = Replica::start(ReplicaSettings {
        database_path: directory.path().join("replica.sqlite"),
        representation_directory: directory.path().join("representations"),
        original_byte_limit: None,
        credential_store: Box::new(FixedCredentialStore::new(None)),
        archive_readers: Box::new(move |_, _| match calls.fetch_add(1, Ordering::Relaxed) {
            0 => Arc::clone(&first_reader) as Arc<dyn ArchiveReader>,
            1 => Arc::clone(&second_reader) as Arc<dyn ArchiveReader>,
            _ => Arc::clone(&third_reader) as Arc<dyn ArchiveReader>,
        }),
        timing: SynchronizationTiming::default(),
        clock: Arc::new(ManualClock::starting_at(START)),
    })
    .unwrap();

    replica
        .attach_archive(
            ArchiveAddress::parse(ARCHIVE_ORIGIN).unwrap(),
            ArchiveToken::new(TOKEN.to_owned()),
            first_archive.read_authorization().unwrap(),
        )
        .unwrap();
    entered_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("old text lane started reading");

    // Reconnect to a different archive while the old lane is still in flight, then unblock the old lane.
    replica
        .attach_archive(
            ArchiveAddress::parse("https://second.example.org").unwrap(),
            ArchiveToken::new("sch_second_token".to_owned()),
            second_archive.read_authorization().unwrap(),
        )
        .unwrap();
    release_tx.send(()).unwrap();

    let mut revision = replica.status().revision;
    loop {
        let status = status_after(&replica, &events, revision);
        revision = status.revision;
        assert!(
            !matches!(status.synchronization, SynchronizationState::Suspended { .. }),
            "stale failure must not suspend the new connection: {status:?}"
        );
        if matches!(status.synchronization, SynchronizationState::Following { .. })
            && status.documents_awaiting_text == 0
        {
            break;
        }
    }
    assert_eq!(replica.extracted_text(&doc_2), Ok("Second text".to_owned()));

    // A 401 from a current-generation text lane suspends synchronization.
    let doc_3 = DocumentIdentifier::parse(&identifier(5, 3)).unwrap();
    second_archive.put_document(DocumentRecord {
        identifier: doc_3.clone(),
        condition: DocumentCondition::Archived,
        title: Some("Triggers 401".to_owned()),
        document_date: CalendarDate::parse("2026-09-22"),
        sender: None,
        category: None,
        person: PersonAssignment::Household,
        summary: None,
        media_type: "application/pdf".to_owned(),
        byte_size: 100,
        page_count: Some(1),
        original: None,
        arrived_at: START,
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    });
    second_archive.put_text(&doc_3, "Third text");
    // Reconnect with the same archive origin/journal to use the third reader whose text call returns 401.
    let mut second_auth = second_archive.read_authorization().unwrap();
    second_auth
        .journal_identifier
        .clone_from(&second_archive.read_authorization().unwrap().journal_identifier);
    replica
        .attach_archive(
            ArchiveAddress::parse("https://second.example.org").unwrap(),
            ArchiveToken::new("sch_third_token".to_owned()),
            second_auth,
        )
        .unwrap();
    loop {
        let status = status_after(&replica, &events, revision);
        revision = status.revision;
        if status.synchronization
            == (SynchronizationState::Suspended {
                reason: SuspensionReason::CredentialRefused,
            })
        {
            break;
        }
    }
    replica.shutdown();
}

struct RepeatingCursorReader {
    cursor: JournalCursor,
}

impl ArchiveReader for RepeatingCursorReader {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        Ok(ArchiveAuthorization {
            journal_identifier: "0".repeat(32),
            token_description: "Test".to_owned(),
            permission_level: PermissionLevel::Read,
            restricted: false,
            scope_digest: archive_access::UNRESTRICTED_SCOPE_DIGEST.to_owned(),
        })
    }

    fn read_changes(&self, _after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        Ok(PageAnswer::Page(JournalPage {
            cursor: self.cursor.clone(),
            complete: false,
            remaining_entries: 5,
            members: Vec::new(),
            senders: Vec::new(),
            categories: Vec::new(),
            tags: Vec::new(),
            documents: Vec::new(),
            removed: Vec::new(),
        }))
    }

    fn read_text(&self, _document: &DocumentIdentifier) -> Result<Option<String>, ArchiveCondition> {
        Ok(None)
    }

    fn download_original(
        &self,
        _document: &DocumentIdentifier,
        _destination: &mut dyn Write,
    ) -> Result<OriginalAnswer, DownloadFailure> {
        Ok(OriginalAnswer::DocumentAbsent)
    }

    fn download_thumbnail(
        &self,
        _document: &DocumentIdentifier,
        _destination: &mut dyn Write,
    ) -> Result<ThumbnailAnswer, DownloadFailure> {
        Ok(ThumbnailAnswer::Absent)
    }
}

#[test]
fn non_advancing_incomplete_page_is_a_protocol_violation() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = ReplicaStore::open(&directory.path().join("replica.sqlite")).unwrap();
    let reader = RepeatingCursorReader {
        cursor: JournalCursor::parse("00000000000000000000000000000000.1").unwrap(),
    };
    store
        .attach(
            ARCHIVE_ORIGIN,
            &reader.read_authorization().unwrap(),
            &ArchiveToken::new(TOKEN.to_owned()).fingerprint(),
        )
        .unwrap();

    assert!(matches!(
        exchange_page(&mut store, &reader, START).unwrap(),
        Some(SynchronizationInput::PageApplied { complete: false, .. })
    ));
    assert!(matches!(
        exchange_page(&mut store, &reader, START).unwrap(),
        Some(SynchronizationInput::RequestFailed(
            ArchiveCondition::ProtocolViolation { .. }
        ))
    ));
}
