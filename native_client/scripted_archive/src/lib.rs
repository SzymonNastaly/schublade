//! An archive in memory for the scenarios of the local copy. It keeps records and a change
//! journal by the server's rules, as `notes/client_protocol.md` states them: one entry per record
//! that ever existed, moved to a number above every number ever issued by each write, kept as the
//! record of a deletion, and read in pages of present states that carry what their documents
//! refer to. It keeps the text, the original, and the picture a script gives a document, and
//! answers them as the three representation routes do. A script changes the archive through its
//! writes, and a copy reads it through `ArchiveReader`.
//!
//! The collector's scenarios still use `collection_core::scripted_archive`, which keeps contents
//! and no journal. This crate becomes the one model of an archive once it answers the collector's
//! three routes as well, so that a submitted content appears in the journal.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::sync::{Mutex, MutexGuard, PoisonError};

use archive_access::{ArchiveAuthorization, ArchiveCondition, DocumentIdentifier, DownloadFailure, PermissionLevel};
use archive_replica::replica_records::{
    ArchiveRecords, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, JournalCursor, JournalPage,
    MemberIdentifier, MemberRecord, PersonAssignment, RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier,
    TagRecord,
};
use archive_replica::{ArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
use sha2::{Digest, Sha256};

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
    texts: BTreeMap<DocumentIdentifier, String>,
    originals: BTreeMap<DocumentIdentifier, Vec<u8>>,
    thumbnails: BTreeMap<DocumentIdentifier, Vec<u8>>,
    /// The originals the archive has sent.
    original_downloads: u64,
    scope: ArchiveScope,
    page_entries: usize,
}

impl Archive {
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
}

/// The journal identifier of the n-th journal of a scripted archive: 32 hexadecimal digits.
fn journal_identifier(journals_issued: u64) -> String {
    format!("{journals_issued:032x}")
}

pub struct ScriptedArchive {
    archive: Mutex<Archive>,
}

impl ScriptedArchive {
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
                texts: BTreeMap::new(),
                originals: BTreeMap::new(),
                thumbnails: BTreeMap::new(),
                original_downloads: 0,
                scope: ArchiveScope::default(),
                page_entries,
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
        if archive.documents.remove(document).is_some() {
            archive.journal(JournaledRecord::Document(document.clone()));
        }
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
}

impl ArchiveReader for ScriptedArchive {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        let archive = self.archive();
        Ok(ArchiveAuthorization {
            journal_identifier: archive.journal_identifier.clone(),
            token_description: "Scripted token".to_owned(),
            permission_level: PermissionLevel::Read,
            restricted: archive.scope.is_restricted(),
            scope_digest: archive.scope.digest(),
        })
    }

    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        self.archive().page_after(after)
    }

    fn read_text(&self, document: &DocumentIdentifier) -> Result<Option<String>, ArchiveCondition> {
        let archive = self.archive();
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
        let archive = self.archive();
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
