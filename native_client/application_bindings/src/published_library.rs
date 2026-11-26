//! The library's status, scopes, listings, facets, and document details as an application sees
//! them.
//!
//! Every conversion destructures its `archive_replica` record without `..` and matches every enum
//! without a wildcard arm, so a new field or variant in the core fails to compile until this
//! module decides how an application receives it.

use std::sync::Arc;
use std::time::SystemTime;

use archive_access::PermissionLevel;
use archive_replica::replica_records::{
    self, CategoryIdentifier as CoreCategoryIdentifier, MemberIdentifier as CoreMemberIdentifier,
    SenderIdentifier as CoreSenderIdentifier, TagIdentifier as CoreTagIdentifier,
};
use archive_replica::{ReplicaStatus, SynchronizationState};

use crate::published_status::{ArchiveConnection, derive_archive_connection, system_time};
use crate::refusals::ApplicationFault;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PublishedPermissionLevel {
    Ingest,
    Read,
    Modify,
    Administer,
}

pub(crate) fn published_permission_level(level: PermissionLevel) -> PublishedPermissionLevel {
    match level {
        PermissionLevel::Ingest => PublishedPermissionLevel::Ingest,
        PermissionLevel::Read => PublishedPermissionLevel::Read,
        PermissionLevel::Modify => PublishedPermissionLevel::Modify,
        PermissionLevel::Administer => PublishedPermissionLevel::Administer,
    }
}

macro_rules! published_identifier {
    ($name:ident) => {
        #[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Hash)]
        pub struct $name {
            pub value: String,
        }
    };
}

