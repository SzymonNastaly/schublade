//! The archive's records as a client holds them: the five kinds of record, a page of the change
//! journal, and the cursor that follows it. `archive_reader.rs` parses the wire format into these
//! types and `replica_store.rs` keeps them, so every value here has passed a boundary.

use std::collections::{BTreeMap, BTreeSet};

use archive_access::{ContentDigest, DocumentIdentifier, Timestamp, is_record_identifier};

/// The position after one page of the journal, as the archive wrote it. A client stores it and
/// sends it back, and reads nothing from it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalCursor(String);

impl JournalCursor {
    /// Accepts the characters a query takes as they are, so the cursor is sent back unchanged.
    pub fn parse(text: &str) -> Option<JournalCursor> {
        let unreserved = |byte: u8| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b'~');
        (!text.is_empty() && text.bytes().all(unreserved)).then(|| JournalCursor(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The identifier of a record of one kind, a UUID as the archive writes it.
macro_rules! record_identifier {
    ($name:ident) => {
        #[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(String);

        impl $name {
            pub fn parse(text: &str) -> Option<$name> {
                is_record_identifier(text).then(|| $name(text.to_owned()))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
    };
}

record_identifier!(MemberIdentifier);
record_identifier!(SenderIdentifier);
record_identifier!(CategoryIdentifier);
record_identifier!(TagIdentifier);

/// A day of the calendar, as a document prints it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CalendarDate {
    year: u16,
    month: u8,
    day: u8,
}

impl CalendarDate {
    /// `YYYY-MM-DD` of a day that exists.
    pub fn parse(text: &str) -> Option<CalendarDate> {
        let bytes = text.as_bytes();
        let well_formed = bytes.len() == 10
            && bytes.iter().enumerate().all(|(index, byte)| {
                if matches!(index, 4 | 7) {
                    *byte == b'-'
                } else {
                    byte.is_ascii_digit()
                }
            });
        if !well_formed {
            return None;
        }
        let year: u16 = text[..4].parse().ok()?;
        let month: u8 = text[5..7].parse().ok()?;
        let day: u8 = text[8..].parse().ok()?;
        (1..=12).contains(&month).then_some(())?;
        (1..=days_of_month(year, month)).contains(&day).then_some(())?;
        Some(CalendarDate { year, month, day })
    }

    pub fn iso_text(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }

    pub fn year(&self) -> u16 {
        self.year
    }

    /// From 1 for January.
    pub fn month(&self) -> u8 {
        self.month
    }

    /// From 1.
    pub fn day(&self) -> u8 {
        self.day
    }

    /// The days from 1970-01-01 to this day, by the proleptic Gregorian calendar.
    pub(crate) fn days_since_epoch(&self) -> i64 {
        // March opens the counted year, so the leap day is its last day.
        let month = i64::from(self.month);
        let year = i64::from(self.year) - i64::from(month <= 2);
        let year_of_era = year.rem_euclid(400);
        let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + i64::from(self.day) - 1;
        let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
        year.div_euclid(400) * 146_097 + day_of_era - 719_468
    }
}

fn days_of_month(year: u16, month: u8) -> u8 {
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Where a document stands in the archive. A failure reason exists exactly when it failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentCondition {
    /// In ingestion: the archive holds the file and has not finished reading it.
    Arriving(IngestionStage),
    Archived,
    Failed(FailureReason),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IngestionStage {
    AwaitingRendering,
    Processing,
    Extracting,
    RecognizingText,
    Classifying,
    /// A status this client does not know, which a newer archive may add. Kept as it came.
    Unrecognized(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FailureReason {
    UnreadableFile,
    PageLimitExceeded,
    UnreadablePage,
    ProcessingError,
    /// A reason this client does not know. Kept as it came.
    Unrecognized(String),
}

impl DocumentCondition {
    /// The status and the failure reason as the archive writes them. `None` for a failed document
    /// without a reason.
    pub fn parse(status: &str, failure_reason: Option<&str>) -> Option<DocumentCondition> {
        Some(match status {
            "archived" => DocumentCondition::Archived,
            "failed" => DocumentCondition::Failed(match failure_reason? {
                "unreadable_file" => FailureReason::UnreadableFile,
                "page_limit_exceeded" => FailureReason::PageLimitExceeded,
                "unreadable_page" => FailureReason::UnreadablePage,
                "processing_error" => FailureReason::ProcessingError,
                unrecognized => FailureReason::Unrecognized(unrecognized.to_owned()),
            }),
            "awaiting_rendering" => DocumentCondition::Arriving(IngestionStage::AwaitingRendering),
            "processing" => DocumentCondition::Arriving(IngestionStage::Processing),
            "extracting" => DocumentCondition::Arriving(IngestionStage::Extracting),
            "recognizing_text" => DocumentCondition::Arriving(IngestionStage::RecognizingText),
            "classifying" => DocumentCondition::Arriving(IngestionStage::Classifying),
            unrecognized => DocumentCondition::Arriving(IngestionStage::Unrecognized(unrecognized.to_owned())),
        })
    }

    pub fn status_name(&self) -> &str {
        match self {
            DocumentCondition::Archived => "archived",
            DocumentCondition::Failed(_) => "failed",
            DocumentCondition::Arriving(IngestionStage::AwaitingRendering) => "awaiting_rendering",
            DocumentCondition::Arriving(IngestionStage::Processing) => "processing",
            DocumentCondition::Arriving(IngestionStage::Extracting) => "extracting",
            DocumentCondition::Arriving(IngestionStage::RecognizingText) => "recognizing_text",
            DocumentCondition::Arriving(IngestionStage::Classifying) => "classifying",
            DocumentCondition::Arriving(IngestionStage::Unrecognized(status)) => status,
        }
    }

    pub fn failure_reason_name(&self) -> Option<&str> {
        match self {
            DocumentCondition::Archived | DocumentCondition::Arriving(_) => None,
            DocumentCondition::Failed(reason) => Some(match reason {
                FailureReason::UnreadableFile => "unreadable_file",
                FailureReason::PageLimitExceeded => "page_limit_exceeded",
                FailureReason::UnreadablePage => "unreadable_page",
                FailureReason::ProcessingError => "processing_error",
                FailureReason::Unrecognized(reason) => reason,
            }),
        }
    }
}

/// Whom a document concerns. Classification assigns the person, so a document that is not yet
/// classified concerns nobody, not even the whole household.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PersonAssignment {
    Household,
    Member(MemberIdentifier),
    Unassigned,
}

#[derive(Clone, Debug, PartialEq)]
pub enum FieldValue {
    Text(String),
    Number(f64),
    Date(CalendarDate),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ExtractedField {
    pub value: FieldValue,
    /// The classifier's confidence between 0 and 1, when it gave one.
    pub confidence: Option<f64>,
}

/// A document as the journal delivers it: whole, with its tags and its extracted fields.
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentRecord {
    pub identifier: DocumentIdentifier,
    pub condition: DocumentCondition,
    pub title: Option<String>,
    pub document_date: Option<CalendarDate>,
    pub sender: Option<SenderIdentifier>,
    pub category: Option<CategoryIdentifier>,
    pub person: PersonAssignment,
    pub summary: Option<String>,
    /// Such as `application/pdf`, or `message/rfc822` for an email the archive has not printed.
    pub media_type: String,
    pub byte_size: u64,
    pub page_count: Option<u32>,
    /// The content the document shows. `None` until the archive has recorded it.
    pub original: Option<ContentDigest>,
    pub arrived_at: Timestamp,
    pub tags: BTreeSet<TagIdentifier>,
    /// By the archive's key, such as `amount` or `due_date`.
    pub fields: BTreeMap<String, ExtractedField>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemberRecord {
    pub identifier: MemberIdentifier,
    pub display_name: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SenderRecord {
    pub identifier: SenderIdentifier,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CategoryRecord {
    pub identifier: CategoryIdentifier,
    pub name: String,
    /// The field keys classification expects for the category.
    pub expected_fields: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TagRecord {
    pub identifier: TagIdentifier,
    pub name: String,
    pub color_hex: Option<String>,
}

/// A record that no longer exists, or that the token no longer sees. A client treats both alike.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemovedRecord {
    Document(DocumentIdentifier),
    Member(MemberIdentifier),
    Sender(SenderIdentifier),
    Category(CategoryIdentifier),
    Tag(TagIdentifier),
}

/// One answer of `GET /api/v1/changes`. Every record is a whole present state, and every member,
/// sender, category, and tag that a document of the page refers to is in the page.
#[derive(Clone, Debug, PartialEq)]
pub struct JournalPage {
    /// What the client requests the next page after.
    pub cursor: JournalCursor,
    /// The journal held no entry after this page when the archive read it.
    pub complete: bool,
    /// An upper bound of the journal entries after this page, for a progress display.
    pub remaining_entries: u64,
    pub members: Vec<MemberRecord>,
    pub senders: Vec<SenderRecord>,
    pub categories: Vec<CategoryRecord>,
    pub tags: Vec<TagRecord>,
    pub documents: Vec<DocumentRecord>,
    pub removed: Vec<RemovedRecord>,
}

/// Every record of an archive or of a copy, each kind in the order of its identifiers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ArchiveRecords {
    pub members: Vec<MemberRecord>,
    pub senders: Vec<SenderRecord>,
    pub categories: Vec<CategoryRecord>,
    pub tags: Vec<TagRecord>,
    pub documents: Vec<DocumentRecord>,
}
