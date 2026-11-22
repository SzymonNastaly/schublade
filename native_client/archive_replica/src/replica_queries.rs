//! What a window reads from the copy: the listings with their search, the sidebar's counts, one
//! document in full, and what a representation is kept under. A `ReplicaQueries` is a read-only
//! connection of its own. The copy keeps a write-ahead log, so a read never waits for the
//! coordinator's writes, and each answer comes from one snapshot.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Duration;

use archive_access::{ArchiveAddress, ContentDigest, DocumentIdentifier, Timestamp};
use rusqlite::types::{Type, Value};
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, ToSql};

use crate::document_detail::{DetailField, DocumentDetail, DocumentPerson, OriginalKind, suggested_file_name};
use crate::document_listing::{
    Amount, DocumentListing, DocumentRow, LibraryScope, ListingHeading, ListingOrder, ListingRequest, ListingRow,
    NamedScope, ReplicaFacets, RowPassage, ScopeCount,
};
use crate::replica_records::{
    CalendarDate, CategoryIdentifier, DocumentCondition, FieldValue, MemberIdentifier, SenderIdentifier, TagIdentifier,
};
use crate::replica_store::{stored, stored_count, stored_field_value, stored_optional, unreadable};
use crate::search_expression::{SearchExpression, folded};

/// How long a document counts as recently added.
const RECENT_ADDITION: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// As many documents under `TextMatched`, from the newest, show the passage a search found. A
/// later one shows its summary. Each passage reads a whole text, and a term such as "der" finds
/// every text of the library, which a person narrows down and does not read to its end.
const EXCERPTED_DOCUMENTS: usize = 200;

/// More than the statements of every scope in every order, so none is prepared twice.
const STATEMENT_CACHE_CAPACITY: usize = 64;
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

pub struct ReplicaQueries {
    connection: Connection,
}

/// Where the copy stands with the extracted text of a document it holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextStanding {
    Held(String),
    /// The archive answered that it holds no text of the document.
    ArchiveHoldsNone,
    /// The copy has not asked yet, or the document is not archived yet.
    NotRetrieved {
        original: Option<ContentDigest>,
    },
}

/// What a representation of a document is kept under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RepresentationSource {
    /// `None` until the archive has recorded the content.
    pub original: Option<ContentDigest>,
    pub kind: OriginalKind,
}

impl ReplicaQueries {
    /// Opens a copy that `ReplicaStore::open` created.
    pub fn open(path: &Path) -> rusqlite::Result<ReplicaQueries> {
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let connection = Connection::open_with_flags(path, flags)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        connection.set_prepared_statement_cache_capacity(STATEMENT_CACHE_CAPACITY);
        Ok(ReplicaQueries { connection })
    }

    /// The rows of the request as the copy holds them now. `now` decides what was added
    /// recently.
    pub fn list_documents(&mut self, request: &ListingRequest, now: Timestamp) -> rusqlite::Result<DocumentListing> {
        let snapshot = self.connection.transaction()?;
        let content_revision = content_revision(&snapshot)?;
        let rows = match request {
            ListingRequest::Browse { scope, order } => browsed_rows(&snapshot, scope, *order, now)?,
            ListingRequest::Search { scope, text } => {
                let expression = SearchExpression::parse(text);
                if expression.terms().is_empty() {
                    browsed_rows(&snapshot, scope, ListingOrder::DocumentDate, now)?
                } else {
                    found_rows(&snapshot, scope, &expression, now)?
                }
            }
        };
        Ok(DocumentListing::assemble(request.clone(), content_revision, rows))
    }

