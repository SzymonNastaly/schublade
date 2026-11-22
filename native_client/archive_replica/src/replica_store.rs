//! `replica.sqlite`, the one file of the copy, and every statement that writes it. The coordinator
//! thread owns the one connection that writes, and `replica_queries.rs` reads for a window on
//! connections of its own. `replica_schema.sql` is the schema.
//!
//! The copy is disposable. Everything in it comes back from the archive, so a file of another
//! schema version, or one SQLite cannot read, is replaced by an empty one.
//!
//! The two search tables have no trigger. `write_document`, `remove_record`, and the upsert of
//! a member, sender, category, or tag name the documents whose search rows they leave stale,
//! and `write_page` rewrites those rows before it ends. `record_texts` writes the text search
//! rows. All of it happens in the transaction of the record, so a search never sees a name the
//! records no longer hold.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Duration;

use archive_access::{ArchiveAuthorization, ContentDigest, DocumentIdentifier, PermissionLevel, Timestamp};
use rusqlite::types::Type;
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, Row, Transaction, params};

use crate::replica_records::{
    ArchiveRecords, CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord,
    ExtractedField, FieldValue, JournalCursor, JournalPage, MemberIdentifier, MemberRecord, PersonAssignment,
    RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use crate::text_retrieval::{AwaitedText, RetrievedText};

/// The `user_version` of a file with the schema of `replica_schema.sql`. Raise it with every
/// change of the schema: a file of another version is replaced and filled again.
const SCHEMA_VERSION: u32 = 3;
const SCHEMA: &str = include_str!("replica_schema.sql");
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// More than the statements this module runs repeatedly, so none is prepared twice.
const STATEMENT_CACHE_CAPACITY: usize = 64;

pub struct ReplicaStore {
    connection: Connection,
}

/// The one row that says what the copy mirrors and how far.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mirror {
    pub archive_origin: String,
    pub journal_identifier: String,
    pub scope_digest: String,
    pub permission_level: PermissionLevel,
    /// Of the token whose authorization the copy was attached with.
    pub credential_fingerprint: String,
    pub cursor: Option<JournalCursor>,
    /// False during the first fill.
    pub fill_complete: bool,
    /// When a page last reached the journal's end.
    pub synchronized_at: Option<Timestamp>,
    /// Rises with every transaction that changed a record or a text.
    pub content_revision: u64,
}

/// How much the copy holds, for a status line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CopyExtent {
    pub documents: u64,
    /// The archived documents whose text the copy has not asked the archive for yet.
    pub documents_awaiting_text: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PageApplication {
    Applied {
        /// The documents in ingestion that the copy holds after the page.
        unsettled_documents: u64,
    },
    /// The stored cursor is not the one the page was requested after, so the page is dropped
    /// unread: another page was applied first, or the copy started over.
    CursorMoved,
}

/// A page written inside a transaction that is still open. `commit` makes it the copy's state.
/// Dropped, it leaves the copy as it was, which is what a crash before the commit leaves.
pub struct StagedPage<'store> {
    transaction: Transaction<'store>,
    application: PageApplication,
}

impl StagedPage<'_> {
    pub fn commit(self) -> rusqlite::Result<PageApplication> {
        self.transaction.commit()?;
        Ok(self.application)
    }
}

impl ReplicaStore {
    /// Opens the copy, or replaces a missing, corrupt, or other-version file by an empty one.
    /// Live database lock or permission errors are returned untouched so another process is never
    /// unlinked out from under its lock.
    pub fn open(path: &Path) -> rusqlite::Result<ReplicaStore> {
        let existing = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let current = if path.exists() {
            Connection::open_with_flags(path, existing).and_then(|connection| {
                connection.busy_timeout(BUSY_TIMEOUT)?;
                let version: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
                Ok((version == SCHEMA_VERSION).then_some(connection))
            })
        } else {
            Ok(None)
        };
        let connection = match current {
            Ok(Some(connection)) => connection,
            Ok(None) => recreate_database(path)?,
            Err(error)
                if matches!(
                    error.sqlite_error_code(),
                    Some(ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt)
                ) =>
            {
                recreate_database(path)?
            }
            Err(error) => return Err(error),
        };
        // The write-ahead log is not flushed at every commit. A power failure can then lose the
        // last pages, which the archive delivers again, and never damages the file.
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.set_prepared_statement_cache_capacity(STATEMENT_CACHE_CAPACITY);
        Ok(ReplicaStore { connection })
    }

    pub fn mirror(&self) -> rusqlite::Result<Option<Mirror>> {
        self.connection
            .prepare_cached(
                "SELECT archive_origin, journal_identifier, scope_digest, permission_level, credential_fingerprint, \
                 journal_cursor, fill_complete, synchronized_at, content_revision FROM mirror",
            )?
            .query_row([], |row| {
                Ok(Mirror {
                    archive_origin: row.get("archive_origin")?,
                    journal_identifier: row.get("journal_identifier")?,
                    scope_digest: row.get("scope_digest")?,
                    permission_level: stored(row, "permission_level", PermissionLevel::parse)?,
                    credential_fingerprint: row.get("credential_fingerprint")?,
                    cursor: stored_optional(row, "journal_cursor", JournalCursor::parse)?,
                    fill_complete: row.get("fill_complete")?,
                    synchronized_at: row.get::<_, Option<i64>>("synchronized_at")?.map(Timestamp),
                    content_revision: stored_count(row, "content_revision")?,
                })
            })
            .optional()
    }

