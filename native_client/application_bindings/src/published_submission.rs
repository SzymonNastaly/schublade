//! A person's document sent to the reception, as the iPhone's application and its share extension
//! prepare and answer it. Both functions are free, so the share extension calls them without
//! starting an `ApplicationCore`: the first reads the token from the Keychain and writes the
//! request's body to a file, the second reads the archive's answer. The platform's background
//! transfer moves the bytes between them.

use std::collections::HashMap;
use std::path::Path;

use archive_access::{ArchiveAddress, DerivedRepresentations, SubmissionAnswer, SubmissionPreparationFailure};

use crate::CredentialStorage;
use crate::published_library::DocumentIdentifier;

/// The request that sends a prepared body: PUT the body's file to `url` with exactly these headers.
#[derive(uniffi::Record, Clone, PartialEq, Eq)]
pub struct DocumentSubmissionRequest {
    pub url: String,
    /// The Authorization header among them holds the token; set them and never keep or log them.
    pub headers: HashMap<String, String>,
    pub body_bytes: u64,
}

impl std::fmt::Debug for DocumentSubmissionRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DocumentSubmissionRequest")
            .field("url", &self.url)
            .field("header_names", &self.headers.keys().collect::<Vec<_>>())
            .field("body_bytes", &self.body_bytes)
            .finish()
    }
}

/// Why no request was prepared.
#[derive(uniffi::Error, Clone, Debug, PartialEq, Eq)]
pub enum SubmissionPreparationRefusal {
    AddressInvalid,
    /// The Keychain holds no token for this archive, so the application must connect first.
    TokenMissing,
    CredentialStorageFailed {
        detail: String,
    },
    /// The archive accepts at most 25,000,000 bytes per document.
    DocumentTooLarge {
        bytes: u64,
    },
    DocumentUnreadable {
        detail: String,
    },
    BodyUnwritable {
        detail: String,
    },
}

impl std::fmt::Display for SubmissionPreparationRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

/// What the archive answered to one sent document.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum DocumentSubmissionAnswer {
    /// The archive holds the bytes, as a new document or, with `already_held`, an existing one.
    Archived {
        document: DocumentIdentifier,
        already_held: bool,
    },
    /// The archive will never take these bytes as they are; sending them again changes nothing.
    Rejected {
        reason: String,
    },
    TokenRefused,
    NotPermitted,
    /// Sending the same body again may succeed.
    ArchiveUnavailable,
}

/// Reads the token of `archive_origin` from `credential_storage` and writes to `destination_path`
/// the body that sends the document at `document_path` with the text of each page and the JPEG at
/// `thumbnail_path`. A thumbnail that cannot be read is left out, and the archive draws none.
#[uniffi::export]
pub fn prepare_document_submission(
    archive_origin: String,
    credential_storage: CredentialStorage,
    document_path: String,
    page_texts: Vec<String>,
    thumbnail_path: Option<String>,
    destination_path: String,
) -> Result<DocumentSubmissionRequest, SubmissionPreparationRefusal> {
    let address = ArchiveAddress::parse(&archive_origin).map_err(|_| SubmissionPreparationRefusal::AddressInvalid)?;
    let token = credential_storage
        .store()
        .read(&address)
        .map_err(|failure| SubmissionPreparationRefusal::CredentialStorageFailed { detail: failure.detail })?
        .ok_or(SubmissionPreparationRefusal::TokenMissing)?;
    let derived = DerivedRepresentations {
        page_texts,
        thumbnail: thumbnail_path.and_then(|path| std::fs::read(path).ok()),
    };
    let prepared = archive_access::prepare_submission(
        &address,
        &token,
        Path::new(&document_path),
        &derived,
        Path::new(&destination_path),
    )
    .map_err(|failure| match failure {
        SubmissionPreparationFailure::DocumentTooLarge { bytes } => {
            SubmissionPreparationRefusal::DocumentTooLarge { bytes }
        }
        SubmissionPreparationFailure::DocumentUnreadable { detail } => {
            SubmissionPreparationRefusal::DocumentUnreadable { detail }
        }
        SubmissionPreparationFailure::BodyUnwritable { detail } => {
            SubmissionPreparationRefusal::BodyUnwritable { detail }
        }
    })?;
    Ok(DocumentSubmissionRequest {
        url: prepared.url,
        headers: prepared.headers.into_iter().collect(),
        body_bytes: prepared.body_bytes,
    })
}

/// Reads the archive's answer to a sent body: its HTTP status, its `Content-Type`, and its body,
/// empty when none came.
#[uniffi::export]
pub fn read_document_submission_answer(
    status: u16,
    content_type: Option<String>,
    body: Vec<u8>,
) -> DocumentSubmissionAnswer {
    match archive_access::read_submission_answer(status, content_type.as_deref(), &body) {
        SubmissionAnswer::Archived { document, already_held } => DocumentSubmissionAnswer::Archived {
            document: DocumentIdentifier {
                value: document.as_str().to_owned(),
            },
            already_held,
        },
        SubmissionAnswer::Rejected { reason } => DocumentSubmissionAnswer::Rejected { reason },
        SubmissionAnswer::TokenRefused => DocumentSubmissionAnswer::TokenRefused,
        SubmissionAnswer::NotPermitted => DocumentSubmissionAnswer::NotPermitted,
        // An Access application that does not list /api/v1 refuses the path until the owner
        // corrects it, so the submission is sent again later rather than given up.
        SubmissionAnswer::RouteUnknown | SubmissionAnswer::ArchiveUnavailable => {
            DocumentSubmissionAnswer::ArchiveUnavailable
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_submission_without_a_stored_token_asks_for_a_connection_first() {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("scan.pdf");
        std::fs::write(&document, b"%PDF-1.4").unwrap();

        let refusal = prepare_document_submission(
            "https://archive.example.org".to_owned(),
            CredentialStorage::ProcessMemory,
            document.to_string_lossy().into_owned(),
            Vec::new(),
            None,
            directory.path().join("request_body").to_string_lossy().into_owned(),
        )
        .unwrap_err();

        assert_eq!(refusal, SubmissionPreparationRefusal::TokenMissing);
    }
}