    pub fn facets(&mut self) -> rusqlite::Result<ReplicaFacets> {
        let snapshot = self.connection.transaction()?;
        let counted = |statement: &str, scope: &dyn Fn(&str) -> Option<LibraryScope>| {
            snapshot
                .prepare_cached(statement)?
                .query_map([], |row| {
                    Ok(ScopeCount {
                        scope: NamedScope {
                            scope: stored(row, "id", scope)?,
                            name: row.get("name")?,
                        },
                        documents: stored_count(row, "document_count")?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<ScopeCount>>>()
        };
        let members = counted(
            "SELECT members.id, members.display_name AS name, count(documents.document_row) AS document_count \
             FROM members LEFT JOIN documents ON documents.member_id = members.id \
             GROUP BY members.id ORDER BY name COLLATE NOCASE, members.id",
            &|member| MemberIdentifier::parse(member).map(LibraryScope::Member),
        )?;
        let categories = counted(
            "SELECT categories.id, categories.name, count(*) AS document_count \
             FROM categories JOIN documents ON documents.category_id = categories.id \
             GROUP BY categories.id ORDER BY document_count DESC, categories.name COLLATE NOCASE, categories.id",
            &|category| CategoryIdentifier::parse(category).map(LibraryScope::Category),
        )?;
        let tags = counted(
            "SELECT tags.id, tags.name, count(*) AS document_count \
             FROM tags JOIN document_tags ON document_tags.tag_id = tags.id \
             GROUP BY tags.id ORDER BY document_count DESC, tags.name COLLATE NOCASE, tags.id",
            &|tag| TagIdentifier::parse(tag).map(LibraryScope::Tag),
        )?;
        snapshot
            .prepare_cached(
                "SELECT count(*) AS documents, \
                 count(*) FILTER (WHERE status NOT IN ('archived', 'failed')) AS in_ingestion, \
                 count(*) FILTER (WHERE status = 'failed') AS failed, \
                 count(*) FILTER (WHERE person_assignment = 'household') AS household FROM documents",
            )?
            .query_row([], |row| {
                Ok(ReplicaFacets {
                    content_revision: content_revision(&snapshot)?,
                    documents: stored_count(row, "documents")?,
                    documents_in_ingestion: stored_count(row, "in_ingestion")?,
                    documents_failed: stored_count(row, "failed")?,
                    household_documents: stored_count(row, "household")?,
                    members,
                    categories,
                    tags,
                })
            })
    }

    /// One document as an inspector shows it, or `None` when the copy does not hold it.
    pub fn document(&mut self, document: &DocumentIdentifier) -> rusqlite::Result<Option<DocumentDetail>> {
        let snapshot = self.connection.transaction()?;
        let identifier = document.as_str();
        let tags = snapshot
            .prepare_cached(
                "SELECT tags.id, tags.name FROM document_tags JOIN tags ON tags.id = document_tags.tag_id \
                 WHERE document_tags.document_id = ?1 ORDER BY tags.name COLLATE NOCASE, tags.id",
            )?
            .query_map([identifier], |row| {
                Ok(NamedScope {
                    scope: LibraryScope::Tag(stored(row, "id", TagIdentifier::parse)?),
                    name: row.get("name")?,
                })
            })?
            .collect::<rusqlite::Result<Vec<NamedScope>>>()?;
        let mut fields = snapshot
            .prepare_cached(
                "SELECT field_key, field_type, value_text, value_number FROM extracted_fields WHERE document_id = ?1",
            )?
            .query_map([identifier], |row| {
                Ok((row.get("field_key")?, stored_field_value(row)?))
            })?
            .collect::<rusqlite::Result<BTreeMap<String, FieldValue>>>()?;
        snapshot
            .prepare_cached(
                "SELECT documents.status, documents.failure_reason, documents.title, documents.document_date, \
                 documents.listing_date, documents.sender_id, senders.name AS sender_name, documents.category_id, \
                 categories.name AS category_name, categories.expected_fields, documents.person_assignment, \
                 documents.member_id, members.display_name AS member_name, documents.summary, documents.media_type, \
                 documents.byte_size, documents.page_count, documents.arrived_at, \
                 (SELECT archive_origin FROM mirror) AS archive_origin \
                 FROM documents LEFT JOIN senders ON senders.id = documents.sender_id \
                 LEFT JOIN categories ON categories.id = documents.category_id \
                 LEFT JOIN members ON members.id = documents.member_id WHERE documents.id = ?1",
            )?
            .query_row([identifier], |row| {
                let named = |scope: Option<LibraryScope>, name: &str| -> rusqlite::Result<Option<NamedScope>> {
                    scope
                        .map(|scope| {
                            Ok(NamedScope {
                                scope,
                                name: row.get(name)?,
                            })
                        })
                        .transpose()
                };
                let sender = stored_optional(row, "sender_id", SenderIdentifier::parse)?.map(LibraryScope::Sender);
                let category =
                    stored_optional(row, "category_id", CategoryIdentifier::parse)?.map(LibraryScope::Category);
                let member = stored_optional(row, "member_id", MemberIdentifier::parse)?.map(LibraryScope::Member);
                let person = match row.get::<_, String>("person_assignment")?.as_str() {
                    "household" => Some(DocumentPerson::Household),
                    _ => named(member, "member_name")?.map(DocumentPerson::Member),
                };
                let expected_fields: Vec<String> =
                    stored_optional(row, "expected_fields", |fields| serde_json::from_str(fields).ok())?
                        .unwrap_or_default();
                let mut ordered_fields = Vec::with_capacity(fields.len());
                for key in expected_fields {
                    if let Some(value) = fields.remove(&key) {
                        ordered_fields.push(DetailField { key, value });
                    }
                }
                ordered_fields.extend(fields.into_iter().map(|(key, value)| DetailField { key, value }));
                let sender = named(sender, "sender_name")?;
                let title: Option<String> = row.get("title")?;
                let original_kind = OriginalKind::of_media_type(&row.get::<_, String>("media_type")?);
                let archive = stored(row, "archive_origin", |origin| ArchiveAddress::parse(origin).ok())?;
                Ok(DocumentDetail {
                    identifier: document.clone(),
                    condition: stored_condition(row)?,
                    document_date: stored_optional(row, "document_date", CalendarDate::parse)?,
                    suggested_file_name: suggested_file_name(
                        &row.get::<_, String>("listing_date")?,
                        sender.as_ref().map(|sender| sender.name.as_str()),
                        title.as_deref(),
                        original_kind,
                    ),
                    title,
                    sender,
                    category: named(category, "category_name")?,
                    person,
                    tags,
                    summary: row.get("summary")?,
                    fields: ordered_fields,
                    original_kind,
                    byte_size: stored_count(row, "byte_size")?,
                    page_count: row.get("page_count")?,
                    arrived_at: Timestamp(row.get("arrived_at")?),
                    archive_page: archive.document_page(document),
                })
            })
            .optional()
    }

    /// `None` when the copy does not hold the document.
    pub fn text_standing(&self, document: &DocumentIdentifier) -> rusqlite::Result<Option<TextStanding>> {
        self.connection
            .prepare_cached(
                "SELECT documents.original_sha256, extracted_texts.document_row IS NOT NULL AS retrieved, \
                 extracted_texts.markdown FROM documents LEFT JOIN extracted_texts USING (document_row) \
                 WHERE documents.id = ?1",
            )?
            .query_row([document.as_str()], |row| {
                Ok(
                    match (row.get("retrieved")?, row.get::<_, Option<String>>("markdown")?) {
                        (true, Some(markdown)) => TextStanding::Held(markdown),
                        (true, None) => TextStanding::ArchiveHoldsNone,
                        (false, _) => TextStanding::NotRetrieved {
                            original: stored_optional(row, "original_sha256", ContentDigest::parse_hexadecimal)?,
                        },
                    },
                )
            })
            .optional()
    }

    /// `None` when the copy does not hold the document.
    pub fn representation_source(
        &self,
        document: &DocumentIdentifier,
    ) -> rusqlite::Result<Option<RepresentationSource>> {
        self.connection
            .prepare_cached("SELECT original_sha256, media_type FROM documents WHERE id = ?1")?
            .query_row([document.as_str()], |row| {
                Ok(RepresentationSource {
                    original: stored_optional(row, "original_sha256", ContentDigest::parse_hexadecimal)?,
                    kind: OriginalKind::of_media_type(&row.get::<_, String>("media_type")?),
                })
            })
            .optional()
    }
}

/// Zero for a copy that mirrors no archive yet.
fn content_revision(connection: &Connection) -> rusqlite::Result<u64> {
    let revision = connection
        .prepare_cached("SELECT content_revision FROM mirror")?
        .query_row([], |row| stored_count(row, "content_revision"))
        .optional()?;
    Ok(revision.unwrap_or(0))
}

fn stored_condition(row: &Row<'_>) -> rusqlite::Result<DocumentCondition> {
    let status: String = row.get("status")?;
    let failure_reason: Option<String> = row.get("failure_reason")?;
    DocumentCondition::parse(&status, failure_reason.as_deref()).ok_or_else(|| unreadable(row, "status"))
}

/// The condition that a scope puts on a row of `documents`, and the value of its `:scope`
/// parameter when it has one.
fn scope_condition(scope: &LibraryScope, now: Timestamp) -> (&'static str, Option<Value>) {
    let identified = |identifier: &str| Some(Value::Text(identifier.to_owned()));
    match scope {
        LibraryScope::AllDocuments => ("TRUE", None),
        LibraryScope::RecentlyAdded => {
            let earliest = now.0 - i64::try_from(RECENT_ADDITION.as_millis()).unwrap_or(i64::MAX);
            ("documents.arrived_at >= :scope", Some(Value::Integer(earliest)))
        }
        LibraryScope::InIngestion => ("documents.status NOT IN ('archived', 'failed')", None),
        LibraryScope::Failed => ("documents.status = 'failed'", None),
        LibraryScope::Household => ("documents.person_assignment = 'household'", None),
        LibraryScope::Member(member) => ("documents.member_id = :scope", identified(member.as_str())),
        LibraryScope::Category(category) => ("documents.category_id = :scope", identified(category.as_str())),
        LibraryScope::Tag(tag) => (
            "documents.id IN (SELECT document_id FROM document_tags WHERE tag_id = :scope)",
            identified(tag.as_str()),
        ),
        LibraryScope::Sender(sender) => ("documents.sender_id = :scope", identified(sender.as_str())),
    }
}

/// A document of a listing with what orders it and decides its heading.
struct ListedDocument {
    row: DocumentRow,
    document_row: i64,
    /// The day of the arrival for a listing by addition, and otherwise the date on the
    /// document, or the day of the arrival for a document without one.
    heading_date: CalendarDate,
}

impl ListedDocument {
    fn newest_arrival_first(&self, other: &ListedDocument) -> Ordering {
        (other.row.arrived_at, &other.row.identifier).cmp(&(self.row.arrived_at, &self.row.identifier))
    }

    fn newest_date_first(&self, other: &ListedDocument) -> Ordering {
        other
            .heading_date
            .cmp(&self.heading_date)
            .then_with(|| self.newest_arrival_first(other))
    }

    /// The documents in ingestion before the others, by their arrival.
    fn arriving_first(&self, other: &ListedDocument) -> Ordering {
        let arriving = |document: &ListedDocument| matches!(document.row.condition, DocumentCondition::Arriving(_));
        match (arriving(self), arriving(other)) {
            (true, true) => self.newest_arrival_first(other),
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            (false, false) => self.newest_date_first(other),
        }
    }
}

/// The documents of `scope`, all of them or those whose `document_row` is selected, in no
/// order. SQLite sorts whole rows, which took longer than the read itself, so a listing sorts
/// what it has read. The columns are read by position, because the statement runs once per
/// document of the library.
fn listed_documents(
    connection: &Connection,
    scope: &LibraryScope,
    now: Timestamp,
    selected: Option<&BTreeSet<i64>>,
    by_addition: bool,
) -> rusqlite::Result<Vec<ListedDocument>> {
    let (condition, scope_value) = scope_condition(scope, now);
    let heading_date = if by_addition {
        "date(documents.arrived_at / 1000, 'unixepoch')"
    } else {
        "documents.listing_date"
    };
    let selection = match selected {
        Some(_) => "AND documents.document_row IN (SELECT value FROM json_each(:rows))",
        None => "",
    };
    let document_rows = selected.map(|selected| {
        let numbers: Vec<String> = selected.iter().map(i64::to_string).collect();
        format!("[{}]", numbers.join(","))
    });
    let mut parameters: Vec<(&str, &dyn ToSql)> = Vec::new();
    if let Some(scope_value) = &scope_value {
        parameters.push((":scope", scope_value));
    }
    if let Some(document_rows) = &document_rows {
        parameters.push((":rows", document_rows));
    }
    connection
        .prepare_cached(&format!(
            "SELECT documents.document_row, documents.id, documents.status, documents.failure_reason, \
             documents.title, senders.name, documents.document_date, {heading_date}, documents.arrived_at, \
             documents.summary, documents.original_sha256 IS NOT NULL, documents.amount, documents.currency, \
             documents.listing_date, documents.media_type \
             FROM documents LEFT JOIN senders ON senders.id = documents.sender_id \
             WHERE {condition} {selection}"
        ))?
        .query_map(parameters.as_slice(), |row| {
            let unreadable = |column: usize| rusqlite::Error::InvalidColumnType(column, String::new(), Type::Text);
            let identifier: String = row.get(1)?;
            let status: String = row.get(2)?;
            let failure_reason: Option<String> = row.get(3)?;
            let document_date: Option<String> = row.get(6)?;
            let heading_date: String = row.get(7)?;
            let listing_date: String = row.get(13)?;
            Ok(ListedDocument {
                document_row: row.get(0)?,
                heading_date: CalendarDate::parse(&heading_date).ok_or_else(|| unreadable(7))?,
                row: DocumentRow {
                    identifier: DocumentIdentifier::parse(&identifier).ok_or_else(|| unreadable(1))?,
                    condition: DocumentCondition::parse(&status, failure_reason.as_deref())
                        .ok_or_else(|| unreadable(2))?,
                    title: row.get(4)?,
                    sender_name: row.get(5)?,
                    document_date: match document_date {
                        Some(date) => Some(CalendarDate::parse(&date).ok_or_else(|| unreadable(6))?),
                        None => None,
                    },
                    arrived_at: Timestamp(row.get(8)?),
                    passage: row.get::<_, Option<String>>(9)?.map(RowPassage::Summary),
                    content_known: row.get(10)?,
                    amount: match row.get::<_, Option<f64>>(11)? {
                        Some(value) => Some(Amount {
                            value,
                            currency: row.get(12)?,
                        }),
                        None => None,
                    },
                    listing_date: CalendarDate::parse(&listing_date).ok_or_else(|| unreadable(13))?,
                    original_kind: OriginalKind::of_media_type(&row.get::<_, String>(14)?),
                },
            })
        })?
        .collect()
}

fn browsed_rows(
    connection: &Connection,
    scope: &LibraryScope,
    order: ListingOrder,
    now: Timestamp,
) -> rusqlite::Result<Vec<ListingRow>> {
    let mut documents = listed_documents(connection, scope, now, None, order == ListingOrder::Addition)?;
    // An alphabetical order is not SQLite's, whose alphabet ends before the umlauts. The sort is
    // stable, so the documents of one title or sender stay newest first.
    let alphabetical = |name: &Option<String>| {
        let letters: String = name.iter().flat_map(|name| name.chars()).map(folded).collect();
        (name.is_none(), letters)
    };
    match order {
        ListingOrder::DocumentDate => documents.sort_unstable_by(ListedDocument::arriving_first),
        ListingOrder::Addition => documents.sort_unstable_by(ListedDocument::newest_arrival_first),
        ListingOrder::Title => {
            documents.sort_unstable_by(ListedDocument::newest_date_first);
            documents.sort_by_cached_key(|document| alphabetical(&document.row.title));
        }
        ListingOrder::Sender => {
            documents.sort_unstable_by(ListedDocument::newest_date_first);
            documents.sort_by_cached_key(|document| alphabetical(&document.row.sender_name));
        }
    }
    let mut rows = Vec::with_capacity(documents.len());
    let mut heading = None;
    for document in documents {
        let period = ListingHeading::Period {
            year: document.heading_date.year(),
            month: document.heading_date.month(),
        };
        let document_heading = match (order, &document.row.condition) {
            (ListingOrder::DocumentDate, DocumentCondition::Arriving(_)) => Some(ListingHeading::Arriving),
            (ListingOrder::DocumentDate, DocumentCondition::Archived | DocumentCondition::Failed(_))
            | (ListingOrder::Addition, _) => Some(period),
            (ListingOrder::Title | ListingOrder::Sender, _) => None,
        };
        if document_heading != heading {
            heading = document_heading;
            rows.extend(heading.map(ListingRow::Heading));
        }
        rows.push(ListingRow::Document(document.row));
    }
    Ok(rows)
}

/// The search: each term's documents from both tables, then the documents every term found.
fn found_rows(
    connection: &Connection,
    scope: &LibraryScope,
    expression: &SearchExpression,
    now: Timestamp,
) -> rusqlite::Result<Vec<ListingRow>> {
    let matching = |table: &str, expression: &str| {
        connection
            .prepare_cached(&format!("SELECT rowid FROM {table} WHERE {table} MATCH ?1"))?
            .query_map([expression], |row| row.get(0))?
            .collect::<rusqlite::Result<BTreeSet<i64>>>()
    };
    let narrowed = |found: Option<BTreeSet<i64>>, by_term: BTreeSet<i64>| match found {
        Some(found) => Some(&found & &by_term),
        None => Some(by_term),
    };
    let mut found = None;
    let mut found_in_details = None;
    for term in expression.terms() {
        let in_details = match term.detail_expression() {
            Some(expression) => matching("document_detail_search", &expression)?,
            None => matching("document_detail_words", &term.text_expression())?,
        };
        let in_text = matching("document_text_search", &term.text_expression())?;
        found = narrowed(found, &in_details | &in_text);
        found_in_details = narrowed(found_in_details, in_details);
    }
    let found_in_details = found_in_details.unwrap_or_default();
    let found_in_text = &found.unwrap_or_default() - &found_in_details;

    let mut rows = Vec::new();
    for (heading, selected) in [
        (ListingHeading::DetailsMatched, &found_in_details),
        (ListingHeading::TextMatched, &found_in_text),
    ] {
        if selected.is_empty() {
            continue;
        }
        let mut documents = listed_documents(connection, scope, now, Some(selected), false)?;
        documents.sort_unstable_by(ListedDocument::newest_date_first);
        rows.extend((!documents.is_empty()).then_some(ListingRow::Heading(heading)));
        for (position, document) in documents.into_iter().enumerate() {
            let mut row = document.row;
            if heading == ListingHeading::TextMatched
                && position < EXCERPTED_DOCUMENTS
                && let Some(excerpt) = excerpt_of(connection, document.document_row, expression)?
            {
                row.passage = Some(RowPassage::Excerpt(excerpt));
            }
            rows.push(ListingRow::Document(row));
        }
    }
    Ok(rows)
}

/// The passage of a document's text that a search found. The text is read here, one document
/// after the other, and not with the rows.
fn excerpt_of(
    connection: &Connection,
    document_row: i64,
    expression: &SearchExpression,
) -> rusqlite::Result<Option<String>> {
    let mut statement = connection.prepare_cached("SELECT markdown FROM extracted_texts WHERE document_row = ?1")?;
    let mut texts = statement.query([document_row])?;
    let Some(text) = texts.next()? else {
        return Ok(None);
    };
    // The text is read where SQLite holds it, without a copy.
    Ok(text
        .get_ref(0)?
        .as_str_or_null()?
        .and_then(|markdown| expression.excerpt(markdown)))
}