    /// The cursor of the last applied page, which the next page is requested after.
    pub fn cursor(&self) -> rusqlite::Result<Option<JournalCursor>> {
        let cursor = self
            .connection
            .prepare_cached("SELECT journal_cursor FROM mirror")?
            .query_row([], |row| stored_optional(row, "journal_cursor", JournalCursor::parse))
            .optional()?;
        Ok(cursor.flatten())
    }

    /// Records the archive the copy mirrors and what the token's authorization said. The copy
    /// and its cursor stay while the origin, the journal, and the scope are the ones it was
    /// filled under, as when a person replaces a token by another of the same scope. Otherwise
    /// the copy is emptied in the same transaction.
    pub fn attach(
        &mut self,
        archive_origin: &str,
        authorization: &ArchiveAuthorization,
        credential_fingerprint: &str,
    ) -> rusqlite::Result<()> {
        let transaction = self.connection.transaction()?;
        let mirrored: Option<(String, String, String)> = transaction
            .query_row(
                "SELECT archive_origin, journal_identifier, scope_digest FROM mirror",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let kept = mirrored.is_some_and(|(origin, journal, scope)| {
            origin == archive_origin
                && journal == authorization.journal_identifier
                && scope == authorization.scope_digest
        });
        if !kept {
            start_over(&transaction)?;
        }
        transaction.execute(
            "INSERT INTO mirror (singleton, archive_origin, journal_identifier, scope_digest, permission_level, \
             credential_fingerprint) VALUES (1, ?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT (singleton) DO UPDATE SET archive_origin = excluded.archive_origin, \
             journal_identifier = excluded.journal_identifier, scope_digest = excluded.scope_digest, \
             permission_level = excluded.permission_level, credential_fingerprint = excluded.credential_fingerprint",
            params![
                archive_origin,
                authorization.journal_identifier,
                authorization.scope_digest,
                authorization.permission_level.name(),
                credential_fingerprint
            ],
        )?;
        transaction.commit()
    }

    /// Applies the page and stores its cursor in one transaction, and only while the stored
    /// cursor is the one the page was requested after. So pages apply in the order of their
    /// cursors, and a repeated or late page changes nothing.
    pub fn apply_page(
        &mut self,
        requested_after: Option<&JournalCursor>,
        page: &JournalPage,
        applied_at: Timestamp,
    ) -> rusqlite::Result<PageApplication> {
        self.stage_page(requested_after, page, applied_at)?.commit()
    }

    /// `apply_page` up to its commit, for the scenario of a process that ends in between.
    pub fn stage_page(
        &mut self,
        requested_after: Option<&JournalCursor>,
        page: &JournalPage,
        applied_at: Timestamp,
    ) -> rusqlite::Result<StagedPage<'_>> {
        let transaction = self.connection.transaction()?;
        let application = write_page(&transaction, requested_after, page, applied_at)?;
        Ok(StagedPage {
            transaction,
            application,
        })
    }

    /// Empties the copy and forgets its cursor, so the next page is the journal's first.
    pub fn discard(&mut self) -> rusqlite::Result<()> {
        let transaction = self.connection.transaction()?;
        start_over(&transaction)?;
        transaction.commit()
    }

