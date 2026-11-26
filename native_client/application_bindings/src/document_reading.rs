//! The document reader an application supplies to its collector: PDFKit and Vision in the Mac
//! application. The collector calls it before each submission, and the archive stores what it read
//! beside the original.

use std::sync::Arc;

use collection_core::DerivedRepresentations;
use collection_core::candidate_classification::{ContentKind, identify_content_kind};
use collection_core::file_system_observation::VerifiedContent;

/// The kinds of file the archive accepts.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentMediaType {
    Pdf,
    Jpeg,
    Png,
    Webp,
}

/// What an application read from one document: the text of each page in page order, empty for a
/// page it could not read, and a JPEG of the first page, at most 480 pixels on its longer side.
/// Both empty when it read nothing, and the archive reads the original itself.
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct DocumentReading {
    pub page_texts: Vec<String>,
    pub thumbnail: Option<Vec<u8>>,
}

/// Reads a document the collector is about to send. The collector calls it on its own threads, at
/// most two at once, so a Swift conformance is `nonisolated` and keeps no main-actor state.
#[uniffi::export(with_foreign)]
pub trait DocumentReader: Send + Sync {
    fn read(&self, original: Vec<u8>, media_type: DocumentMediaType) -> DocumentReading;
}

/// The application's reader as the collector calls it.
pub(crate) struct ApplicationDocumentReader(pub(crate) Arc<dyn DocumentReader>);

impl collection_core::DocumentReader for ApplicationDocumentReader {
    fn read(&self, content: &VerifiedContent) -> DerivedRepresentations {
        let Some(kind) = identify_content_kind(content.bytes()) else {
            return DerivedRepresentations::default();
        };
        let media_type = match kind {
            ContentKind::PortableDocument => DocumentMediaType::Pdf,
            ContentKind::JointPhotographicImage => DocumentMediaType::Jpeg,
            ContentKind::PortableNetworkGraphic => DocumentMediaType::Png,
            ContentKind::WebPicture => DocumentMediaType::Webp,
        };
        let DocumentReading { page_texts, thumbnail } = self.0.read(content.bytes().to_vec(), media_type);
        DerivedRepresentations { page_texts, thumbnail }
    }
}
