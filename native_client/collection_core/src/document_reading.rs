//! What a collector reads from a document before it sends it: the text of each page and a JPEG of
//! the first page, which the archive stores beside the original so it need not read the document
//! itself. The platform supplies the reader: PDFKit and Vision in the Mac application, PDFium in
//! `schublade-collector`. PDFium stays out of this crate, so the applications never link it.

pub use archive_access::DerivedRepresentations;

use crate::file_system_observation::VerifiedContent;

/// Reads a document whose bytes a submission verified. Called on a submission lane, so two
/// documents can be read at once.
pub trait DocumentReader: Send + Sync {
    /// Never fails: a reader that cannot read a document, or a page of it, leaves it out, and the
    /// archive reads the original itself. So reading never holds back a submission.
    fn read(&self, content: &VerifiedContent) -> DerivedRepresentations;
}

/// Reads nothing, so the archive reads every original itself, as it did before collectors sent
/// what they read.
pub struct EmptyDocumentReader;

impl DocumentReader for EmptyDocumentReader {
    fn read(&self, _content: &VerifiedContent) -> DerivedRepresentations {
        DerivedRepresentations::default()
    }
}
