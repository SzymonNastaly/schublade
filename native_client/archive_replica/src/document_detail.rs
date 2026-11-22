//! One document as an inspector shows it: every name resolved, every field typed, and what the
//! file of its original is called.

use archive_access::{DocumentIdentifier, Timestamp};

use crate::document_listing::NamedScope;
use crate::replica_records::{CalendarDate, DocumentCondition, FieldValue};

/// What kind of file a document's original is, from its media type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OriginalKind {
    PortableDocument,
    JpegImage,
    PngImage,
    WebpImage,
    /// An email that the archive has not printed as a PDF yet. It has no original to read.
    UnprintedEmail,
    /// A media type that a newer archive accepts and this client does not know.
    Unrecognized,
}

impl OriginalKind {
    pub fn of_media_type(media_type: &str) -> OriginalKind {
        match media_type {
            "application/pdf" => OriginalKind::PortableDocument,
            "image/jpeg" => OriginalKind::JpegImage,
            "image/png" => OriginalKind::PngImage,
            "image/webp" => OriginalKind::WebpImage,
            "message/rfc822" => OriginalKind::UnprintedEmail,
            _ => OriginalKind::Unrecognized,
        }
    }

    /// The extension of a file of this kind, by which the system chooses how to open it.
    pub fn file_extension(self) -> &'static str {
        match self {
            OriginalKind::PortableDocument => "pdf",
            OriginalKind::JpegImage => "jpg",
            OriginalKind::PngImage => "png",
            OriginalKind::WebpImage => "webp",
            OriginalKind::UnprintedEmail => "eml",
            OriginalKind::Unrecognized => "bin",
        }
    }
}

/// Whom a classified document concerns.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentPerson {
    Household,
    Member(NamedScope),
}

#[derive(Clone, Debug, PartialEq)]
pub struct DetailField {
    /// The archive's key, such as `amount` or `due_date`.
    pub key: String,
    pub value: FieldValue,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DocumentDetail {
    pub identifier: DocumentIdentifier,
    pub condition: DocumentCondition,
    pub title: Option<String>,
    pub document_date: Option<CalendarDate>,
    pub sender: Option<NamedScope>,
    pub category: Option<NamedScope>,
    /// `None` while the archive has not classified the document.
    pub person: Option<DocumentPerson>,
    /// By name.
    pub tags: Vec<NamedScope>,
    pub summary: Option<String>,
    /// The fields the document's category expects, in the category's order, then every other
    /// field by its key.
    pub fields: Vec<DetailField>,
    pub original_kind: OriginalKind,
    pub byte_size: u64,
    pub page_count: Option<u32>,
    pub arrived_at: Timestamp,
    /// The document's page in the browser.
    pub archive_page: String,
    /// What a copy of the original is called outside the application, such as
    /// `2026-09-22 Stadtwerke Talbrück Electricity Annual Statement.pdf`.
    pub suggested_file_name: String,
}

/// The longest name before the extension, in characters. A file system takes 255 bytes.
const LONGEST_FILE_NAME_CHARACTERS: usize = 120;

/// The listing date, the sender, and the title, without the characters a file system or a
/// shell reads as something else.
pub(crate) fn suggested_file_name(
    listing_date: &str,
    sender_name: Option<&str>,
    title: Option<&str>,
    kind: OriginalKind,
) -> String {
    let name = [Some(listing_date), sender_name, Some(title.unwrap_or("Document"))]
        .into_iter()
        .flatten()
        .flat_map(|part| part.split(|character: char| character.is_control() || matches!(character, '/' | '\\' | ':')))
        .flat_map(str::split_whitespace)
        .collect::<Vec<&str>>()
        .join(" ");
    let name: String = name.chars().take(LONGEST_FILE_NAME_CHARACTERS).collect();
    format!("{}.{}", name.trim_end(), kind.file_extension())
}
