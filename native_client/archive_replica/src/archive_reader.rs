//! The seam to the archive for reading. `ArchiveReader` answers in domain terms, and the JSON of
//! `GET /api/v1/changes` never leaves this module.

use std::collections::{BTreeMap, BTreeSet};

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveCondition, ArchiveExchange, ArchiveToken, ContentDigest,
    DocumentIdentifier, Timestamp, read_authorization,
};

use crate::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, ExtractedField, FieldValue,
    JournalCursor, JournalPage, MemberIdentifier, MemberRecord, PersonAssignment, RemovedRecord, SenderIdentifier,
    SenderRecord, TagIdentifier, TagRecord,
};

#[derive(Clone, Debug, PartialEq)]
pub enum PageAnswer {
    Page(JournalPage),
    /// 410: the cursor names another journal, or a position this journal never issued. The copy
    /// is discarded and filled again from the journal's start.
    JournalReplaced,
}

/// What a copy reads from its archive. `HttpArchiveReader` speaks the routes, and the scripted
/// archive answers them in a scenario.
pub trait ArchiveReader: Send + Sync {
    /// `GET /api/v1/authorization`.
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition>;

    /// `GET /api/v1/changes`: the page after the cursor, or the journal's first page without one.
    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition>;
}

/// A page covers 250 journal entries today, by the server's choice, and the records their
/// documents refer to. A document with its summary and fields takes about 2,000 bytes, so this is
/// many times such a page.
const MAXIMUM_PAGE_BYTES: u64 = 8_000_000;

pub struct HttpArchiveReader {
    exchange: ArchiveExchange,
}

impl HttpArchiveReader {
    pub fn new(address: &ArchiveAddress, token: &ArchiveToken) -> HttpArchiveReader {
        HttpArchiveReader {
            exchange: ArchiveExchange::new(address, token),
        }
    }
}

impl ArchiveReader for HttpArchiveReader {
    fn read_authorization(&self) -> Result<ArchiveAuthorization, ArchiveCondition> {
        read_authorization(&self.exchange)
    }

    fn read_changes(&self, after: Option<&JournalCursor>) -> Result<PageAnswer, ArchiveCondition> {
        let path = match after {
            Some(cursor) => format!("/api/v1/changes?after={}", cursor.as_str()),
            None => "/api/v1/changes".to_owned(),
        };
        let response = self.exchange.get_within(&path, MAXIMUM_PAGE_BYTES)?;
        match response.status() {
            200 => journal_page(response.body())
                .map(PageAnswer::Page)
                .ok_or_else(|| response.protocol_violation()),
            410 => Ok(PageAnswer::JournalReplaced),
            _ => Err(response.protocol_violation()),
        }
    }
}

#[derive(serde::Deserialize)]
struct ChangesAnswer {
    changes: Vec<EntryAnswer>,
    cursor: String,
    complete: bool,
    remaining: u64,
}

/// One entry. Its record sits under the member that `record` names, so an entry of a kind this
/// client does not know parses with every record absent.
#[derive(serde::Deserialize)]
struct EntryAnswer {
    record: String,
    id: String,
    change: String,
    document: Option<DocumentAnswer>,
    household_member: Option<MemberAnswer>,
    sender: Option<SenderAnswer>,
    category: Option<CategoryAnswer>,
    tag: Option<TagAnswer>,
}

#[derive(serde::Deserialize)]
struct MemberAnswer {
    display_name: String,
}

#[derive(serde::Deserialize)]
struct SenderAnswer {
    name: String,
}

#[derive(serde::Deserialize)]
struct CategoryAnswer {
    name: String,
    expected_fields: Vec<String>,
}

#[derive(serde::Deserialize)]
struct TagAnswer {
    name: String,
    color_hex: Option<String>,
}

#[derive(serde::Deserialize)]
struct DocumentAnswer {
    status: String,
    failure_reason: Option<String>,
    title: Option<String>,
    document_date: Option<String>,
    sender_id: Option<String>,
    category_id: Option<String>,
    person: PersonAnswer,
    summary: Option<String>,
    media_type: String,
    byte_size: u64,
    page_count: Option<u32>,
    original_sha256: Option<String>,
    arrived_at: String,
    tag_ids: Vec<String>,
    fields: Vec<FieldAnswer>,
}

#[derive(serde::Deserialize)]
struct PersonAnswer {
    kind: String,
    member_id: Option<String>,
}

#[derive(serde::Deserialize)]
struct FieldAnswer {
    key: String,
    #[serde(rename = "type")]
    value_type: String,
    value: serde_json::Value,
    confidence: Option<f64>,
}

