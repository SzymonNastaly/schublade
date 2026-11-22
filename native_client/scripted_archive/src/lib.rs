//! One archive model in memory for both the local copy and the collector. It keeps records and
//! a change journal by the server's rules as `notes/client_protocol.md` states them, and keeps
//! contents and lookup rules for `collection_core::ArchiveClient`, so a file submitted by the
//! collector appears in the journal and in a library that follows it.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::Write;
use std::sync::{Mutex, MutexGuard, PoisonError};

use archive_access::{
    ArchiveAuthorization, ArchiveCondition, ContentDigest, DocumentIdentifier, DownloadFailure, PermissionLevel,
    Timestamp,
};
use archive_replica::replica_records::{
    ArchiveRecords, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, FailureReason,
    IngestionStage, JournalCursor, JournalPage, MemberIdentifier, MemberRecord, PersonAssignment, RemovedRecord,
    SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use archive_replica::{ArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
use collection_core::ArchiveClient;
use collection_core::archive_connection::SubmissionCondition;
use collection_core::candidate_classification::{MAXIMUM_CONTENT_BYTES, identify_content_kind};
use collection_core::content_synchronization::{LookupAnswer, SubmissionAuthorization, SubmissionOutcome};
use collection_core::domain_types::DocumentStatus;
use collection_core::file_system_observation::VerifiedContent;
use sha2::{Digest, Sha256};

/// The answer to one file of a person's upload, as the Worker's `UploadOutcome` has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UploadOutcome {
    Accepted(DocumentIdentifier),
    AlreadyArchived(DocumentIdentifier),
    Rejected(String),
}

/// What a token may see: the four lists of the server's `AuthorizationScope`. A scope without a
/// list sees every record, and one with any list is restricted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ArchiveScope {
    pub allowed_categories: Option<BTreeSet<CategoryIdentifier>>,
    pub allowed_tags: Option<BTreeSet<TagIdentifier>>,
    pub denied_tags: Option<BTreeSet<TagIdentifier>>,
    pub allowed_senders: Option<BTreeSet<SenderIdentifier>>,
}

impl ArchiveScope {
    fn is_restricted(&self) -> bool {
        *self != ArchiveScope::default()
    }

