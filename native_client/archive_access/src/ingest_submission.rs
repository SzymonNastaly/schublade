//! A person's upload of one file through `POST /api/documents/ingest`, the multipart route of the
//! iPhone builds before the reception. The request is written to a file for the iPhone's
//! background transfer, which uploads from a file and continues while the application is
//! suspended, so this module writes the body and reads the answer, and the platform moves the
//! bytes. No wire type leaves it. It goes once the iPhone sends to the reception (unit C2 of
//! `notes/client_preprocessing_design.md`).

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::Path;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::archive_address::ArchiveAddress;
use crate::archive_identifiers::DocumentIdentifier;
use crate::archive_token::ArchiveToken;
use crate::document_submission::{MAXIMUM_DOCUMENT_BYTES, SubmissionAnswer, SubmissionPreparationFailure};

/// The path of the ingest route, as `src/ingestion/token_ingestion_path.ts` names it.
pub const INGEST_PATH: &str = "/api/documents/ingest";

/// The kinds of file the archive accepts, as `src/ingestion/source_file.ts` lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmissionMediaType {
    Pdf,
    Jpeg,
    Png,
    Webp,
}

impl SubmissionMediaType {
    pub fn media_type(self) -> &'static str {
        match self {
            SubmissionMediaType::Pdf => "application/pdf",
            SubmissionMediaType::Jpeg => "image/jpeg",
            SubmissionMediaType::Png => "image/png",
            SubmissionMediaType::Webp => "image/webp",
        }
    }
}

/// The request that sends a written body: the platform sets these two headers and uploads the
/// body's file to the URL with POST. The authorization holds the token, so it is never logged.
#[derive(Clone, PartialEq, Eq)]
pub struct PreparedIngestSubmission {
    pub url: String,
    pub content_type: String,
    pub authorization: String,
    pub body_bytes: u64,
}

impl std::fmt::Debug for PreparedIngestSubmission {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PreparedIngestSubmission")
            .field("url", &self.url)
            .field("content_type", &self.content_type)
            .field("body_bytes", &self.body_bytes)
            .finish_non_exhaustive()
    }
}

/// Streams the multipart body of one file to `destination` without holding the file in memory,
/// and returns the request that sends it. The boundary is derived from the file's SHA-256, so the
/// same file always gives the same body, and the boundary cannot occur in it.
pub fn prepare_ingest_submission(
    archive: &ArchiveAddress,
    token: &ArchiveToken,
    document: &Path,
    file_name: &str,
    media_type: SubmissionMediaType,
    destination: &Path,
) -> Result<PreparedIngestSubmission, SubmissionPreparationFailure> {
    let unreadable = |error: std::io::Error| SubmissionPreparationFailure::DocumentUnreadable {
        detail: error.to_string(),
    };
    let unwritable = |error: std::io::Error| SubmissionPreparationFailure::BodyUnwritable {
        detail: error.to_string(),
    };
    let document_bytes = std::fs::metadata(document).map_err(unreadable)?.len();
    if document_bytes > MAXIMUM_DOCUMENT_BYTES {
        return Err(SubmissionPreparationFailure::DocumentTooLarge { bytes: document_bytes });
    }

    let mut digest = Sha256::new();
    let mut reader = BufReader::new(File::open(document).map_err(unreadable)?);
    let mut block = [0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut block).map_err(unreadable)?;
        if read == 0 {
            break;
        }
        digest.update(&block[..read]);
    }
    let boundary = format!("schublade-{}", hex(&digest.finalize()));

    let opening = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{}\"\r\nContent-Type: {}\r\n\r\n",
        quoted_file_name(file_name),
        media_type.media_type()
    );
    let closing = format!("\r\n--{boundary}--\r\n");
    let mut body = BufWriter::new(File::create(destination).map_err(unwritable)?);
    body.write_all(opening.as_bytes()).map_err(unwritable)?;
    let copied = std::io::copy(
        &mut BufReader::new(File::open(document).map_err(unreadable)?).take(document_bytes),
        &mut body,
    )
    .map_err(unwritable)?;
    body.write_all(closing.as_bytes()).map_err(unwritable)?;
    body.into_inner()
        .map_err(|error| unwritable(error.into_error()))?
        .sync_all()
        .map_err(unwritable)?;

    Ok(PreparedIngestSubmission {
        url: format!("{}{INGEST_PATH}", archive.origin()),
        content_type: format!("multipart/form-data; boundary={boundary}"),
        authorization: format!("Bearer {}", token.secret()),
        body_bytes: u64::try_from(opening.len() + closing.len()).unwrap_or(u64::MAX) + copied,
    })
}