/// `None` for a body that is no page of the protocol.
fn journal_page(body: &str) -> Option<JournalPage> {
    let answer: ChangesAnswer = serde_json::from_str(body).ok()?;
    let mut page = JournalPage {
        cursor: JournalCursor::parse(&answer.cursor)?,
        complete: answer.complete,
        remaining_entries: answer.remaining,
        members: Vec::new(),
        senders: Vec::new(),
        categories: Vec::new(),
        tags: Vec::new(),
        documents: Vec::new(),
        removed: Vec::new(),
    };
    for entry in answer.changes {
        let removal = match entry.change.as_str() {
            "upsert" => false,
            "removal" => true,
            _ => return None,
        };
        match entry.record.as_str() {
            "document" => {
                let identifier = DocumentIdentifier::parse(&entry.id)?;
                if removal {
                    page.removed.push(RemovedRecord::Document(identifier));
                } else {
                    page.documents.push(document_record(identifier, entry.document?)?);
                }
            }
            "household_member" => {
                let identifier = MemberIdentifier::parse(&entry.id)?;
                if removal {
                    page.removed.push(RemovedRecord::Member(identifier));
                } else {
                    page.members.push(MemberRecord {
                        identifier,
                        display_name: entry.household_member?.display_name,
                    });
                }
            }
            "sender" => {
                let identifier = SenderIdentifier::parse(&entry.id)?;
                if removal {
                    page.removed.push(RemovedRecord::Sender(identifier));
                } else {
                    page.senders.push(SenderRecord {
                        identifier,
                        name: entry.sender?.name,
                    });
                }
            }
            "category" => {
                let identifier = CategoryIdentifier::parse(&entry.id)?;
                if removal {
                    page.removed.push(RemovedRecord::Category(identifier));
                } else {
                    let category = entry.category?;
                    page.categories.push(CategoryRecord {
                        identifier,
                        name: category.name,
                        expected_fields: category.expected_fields,
                    });
                }
            }
            "tag" => {
                let identifier = TagIdentifier::parse(&entry.id)?;
                if removal {
                    page.removed.push(RemovedRecord::Tag(identifier));
                } else {
                    let tag = entry.tag?;
                    page.tags.push(TagRecord {
                        identifier,
                        name: tag.name,
                        color_hex: tag.color_hex,
                    });
                }
            }
            // A kind a newer archive added. The cursor still advances past its entry.
            _ => {}
        }
    }
    Some(page)
}

fn document_record(identifier: DocumentIdentifier, document: DocumentAnswer) -> Option<DocumentRecord> {
    let person = match (document.person.kind.as_str(), document.person.member_id) {
        ("household", None) => PersonAssignment::Household,
        ("unassigned", None) => PersonAssignment::Unassigned,
        ("member", Some(member)) => PersonAssignment::Member(MemberIdentifier::parse(&member)?),
        _ => return None,
    };
    let mut fields = BTreeMap::new();
    for field in document.fields {
        let value = match field.value_type.as_str() {
            "number" => FieldValue::Number(field.value.as_f64()?),
            "text" => FieldValue::Text(field.value.as_str()?.to_owned()),
            "date" => FieldValue::Date(CalendarDate::parse(field.value.as_str()?)?),
            // A type a newer archive added, which this client cannot show.
            _ => continue,
        };
        fields.insert(
            field.key,
            ExtractedField {
                value,
                confidence: field.confidence,
            },
        );
    }
    Some(DocumentRecord {
        identifier,
        condition: DocumentCondition::parse(&document.status, document.failure_reason.as_deref())?,
        title: document.title,
        document_date: optional(document.document_date, CalendarDate::parse)?,
        sender: optional(document.sender_id, SenderIdentifier::parse)?,
        category: optional(document.category_id, CategoryIdentifier::parse)?,
        person,
        summary: document.summary,
        media_type: document.media_type,
        byte_size: document.byte_size,
        page_count: document.page_count,
        original: optional(document.original_sha256, ContentDigest::parse_hexadecimal)?,
        arrived_at: instant(&document.arrived_at)?,
        tags: document
            .tag_ids
            .iter()
            .map(|tag| TagIdentifier::parse(tag))
            .collect::<Option<BTreeSet<TagIdentifier>>>()?,
        fields,
    })
}

/// An absent member stays absent, and a present one must parse.
fn optional<Value>(text: Option<String>, parse: impl Fn(&str) -> Option<Value>) -> Option<Option<Value>> {
    match text {
        Some(text) => parse(&text).map(Some),
        None => Some(None),
    }
}

/// ISO 8601 in UTC as the archive writes a time, `2026-09-23T08:14:02Z`, with or without a
/// fraction of the second.
fn instant(text: &str) -> Option<Timestamp> {
    let (date, time) = text.strip_suffix('Z')?.split_once('T')?;
    let date = CalendarDate::parse(date)?;
    let (clock, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let clock_bytes = clock.as_bytes();
    let well_formed = clock_bytes.len() == 8
        && clock_bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 2 | 5) {
                *byte == b':'
            } else {
                byte.is_ascii_digit()
            }
        })
        && !fraction.is_empty()
        && fraction.bytes().all(|byte| byte.is_ascii_digit());
    if !well_formed {
        return None;
    }
    let hour: i64 = clock[..2].parse().ok()?;
    let minute: i64 = clock[3..5].parse().ok()?;
    let second: i64 = clock[6..].parse().ok()?;
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let milliseconds: i64 = format!("{fraction:0<3}")[..3].parse().ok()?;
    let seconds = date.days_since_epoch() * 86_400 + hour * 3_600 + minute * 60 + second;
    Some(Timestamp(seconds * 1_000 + milliseconds))
}
