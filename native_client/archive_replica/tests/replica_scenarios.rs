//! The copy against the scripted archive, which keeps records and a journal by the server's rules.
//! The first scenario drives the store and the reader directly, page by page, so that a script
//! can stop between any two pages. The second runs the whole `Replica`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Debug;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveCondition, ArchiveToken, DocumentIdentifier, FixedCredentialStore,
    ManualClock, PermissionLevel, Timestamp,
};
use archive_replica::replica_records::{
    ArchiveRecords, CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord,
    ExtractedField, FailureReason, FieldValue, IngestionStage, JournalCursor, JournalPage, MemberIdentifier,
    MemberRecord, PersonAssignment, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use archive_replica::{
    ArchiveReader, MirroredArchive, PageAnswer, Replica, ReplicaEvent, ReplicaSettings, ReplicaStatus, ReplicaStore,
    SynchronizationInput, SynchronizationState, SynchronizationTiming, exchange_page,
};
use scripted_archive::{ArchiveScope, ScriptedArchive};

const START: Timestamp = Timestamp(1_790_000_000_000);
const ARCHIVE_ORIGIN: &str = "https://archive.example.org";
const TOKEN: &str = "schublade_scenario_token";

/// SplitMix64: the same numbers for a seed on every machine.
struct Generator(u64);

impl Generator {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut mixed = self.0;
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        mixed ^ (mixed >> 31)
    }

    fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next() % u64::try_from(bound).unwrap()).unwrap()
    }

    fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    fn pick<'items, Item>(&mut self, items: &'items [Item]) -> Option<&'items Item> {
        (!items.is_empty()).then(|| &items[self.below(items.len())])
    }

    fn subset<Item: Clone + Ord>(&mut self, items: &[Item]) -> BTreeSet<Item> {
        items.iter().filter(|_| self.chance(40)).cloned().collect()
    }
}

/// An identifier that names its kind in its first group and its number in its last.
fn identifier(kind: u8, number: usize) -> String {
    format!("{kind:08x}-0000-4000-8000-{number:012x}")
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

/// Waits for an announcement above the revision a follower holds, then reads the status.
fn status_after(replica: &Replica, events: &Receiver<ReplicaEvent>, held_revision: u64) -> ReplicaStatus {
    loop {
        let ReplicaEvent::StatusChanged { revision } = events
            .recv_timeout(Duration::from_secs(30))
            .expect("the replica announces a change");
        if revision > held_revision {
            let status = replica.status();
            assert!(status.revision >= revision, "{} after {revision}", status.revision);
            return status;
        }
    }
}

#[test]
fn a_follower_sees_the_fill_complete_and_never_an_older_revision() {
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
        archive.put_document(DocumentRecord {
            identifier: DocumentIdentifier::parse(&identifier(5, number)).unwrap(),
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
    }
    let directory = tempfile::tempdir().unwrap();
    let database_path = directory.path().join("replica.sqlite");
    let reader: Arc<dyn ArchiveReader> = archive.clone();
    let (replica, events) = Replica::start(ReplicaSettings {
        database_path: database_path.clone(),
        credential_store: Box::new(FixedCredentialStore::new(None)),
        archive_readers: Box::new(move |_, _| Arc::clone(&reader)),
        timing: SynchronizationTiming::default(),
        clock: Arc::new(ManualClock::starting_at(START)),
    })
    .unwrap();

    let mut followed = vec![replica.status()];
    replica
        .attach_archive(
            ArchiveAddress::parse(ARCHIVE_ORIGIN).unwrap(),
            ArchiveToken::new(TOKEN.to_owned()),
            archive.read_authorization().unwrap(),
        )
        .unwrap();
    while !matches!(
        followed.last().unwrap().synchronization,
        SynchronizationState::Following { .. }
    ) {
        let held_revision = followed.last().unwrap().revision;
        followed.push(status_after(&replica, &events, held_revision));
    }
    replica.shutdown();

    assert_eq!(
        followed.first(),
        Some(&ReplicaStatus {
            revision: 0,
            content_revision: 0,
            archive: None,
            synchronization: SynchronizationState::Disconnected,
        })
    );
    let revisions: Vec<u64> = followed.iter().map(|status| status.revision).collect();
    assert!(
        revisions.is_sorted_by(|earlier, later| earlier < later),
        "{revisions:?}"
    );
    // The attachment, then four pages of two journal entries each, the last with one.
    assert_eq!(
        followed.last(),
        Some(&ReplicaStatus {
            revision: 5,
            content_revision: 4,
            archive: Some(MirroredArchive {
                origin: ARCHIVE_ORIGIN.to_owned(),
                permission_level: PermissionLevel::Ingest,
                fill_complete: true,
                synchronized_at: Some(START),
            }),
            synchronization: SynchronizationState::Following {
                next_request_at: Timestamp(START.0 + 15 * 60 * 1_000),
            },
        })
    );
    assert_eq!(
        ReplicaStore::open(&database_path).unwrap().records().unwrap(),
        archive.records()
    );
}