    /// The SHA-256 of the JSON text of the four lists, in the order `allowedCategories`,
    /// `allowedTags`, `deniedTags`, `allowedSenders`, each sorted and an absent one `null`.
    fn digest(&self) -> String {
        fn list<Identifier>(
            identifiers: &Option<BTreeSet<Identifier>>,
            text: impl Fn(&Identifier) -> &str,
        ) -> serde_json::Value {
            match identifiers {
                Some(identifiers) => identifiers.iter().map(text).collect(),
                None => serde_json::Value::Null,
            }
        }
        let lists = serde_json::Value::from(vec![
            list(&self.allowed_categories, CategoryIdentifier::as_str),
            list(&self.allowed_tags, TagIdentifier::as_str),
            list(&self.denied_tags, TagIdentifier::as_str),
            list(&self.allowed_senders, SenderIdentifier::as_str),
        ]);
        Sha256::digest(lists.to_string().as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

/// The kind and identifier of a record, which is what a journal entry names.
type JournaledRecord = RemovedRecord;

/// Metadata and bytes of an original held for a document, for HTTP responses with `ETag`.
pub struct OriginalContent {
    pub media_type: String,
    pub digest: Option<ContentDigest>,
    pub bytes: Vec<u8>,
}

struct Archive {
    journal_identifier: String,
    /// The journals this archive has had, from which the next identifier derives.
    journals_issued: u64,
    /// The highest sequence number the journal issued, which no later entry takes again.
    last_sequence_number: u64,
    /// The entries by sequence number. Each record has exactly one.
    entries: BTreeMap<u64, JournaledRecord>,
    members: BTreeMap<MemberIdentifier, MemberRecord>,
    senders: BTreeMap<SenderIdentifier, SenderRecord>,
    categories: BTreeMap<CategoryIdentifier, CategoryRecord>,
    tags: BTreeMap<TagIdentifier, TagRecord>,
    documents: BTreeMap<DocumentIdentifier, DocumentRecord>,
    contents: BTreeMap<ContentDigest, LookupAnswer>,
    /// Tracks failed documents whose failure reason was explicitly `None`.
    empty_failure_reasons: BTreeSet<DocumentIdentifier>,
    texts: BTreeMap<DocumentIdentifier, String>,
    originals: BTreeMap<DocumentIdentifier, Vec<u8>>,
    thumbnails: BTreeMap<DocumentIdentifier, Vec<u8>>,
    /// The originals the archive has sent.
    original_downloads: u64,
    scope: ArchiveScope,
    permission_level: PermissionLevel,
    page_entries: usize,
    conditions: VecDeque<ArchiveCondition>,
    lookup_overrides: BTreeMap<ContentDigest, VecDeque<LookupAnswer>>,
    lookups: Vec<Vec<ContentDigest>>,
    submissions: Vec<ContentDigest>,
    status_reads: Vec<DocumentIdentifier>,
    next_arrival_ms: i64,
}

impl Archive {
    /// Archives bytes the archive does not hold as a new document in ingestion, with its original
    /// and a journal entry, as the Worker's `archiveContent` does.
    fn archive_new_document(&mut self, digest: ContentDigest, bytes: &[u8]) -> DocumentIdentifier {
        let document = ScriptedArchive::document_of(&digest);
        let media_type = identify_content_kind(bytes)
            .map_or("application/pdf", |kind| kind.media_type())
            .to_owned();
        let byte_size = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        let arrived_at = Timestamp(self.next_arrival_ms);
        self.next_arrival_ms += 1_000;
        self.contents.insert(digest, LookupAnswer::Present(document.clone()));
        self.originals.insert(document.clone(), bytes.to_vec());
        self.documents.insert(
            document.clone(),
            DocumentRecord {
                identifier: document.clone(),
                condition: DocumentCondition::Arriving(IngestionStage::Processing),
                title: None,
                document_date: None,
                sender: None,
                category: None,
                person: PersonAssignment::Unassigned,
                summary: None,
                media_type,
                byte_size,
                page_count: None,
                original: Some(digest),
                arrived_at,
                tags: BTreeSet::new(),
                fields: BTreeMap::new(),
            },
        );
        self.journal(JournaledRecord::Document(document.clone()));
        document
    }

    /// Gives the record's entry the next number, as every trigger of the server does inside the
    /// statement that fired it.
    fn journal(&mut self, record: JournaledRecord) {
        self.entries.retain(|_, journaled| *journaled != record);
        self.last_sequence_number += 1;
        self.entries.insert(self.last_sequence_number, record);
    }

    fn cursor(&self, sequence_number: u64) -> JournalCursor {
        JournalCursor::parse(&format!("{}.{sequence_number}", self.journal_identifier))
            .unwrap_or_else(|| unreachable!("an identifier, a full stop, and a number form a cursor"))
    }

    /// The server's `scopeAdmission`: a restricted scope admits only archived documents that
    /// satisfy every list it holds.
    fn admits(&self, document: &DocumentRecord) -> bool {
        let scope = &self.scope;
        if !scope.is_restricted() {
            return true;
        }
        fn listed<Identifier: Ord>(list: &Option<BTreeSet<Identifier>>, held: Option<&Identifier>) -> bool {
            list.as_ref()
                .is_none_or(|list| held.is_some_and(|held| list.contains(held)))
        }
        document.condition == DocumentCondition::Archived
            && listed(&scope.allowed_categories, document.category.as_ref())
            && listed(&scope.allowed_senders, document.sender.as_ref())
            && scope
                .allowed_tags
                .as_ref()
                .is_none_or(|allowed| !allowed.is_disjoint(&document.tags))
            && scope
                .denied_tags
                .as_ref()
                .is_none_or(|denied| denied.is_disjoint(&document.tags))
    }

    /// Whether a document refers to the record of the entry.
    fn refers(document: &DocumentRecord, record: &JournaledRecord) -> bool {
        match record {
            JournaledRecord::Document(_) => false,
            JournaledRecord::Member(member) => document.person == PersonAssignment::Member(member.clone()),
            JournaledRecord::Sender(sender) => document.sender.as_ref() == Some(sender),
            JournaledRecord::Category(category) => document.category.as_ref() == Some(category),
            JournaledRecord::Tag(tag) => document.tags.contains(tag),
        }
    }

    /// The records a page sends for these entries and what their admitted documents refer to,
    /// and the entries whose record it does not send. A member, sender, category, or tag of an
    /// entry is sent to a restricted scope only while the scope admits a document, anywhere in
    /// the archive, that refers to it.
    fn records_of(&self, entries: impl Iterator<Item = JournaledRecord>) -> (ArchiveRecords, Vec<RemovedRecord>) {
        let unrestricted = !self.scope.is_restricted();
        let mut members = BTreeSet::new();
        let mut senders = BTreeSet::new();
        let mut categories = BTreeSet::new();
        let mut tags = BTreeSet::new();
        let mut documents = Vec::new();
        let mut removed = Vec::new();
        for entry in entries {
            let referred = || {
                unrestricted
                    || self
                        .admitted_documents()
                        .any(|document| Archive::refers(document, &entry))
            };
            let sent = match &entry {
                JournaledRecord::Document(identifier) => match self.documents.get(identifier) {
                    Some(document) if self.admits(document) => {
                        if let PersonAssignment::Member(member) = &document.person {
                            members.insert(member.clone());
                        }
                        senders.extend(document.sender.clone());
                        categories.extend(document.category.clone());
                        tags.extend(document.tags.iter().cloned());
                        documents.push(document.clone());
                        true
                    }
                    Some(_) | None => false,
                },
                JournaledRecord::Member(member) => {
                    let sent = self.members.contains_key(member) && referred();
                    members.extend(sent.then(|| member.clone()));
                    sent
                }
                JournaledRecord::Sender(sender) => {
                    let sent = self.senders.contains_key(sender) && referred();
                    senders.extend(sent.then(|| sender.clone()));
                    sent
                }
                JournaledRecord::Category(category) => {
                    let sent = self.categories.contains_key(category) && referred();
                    categories.extend(sent.then(|| category.clone()));
                    sent
                }
                JournaledRecord::Tag(tag) => {
                    let sent = self.tags.contains_key(tag) && referred();
                    tags.extend(sent.then(|| tag.clone()));
                    sent
                }
            };
            if !sent {
                removed.push(entry);
            }
        }
        documents.sort_by(|one, other| one.identifier.cmp(&other.identifier));
        let records = ArchiveRecords {
            members: members.iter().map(|member| self.members[member].clone()).collect(),
            senders: senders.iter().map(|sender| self.senders[sender].clone()).collect(),
            categories: categories
                .iter()
                .map(|category| self.categories[category].clone())
                .collect(),
            tags: tags.iter().map(|tag| self.tags[tag].clone()).collect(),
            documents,
        };
        (records, removed)
    }

    /// The document as the representation routes see it: one that exists and that the scope
    /// admits.
    fn represented(&self, document: &DocumentIdentifier) -> Option<&DocumentRecord> {
        self.documents.get(document).filter(|document| self.admits(document))
    }

    fn admitted_documents(&self) -> impl Iterator<Item = &DocumentRecord> {
        self.documents.values().filter(|document| self.admits(document))
    }

    fn page_after(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        if self.permission_level < PermissionLevel::Read {
            return Err(ArchiveCondition::CredentialInsufficient);
        }
        let after_number = match after {
            Some(cursor) => {
                let position = cursor
                    .as_str()
                    .split_once('.')
                    .and_then(|(journal, number)| Some((journal, number.parse::<u64>().ok()?)));
                match position {
                    Some((journal, number))
                        if journal == self.journal_identifier && number <= self.last_sequence_number =>
                    {
                        number
                    }
                    Some(_) => return Ok(PageAnswer::JournalReplaced),
                    None => {
                        return Err(ArchiveCondition::ProtocolViolation {
                            detail: "400: The cursor is not one this archive answered. Send the cursor of the last \
                                     page as it came."
                                .to_owned(),
                        });
                    }
                }
            }
            None => 0,
        };
        let excluded_tag_missing = self
            .scope
            .denied_tags
            .iter()
            .flatten()
            .any(|tag| !self.tags.contains_key(tag));
        if excluded_tag_missing {
            return Err(ArchiveCondition::CredentialInsufficient);
        }
        let following = || self.entries.range(after_number + 1..);
        let page: Vec<(u64, JournaledRecord)> = following()
            .take(self.page_entries)
            .map(|(number, record)| (*number, record.clone()))
            .collect();
        let last_number = page.last().map_or(after_number, |(number, _)| *number);
        let remaining = following().count() - page.len();
        let (records, removed) = self.records_of(page.into_iter().map(|(_, record)| record));
        Ok(PageAnswer::Page(JournalPage {
            cursor: self.cursor(last_number),
            complete: remaining == 0,
            remaining_entries: u64::try_from(remaining).unwrap_or(u64::MAX),
            members: records.members,
            senders: records.senders,
            categories: records.categories,
            tags: records.tags,
            documents: records.documents,
            removed,
        }))
    }

    fn document_status(&self, identifier: &DocumentIdentifier) -> Option<DocumentStatus> {
        let document = self.documents.get(identifier)?;
        Some(match &document.condition {
            DocumentCondition::Arriving(stage) => match stage {
                IngestionStage::AwaitingRendering => DocumentStatus::AwaitingRendering,
                IngestionStage::Processing | IngestionStage::Unrecognized(_) => DocumentStatus::Processing,
                IngestionStage::Extracting => DocumentStatus::Extracting,
                IngestionStage::RecognizingText => DocumentStatus::RecognizingText,
                IngestionStage::Classifying => DocumentStatus::Classifying,
            },
            DocumentCondition::Archived => DocumentStatus::Archived,
            DocumentCondition::Failed(_) => DocumentStatus::Failed {
                failure_reason: if self.empty_failure_reasons.contains(identifier) {
                    None
                } else {
                    document.condition.failure_reason_name().map(str::to_owned)
                },
            },
        })
    }

    fn record_condition(&mut self, identifier: &DocumentIdentifier, status: DocumentStatus) -> DocumentCondition {
        self.empty_failure_reasons.remove(identifier);
        match status {
            DocumentStatus::AwaitingRendering => DocumentCondition::Arriving(IngestionStage::AwaitingRendering),
            DocumentStatus::Processing => DocumentCondition::Arriving(IngestionStage::Processing),
            DocumentStatus::Extracting => DocumentCondition::Arriving(IngestionStage::Extracting),
            DocumentStatus::RecognizingText => DocumentCondition::Arriving(IngestionStage::RecognizingText),
            DocumentStatus::Classifying => DocumentCondition::Arriving(IngestionStage::Classifying),
            DocumentStatus::Archived => DocumentCondition::Archived,
            DocumentStatus::Failed { failure_reason: None } => {
                self.empty_failure_reasons.insert(identifier.clone());
                DocumentCondition::Failed(FailureReason::ProcessingError)
            }
            DocumentStatus::Failed {
                failure_reason: Some(reason),
            } => DocumentCondition::parse("failed", Some(&reason))
                .unwrap_or_else(|| unreachable!("a present failure reason always parses")),
        }
    }

    fn minimal_document(
        &mut self,
        identifier: DocumentIdentifier,
        condition: DocumentCondition,
        original: Option<ContentDigest>,
    ) -> DocumentRecord {
        let arrived_at = Timestamp(self.next_arrival_ms);
        self.next_arrival_ms += 1_000;
        DocumentRecord {
            identifier,
            condition,
            title: None,
            document_date: None,
            sender: None,
            category: None,
            person: PersonAssignment::Unassigned,
            summary: None,
            media_type: "application/pdf".to_owned(),
            byte_size: 0,
            page_count: None,
            original,
            arrived_at,
            tags: BTreeSet::new(),
            fields: BTreeMap::new(),
        }
    }
}

/// The journal identifier of the n-th journal of a scripted archive: 32 hexadecimal digits.
fn journal_identifier(journals_issued: u64) -> String {
    format!("{journals_issued:032x}")
}

pub struct ScriptedArchive {
    archive: Mutex<Archive>,
}

impl Default for ScriptedArchive {
    fn default() -> ScriptedArchive {
        ScriptedArchive::new()
    }
}

impl ScriptedArchive {
    /// An empty archive with the server's 250-entry pages.
    pub fn new() -> ScriptedArchive {
        ScriptedArchive::with_page_entries(250)
    }

    /// An empty archive that an unrestricted token reads, in pages of at most this many journal
    /// entries. The server's pages cover 250.
    pub fn with_page_entries(page_entries: usize) -> ScriptedArchive {
        ScriptedArchive {
            archive: Mutex::new(Archive {
                journal_identifier: journal_identifier(1),
                journals_issued: 1,
                last_sequence_number: 0,
                entries: BTreeMap::new(),
                members: BTreeMap::new(),
                senders: BTreeMap::new(),
                categories: BTreeMap::new(),
                tags: BTreeMap::new(),
                documents: BTreeMap::new(),
                contents: BTreeMap::new(),
                empty_failure_reasons: BTreeSet::new(),
                texts: BTreeMap::new(),
                originals: BTreeMap::new(),
                thumbnails: BTreeMap::new(),
                original_downloads: 0,
                scope: ArchiveScope::default(),
                permission_level: PermissionLevel::Read,
                page_entries,
                conditions: VecDeque::new(),
                lookup_overrides: BTreeMap::new(),
                lookups: Vec::new(),
                submissions: Vec::new(),
                status_reads: Vec::new(),
                next_arrival_ms: 1_790_000_000_000,
            }),
        }
    }

    fn archive(&self) -> MutexGuard<'_, Archive> {
        self.archive.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Creates the member or replaces its state.
    pub fn put_member(&self, member: MemberRecord) {
        let mut archive = self.archive();
        archive.journal(JournaledRecord::Member(member.identifier.clone()));
        archive.members.insert(member.identifier.clone(), member);
    }

    /// Creates the sender or replaces its state, as a rename does.
    pub fn put_sender(&self, sender: SenderRecord) {
        let mut archive = self.archive();
        archive.journal(JournaledRecord::Sender(sender.identifier.clone()));
        archive.senders.insert(sender.identifier.clone(), sender);
    }

    pub fn put_category(&self, category: CategoryRecord) {
        let mut archive = self.archive();
        archive.journal(JournaledRecord::Category(category.identifier.clone()));
        archive.categories.insert(category.identifier.clone(), category);
    }

    pub fn put_tag(&self, tag: TagRecord) {
        let mut archive = self.archive();
        archive.journal(JournaledRecord::Tag(tag.identifier.clone()));
        archive.tags.insert(tag.identifier.clone(), tag);
    }

    /// Creates the document or replaces its state, tags and fields included, as an upload, a
    /// step of the ingestion, a revision, or a change of its tags does. Every record it refers to
    /// must exist, as the server's foreign keys demand.
    pub fn put_document(&self, document: DocumentRecord) {
        let mut archive = self.archive();
        let references_resolve = document
            .sender
            .as_ref()
            .is_none_or(|sender| archive.senders.contains_key(sender))
            && document
                .category
                .as_ref()
                .is_none_or(|category| archive.categories.contains_key(category))
            && document.tags.iter().all(|tag| archive.tags.contains_key(tag))
            && match &document.person {
                PersonAssignment::Member(member) => archive.members.contains_key(member),
                PersonAssignment::Household | PersonAssignment::Unassigned => true,
            };
        assert!(
            references_resolve,
            "{} refers to a record the archive lacks",
            document.identifier.as_str()
        );
        archive.empty_failure_reasons.remove(&document.identifier);
        if let Some(digest) = document.original {
            archive
                .contents
                .insert(digest, LookupAnswer::Present(document.identifier.clone()));
        }
        archive.journal(JournaledRecord::Document(document.identifier.clone()));
        archive.documents.insert(document.identifier.clone(), document);
    }

    /// Stores the extracted Markdown of a document, as the step before classification does. It
    /// writes no record, so the journal does not move.
    pub fn put_text(&self, document: &DocumentIdentifier, markdown: &str) {
        self.archive().texts.insert(document.clone(), markdown.to_owned());
    }

    /// Stores the file of a document. The record names its content, so a script can store bytes
    /// that the record does not name.
    pub fn put_original(&self, document: &DocumentIdentifier, bytes: &[u8]) {
        self.archive().originals.insert(document.clone(), bytes.to_vec());
    }

    /// Stores the picture of a document's first page.
    pub fn put_thumbnail(&self, document: &DocumentIdentifier, bytes: &[u8]) {
        self.archive().thumbnails.insert(document.clone(), bytes.to_vec());
    }

    /// How many originals the archive has sent.
    pub fn original_downloads(&self) -> u64 {
        self.archive().original_downloads
    }

    /// Deletes the document. Its journal entry stays as the record of the deletion.
    pub fn delete_document(&self, document: &DocumentIdentifier) {
        let mut archive = self.archive();
        if let Some(removed) = archive.documents.remove(document) {
            archive.empty_failure_reasons.remove(document);
            if let Some(digest) = removed.original {
                let replacement = archive
                    .documents
                    .values()
                    .find(|other| other.original == Some(digest))
                    .map(|other| other.identifier.clone());
                let state = match replacement {
                    Some(other) => LookupAnswer::Present(other),
                    None => LookupAnswer::Deleted,
                };
                archive.contents.insert(digest, state);
            }
            archive.journal(JournaledRecord::Document(document.clone()));
        }
    }

    /// The archive holds this content in this document.
    pub fn hold(&self, digest: ContentDigest, document: DocumentIdentifier, status: DocumentStatus) {
        let mut archive = self.archive();
        let condition = archive.record_condition(&document, status);
        archive.contents.insert(digest, LookupAnswer::Present(document.clone()));
        if let Some(existing) = archive.documents.get_mut(&document) {
            existing.condition = condition;
            existing.original = Some(digest);
        } else {
            let record = archive.minimal_document(document.clone(), condition, Some(digest));
            archive.documents.insert(document.clone(), record);
        }
        archive.journal(JournaledRecord::Document(document));
    }

    /// The owner deleted the document that held this content.
    pub fn delete(&self, digest: &ContentDigest) {
        let mut archive = self.archive();
        if let Some(LookupAnswer::Present(document)) = archive.contents.insert(*digest, LookupAnswer::Deleted) {
            archive.documents.remove(&document);
            archive.empty_failure_reasons.remove(&document);
            archive.journal(JournaledRecord::Document(document));
        }
    }

    pub fn set_document_status(&self, document: &DocumentIdentifier, status: DocumentStatus) {
        let mut archive = self.archive();
        let condition = archive.record_condition(document, status);
        if let Some(existing) = archive.documents.get_mut(document) {
            existing.condition = condition;
        } else {
            let record = archive.minimal_document(document.clone(), condition, None);
            archive.documents.insert(document.clone(), record);
        }
        archive.journal(JournaledRecord::Document(document.clone()));
    }

    /// Folds one tag into another: every document of the first takes the second in its place,
    /// and the first is deleted.
    pub fn merge_tags(&self, merged: &TagIdentifier, into: &TagIdentifier) {
        let mut archive = self.archive();
        assert!(
            merged != into && archive.tags.contains_key(merged) && archive.tags.contains_key(into),
            "a merge takes two tags of the archive"
        );
        let mut retagged = Vec::new();
        for document in archive.documents.values_mut() {
            if document.tags.remove(merged) {
                document.tags.insert(into.clone());
                retagged.push(document.identifier.clone());
            }
        }
        for document in retagged {
            archive.journal(JournaledRecord::Document(document));
        }
        archive.tags.remove(merged);
        archive.journal(JournaledRecord::Tag(merged.clone()));
    }

    /// From now on the token sees this scope, as when a person connects with another token.
    pub fn restrict_scope(&self, scope: ArchiveScope) {
        self.archive().scope = scope;
    }

    /// Sets the level reported by `read_authorization` and enforced on every route.
    pub fn set_permission_level(&self, level: PermissionLevel) {
        self.archive().permission_level = level;
    }

    pub fn permission_level(&self) -> PermissionLevel {
        self.archive().permission_level
    }

    /// The next request answers with this condition instead of its answer.
    pub fn fail_next(&self, condition: ArchiveCondition) {
        self.archive().conditions.push_back(condition);
    }

    /// The next lookup of this digest answers as given, whatever the archive records: the
    /// window in which another device uploaded, or the owner deleted, between lookup and PUT.
    pub fn answer_next_lookup(&self, digest: ContentDigest, answer: LookupAnswer) {
        self.archive()
            .lookup_overrides
            .entry(digest)
            .or_default()
            .push_back(answer);
    }

    /// Whether the archive holds a document for this content.
    /// One file of `POST /api/documents/ingest`, as a person's upload: bytes of an unaccepted kind
    /// or above 25 MB are rejected, bytes a document holds answer that document, and any other
    /// bytes become a new document, even bytes whose document the owner deleted, because a person
    /// chose to send them.
    pub fn upload(&self, bytes: &[u8]) -> UploadOutcome {
        if identify_content_kind(bytes).is_none() {
            return UploadOutcome::Rejected("Only PDF, JPEG, PNG, and WebP files can be archived.".to_owned());
        }
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAXIMUM_CONTENT_BYTES {
            return UploadOutcome::Rejected("The file is larger than 25 MB".to_owned());
        }
        let digest = ContentDigest::from_bytes(Sha256::digest(bytes).into());
        let mut archive = self.archive();
        archive.submissions.push(digest);
        match archive.contents.get(&digest).cloned() {
            Some(LookupAnswer::Present(document)) => UploadOutcome::AlreadyArchived(document),
            Some(LookupAnswer::Deleted | LookupAnswer::Absent) | None => {
                UploadOutcome::Accepted(archive.archive_new_document(digest, bytes))
            }
        }
    }

    pub fn holds(&self, digest: &ContentDigest) -> bool {
        matches!(self.archive().contents.get(digest), Some(LookupAnswer::Present(_)))
    }

    /// Every content digest the archive currently holds as `Present`, in ascending order.
    pub fn held_digests(&self) -> Vec<ContentDigest> {
        self.archive()
            .contents
            .iter()
            .filter_map(|(digest, answer)| matches!(answer, LookupAnswer::Present(_)).then_some(*digest))
            .collect()
    }

    pub fn submission_count(&self, digest: &ContentDigest) -> usize {
        self.archive()
            .submissions
            .iter()
            .filter(|submitted| *submitted == digest)
            .count()
    }

    pub fn lookups(&self) -> Vec<Vec<ContentDigest>> {
        self.archive().lookups.clone()
    }

    pub fn status_reads(&self) -> Vec<DocumentIdentifier> {
        self.archive().status_reads.clone()
    }

    /// A deterministic identifier per content, so a scenario can name the document it expects.
    pub fn document_of(digest: &ContentDigest) -> DocumentIdentifier {
        let hexadecimal = digest.hexadecimal();
        DocumentIdentifier::parse(&format!(
            "{}-{}-4{}-8{}-{}",
            &hexadecimal[..8],
            &hexadecimal[8..12],
            &hexadecimal[13..16],
            &hexadecimal[17..20],
            &hexadecimal[20..32]
        ))
        .unwrap_or_else(|| unreachable!("the groups are lowercase hexadecimal of the right lengths"))
    }

    /// Gives the journal another identifier and numbers its entries anew, as the end of a
    /// database restore does. Every cursor of the former journal answers `JournalReplaced`.
    pub fn replace_journal(&self) {
        let mut archive = self.archive();
        archive.journals_issued += 1;
        archive.journal_identifier = journal_identifier(archive.journals_issued);
        let entries: Vec<JournaledRecord> = std::mem::take(&mut archive.entries).into_values().collect();
        archive.last_sequence_number = 0;
        for record in entries {
            archive.journal(record);
        }
    }

    /// Every record the archive holds.
    pub fn records(&self) -> ArchiveRecords {
        let archive = self.archive();
        ArchiveRecords {
            members: archive.members.values().cloned().collect(),
            senders: archive.senders.values().cloned().collect(),
            categories: archive.categories.values().cloned().collect(),
            tags: archive.tags.values().cloned().collect(),
            documents: archive.documents.values().cloned().collect(),
        }
    }

    /// The records a copy holds after it filled from this archive now: the documents the scope
    /// admits, with every record of an unrestricted scope, or the records those documents refer
    /// to of a restricted one.
    pub fn admitted_records(&self) -> ArchiveRecords {
        let archive = self.archive();
        let entries: Vec<JournaledRecord> = archive.entries.values().cloned().collect();
        archive.records_of(entries.into_iter()).0
    }

    /// Reads an original together with its media type and digest for HTTP `Content-Type` and
    /// `ETag` headers, without holding the lock across the socket write.
    pub fn read_original_content(&self, document: &DocumentIdentifier) -> Result<OriginalContent, OriginalAnswer> {
        let mut archive = self.archive();
        let Some(record) = archive.represented(document).cloned() else {
            return Err(OriginalAnswer::DocumentAbsent);
        };
        if record.media_type == "message/rfc822" {
            return Err(OriginalAnswer::NotPrinted);
        }
        let Some(bytes) = archive.originals.get(document).cloned() else {
            return Err(OriginalAnswer::DocumentAbsent);
        };
        archive.original_downloads += 1;
        Ok(OriginalContent {
            media_type: record.media_type,
            digest: record.original,
            bytes,
        })
    }
}

impl ArchiveReader for ScriptedArchive {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        let mut archive = self.archive();
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition);
        }
        Ok(ArchiveAuthorization {
            journal_identifier: archive.journal_identifier.clone(),
            token_description: "Scripted token".to_owned(),
            permission_level: archive.permission_level,
            restricted: archive.scope.is_restricted(),
            scope_digest: archive.scope.digest(),
        })
    }

    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        let mut archive = self.archive();
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition);
        }
        archive.page_after(after)
    }

    fn read_text(&self, document: &DocumentIdentifier) -> Result<Option<String>, ArchiveCondition> {
        let mut archive = self.archive();
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition);
        }
        if archive.permission_level < PermissionLevel::Read {
            return Err(ArchiveCondition::CredentialInsufficient);
        }
        Ok(archive
            .represented(document)
            .and_then(|_| archive.texts.get(document).cloned()))
    }

    fn download_original(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<OriginalAnswer, DownloadFailure> {
        let mut archive = self.archive();
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(DownloadFailure::Archive(condition));
        }
        if archive.permission_level < PermissionLevel::Read {
            return Err(DownloadFailure::Archive(ArchiveCondition::CredentialInsufficient));
        }
        let Some(record) = archive.represented(document) else {
            return Ok(OriginalAnswer::DocumentAbsent);
        };
        if record.media_type == "message/rfc822" {
            return Ok(OriginalAnswer::NotPrinted);
        }
        let Some(original) = archive.originals.get(document) else {
            return Ok(OriginalAnswer::DocumentAbsent);
        };
        destination.write_all(original).map_err(DownloadFailure::Destination)?;
        archive.original_downloads += 1;
        Ok(OriginalAnswer::Received)
    }

    fn download_thumbnail(
        &self,
        document: &DocumentIdentifier,
        destination: &mut dyn Write,
    ) -> Result<ThumbnailAnswer, DownloadFailure> {
        let mut archive = self.archive();
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(DownloadFailure::Archive(condition));
        }
        if archive.permission_level < PermissionLevel::Read {
            return Err(DownloadFailure::Archive(ArchiveCondition::CredentialInsufficient));
        }
        let Some(thumbnail) = archive
            .represented(document)
            .and_then(|_| archive.thumbnails.get(document))
        else {
            return Ok(ThumbnailAnswer::Absent);
        };
        destination.write_all(thumbnail).map_err(DownloadFailure::Destination)?;
        Ok(ThumbnailAnswer::Received)
    }
}

