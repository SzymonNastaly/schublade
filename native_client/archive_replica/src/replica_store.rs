//! `replica.sqlite`, the one file of the copy, and the only module with SQL. The coordinator
//! thread owns the one connection that writes. `replica_schema.sql` is the schema.
//!
//! The copy is disposable. Everything in it comes back from the archive, so a file of another
//! schema version, or one SQLite cannot read, is replaced by an empty one.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use archive_access::{ArchiveAuthorization, ContentDigest, DocumentIdentifier, PermissionLevel, Timestamp};
use rusqlite::types::Type;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, Transaction, params};

use crate::replica_records::{
    ArchiveRecords, CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord,
    ExtractedField, FieldValue, JournalCursor, JournalPage, MemberIdentifier, MemberRecord, PersonAssignment,
    RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};

/// The `user_version` of a file with the schema of `replica_schema.sql`. Raise it with every
/// change of the schema: a file of another version is replaced and filled again.
const SCHEMA_VERSION: u32 = 1;
const SCHEMA: &str = include_str!("replica_schema.sql");

/// More than the statements this module runs repeatedly, so none is prepared twice.
const STATEMENT_CACHE_CAPACITY: usize = 48;

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
    /// Rises with every transaction that changed a record.
    pub content_revision: u64,
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
    /// Opens the copy, or replaces a file that is not a copy of this schema version by an empty
    /// one.
    pub fn open(path: &Path) -> rusqlite::Result<ReplicaStore> {
        let existing = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let current = Connection::open_with_flags(path, existing).and_then(|connection| {
            let version: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
            Ok((version == SCHEMA_VERSION).then_some(connection))
        });
        let connection = match current {
            Ok(Some(connection)) => connection,
            Ok(None) | Err(_) => {
                for suffix in ["", "-wal", "-shm"] {
                    let mut file = path.as_os_str().to_owned();
                    file.push(suffix);
                    // A file that is not there needs no removal, and one that cannot be removed
                    // fails the creation below.
                    let _ = std::fs::remove_file(file);
                }
                let connection = Connection::open(path)?;
                // Nothing is flushed while the empty copy is created. A power failure then leaves
                // a file of another version or none, which the next start replaces.
                connection.pragma_update(None, "synchronous", "OFF")?;
                connection.pragma_update(None, "journal_mode", "WAL")?;
                connection.execute_batch(&format!(
                    "BEGIN; {SCHEMA} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
                ))?;
                connection
            }
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

/// Empties every record table and resets what the mirror row says of the copy's extent.
fn start_over(transaction: &Transaction<'_>) -> rusqlite::Result<()> {
    let mut removed = 0;
    // The documents go first, and their tag links and fields with them.
    for table in ["documents", "members", "senders", "categories", "tags"] {
        removed += run(transaction, &format!("DELETE FROM {table}"), [])?;
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
    for member in &page.members {
        changed += run(
            transaction,
            "INSERT INTO members (id, display_name) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE \
             SET display_name = excluded.display_name WHERE display_name IS NOT excluded.display_name",
            params![member.identifier.as_str(), member.display_name],
        )?;
    }
    for sender in &page.senders {
        changed += run(
            transaction,
            "INSERT INTO senders (id, name) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE \
             SET name = excluded.name WHERE name IS NOT excluded.name",
            params![sender.identifier.as_str(), sender.name],
        )?;
    }
    for category in &page.categories {
        changed += run(
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
    }
    for tag in &page.tags {
        changed += run(
            transaction,
            "INSERT INTO tags (id, name, color_hex) VALUES (?1, ?2, ?3) ON CONFLICT (id) DO UPDATE \
             SET name = excluded.name, color_hex = excluded.color_hex \
             WHERE name IS NOT excluded.name OR color_hex IS NOT excluded.color_hex",
            params![tag.identifier.as_str(), tag.name, tag.color_hex],
        )?;
    }
    for document in &page.documents {
        // A document is delivered again after writes of the archive that a client does not
        // read, and such a delivery must not count as a change of the records.
        if documents(transaction, Some(&document.identifier))?.first() != Some(document) {
            write_document(transaction, document)?;
            changed += 1;
        }
    }
    for removed in &page.removed {
        changed += remove_record(transaction, removed)?;
    }
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
/// stay.
fn write_document(transaction: &Transaction<'_>, document: &DocumentRecord) -> rusqlite::Result<()> {
    let (person_assignment, member) = match &document.person {
        PersonAssignment::Household => ("household", None),
        PersonAssignment::Member(member) => ("member", Some(member.as_str())),
        PersonAssignment::Unassigned => ("unassigned", None),
    };
    let identifier = document.identifier.as_str();
    run(
        transaction,
        "INSERT INTO documents (id, status, failure_reason, title, document_date, sender_id, category_id, \
         person_assignment, member_id, summary, media_type, byte_size, page_count, original_sha256, arrived_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15) \
         ON CONFLICT (id) DO UPDATE SET status = excluded.status, failure_reason = excluded.failure_reason, \
         title = excluded.title, document_date = excluded.document_date, sender_id = excluded.sender_id, \
         category_id = excluded.category_id, person_assignment = excluded.person_assignment, \
         member_id = excluded.member_id, summary = excluded.summary, media_type = excluded.media_type, \
         byte_size = excluded.byte_size, page_count = excluded.page_count, \
         original_sha256 = excluded.original_sha256, arrived_at = excluded.arrived_at",
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
            document.original.map(|digest| digest.hexadecimal()),
            document.arrived_at.0
        ],
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
    Ok(())
}

/// The number of rows removed: one, or none for a record the copy never held.
fn remove_record(transaction: &Transaction<'_>, removed: &RemovedRecord) -> rusqlite::Result<usize> {
    match removed {
        RemovedRecord::Document(document) => {
            run(transaction, "DELETE FROM documents WHERE id = ?1", [document.as_str()])
        }
        RemovedRecord::Member(member) => {
            // What the archive says of a document without a member: an archived one concerns the
            // household, and any other is not yet assigned.
            run(
                transaction,
                "UPDATE documents SET member_id = NULL, \
                 person_assignment = CASE WHEN status = 'archived' THEN 'household' ELSE 'unassigned' END \
                 WHERE member_id = ?1",
                [member.as_str()],
            )?;
            run(transaction, "DELETE FROM members WHERE id = ?1", [member.as_str()])
        }
        RemovedRecord::Sender(sender) => run(transaction, "DELETE FROM senders WHERE id = ?1", [sender.as_str()]),
        RemovedRecord::Category(category) => {
            run(transaction, "DELETE FROM categories WHERE id = ?1", [category.as_str()])
        }
        RemovedRecord::Tag(tag) => run(transaction, "DELETE FROM tags WHERE id = ?1", [tag.as_str()]),
    }
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
        let value = match (
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
        };
        fields.entry(row.get("document_id")?).or_default().insert(
            row.get("field_key")?,
            ExtractedField {
                value,
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

/// A text column as the domain value it was written from.
fn stored<Value>(row: &Row<'_>, column: &str, parse: impl Fn(&str) -> Option<Value>) -> rusqlite::Result<Value> {
    stored_optional(row, column, parse)?.ok_or_else(|| unreadable(row, column))
}

fn stored_optional<Value>(
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
fn stored_count(row: &Row<'_>, column: &str) -> rusqlite::Result<u64> {
    u64::try_from(row.get::<_, i64>(column)?).map_err(|_| unreadable(row, column))
}

/// A row that this module did not write.
fn unreadable(row: &Row<'_>, column: &str) -> rusqlite::Error {
    let index = row.as_ref().column_index(column).unwrap_or(0);
    rusqlite::Error::InvalidColumnType(index, column.to_owned(), Type::Text)
}
