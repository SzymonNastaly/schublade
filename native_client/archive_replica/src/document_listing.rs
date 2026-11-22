//! What a list of documents asks for and receives: the request, the listing that answers it, and
//! the difference between two listings of one request. Everything here is plain data. The rows
//! come from `replica_queries.rs`.

use std::collections::HashMap;

use archive_access::{DocumentIdentifier, Timestamp};

use crate::replica_records::{
    CalendarDate, CategoryIdentifier, DocumentCondition, MemberIdentifier, SenderIdentifier, TagIdentifier,
};

/// The part of the library a listing covers: a destination of the sidebar, or the documents of
/// one sender, which a person reaches from a document.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LibraryScope {
    AllDocuments,
    /// The documents that arrived within the last 30 days.
    RecentlyAdded,
    /// The documents the archive is still reading.
    InIngestion,
    /// The documents whose ingestion failed.
    Failed,
    /// The documents that concern the whole household.
    Household,
    Member(MemberIdentifier),
    Category(CategoryIdentifier),
    Tag(TagIdentifier),
    Sender(SenderIdentifier),
}

/// A scope with the name its record has, which a person clicks to list its documents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NamedScope {
    pub scope: LibraryScope,
    pub name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ListingOrder {
    /// The documents in ingestion first, under `Arriving`, then by the date on the document,
    /// newest first, under the month of that date. A document without a date takes the day it
    /// arrived.
    DocumentDate,
    /// By arrival, newest first, under the month of the arrival.
    Addition,
    /// By title, alphabetically, the documents without one last. No headings.
    Title,
    /// By the sender's name, alphabetically, the documents without one last. No headings.
    Sender,
}

/// What a list shows. A search is ranked, so it has no order to choose.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ListingRequest {
    Browse {
        scope: LibraryScope,
        order: ListingOrder,
    },
    /// The documents of the scope in which every term of the text is found, those whose details
    /// hold every term first, then those found through their text, each newest first. A text
    /// without a term lists what `Browse` lists by the document date.
    Search {
        scope: LibraryScope,
        text: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ListingHeading {
    Arriving,
    /// A month of the calendar, `month` from 1.
    Period {
        year: u16,
        month: u8,
    },
    /// Every term was found in the title, the sender, the category, the tags, the person, the
    /// extracted fields, or the summary.
    DetailsMatched,
    /// A term was found in the extracted text alone.
    TextMatched,
}

/// The `amount` field of a document with its `currency` field.
#[derive(Clone, Debug, PartialEq)]
pub struct Amount {
    pub value: f64,
    /// ISO 4217, such as `EUR`.
    pub currency: Option<String>,
}

/// The third line of a row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RowPassage {
    Summary(String),
    /// The extracted text around the word a search found.
    Excerpt(String),
}

/// What one row of the list shows of a document.
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentRow {
    pub identifier: DocumentIdentifier,
    /// Archived, failed with its reason, or in ingestion with its stage.
    pub condition: DocumentCondition,
    pub title: Option<String>,
    pub sender_name: Option<String>,
    pub document_date: Option<CalendarDate>,
    pub arrived_at: Timestamp,
    pub amount: Option<Amount>,
    pub passage: Option<RowPassage>,
    /// The archive has recorded the content the document shows, so a picture of its first page
    /// can be asked for and never changes.
    pub content_known: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ListingRow {
    Heading(ListingHeading),
    Document(DocumentRow),
}

/// What makes a row the same row in two listings.
#[derive(PartialEq, Eq, Hash)]
enum RowIdentity<'row> {
    Heading(ListingHeading),
    Document(&'row DocumentIdentifier),
}

impl ListingRow {
    fn identity(&self) -> RowIdentity<'_> {
        match self {
            ListingRow::Heading(heading) => RowIdentity::Heading(*heading),
            ListingRow::Document(row) => RowIdentity::Document(&row.identifier),
        }
    }
}

/// The rows of one request at one content revision, whole and in memory, so a table reads any
/// row without the store. It never changes: a changed copy is another listing.
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentListing {
    request: ListingRequest,
    content_revision: u64,
    rows: Vec<ListingRow>,
    heading_positions: Vec<usize>,
    document_count: usize,
}

impl DocumentListing {
    pub(crate) fn assemble(request: ListingRequest, content_revision: u64, rows: Vec<ListingRow>) -> DocumentListing {
        let mut heading_positions = Vec::new();
        let mut document_count = 0;
        for (position, row) in rows.iter().enumerate() {
            match row {
                ListingRow::Heading(_) => heading_positions.push(position),
                ListingRow::Document(_) => document_count += 1,
            }
        }
        DocumentListing {
            request,
            content_revision,
            rows,
            heading_positions,
            document_count,
        }
    }

    pub fn request(&self) -> &ListingRequest {
        &self.request
    }

    /// The content revision of the copy the rows were read at.
    pub fn content_revision(&self) -> u64 {
        self.content_revision
    }