published_identifier!(DocumentIdentifier);
published_identifier!(MemberIdentifier);
published_identifier!(SenderIdentifier);
published_identifier!(CategoryIdentifier);
published_identifier!(TagIdentifier);

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LibraryStatus {
    pub revision: u64,
    pub archive: ArchiveConnection,
    pub copy: LibraryCopy,
    /// Rises when a record or a text of the copy changed. A screen reads its listing, facets, or
    /// document again when this number differs from the one it read at.
    pub content_revision: u64,
    pub counts: LibraryCounts,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum LibraryCopy {
    Absent,
    Filling { received: u64, remaining: u64 },
    Complete { synchronized_at: SystemTime },
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct LibraryCounts {
    pub documents: u64,
    pub documents_in_ingestion: u64,
    pub documents_failed: u64,
    pub documents_awaiting_text: u64,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Hash)]
pub enum LibraryScope {
    AllDocuments,
    RecentlyAdded,
    InIngestion,
    Failed,
    Household,
    Member { member: MemberIdentifier },
    Category { category: CategoryIdentifier },
    Tag { tag: TagIdentifier },
    Sender { sender: SenderIdentifier },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct NamedScope {
    pub scope: LibraryScope,
    pub name: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ScopeCount {
    pub scope: NamedScope,
    pub documents: u64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LibraryFacets {
    pub content_revision: u64,
    pub documents: u64,
    pub documents_in_ingestion: u64,
    pub documents_failed: u64,
    pub household_documents: u64,
    pub members: Vec<ScopeCount>,
    pub categories: Vec<ScopeCount>,
    pub tags: Vec<ScopeCount>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ListingOrder {
    DocumentDate,
    Addition,
    Title,
    Sender,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Hash)]
pub enum ListingRequest {
    Browse { scope: LibraryScope, order: ListingOrder },
    Search { scope: LibraryScope, text: String },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ListingHeading {
    Arriving,
    Period { year: u16, month: u8 },
    DetailsMatched,
    TextMatched,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CalendarDate {
    pub year: u16,
    pub month: u8,
    pub day: u8,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct Amount {
    /// Exact decimal representation of the extracted number so Swift formats cents without float
    /// drift across UniFFI.
    pub decimal_text: String,
    pub currency: Option<String>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum RowPassage {
    Summary { text: String },
    Excerpt { text: String },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum DocumentCondition {
    InIngestion { stage: IngestionStage },
    Archived,
    Failed { reason: FailureReason },
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum IngestionStage {
    AwaitingRendering,
    Processing,
    Extracting,
    RecognizingText,
    Classifying,
    Other,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FailureReason {
    UnreadableFile,
    UnreadablePage,
    ProcessingError,
    Other,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct DocumentRow {
    pub document: DocumentIdentifier,
    pub condition: DocumentCondition,
    pub title: Option<String>,
    pub sender_name: Option<String>,
    pub document_date: Option<CalendarDate>,
    pub arrived_at: SystemTime,
    pub amount: Option<Amount>,
    pub passage: Option<RowPassage>,
    pub content_known: bool,
    /// The name a copy of the original takes, such as
    /// `2026-09-22 Stadtwerke Talbrück Electricity Annual Statement.pdf`.
    pub suggested_file_name: String,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
#[expect(
    clippy::large_enum_variant,
    reason = "UniFFI lowers a variant's fields by value, and a listing crosses 64 rows at a time"
)]
pub enum ListingRow {
    Heading { heading: ListingHeading },
    Document { row: DocumentRow },
}

/// An immutable listing kept in Rust so a table reads row windows from memory on the main thread.
#[derive(uniffi::Object)]
pub struct DocumentListing {
    inner: archive_replica::DocumentListing,
}

#[uniffi::export]
impl DocumentListing {
    pub fn row_count(&self) -> u32 {
        usize_to_u32(self.inner.row_count())
    }

    pub fn document_count(&self) -> u32 {
        usize_to_u32(self.inner.document_count())
    }

    pub fn heading_positions(&self) -> Vec<u32> {
        self.inner
            .heading_positions()
            .iter()
            .copied()
            .map(usize_to_u32)
            .collect()
    }

    pub fn content_revision(&self) -> u64 {
        self.inner.content_revision()
    }

    pub fn rows(&self, first: u32, count: u32) -> Vec<ListingRow> {
        self.inner
            .rows(first as usize, count as usize)
            .iter()
            .cloned()
            .map(listing_row)
            .collect()
    }

    pub fn position_of(&self, document: DocumentIdentifier) -> Option<u32> {
        let identifier = archive_access::DocumentIdentifier::parse(&document.value)?;
        self.inner.position_of(&identifier).map(usize_to_u32)
    }
}

impl DocumentListing {
    pub(crate) fn inner(&self) -> &archive_replica::DocumentListing {
        &self.inner
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ListingDifference {
    pub removed_positions: Vec<u32>,
    pub inserted_positions: Vec<u32>,
    pub revised_positions: Vec<u32>,
}

#[derive(uniffi::Record)]
pub struct ListingAnswer {
    pub listing: Arc<DocumentListing>,
    pub difference: Option<ListingDifference>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum DocumentPerson {
    Household,
    Member { scope: NamedScope },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum FieldValue {
    Text { text: String },
    Number { decimal_text: String },
    Date { date: CalendarDate },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct DetailField {
    pub key: String,
    pub value: FieldValue,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OriginalKind {
    PortableDocument,
    JpegImage,
    PngImage,
    WebpImage,
    UnprintedEmail,
    Unrecognized,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct DocumentDetail {
    pub document: DocumentIdentifier,
    pub condition: DocumentCondition,
    pub title: Option<String>,
    pub document_date: Option<CalendarDate>,
    pub sender: Option<NamedScope>,
    pub category: Option<NamedScope>,
    pub person: Option<DocumentPerson>,
    pub tags: Vec<NamedScope>,
    pub summary: Option<String>,
    pub fields: Vec<DetailField>,
    pub original_kind: OriginalKind,
    pub byte_size: u64,
    pub page_count: Option<u32>,
    pub arrived_at: SystemTime,
    pub archive_page: String,
    pub suggested_file_name: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LocalFile {
    pub path: String,
}

/// What the downloaded originals take on this Mac, and the most they may take; `None` is no limit.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct OriginalStorage {
    pub held_bytes: u64,
    pub limit_bytes: Option<u64>,
}

pub(crate) fn publish_library_status(
    status: &ReplicaStatus,
    collector: Option<&(Option<String>, collection_core::ConnectionStatus)>,
    documents_in_ingestion: u64,
    documents_failed: u64,
    revision: u64,
) -> LibraryStatus {
    let archive = derive_archive_connection(status, collector);
    let copy = match &status.archive {
        None => LibraryCopy::Absent,
        Some(mirrored) if !mirrored.fill_complete => {
            let remaining = match status.synchronization {
                SynchronizationState::Filling { remaining_entries } => remaining_entries,
                SynchronizationState::Disconnected
                | SynchronizationState::Following { .. }
                | SynchronizationState::CatchingUp
                | SynchronizationState::Unreachable { .. }
                | SynchronizationState::Suspended { .. }
                | SynchronizationState::ArchiveOutdated { .. } => 0,
            };
            LibraryCopy::Filling {
                received: status.documents,
                remaining,
            }
        }
        Some(mirrored) => LibraryCopy::Complete {
            synchronized_at: system_time(mirrored.synchronized_at.unwrap_or(archive_access::Timestamp(0))),
        },
    };
    LibraryStatus {
        revision,
        archive,
        copy,
        content_revision: status.content_revision,
        counts: LibraryCounts {
            documents: status.documents,
            documents_in_ingestion,
            documents_failed,
            documents_awaiting_text: status.documents_awaiting_text,
        },
    }
}

pub(crate) fn to_core_listing_request(
    request: ListingRequest,
) -> Result<archive_replica::ListingRequest, ApplicationFault> {
    Ok(match request {
        ListingRequest::Browse { scope, order } => archive_replica::ListingRequest::Browse {
            scope: to_core_scope(scope)?,
            order: to_core_order(order),
        },
        ListingRequest::Search { scope, text } => archive_replica::ListingRequest::Search {
            scope: to_core_scope(scope)?,
            text,
        },
    })
}

fn to_core_scope(scope: LibraryScope) -> Result<archive_replica::LibraryScope, ApplicationFault> {
    let invalid = |kind: &str, value: &str| ApplicationFault::Unexpected {
        detail: format!("Invalid {kind} identifier: {value}"),
    };
    Ok(match scope {
        LibraryScope::AllDocuments => archive_replica::LibraryScope::AllDocuments,
        LibraryScope::RecentlyAdded => archive_replica::LibraryScope::RecentlyAdded,
        LibraryScope::InIngestion => archive_replica::LibraryScope::InIngestion,
        LibraryScope::Failed => archive_replica::LibraryScope::Failed,
        LibraryScope::Household => archive_replica::LibraryScope::Household,
        LibraryScope::Member { member } => archive_replica::LibraryScope::Member(
            CoreMemberIdentifier::parse(&member.value).ok_or_else(|| invalid("member", &member.value))?,
        ),
        LibraryScope::Category { category } => archive_replica::LibraryScope::Category(
            CoreCategoryIdentifier::parse(&category.value).ok_or_else(|| invalid("category", &category.value))?,
        ),
        LibraryScope::Tag { tag } => archive_replica::LibraryScope::Tag(
            CoreTagIdentifier::parse(&tag.value).ok_or_else(|| invalid("tag", &tag.value))?,
        ),
        LibraryScope::Sender { sender } => archive_replica::LibraryScope::Sender(
            CoreSenderIdentifier::parse(&sender.value).ok_or_else(|| invalid("sender", &sender.value))?,
        ),
    })
}

fn to_core_order(order: ListingOrder) -> archive_replica::ListingOrder {
    match order {
        ListingOrder::DocumentDate => archive_replica::ListingOrder::DocumentDate,
        ListingOrder::Addition => archive_replica::ListingOrder::Addition,
        ListingOrder::Title => archive_replica::ListingOrder::Title,
        ListingOrder::Sender => archive_replica::ListingOrder::Sender,
    }
}

pub(crate) fn listing_answer(answer: archive_replica::ListingAnswer) -> ListingAnswer {
    let archive_replica::ListingAnswer { listing, difference } = answer;
    ListingAnswer {
        listing: Arc::new(DocumentListing { inner: listing }),
        difference: difference.map(|difference| {
            let archive_replica::ListingDifference {
                removed_positions,
                inserted_positions,
                revised_positions,
            } = difference;
            ListingDifference {
                removed_positions: removed_positions.into_iter().map(usize_to_u32).collect(),
                inserted_positions: inserted_positions.into_iter().map(usize_to_u32).collect(),
                revised_positions: revised_positions.into_iter().map(usize_to_u32).collect(),
            }
        }),
    }
}

pub(crate) fn library_facets(facets: archive_replica::ReplicaFacets) -> LibraryFacets {
    let archive_replica::ReplicaFacets {
        content_revision,
        documents,
        documents_in_ingestion,
        documents_failed,
        household_documents,
        members,
        categories,
        tags,
    } = facets;
    LibraryFacets {
        content_revision,
        documents,
        documents_in_ingestion,
        documents_failed,
        household_documents,
        members: members.into_iter().map(scope_count).collect(),
        categories: categories.into_iter().map(scope_count).collect(),
        tags: tags.into_iter().map(scope_count).collect(),
    }
}

pub(crate) fn document_detail(detail: archive_replica::DocumentDetail) -> DocumentDetail {
    let archive_replica::DocumentDetail {
        identifier,
        condition,
        title,
        document_date,
        sender,
        category,
        person,
        tags,
        summary,
        fields,
        original_kind,
        byte_size,
        page_count,
        arrived_at,
        archive_page,
        suggested_file_name,
    } = detail;
    DocumentDetail {
        document: DocumentIdentifier {
            value: identifier.as_str().to_owned(),
        },
        condition: document_condition(condition),
        title,
        document_date: document_date.map(calendar_date),
        sender: sender.map(named_scope),
        category: category.map(named_scope),
        person: person.map(|person| match person {
            archive_replica::DocumentPerson::Household => DocumentPerson::Household,
            archive_replica::DocumentPerson::Member(scope) => DocumentPerson::Member {
                scope: named_scope(scope),
            },
        }),
        tags: tags.into_iter().map(named_scope).collect(),
        summary,
        fields: fields
            .into_iter()
            .map(|field| {
                let archive_replica::DetailField { key, value } = field;
                DetailField {
                    key,
                    value: field_value(value),
                }
            })
            .collect(),
        original_kind: published_original_kind(original_kind),
        byte_size,
        page_count,
        arrived_at: system_time(arrived_at),
        archive_page,
        suggested_file_name,
    }
}

fn scope_count(count: archive_replica::ScopeCount) -> ScopeCount {
    let archive_replica::ScopeCount { scope, documents } = count;
    ScopeCount {
        scope: named_scope(scope),
        documents,
    }
}

fn named_scope(scope: archive_replica::NamedScope) -> NamedScope {
    let archive_replica::NamedScope { scope, name } = scope;
    NamedScope {
        scope: library_scope(scope),
        name,
    }
}

fn library_scope(scope: archive_replica::LibraryScope) -> LibraryScope {
    match scope {
        archive_replica::LibraryScope::AllDocuments => LibraryScope::AllDocuments,
        archive_replica::LibraryScope::RecentlyAdded => LibraryScope::RecentlyAdded,
        archive_replica::LibraryScope::InIngestion => LibraryScope::InIngestion,
        archive_replica::LibraryScope::Failed => LibraryScope::Failed,
        archive_replica::LibraryScope::Household => LibraryScope::Household,
        archive_replica::LibraryScope::Member(member) => LibraryScope::Member {
            member: MemberIdentifier {
                value: member.as_str().to_owned(),
            },
        },
        archive_replica::LibraryScope::Category(category) => LibraryScope::Category {
            category: CategoryIdentifier {
                value: category.as_str().to_owned(),
            },
        },
        archive_replica::LibraryScope::Tag(tag) => LibraryScope::Tag {
            tag: TagIdentifier {
                value: tag.as_str().to_owned(),
            },
        },
        archive_replica::LibraryScope::Sender(sender) => LibraryScope::Sender {
            sender: SenderIdentifier {
                value: sender.as_str().to_owned(),
            },
        },
    }
}

fn listing_row(row: archive_replica::ListingRow) -> ListingRow {
    match row {
        archive_replica::ListingRow::Heading(heading) => ListingRow::Heading {
            heading: match heading {
                archive_replica::ListingHeading::Arriving => ListingHeading::Arriving,
                archive_replica::ListingHeading::Period { year, month } => ListingHeading::Period { year, month },
                archive_replica::ListingHeading::DetailsMatched => ListingHeading::DetailsMatched,
                archive_replica::ListingHeading::TextMatched => ListingHeading::TextMatched,
            },
        },
        archive_replica::ListingRow::Document(row) => ListingRow::Document { row: document_row(row) },
    }
}

fn document_row(row: archive_replica::DocumentRow) -> DocumentRow {
    let suggested_file_name = row.suggested_file_name();
    let archive_replica::DocumentRow {
        identifier,
        condition,
        title,
        sender_name,
        document_date,
        arrived_at,
        amount,
        passage,
        content_known,
        listing_date: _,
        original_kind: _,
    } = row;
    DocumentRow {
        document: DocumentIdentifier {
            value: identifier.as_str().to_owned(),
        },
        condition: document_condition(condition),
        title,
        sender_name,
        document_date: document_date.map(calendar_date),
        arrived_at: system_time(arrived_at),
        amount: amount.map(|amount| {
            let archive_replica::Amount { value, currency } = amount;
            Amount {
                decimal_text: decimal_text(value),
                currency,
            }
        }),
        passage: passage.map(|passage| match passage {
            archive_replica::RowPassage::Summary(text) => RowPassage::Summary { text },
            archive_replica::RowPassage::Excerpt(text) => RowPassage::Excerpt { text },
        }),
        content_known,
        suggested_file_name,
    }
}

fn document_condition(condition: replica_records::DocumentCondition) -> DocumentCondition {
    match condition {
        replica_records::DocumentCondition::Arriving(stage) => DocumentCondition::InIngestion {
            stage: match stage {
                replica_records::IngestionStage::AwaitingRendering => IngestionStage::AwaitingRendering,
                replica_records::IngestionStage::Processing => IngestionStage::Processing,
                replica_records::IngestionStage::Extracting => IngestionStage::Extracting,
                replica_records::IngestionStage::RecognizingText => IngestionStage::RecognizingText,
                replica_records::IngestionStage::Classifying => IngestionStage::Classifying,
                replica_records::IngestionStage::Unrecognized(_) => IngestionStage::Other,
            },
        },
        replica_records::DocumentCondition::Archived => DocumentCondition::Archived,
        replica_records::DocumentCondition::Failed(reason) => DocumentCondition::Failed {
            reason: match reason {
                replica_records::FailureReason::UnreadableFile => FailureReason::UnreadableFile,
                replica_records::FailureReason::UnreadablePage => FailureReason::UnreadablePage,
                replica_records::FailureReason::ProcessingError => FailureReason::ProcessingError,
                replica_records::FailureReason::Unrecognized(_) => FailureReason::Other,
            },
        },
    }
}

fn field_value(value: replica_records::FieldValue) -> FieldValue {
    match value {
        replica_records::FieldValue::Text(text) => FieldValue::Text { text },
        replica_records::FieldValue::Number(number) => FieldValue::Number {
            decimal_text: decimal_text(number),
        },
        replica_records::FieldValue::Date(date) => FieldValue::Date {
            date: calendar_date(date),
        },
    }
}

fn published_original_kind(kind: archive_replica::OriginalKind) -> OriginalKind {
    match kind {
        archive_replica::OriginalKind::PortableDocument => OriginalKind::PortableDocument,
        archive_replica::OriginalKind::JpegImage => OriginalKind::JpegImage,
        archive_replica::OriginalKind::PngImage => OriginalKind::PngImage,
        archive_replica::OriginalKind::WebpImage => OriginalKind::WebpImage,
        archive_replica::OriginalKind::UnprintedEmail => OriginalKind::UnprintedEmail,
        archive_replica::OriginalKind::Unrecognized => OriginalKind::Unrecognized,
    }
}

fn calendar_date(date: replica_records::CalendarDate) -> CalendarDate {
    CalendarDate {
        year: date.year(),
        month: date.month(),
        day: date.day(),
    }
}

fn decimal_text(value: f64) -> String {
    let normalized = if value == 0.0 { 0.0 } else { value };
    normalized.to_string()
}

fn usize_to_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}