    /// Keeps each text whose document is still archived with the content the text was retrieved
    /// for, and makes it searchable. A text that arrives a second time, or for a document that
    /// changed or left in between, is dropped.
    pub fn record_texts(&mut self, texts: &[RetrievedText]) -> rusqlite::Result<()> {
        let transaction = self.connection.transaction()?;
        let mut recorded = BTreeMap::new();
        for text in texts {
            let document_row: Option<i64> = transaction
                .prepare_cached(
                    "INSERT INTO extracted_texts (document_row, markdown) \
                     SELECT document_row, ?3 FROM documents \
                     WHERE id = ?1 AND status = 'archived' AND original_sha256 IS ?2 \
                     ON CONFLICT (document_row) DO NOTHING RETURNING document_row",
                )?
                .query_row(
                    params![
                        text.document.as_str(),
                        text.original.map(|digest| digest.hexadecimal()),
                        text.markdown
                    ],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(document_row) = document_row {
                recorded.insert(document_row, text.markdown.as_deref());
            }
        }
        // The search rows come after every text row and in the order of their rows, for the
        // reason `StaleSearchRows` gives.
        let mut indexed_text = false;
        for (document_row, markdown) in &recorded {
            if let Some(markdown) = markdown {
                let indexed = index_body_text(markdown);
                run(
                    &transaction,
                    "INSERT INTO document_text_search (rowid, markdown) VALUES (?1, ?2)",
                    params![document_row, indexed.as_ref()],
                )?;
                indexed_text = true;
            }
        }
        if indexed_text {
            run(
                &transaction,
                "UPDATE mirror SET content_revision = content_revision + 1",
                [],
            )?;
        }
        transaction.commit()
    }

    /// The archived documents without a text row, newest arrival first. Work is derived from the
    /// records, never queued, so nothing is lost with a process that ends.
    pub fn documents_awaiting_text(&self, limit: usize) -> rusqlite::Result<Vec<AwaitedText>> {
        self.connection
            .prepare_cached(&format!(
                "SELECT id, original_sha256 FROM documents WHERE {AWAITS_TEXT} \
                 ORDER BY arrived_at DESC, id DESC LIMIT ?1"
            ))?
            .query_map([i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
                Ok(AwaitedText {
                    document: stored(row, "id", DocumentIdentifier::parse)?,
                    original: stored_optional(row, "original_sha256", ContentDigest::parse_hexadecimal)?,
                })
            })?
            .collect()
    }

    pub fn extent(&self) -> rusqlite::Result<CopyExtent> {
        self.connection
            .prepare_cached(&format!(
                "SELECT count(*) AS documents, count(*) FILTER (WHERE {AWAITS_TEXT}) AS awaiting_text FROM documents"
            ))?
            .query_row([], |row| {
                Ok(CopyExtent {
                    documents: stored_count(row, "documents")?,
                    documents_awaiting_text: stored_count(row, "awaiting_text")?,
                })
            })
    }

    /// Every record of the copy.
    pub fn records(&self) -> rusqlite::Result<ArchiveRecords> {
        let connection = &self.connection;
        let members = connection
            .prepare_cached("SELECT id, display_name FROM members ORDER BY id")?
            .query_map([], |row| {
                Ok(MemberRecord {
                    identifier: stored(row, "id", MemberIdentifier::parse)?,
                    display_name: row.get("display_name")?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        let senders = connection
            .prepare_cached("SELECT id, name FROM senders ORDER BY id")?
            .query_map([], |row| {
                Ok(SenderRecord {
                    identifier: stored(row, "id", SenderIdentifier::parse)?,
                    name: row.get("name")?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        let categories = connection
            .prepare_cached("SELECT id, name, expected_fields FROM categories ORDER BY id")?
            .query_map([], |row| {
                Ok(CategoryRecord {
                    identifier: stored(row, "id", CategoryIdentifier::parse)?,
                    name: row.get("name")?,
                    expected_fields: stored(row, "expected_fields", |fields| serde_json::from_str(fields).ok())?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        let tags = connection
            .prepare_cached("SELECT id, name, color_hex FROM tags ORDER BY id")?
            .query_map([], |row| {
                Ok(TagRecord {
                    identifier: stored(row, "id", TagIdentifier::parse)?,
                    name: row.get("name")?,
                    color_hex: row.get("color_hex")?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(ArchiveRecords {
            members,
            senders,
            categories,
            tags,
            documents: documents(connection, None)?,
        })
    }
}

/// Runs a statement that stays prepared for the life of the connection, because a page runs each
/// of its statements once per record.
fn run(transaction: &Transaction<'_>, statement: &str, parameters: impl rusqlite::Params) -> rusqlite::Result<usize> {
    transaction.prepare_cached(statement)?.execute(parameters)
}

/// The condition of a document that awaits its text.
const AWAITS_TEXT: &str = "status = 'archived' AND NOT EXISTS \
     (SELECT 1 FROM extracted_texts WHERE extracted_texts.document_row = documents.document_row)";

/// A member, sender, category, or tag, whose name the details of its documents show.
#[derive(Clone, Copy)]
enum ShownRecord<'identifier> {
    Member(&'identifier str),
    Sender(&'identifier str),
    Category(&'identifier str),
    Tag(&'identifier str),
}

/// The rows of the documents that refer to the record.
fn documents_showing(transaction: &Transaction<'_>, record: ShownRecord<'_>) -> rusqlite::Result<Vec<i64>> {
    let (statement, identifier) = match record {
        ShownRecord::Member(member) => ("SELECT document_row FROM documents WHERE member_id = ?1", member),
        ShownRecord::Sender(sender) => ("SELECT document_row FROM documents WHERE sender_id = ?1", sender),
        ShownRecord::Category(category) => ("SELECT document_row FROM documents WHERE category_id = ?1", category),
        ShownRecord::Tag(tag) => (
            "SELECT documents.document_row FROM document_tags \
             JOIN documents ON documents.id = document_tags.document_id WHERE document_tags.tag_id = ?1",
            tag,
        ),
    };
    transaction
        .prepare_cached(statement)?
        .query_map([identifier], |row| row.get(0))?
        .collect()
}

/// The documents whose search rows a page leaves behind the records, by `document_row`. Every
/// write of a record names them here, and the page writes them once, after its last record.
///
/// FTS5 writes what it has gathered to the file as a segment of its own whenever SQLite opens a
/// savepoint, which it does for every statement that can change several rows, and whenever a
/// row comes with a lower rowid than the one before. A page that wrote each search row beside
/// its record took five times as long as one that writes them together, in the order of their
/// rows, with statements that change one row each.
#[derive(Default)]
struct StaleSearchRows {
    /// The detail search row is written anew, or removed with a document that is gone.
    details: BTreeSet<i64>,
    /// The text search row is removed, because the text is.
    texts: BTreeSet<i64>,
}

impl StaleSearchRows {
    /// After the upsert of a member, sender, category, or tag that changed it: the documents
    /// that show its name follow.
    fn follow(
        &mut self,
        transaction: &Transaction<'_>,
        written: usize,
        record: ShownRecord<'_>,
    ) -> rusqlite::Result<usize> {
        if written > 0 {
            self.details.extend(documents_showing(transaction, record)?);
        }
        Ok(written)
    }

    /// Writes the detail search rows from the records as they stand: the title, the names the
    /// document refers to, the document's own date, its field values, and its summary. Both the
    /// trigram table (`document_detail_search`) and the word-prefix table (`document_detail_words`)
    /// are updated in ascending `document_row` order.
    fn rewrite(self, transaction: &Transaction<'_>) -> rusqlite::Result<()> {
        for document_row in &self.texts {
            run(
                transaction,
                "DELETE FROM document_text_search WHERE rowid = ?1",
                [document_row],
            )?;
        }
        for document_row in &self.details {
            run(
                transaction,
                "DELETE FROM document_detail_search WHERE rowid = ?1",
                [document_row],
            )?;
            run(
                transaction,
                "DELETE FROM document_detail_words WHERE rowid = ?1",
                [document_row],
            )?;
            let details: Option<(String, [Option<String>; 7])> = transaction
                .prepare_cached(
                    "SELECT documents.id, documents.title, senders.name, categories.name, \
                     (SELECT group_concat(tags.name, char(10)) FROM document_tags \
                      JOIN tags ON tags.id = document_tags.tag_id WHERE document_tags.document_id = documents.id), \
                     members.display_name, documents.document_date, documents.summary \
                     FROM documents LEFT JOIN senders ON senders.id = documents.sender_id \
                     LEFT JOIN categories ON categories.id = documents.category_id \
                     LEFT JOIN members ON members.id = documents.member_id WHERE documents.document_row = ?1",
                )?
                .query_row([document_row], |row| {
                    Ok((
                        row.get(0)?,
                        [
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                            row.get(5)?,
                            row.get(6)?,
                            row.get(7)?,
                        ],
                    ))
                })
                .optional()?;
            if let Some((document_id, [title, sender, category, tags, person, document_date, summary])) = details {
                let mut field_statement = transaction.prepare_cached(
                    "SELECT field_type, value_text, value_number FROM extracted_fields WHERE document_id = ?1",
                )?;
                let extracted_fields = field_statement
                    .query_map([&document_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                    .collect::<rusqlite::Result<Vec<(String, Option<String>, Option<f64>)>>>()?;
                let fields = format_indexed_fields(document_date.as_deref(), &extracted_fields);
                let title = title.map(|value| index_detail_text(&value));
                let sender = sender.map(|value| index_detail_text(&value));
                let category = category.map(|value| index_detail_text(&value));
                let tags = tags.map(|value| index_detail_text(&value));
                let person = person.map(|value| index_detail_text(&value));
                let fields = fields.map(|value| index_detail_text(&value));
                let summary = summary.map(|value| index_detail_text(&value));
                run(
                    transaction,
                    "INSERT INTO document_detail_search \
                     (rowid, title, sender, category, tags, person, fields, summary) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![document_row, title, sender, category, tags, person, fields, summary],
                )?;
                run(
                    transaction,
                    "INSERT INTO document_detail_words \
                     (rowid, title, sender, category, tags, person, fields, summary) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![document_row, title, sender, category, tags, person, fields, summary],
                )?;
            }
        }
        Ok(())
    }
}

fn recreate_database(path: &Path) -> rusqlite::Result<Connection> {
    for suffix in ["", "-wal", "-shm"] {
        let mut file = path.as_os_str().to_owned();
        file.push(suffix);
        let _ = std::fs::remove_file(file);
    }
    let connection = Connection::open(path)?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    // Nothing is flushed while the empty copy is created. A power failure then leaves a file of
    // another version or none, which the next start replaces.
    connection.pragma_update(None, "synchronous", "OFF")?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.execute_batch(&format!(
        "BEGIN; {SCHEMA} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
    ))?;
    Ok(connection)
}

fn format_indexed_fields(
    document_date: Option<&str>,
    fields: &[(String, Option<String>, Option<f64>)],
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    if let Some(date) = document_date {
        push_date_forms(&mut parts, date);
    }
    for (field_type, value_text, value_number) in fields {
        match (field_type.as_str(), value_text.as_deref(), value_number) {
            ("number", _, Some(number)) => push_number_forms(&mut parts, *number),
            ("date", Some(date), _) => push_date_forms(&mut parts, date),
            ("text", Some(text), _) => {
                parts.push(text.to_owned());
                if let Some((compact, spaced)) = iban_forms(text) {
                    parts.push(compact);
                    parts.push(spaced);
                }
            }
            (_, Some(text), _) => parts.push(text.to_owned()),
            _ => {}
        }
    }
    (!parts.is_empty()).then(|| parts.join("\n"))
}

fn push_date_forms(parts: &mut Vec<String>, iso: &str) {
    parts.push(iso.to_owned());
    let bytes = iso.as_bytes();
    if bytes.len() == 10 && bytes[4] == b'-' && bytes[7] == b'-' {
        parts.push(format!("{}.{}.{}", &iso[8..10], &iso[5..7], &iso[0..4]));
    }
}

fn push_number_forms(parts: &mut Vec<String>, value: f64) {
    let number = if value == 0.0 { 0.0 } else { value };
    let plain = format!("{number:.2}");
    parts.push(plain.clone());
    parts.push(plain.replace('.', ","));
    let (signed_integer, fraction) = plain.split_once('.').unwrap_or((&plain, ""));
    let (sign, integer_digits) = signed_integer
        .strip_prefix('-')
        .map_or(("", signed_integer), |digits| ("-", digits));
    if number.abs() >= 1000.0 {
        let german = group_thousands(integer_digits, '.');
        let english = group_thousands(integer_digits, ',');
        parts.push(format!("{sign}{german},{fraction}"));
        parts.push(format!("{sign}{english}.{fraction}"));
    }
    if number.fract() == 0.0 {
        parts.push(format!("{sign}{integer_digits}"));
        if number.abs() >= 1000.0 {
            parts.push(format!("{sign}{}", group_thousands(integer_digits, '.')));
            parts.push(format!("{sign}{}", group_thousands(integer_digits, ',')));
        }
    }
}

fn group_thousands(digits: &str, separator: char) -> String {
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(separator);
        }
        grouped.push(character);
    }
    grouped
}

fn iban_forms(text: &str) -> Option<(String, String)> {
    let compact: String = text
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .collect();
    let bytes = compact.as_bytes();
    let valid = (15..=34).contains(&bytes.len())
        && bytes[0].is_ascii_alphabetic()
        && bytes[1].is_ascii_alphabetic()
        && bytes[2].is_ascii_digit()
        && bytes[3].is_ascii_digit()
        && bytes.iter().all(u8::is_ascii_alphanumeric);
    if !valid {
        return None;
    }
    let spaced = bytes
        .chunks(4)
        .map(|chunk| std::str::from_utf8(chunk).expect("ASCII IBAN chunk"))
        .collect::<Vec<_>>()
        .join(" ");
    Some((compact, spaced))
}

fn is_combining_mark(character: char) -> bool {
    matches!(
        character,
        '\u{0300}'..='\u{036F}'
            | '\u{1AB0}'..='\u{1AFF}'
            | '\u{1DC0}'..='\u{1DFF}'
            | '\u{20D0}'..='\u{20FF}'
            | '\u{FE20}'..='\u{FE2F}'
    )
}

fn normalize_for_index(text: &str) -> (String, String, bool) {
    let mut base = String::with_capacity(text.len());
    let mut expanded = String::with_capacity(text.len());
    let mut has_umlaut = false;
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        if matches!(character, 'ß' | 'ẞ') {
            base.push_str("ss");
            expanded.push_str("ss");
            continue;
        }
        let mut next_is_diaeresis = false;
        while let Some(&next) = chars.peek()
            && is_combining_mark(next)
        {
            if next == '\u{0308}' {
                next_is_diaeresis = true;
            }
            chars.next();
        }
        if next_is_diaeresis
            && let Some(digraph) = match character {
                'a' => Some("ae"),
                'A' => Some("Ae"),
                'o' => Some("oe"),
                'O' => Some("Oe"),
                'u' => Some("ue"),
                'U' => Some("Ue"),
                _ => None,
            }
        {
            has_umlaut = true;
            base.push(character);
            expanded.push_str(digraph);
            continue;
        }
        if let Some(digraph) = match character {
            'ä' => Some("ae"),
            'Ä' => Some("Ae"),
            'ö' => Some("oe"),
            'Ö' => Some("Oe"),
            'ü' => Some("ue"),
            'Ü' => Some("Ue"),
            _ => None,
        } {
            has_umlaut = true;
            base.push(character);
            expanded.push_str(digraph);
            continue;
        }
        base.push(character);
        expanded.push(character);
    }
    (base, expanded, has_umlaut)
}

fn index_detail_text(text: &str) -> String {
    let (mut base, expanded, has_umlaut) = normalize_for_index(text);
    if has_umlaut {
        base.push(' ');
        base.push_str(&expanded);
    }
    base
}

fn index_body_text(markdown: &str) -> Cow<'_, str> {
    let needs_work = markdown
        .chars()
        .any(|character| matches!(character, 'ß' | 'ẞ' | 'ä' | 'Ä' | 'ö' | 'Ö' | 'ü' | 'Ü' | '\u{0308}'));
    if !needs_work {
        return Cow::Borrowed(markdown);
    }
    let (mut out, _, has_umlaut) = normalize_for_index(markdown);
    if has_umlaut {
        for word in markdown.split(|character: char| !character.is_alphanumeric() && !is_combining_mark(character)) {
            if word.is_empty() {
                continue;
            }
            let (_, expanded, word_umlaut) = normalize_for_index(word);
            if word_umlaut {
                out.push(' ');
                out.push_str(&expanded);
            }
        }
    }
    Cow::Owned(out)
}

/// Empties every record table and resets what the mirror row says of the copy's extent.
fn start_over(transaction: &Transaction<'_>) -> rusqlite::Result<()> {
    let mut removed = 0;
    // The documents go first, and their tag links, fields, and texts with them.
    for table in ["documents", "members", "senders", "categories", "tags"] {
        removed += run(transaction, &format!("DELETE FROM {table}"), [])?;
    }
    for table in [
        "document_detail_search",
        "document_detail_words",
        "document_text_search",
    ] {
        run(
            transaction,
            &format!("INSERT INTO {table} ({table}) VALUES ('delete-all')"),
            [],
        )?;
    }
    run(
        transaction,
        "UPDATE mirror SET journal_cursor = NULL, fill_complete = 0, synchronized_at = NULL, \
         content_revision = content_revision + ?1",
        [removed > 0],
    )?;
    Ok(())
}

fn write_page(
    transaction: &Transaction<'_>,
    requested_after: Option<&JournalCursor>,
    page: &JournalPage,
    applied_at: Timestamp,
) -> rusqlite::Result<PageApplication> {
    let advanced = run(
        transaction,
        "UPDATE mirror SET journal_cursor = ?1, fill_complete = max(fill_complete, ?2), \
         synchronized_at = CASE WHEN ?2 THEN ?3 ELSE synchronized_at END \
         WHERE journal_cursor IS ?4",
        params![
            page.cursor.as_str(),
            page.complete,
            applied_at.0,
            requested_after.map(JournalCursor::as_str)
        ],
    )?;
    if advanced == 0 {
        return Ok(PageApplication::CursorMoved);
    }
    // The records a document refers to are written before it, and the removals come last, so
    // every reference resolves whatever the order of the page's entries was.
    let mut changed = 0;
    let mut stale = StaleSearchRows::default();
    for member in &page.members {
        let written = run(
            transaction,
            "INSERT INTO members (id, display_name) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE \
             SET display_name = excluded.display_name WHERE display_name IS NOT excluded.display_name",
            params![member.identifier.as_str(), member.display_name],
        )?;
        changed += stale.follow(transaction, written, ShownRecord::Member(member.identifier.as_str()))?;
    }
    for sender in &page.senders {
        let written = run(
            transaction,
            "INSERT INTO senders (id, name) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE \
             SET name = excluded.name WHERE name IS NOT excluded.name",
            params![sender.identifier.as_str(), sender.name],
        )?;
        changed += stale.follow(transaction, written, ShownRecord::Sender(sender.identifier.as_str()))?;
    }
    for category in &page.categories {
        let written = run(
            transaction,
            "INSERT INTO categories (id, name, expected_fields) VALUES (?1, ?2, ?3) ON CONFLICT (id) DO UPDATE \
             SET name = excluded.name, expected_fields = excluded.expected_fields \
             WHERE name IS NOT excluded.name OR expected_fields IS NOT excluded.expected_fields",
            params![
                category.identifier.as_str(),
                category.name,
                serde_json::Value::from(category.expected_fields.clone()).to_string()
            ],
        )?;
        changed += stale.follow(
            transaction,
            written,
            ShownRecord::Category(category.identifier.as_str()),
        )?;
    }
    for tag in &page.tags {
        let written = run(
            transaction,
            "INSERT INTO tags (id, name, color_hex) VALUES (?1, ?2, ?3) ON CONFLICT (id) DO UPDATE \
             SET name = excluded.name, color_hex = excluded.color_hex \
             WHERE name IS NOT excluded.name OR color_hex IS NOT excluded.color_hex",
            params![tag.identifier.as_str(), tag.name, tag.color_hex],
        )?;
        changed += stale.follow(transaction, written, ShownRecord::Tag(tag.identifier.as_str()))?;
    }
    for document in &page.documents {
        // A document is delivered again after writes of the archive that a client does not
        // read, and such a delivery must not count as a change of the records.
        if documents(transaction, Some(&document.identifier))?.first() != Some(document) {
            write_document(transaction, document, &mut stale)?;
            changed += 1;
        }
    }
    for removed in &page.removed {
        changed += remove_record(transaction, removed, &mut stale)?;
    }
    stale.rewrite(transaction)?;
    if changed > 0 {
        run(
            transaction,
            "UPDATE mirror SET content_revision = content_revision + 1",
            [],
        )?;
    }
    let unsettled_documents = transaction.query_row(
        "SELECT count(*) AS unsettled FROM documents WHERE status NOT IN ('archived', 'failed')",
        [],
        |row| stored_count(row, "unsettled"),
    )?;
    Ok(PageApplication::Applied { unsettled_documents })
}

/// The row is updated in place, so its `document_row` and whatever else refers to the document
/// stay. A text that was retrieved for another content goes, so the document awaits its text
/// again, and the detail search row is written anew.
fn write_document(
    transaction: &Transaction<'_>,
    document: &DocumentRecord,
    stale: &mut StaleSearchRows,
) -> rusqlite::Result<()> {
    let (person_assignment, member) = match &document.person {
        PersonAssignment::Household => ("household", None),
        PersonAssignment::Member(member) => ("member", Some(member.as_str())),
        PersonAssignment::Unassigned => ("unassigned", None),
    };
    let identifier = document.identifier.as_str();
    let original = document.original.map(|digest| digest.hexadecimal());
    let superseded_text: Option<i64> = transaction
        .prepare_cached(
            "SELECT document_row FROM documents JOIN extracted_texts USING (document_row) \
             WHERE id = ?1 AND original_sha256 IS NOT ?2",
        )?
        .query_row(params![identifier, original], |row| row.get(0))
        .optional()?;
    if let Some(document_row) = superseded_text {
        run(
            transaction,
            "DELETE FROM extracted_texts WHERE document_row = ?1",
            [document_row],
        )?;
        stale.texts.insert(document_row);
    }
    let document_row: i64 = transaction
        .prepare_cached(
            "INSERT INTO documents (id, status, failure_reason, title, document_date, sender_id, category_id, \
         person_assignment, member_id, summary, media_type, byte_size, page_count, original_sha256, arrived_at, \
         amount, currency) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17) \
         ON CONFLICT (id) DO UPDATE SET status = excluded.status, failure_reason = excluded.failure_reason, \
         title = excluded.title, document_date = excluded.document_date, sender_id = excluded.sender_id, \
         category_id = excluded.category_id, person_assignment = excluded.person_assignment, \
         member_id = excluded.member_id, summary = excluded.summary, media_type = excluded.media_type, \
         byte_size = excluded.byte_size, page_count = excluded.page_count, \
         original_sha256 = excluded.original_sha256, arrived_at = excluded.arrived_at, \
         amount = excluded.amount, currency = excluded.currency RETURNING document_row",
        )?
        .query_row(
            params![
                identifier,
                document.condition.status_name(),
                document.condition.failure_reason_name(),
                document.title,
                document.document_date.map(|date| date.iso_text()),
                document.sender.as_ref().map(SenderIdentifier::as_str),
                document.category.as_ref().map(CategoryIdentifier::as_str),
                person_assignment,
                member,
                document.summary,
                document.media_type,
                i64::try_from(document.byte_size).unwrap_or(i64::MAX),
                document.page_count,
                original,
                document.arrived_at.0,
                match document.fields.get("amount") {
                    Some(ExtractedField {
                        value: FieldValue::Number(amount),
                        ..
                    }) => Some(*amount),
                    _ => None,
                },
                match document.fields.get("currency") {
                    Some(ExtractedField {
                        value: FieldValue::Text(currency),
                        ..
                    }) => Some(currency.as_str()),
                    _ => None,
                }
            ],
            |row| row.get(0),
        )?;
    run(
        transaction,
        "DELETE FROM document_tags WHERE document_id = ?1",
        [identifier],
    )?;
    for tag in &document.tags {
        run(
            transaction,
            "INSERT INTO document_tags (document_id, tag_id) VALUES (?1, ?2)",
            [identifier, tag.as_str()],
        )?;
    }
    run(
        transaction,
        "DELETE FROM extracted_fields WHERE document_id = ?1",
        [identifier],
    )?;
    for (key, field) in &document.fields {
        let (field_type, value_text, value_number) = match &field.value {
            FieldValue::Text(text) => ("text", Some(text.clone()), None),
            FieldValue::Number(number) => ("number", None, Some(*number)),
            FieldValue::Date(date) => ("date", Some(date.iso_text()), None),
        };
        run(
            transaction,
            "INSERT INTO extracted_fields (document_id, field_key, field_type, value_text, value_number, confidence) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![identifier, key, field_type, value_text, value_number, field.confidence],
        )?;
    }
    stale.details.insert(document_row);
    Ok(())
}

/// The number of rows removed: one, or none for a record the copy never held. A document's
/// search rows go with it, and the documents that showed another record are indexed without it.
fn remove_record(
    transaction: &Transaction<'_>,
    removed: &RemovedRecord,
    stale: &mut StaleSearchRows,
) -> rusqlite::Result<usize> {
    let (shown, statement) = match removed {
        RemovedRecord::Document(document) => {
            let document_row: Option<i64> = transaction
                .prepare_cached("DELETE FROM documents WHERE id = ?1 RETURNING document_row")?
                .query_row([document.as_str()], |row| row.get(0))
                .optional()?;
            let Some(document_row) = document_row else {
                return Ok(0);
            };
            stale.details.insert(document_row);
            stale.texts.insert(document_row);
            return Ok(1);
        }
        RemovedRecord::Member(member) => (
            ShownRecord::Member(member.as_str()),
            "DELETE FROM members WHERE id = ?1",
        ),
        RemovedRecord::Sender(sender) => (
            ShownRecord::Sender(sender.as_str()),
            "DELETE FROM senders WHERE id = ?1",
        ),
        RemovedRecord::Category(category) => (
            ShownRecord::Category(category.as_str()),
            "DELETE FROM categories WHERE id = ?1",
        ),
        RemovedRecord::Tag(tag) => (ShownRecord::Tag(tag.as_str()), "DELETE FROM tags WHERE id = ?1"),
    };
    stale.details.extend(documents_showing(transaction, shown)?);
    let identifier = match shown {
        ShownRecord::Member(member) => {
            // What the archive says of a document without a member: an archived one concerns the
            // household, and any other is not yet assigned.
            run(
                transaction,
                "UPDATE documents SET member_id = NULL, \
                 person_assignment = CASE WHEN status = 'archived' THEN 'household' ELSE 'unassigned' END \
                 WHERE member_id = ?1",
                [member],
            )?;
            member
        }
        ShownRecord::Sender(identifier) | ShownRecord::Category(identifier) | ShownRecord::Tag(identifier) => {
            identifier
        }
    };
    run(transaction, statement, [identifier])
}

/// One document, or every document in the order of the identifiers.
fn documents(connection: &Connection, only: Option<&DocumentIdentifier>) -> rusqlite::Result<Vec<DocumentRecord>> {
    let only = only.map(DocumentIdentifier::as_str);
    let selection = |column: &str| match only {
        Some(_) => format!("WHERE {column} = ?1"),
        None => String::new(),
    };
    let mut tags: BTreeMap<String, BTreeSet<TagIdentifier>> = BTreeMap::new();
    let mut statement = connection.prepare_cached(&format!(
        "SELECT document_id, tag_id FROM document_tags {}",
        selection("document_id")
    ))?;
    let mut rows = statement.query(rusqlite::params_from_iter(only))?;
    while let Some(row) = rows.next()? {
        tags.entry(row.get("document_id")?)
            .or_default()
            .insert(stored(row, "tag_id", TagIdentifier::parse)?);
    }

    let mut fields: BTreeMap<String, BTreeMap<String, ExtractedField>> = BTreeMap::new();
    let mut statement = connection.prepare_cached(&format!(
        "SELECT document_id, field_key, field_type, value_text, value_number, confidence FROM extracted_fields {}",
        selection("document_id")
    ))?;
    let mut rows = statement.query(rusqlite::params_from_iter(only))?;
    while let Some(row) = rows.next()? {
        fields.entry(row.get("document_id")?).or_default().insert(
            row.get("field_key")?,
            ExtractedField {
                value: stored_field_value(row)?,
                confidence: row.get("confidence")?,
            },
        );
    }

    let mut statement = connection.prepare_cached(&format!(
        "SELECT id, status, failure_reason, title, document_date, sender_id, category_id, person_assignment, \
         member_id, summary, media_type, byte_size, page_count, original_sha256, arrived_at FROM documents {} \
         ORDER BY id",
        selection("id")
    ))?;
    let mut rows = statement.query(rusqlite::params_from_iter(only))?;
    let mut documents = Vec::new();
    while let Some(row) = rows.next()? {
        let identifier: String = row.get("id")?;
        let status: String = row.get("status")?;
        let failure_reason: Option<String> = row.get("failure_reason")?;
        let person = match row.get::<_, String>("person_assignment")?.as_str() {
            "household" => PersonAssignment::Household,
            "unassigned" => PersonAssignment::Unassigned,
            _ => PersonAssignment::Member(stored(row, "member_id", MemberIdentifier::parse)?),
        };
        documents.push(DocumentRecord {
            condition: DocumentCondition::parse(&status, failure_reason.as_deref())
                .ok_or_else(|| unreadable(row, "status"))?,
            title: row.get("title")?,
            document_date: stored_optional(row, "document_date", CalendarDate::parse)?,
            sender: stored_optional(row, "sender_id", SenderIdentifier::parse)?,
            category: stored_optional(row, "category_id", CategoryIdentifier::parse)?,
            person,
            summary: row.get("summary")?,
            media_type: row.get("media_type")?,
            byte_size: stored_count(row, "byte_size")?,
            page_count: row.get("page_count")?,
            original: stored_optional(row, "original_sha256", ContentDigest::parse_hexadecimal)?,
            arrived_at: Timestamp(row.get("arrived_at")?),
            tags: tags.remove(&identifier).unwrap_or_default(),
            fields: fields.remove(&identifier).unwrap_or_default(),
            identifier: stored(row, "id", DocumentIdentifier::parse)?,
        });
    }
    Ok(documents)
}

/// The value of a row of `extracted_fields`, from its `field_type`, `value_text`, and
/// `value_number`.
pub(crate) fn stored_field_value(row: &Row<'_>) -> rusqlite::Result<FieldValue> {
    Ok(
        match (
            row.get::<_, String>("field_type")?.as_str(),
            row.get::<_, Option<String>>("value_text")?,
            row.get::<_, Option<f64>>("value_number")?,
        ) {
            ("text", Some(text), None) => FieldValue::Text(text),
            ("number", None, Some(number)) => FieldValue::Number(number),
            ("date", Some(date), None) => {
                FieldValue::Date(CalendarDate::parse(&date).ok_or_else(|| unreadable(row, "value_text"))?)
            }
            _ => return Err(unreadable(row, "field_type")),
        },
    )
}

/// A text column as the domain value it was written from.
pub(crate) fn stored<Value>(
    row: &Row<'_>,
    column: &str,
    parse: impl Fn(&str) -> Option<Value>,
) -> rusqlite::Result<Value> {
    stored_optional(row, column, parse)?.ok_or_else(|| unreadable(row, column))
}

pub(crate) fn stored_optional<Value>(
    row: &Row<'_>,
    column: &str,
    parse: impl Fn(&str) -> Option<Value>,
) -> rusqlite::Result<Option<Value>> {
    match row.get::<_, Option<String>>(column)? {
        Some(text) => parse(&text).map(Some).ok_or_else(|| unreadable(row, column)),
        None => Ok(None),
    }
}

/// An integer column that holds a count or a size.
pub(crate) fn stored_count(row: &Row<'_>, column: &str) -> rusqlite::Result<u64> {
    u64::try_from(row.get::<_, i64>(column)?).map_err(|_| unreadable(row, column))
}

/// A row that this module did not write.
pub(crate) fn unreadable(row: &Row<'_>, column: &str) -> rusqlite::Error {
    let index = row.as_ref().column_index(column).unwrap_or(0);
    rusqlite::Error::InvalidColumnType(index, column.to_owned(), Type::Text)
}