    /// The headings and the documents.
    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn document_count(&self) -> usize {
        self.document_count
    }

    pub fn heading_positions(&self) -> &[usize] {
        &self.heading_positions
    }

    /// At most `count` rows from position `first`, fewer at the listing's end.
    pub fn rows(&self, first: usize, count: usize) -> &[ListingRow] {
        let first = first.min(self.rows.len());
        &self.rows[first..first.saturating_add(count).min(self.rows.len())]
    }

    pub fn position_of(&self, document: &DocumentIdentifier) -> Option<usize> {
        self.rows
            .iter()
            .position(|row| matches!(row, ListingRow::Document(row) if row.identifier == *document))
    }
}

/// What turns one listing into the next, in the positions a table view takes: removals in the
/// preceding listing, insertions and revisions in the following one. A row that changed its
/// place among the rows that stay is a removal and an insertion.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ListingDifference {
    /// Ascending positions in the preceding listing.
    pub removed_positions: Vec<usize>,
    /// Ascending positions in the following listing.
    pub inserted_positions: Vec<usize>,
    /// Ascending positions in the following listing of rows that stay and show something else.
    pub revised_positions: Vec<usize>,
}

/// A new listing, and its difference from the preceding listing when that was of the same
/// request. Without a difference the list shows the listing anew.
#[derive(Clone, Debug, PartialEq)]
pub struct ListingAnswer {
    pub listing: DocumentListing,
    pub difference: Option<ListingDifference>,
}

/// For every pair of listings: removing `removed_positions` from the preceding rows, inserting
/// the following listing's rows at `inserted_positions`, and replacing the rows at
/// `revised_positions` by the following listing's gives the following rows. The rows that stay
/// are the longest run of common rows that keeps its order, so a change moves as few rows as
/// can be.
pub fn listing_difference(preceding: &DocumentListing, following: &DocumentListing) -> ListingDifference {
    let following_positions: HashMap<RowIdentity<'_>, usize> = following
        .rows
        .iter()
        .enumerate()
        .map(|(position, row)| (row.identity(), position))
        .collect();
    let common: Vec<(usize, usize)> = preceding
        .rows
        .iter()
        .enumerate()
        .filter_map(|(position, row)| Some((position, *following_positions.get(&row.identity())?)))
        .collect();
    let mut stays_in_preceding = vec![false; preceding.rows.len()];
    let mut stays_in_following = vec![false; following.rows.len()];
    let mut difference = ListingDifference::default();
    for index in longest_ascending_run(&common) {
        let (preceding_position, following_position) = common[index];
        stays_in_preceding[preceding_position] = true;
        stays_in_following[following_position] = true;
        if preceding.rows[preceding_position] != following.rows[following_position] {
            difference.revised_positions.push(following_position);
        }
    }
    let positions_leaving = |stays: Vec<bool>| -> Vec<usize> {
        stays
            .into_iter()
            .enumerate()
            .filter_map(|(position, stays)| (!stays).then_some(position))
            .collect()
    };
    difference.removed_positions = positions_leaving(stays_in_preceding);
    difference.inserted_positions = positions_leaving(stays_in_following);
    difference
}

/// The indexes of a longest run of pairs whose second members ascend, in the order of the pairs.
fn longest_ascending_run(pairs: &[(usize, usize)]) -> Vec<usize> {
    // `ends[length - 1]` is the pair with the smallest second member that ends an ascending run
    // of that length, and `preceding_in_run` leads from each pair back through its run.
    let mut ends: Vec<usize> = Vec::new();
    let mut preceding_in_run: Vec<Option<usize>> = Vec::with_capacity(pairs.len());
    for (index, (_, value)) in pairs.iter().enumerate() {
        let length = ends.partition_point(|&end| pairs[end].1 < *value);
        preceding_in_run.push(length.checked_sub(1).map(|shorter| ends[shorter]));
        if length == ends.len() {
            ends.push(index);
        } else {
            ends[length] = index;
        }
    }
    let mut run = Vec::with_capacity(ends.len());
    let mut next = ends.last().copied();
    while let Some(index) = next {
        run.push(index);
        next = preceding_in_run[index];
    }
    run.reverse();
    run
}

/// A member, category, or tag of the sidebar with the number of its documents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeCount {
    pub scope: NamedScope,
    pub documents: u64,
}

/// The sidebar's counts, read at one content revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplicaFacets {
    pub content_revision: u64,
    pub documents: u64,
    pub documents_in_ingestion: u64,
    pub documents_failed: u64,
    pub household_documents: u64,
    /// Every member, by name.
    pub members: Vec<ScopeCount>,
    /// The categories with a document, the one with the most documents first.
    pub categories: Vec<ScopeCount>,
    /// The tags with a document, the one with the most documents first.
    pub tags: Vec<ScopeCount>,
}