impl ArchiveClient for ScriptedArchive {
    fn look_up(&self, digests: &[ContentDigest]) -> Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition> {
        let mut archive = self.archive();
        archive.lookups.push(digests.to_vec());
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition);
        }
        if archive.scope.is_restricted() {
            return Err(ArchiveCondition::CredentialInsufficient);
        }
        let mut answers = Vec::with_capacity(digests.len());
        for digest in digests {
            let overridden = archive.lookup_overrides.get_mut(digest).and_then(VecDeque::pop_front);
            let answer =
                overridden.unwrap_or_else(|| archive.contents.get(digest).cloned().unwrap_or(LookupAnswer::Absent));
            answers.push((*digest, answer));
        }
        Ok(answers)
    }

    fn submit(
        &self,
        authorization: SubmissionAuthorization,
        content: VerifiedContent,
    ) -> Result<SubmissionOutcome, SubmissionCondition> {
        let digest = authorization.digest();
        assert_eq!(
            digest,
            content.digest(),
            "a submission's authorization and content must name the same digest"
        );
        let mut archive = self.archive();
        archive.submissions.push(digest);
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition.into());
        }
        if archive.scope.is_restricted() {
            return Err(ArchiveCondition::CredentialInsufficient.into());
        }
        Ok(match archive.contents.get(&digest).cloned() {
            Some(LookupAnswer::Deleted) => SubmissionOutcome::Deleted,
            Some(LookupAnswer::Present(document)) => {
                let status = archive.document_status(&document).unwrap_or(DocumentStatus::Processing);
                SubmissionOutcome::AlreadyHeld { document, status }
            }
            Some(LookupAnswer::Absent) | None => {
                let document = archive.archive_new_document(digest, content.bytes());
                SubmissionOutcome::Accepted {
                    document,
                    status: DocumentStatus::Processing,
                }
            }
        })
    }

    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition> {
        let mut archive = self.archive();
        archive.status_reads.push(document.clone());
        if let Some(condition) = archive.conditions.pop_front() {
            return Err(condition);
        }
        if archive.scope.is_restricted() {
            return Err(ArchiveCondition::CredentialInsufficient);
        }
        Ok(archive.document_status(document))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use collection_core::content_synchronization::{
        ArchiveStanding, ContentRecord, SubmissionFailures, authorize_submission,
    };
    use collection_core::domain_types::{Timestamp, TimingPolicy};

    fn authorization(digest: ContentDigest) -> SubmissionAuthorization {
        let record = ContentRecord {
            digest,
            standing: ArchiveStanding::Absent {
                looked_up_at: Timestamp(0),
                failures: SubmissionFailures::default(),
            },
        };
        authorize_submission(&record, Timestamp(1), &TimingPolicy::default()).unwrap()
    }

    #[test]
    fn a_persons_upload_brings_back_a_document_the_owner_deleted() {
        let archive = ScriptedArchive::new();
        let scan = b"%PDF-1.7 a scanned letter";
        let UploadOutcome::Accepted(document) = archive.upload(scan) else {
            panic!("new bytes become a document");
        };
        assert_eq!(archive.upload(scan), UploadOutcome::AlreadyArchived(document.clone()));

        archive.delete(&ContentDigest::from_bytes(Sha256::digest(scan).into()));
        assert_eq!(archive.upload(scan), UploadOutcome::Accepted(document));
    }

    #[test]
    fn the_scripted_archive_keeps_the_servers_rules() {
        let archive = ScriptedArchive::new();
        let content = VerifiedContent::from_bytes(b"%PDF-1.7 scripted".to_vec());
        let digest = content.digest();
        let other = ContentDigest::from_bytes([7; 32]);

        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Absent)]
        );
        let accepted = archive.submit(authorization(digest), content.clone()).unwrap();
        let document = ScriptedArchive::document_of(&digest);
        assert_eq!(
            accepted,
            SubmissionOutcome::Accepted {
                document: document.clone(),
                status: DocumentStatus::Processing
            }
        );
        assert_eq!(
            archive.look_up(&[digest, other]).unwrap(),
            vec![
                (digest, LookupAnswer::Present(document.clone())),
                (other, LookupAnswer::Absent)
            ]
        );
        archive.set_document_status(&document, DocumentStatus::Archived);
        assert_eq!(
            archive.submit(authorization(digest), content.clone()).unwrap(),
            SubmissionOutcome::AlreadyHeld {
                document: document.clone(),
                status: DocumentStatus::Archived
            }
        );
        assert_eq!(
            archive.read_document_status(&document).unwrap(),
            Some(DocumentStatus::Archived)
        );
        let PageAnswer::Page(page) = archive.read_changes(None).unwrap() else {
            panic!("expected a page");
        };
        assert_eq!(page.documents.len(), 1);
        assert_eq!(page.documents[0].identifier, document);

        archive.delete(&digest);
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Deleted)]
        );
        assert_eq!(
            archive.submit(authorization(digest), content).unwrap(),
            SubmissionOutcome::Deleted
        );
        assert_eq!(archive.read_document_status(&document).unwrap(), None);

        archive.fail_next(ArchiveCondition::TimedOut);
        assert_eq!(archive.look_up(&[digest]), Err(ArchiveCondition::TimedOut));
        assert_eq!(archive.look_up(&[digest]).unwrap().len(), 1);
        assert_eq!(archive.submission_count(&digest), 3);
        assert_eq!(archive.lookups().len(), 5);

        archive.answer_next_lookup(digest, LookupAnswer::Absent);
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Absent)]
        );
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Deleted)]
        );
        assert!(!archive.holds(&digest));
        let held = VerifiedContent::from_bytes(b"%PDF-1.7 held".to_vec());
        archive.submit(authorization(held.digest()), held.clone()).unwrap();
        assert!(archive.holds(&held.digest()));
        assert_eq!(archive.status_reads(), vec![document.clone(), document]);
    }
}