/// A file name inside the quotes of `Content-Disposition`, escaped as browsers escape it for
/// `multipart/form-data`: a quotation mark and the two line breaks as percent sequences.
fn quoted_file_name(file_name: &str) -> String {
    file_name.replace('"', "%22").replace('\r', "%0D").replace('\n', "%0A")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[derive(Deserialize)]
struct UploadAnswer {
    outcomes: Vec<UploadOutcome>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum UploadOutcome {
    Accepted {
        #[serde(rename = "documentId")]
        document_id: String,
    },
    AlreadyArchived {
        #[serde(rename = "documentId")]
        document_id: String,
    },
    Rejected {
        reason: String,
    },
    Failed,
}

#[derive(Deserialize)]
struct RefusalAnswer {
    error: String,
}

/// Reads the archive's answer to a request of one file, whatever its status.
pub fn read_ingest_submission_answer(status: u16, body: &[u8]) -> SubmissionAnswer {
    match status {
        200 => {
            let Ok(UploadAnswer { outcomes }) = serde_json::from_slice::<UploadAnswer>(body) else {
                return SubmissionAnswer::ArchiveUnavailable;
            };
            let archived = |document_id: String, already_held| {
                DocumentIdentifier::parse(&document_id).map_or(SubmissionAnswer::ArchiveUnavailable, |document| {
                    SubmissionAnswer::Archived { document, already_held }
                })
            };
            match outcomes.into_iter().next() {
                Some(UploadOutcome::Accepted { document_id }) => archived(document_id, false),
                Some(UploadOutcome::AlreadyArchived { document_id }) => archived(document_id, true),
                Some(UploadOutcome::Rejected { reason }) => SubmissionAnswer::Rejected { reason },
                Some(UploadOutcome::Failed) | None => SubmissionAnswer::ArchiveUnavailable,
            }
        }
        401 => SubmissionAnswer::TokenRefused,
        403 => SubmissionAnswer::NotPermitted,
        400 | 405 | 413 | 415 => SubmissionAnswer::Rejected {
            reason: serde_json::from_slice::<RefusalAnswer>(body)
                .map(|answer| answer.error)
                .unwrap_or_else(|_| format!("The archive refused the upload with status {status}.")),
        },
        _ => SubmissionAnswer::ArchiveUnavailable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOCUMENT: &str = "11111111-2222-4333-8444-555555555555";

    #[test]
    fn the_body_holds_the_file_between_one_boundary_derived_from_its_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("scan.pdf");
        std::fs::write(&document, b"%PDF-1.4 a letter").unwrap();
        let body = directory.path().join("request_body");

        let prepared = prepare_ingest_submission(
            &ArchiveAddress::parse("https://archive.example.org/").unwrap(),
            &ArchiveToken::new("secret-token".to_owned()),
            &document,
            "Brief \"Stadtwerke\"\n.pdf",
            SubmissionMediaType::Pdf,
            &body,
        )
        .unwrap();

        let boundary = format!("schublade-{}", hex(&Sha256::digest(b"%PDF-1.4 a letter")));
        let expected = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"Brief %22Stadtwerke%22%0A.pdf\"\r\nContent-Type: application/pdf\r\n\r\n%PDF-1.4 a letter\r\n--{boundary}--\r\n"
        );
        assert_eq!(std::fs::read_to_string(&body).unwrap(), expected);
        assert_eq!(prepared.url, "https://archive.example.org/api/documents/ingest");
        assert_eq!(
            prepared.content_type,
            format!("multipart/form-data; boundary={boundary}")
        );
        assert_eq!(prepared.authorization, "Bearer secret-token");
        assert_eq!(prepared.body_bytes, u64::try_from(expected.len()).unwrap());
        assert!(!format!("{prepared:?}").contains("secret-token"));
    }

    #[test]
    fn a_document_above_the_limit_is_refused_before_a_body_is_written() {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("long scan.pdf");
        File::create(&document)
            .unwrap()
            .set_len(MAXIMUM_DOCUMENT_BYTES + 1)
            .unwrap();
        let body = directory.path().join("request_body");

        let failure = prepare_ingest_submission(
            &ArchiveAddress::parse("https://archive.example.org").unwrap(),
            &ArchiveToken::new("secret-token".to_owned()),
            &document,
            "long scan.pdf",
            SubmissionMediaType::Pdf,
            &body,
        )
        .unwrap_err();

        assert_eq!(
            failure,
            SubmissionPreparationFailure::DocumentTooLarge {
                bytes: MAXIMUM_DOCUMENT_BYTES + 1
            }
        );
        assert!(!body.exists());
    }

    #[test]
    fn each_answer_of_the_ingest_route_reads_as_what_the_application_does_next() {
        let document = DocumentIdentifier::parse(DOCUMENT).unwrap();
        let outcome = |json: &str| read_ingest_submission_answer(200, format!(r#"{{"outcomes":[{json}]}}"#).as_bytes());

        assert_eq!(
            outcome(&format!(
                r#"{{"kind":"accepted","fileName":"scan.pdf","documentId":"{DOCUMENT}"}}"#
            )),
            SubmissionAnswer::Archived {
                document: document.clone(),
                already_held: false
            }
        );
        assert_eq!(
            outcome(&format!(
                r#"{{"kind":"already_archived","fileName":"scan.pdf","documentId":"{DOCUMENT}"}}"#
            )),
            SubmissionAnswer::Archived {
                document,
                already_held: true
            }
        );
        assert_eq!(
            outcome(r#"{"kind":"rejected","fileName":"notes.txt","reason":"Only PDF files can be archived."}"#),
            SubmissionAnswer::Rejected {
                reason: "Only PDF files can be archived.".to_owned()
            }
        );
        assert_eq!(
            outcome(r#"{"kind":"failed","fileName":"scan.pdf","reason":"Upload it again."}"#),
            SubmissionAnswer::ArchiveUnavailable
        );
        assert_eq!(
            read_ingest_submission_answer(200, b"<html>"),
            SubmissionAnswer::ArchiveUnavailable
        );
        assert_eq!(read_ingest_submission_answer(401, b""), SubmissionAnswer::TokenRefused);
        assert_eq!(
            read_ingest_submission_answer(403, b"{}"),
            SubmissionAnswer::NotPermitted
        );
        assert_eq!(
            read_ingest_submission_answer(413, br#"{"error":"The upload is larger than 50 MB."}"#),
            SubmissionAnswer::Rejected {
                reason: "The upload is larger than 50 MB.".to_owned()
            }
        );
        assert_eq!(
            read_ingest_submission_answer(503, b""),
            SubmissionAnswer::ArchiveUnavailable
        );
    }
}
