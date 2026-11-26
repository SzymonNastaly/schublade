//! A document sent to the archive's reception: `PUT /api/v1/submitted_documents/{sha256}` for a
//! person and `PUT /api/v1/collected_documents/{sha256}` for a collector. The body is the text the
//! client read, then the JPEG of the first page it drew, then the original, with no separator, and
//! two headers count the first two. The iPhone writes the body to a file for its background
//! transfer, which continues while the application is suspended, and a collector sends the parts
//! from memory. `notes/client_protocol.md`, "Receiving a document", defines the wire, and no wire
//! type leaves this module.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::Path;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::archive_address::ArchiveAddress;
use crate::archive_exchange::{ArchiveCondition, ArchiveExchange, ArchiveResponse, is_problem_json};
use crate::archive_identifiers::{ContentDigest, DocumentIdentifier};
use crate::archive_token::ArchiveToken;

/// The most bytes the archive archives as one document, `MAXIMUM_DOCUMENT_BYTES` of
/// `src/ingestion/document_upload.ts`.
pub const MAXIMUM_DOCUMENT_BYTES: u64 = 25_000_000;
/// The longest text the reception takes, as `src/ingestion/reception_headers.ts` limits it. A
/// longer text belongs to a PDF with a text layer, which the archive reads itself.
pub const MAXIMUM_TEXT_BYTES: usize = 2_000_000;
/// The largest thumbnail the reception takes, as `src/ingestion/reception_headers.ts` limits it.
pub const MAXIMUM_THUMBNAIL_BYTES: usize = 200_000;
const JPEG_SIGNATURE: [u8; 3] = [0xff, 0xd8, 0xff];

/// The two paths of the reception. They differ only in the rules a collector obeys: the collector's
/// path answers 409 for a content whose document the owner deleted and 503 while a digest is
/// missing, and a person's path archives a deleted content again, because a person chose to send.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmissionRoute {
    SubmittedDocuments,
    CollectedDocuments,
}

impl SubmissionRoute {
    pub fn path(self, digest: &ContentDigest) -> String {
        let collection = match self {
            SubmissionRoute::SubmittedDocuments => "submitted_documents",
            SubmissionRoute::CollectedDocuments => "collected_documents",
        };
        format!("/api/v1/{collection}/{}", digest.hexadecimal())
    }
}

/// What a client read from a document: the text of each page in page order, and a JPEG of the
/// first page. A client that read nothing sends the default, and the archive reads the original
/// itself.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DerivedRepresentations {
    pub page_texts: Vec<String>,
    pub thumbnail: Option<Vec<u8>>,
}

/// The text of a document as the archive stores a text layer: a `## Page N` heading for each page
/// in page order, each page's text without its surrounding white space, and a page without text
/// keeping its heading, so the page numbers stay right.
pub fn compose_document_text(page_texts: &[String]) -> String {
    page_texts
        .iter()
        .enumerate()
        .map(|(index, text)| match text.trim() {
            "" => format!("## Page {}\n", index + 1),
            text => format!("## Page {}\n\n{text}\n", index + 1),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The counted part of a body. A text or a thumbnail beyond the reception's limits, or a
/// thumbnail that is no JPEG, is left out, because the reception would refuse the original with
/// it and reads the original without it.
struct ReceptionPrefix<'derived> {
    text: Vec<u8>,
    thumbnail: &'derived [u8],
    page_count: Option<usize>,
}

impl ReceptionPrefix<'_> {
    fn new(derived: &DerivedRepresentations) -> ReceptionPrefix<'_> {
        let text = compose_document_text(&derived.page_texts).into_bytes();
        let thumbnail = derived
            .thumbnail
            .as_deref()
            .filter(|thumbnail| thumbnail.len() <= MAXIMUM_THUMBNAIL_BYTES && thumbnail.starts_with(&JPEG_SIGNATURE))
            .unwrap_or_default();
        ReceptionPrefix {
            text: if text.len() <= MAXIMUM_TEXT_BYTES {
                text
            } else {
                Vec::new()
            },
            thumbnail,
            page_count: Some(derived.page_texts.len()).filter(|count| *count > 0),
        }
    }

    fn headers(&self) -> Vec<(String, String)> {
        let mut headers = vec![
            ("Schublade-Text-Byte-Count".to_owned(), self.text.len().to_string()),
            (
                "Schublade-Thumbnail-Byte-Count".to_owned(),
                self.thumbnail.len().to_string(),
            ),
        ];
        if let Some(page_count) = self.page_count {
            headers.push(("Schublade-Page-Count".to_owned(), page_count.to_string()));
        }
        headers
    }

    fn byte_count(&self) -> u64 {
        u64::try_from(self.text.len() + self.thumbnail.len()).unwrap_or(u64::MAX)
    }
}

/// The request that sends a written body: the platform uploads the body's file to the URL with
/// PUT and these headers. The headers hold the token, so they are never logged.
#[derive(Clone, PartialEq, Eq)]
pub struct PreparedSubmission {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body_bytes: u64,
}

impl std::fmt::Debug for PreparedSubmission {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let header_names: Vec<&str> = self.headers.iter().map(|(name, _)| name.as_str()).collect();
        formatter
            .debug_struct("PreparedSubmission")
            .field("url", &self.url)
            .field("header_names", &header_names)
            .field("body_bytes", &self.body_bytes)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmissionPreparationFailure {
    /// The document is larger than the archive accepts, so sending it would only be refused.
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

/// What the archive answered to one document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmissionAnswer {
    /// The archive holds the bytes: as a new document, or, with `already_held`, as the document
    /// that held them before.
    Archived {
        document: DocumentIdentifier,
        already_held: bool,
    },
    /// The archive will never take this body as it is: its kind, its size, a digest that does not
    /// match, or a request it cannot read. Sending it again changes nothing.
    Rejected { reason: String },
    /// 401: the token is unknown or revoked.
    TokenRefused,
    /// 403 with a problem document: the token's level does not permit sending, or its scope is
    /// restricted.
    NotPermitted,
    /// 403 without a problem document: the archive is older than the reception. The client holds
    /// the submission and asks the owner to update the archive.
    RouteUnknown,
    /// Storing failed, the archive answered 5xx, or its answer could not be read. Sending the same
    /// body again may succeed.
    ArchiveUnavailable,
}

/// Writes the body of a person's submission to `destination` without holding the document in
/// memory, and returns the request that sends it to `submitted_documents` under the document's
/// SHA-256, which the same pass computes.
pub fn prepare_submission(
    archive: &ArchiveAddress,
    token: &ArchiveToken,
    document: &Path,
    derived: &DerivedRepresentations,
    destination: &Path,
) -> Result<PreparedSubmission, SubmissionPreparationFailure> {
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

    let prefix = ReceptionPrefix::new(derived);
    let mut original = BufReader::new(File::open(document).map_err(unreadable)?).take(document_bytes);
    let mut body = BufWriter::new(File::create(destination).map_err(unwritable)?);
    body.write_all(&prefix.text).map_err(unwritable)?;
    body.write_all(prefix.thumbnail).map_err(unwritable)?;
    let mut digest = Sha256::new();
    let mut copied = 0_u64;
    let mut block = [0_u8; 64 * 1024];
    loop {
        let read = original.read(&mut block).map_err(unreadable)?;
        if read == 0 {
            break;
        }
        digest.update(&block[..read]);
        body.write_all(&block[..read]).map_err(unwritable)?;
        copied += u64::try_from(read).unwrap_or(u64::MAX);
    }
    body.into_inner()
        .map_err(|error| unwritable(error.into_error()))?
        .sync_all()
        .map_err(unwritable)?;

    let digest = ContentDigest::from_bytes(digest.finalize().into());
    let mut headers = vec![("Authorization".to_owned(), format!("Bearer {}", token.secret()))];
    headers.extend(prefix.headers());
    Ok(PreparedSubmission {
        url: format!(
            "{}{}",
            archive.origin(),
            SubmissionRoute::SubmittedDocuments.path(&digest)
        ),
        headers,
        body_bytes: prefix.byte_count() + copied,
    })
}

/// Sends one document whose original is in memory, as a collector holds it, without copying the
/// original into one body with its prefix.
pub fn send_document(
    exchange: &ArchiveExchange,
    route: SubmissionRoute,
    digest: &ContentDigest,
    derived: &DerivedRepresentations,
    original: &[u8],
) -> Result<ArchiveResponse, ArchiveCondition> {
    let prefix = ReceptionPrefix::new(derived);
    exchange.put_document(
        &route.path(digest),
        &prefix.headers(),
        &[&prefix.text, prefix.thumbnail, original],
    )
}

#[derive(Deserialize)]
struct ReceptionAnswer {
    document_id: String,
}

#[derive(Deserialize)]
struct ProblemAnswer {
    detail: String,
}

/// Reads the reception's answer to a sent body from its status, its `Content-Type`, and its body,
/// empty when none came.
pub fn read_submission_answer(status: u16, content_type: Option<&str>, body: &[u8]) -> SubmissionAnswer {
    match status {
        200 | 202 => serde_json::from_slice::<ReceptionAnswer>(body)
            .ok()
            .and_then(|answer| DocumentIdentifier::parse(&answer.document_id))
            .map_or(SubmissionAnswer::ArchiveUnavailable, |document| {
                SubmissionAnswer::Archived {
                    document,
                    already_held: status == 200,
                }
            }),
        401 => SubmissionAnswer::TokenRefused,
        403 if is_problem_json(content_type) => SubmissionAnswer::NotPermitted,
        403 => SubmissionAnswer::RouteUnknown,
        400 | 411 | 413 | 415 | 422 => SubmissionAnswer::Rejected {
            reason: serde_json::from_slice::<ProblemAnswer>(body)
                .map(|problem| problem.detail)
                .unwrap_or_else(|_| format!("The archive refused the document with status {status}.")),
        },
        _ => SubmissionAnswer::ArchiveUnavailable,
    }
}

/// Whether an archive offers the reception.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentReception {
    Offered,
    /// The archive is older than the reception, so a client holds its documents until the owner
    /// updates it.
    Absent,
}

/// Asks the archive whether it offers the reception without sending a document: a GET, which the
/// reception answers 405 before it reads the token, while an older archive answers the plain 403
/// of Cloudflare Access.
pub fn read_document_reception(exchange: &ArchiveExchange) -> Result<DocumentReception, ArchiveCondition> {
    let probe = SubmissionRoute::SubmittedDocuments.path(&ContentDigest::from_bytes([0; 32]));
    match exchange.get(&probe) {
        Ok(response) if response.status() == 405 => Ok(DocumentReception::Offered),
        Ok(response) => Err(response.protocol_violation()),
        Err(ArchiveCondition::RouteUnknown) => Ok(DocumentReception::Absent),
        Err(condition) => Err(condition),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOCUMENT: &str = "11111111-2222-4333-8444-555555555555";

    #[test]
    fn the_body_is_the_shared_text_the_thumbnail_and_the_original_under_their_counts() {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("scan.pdf");
        std::fs::write(&document, b"%PDF-1.4 a letter").unwrap();
        let body = directory.path().join("request_body");
        let thumbnail = vec![0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9];
        let derived = DerivedRepresentations {
            page_texts: vec![
                "Stadtwerke Talbrück GmbH\nJahresabrechnung Strom 2025-2026\nRechnungsnummer JA-2026-0381547\n"
                    .to_owned(),
                " \n".to_owned(),
                "Nachzahlungsbetrag 72,09 €\nFällig am 06.10.2026".to_owned(),
            ],
            thumbnail: Some(thumbnail.clone()),
        };

        let prepared = prepare_submission(
            &ArchiveAddress::parse("https://archive.example.org/").unwrap(),
            &ArchiveToken::new("secret-token".to_owned()),
            &document,
            &derived,
            &body,
        )
        .unwrap();

        let text = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../test_fixtures/client_protocol/submitted_document_text.md"
        ))
        .unwrap();
        assert_eq!(
            std::fs::read(&body).unwrap(),
            [text.as_slice(), &thumbnail, b"%PDF-1.4 a letter"].concat()
        );
        assert_eq!(
            prepared.url,
            format!(
                "https://archive.example.org/api/v1/submitted_documents/{}",
                ContentDigest::from_bytes(Sha256::digest(b"%PDF-1.4 a letter").into()).hexadecimal()
            )
        );
        let header = |name: &str| {
            prepared
                .headers
                .iter()
                .find(|(header, _)| header == name)
                .map(|(_, value)| value.as_str())
        };
        assert_eq!(header("Authorization"), Some("Bearer secret-token"));
        assert_eq!(
            header("Schublade-Text-Byte-Count"),
            Some(text.len().to_string().as_str())
        );
        assert_eq!(header("Schublade-Thumbnail-Byte-Count"), Some("6"));
        assert_eq!(header("Schublade-Page-Count"), Some("3"));
        assert_eq!(prepared.body_bytes, u64::try_from(text.len() + 6 + 17).unwrap());
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

        let failure = prepare_submission(
            &ArchiveAddress::parse("https://archive.example.org").unwrap(),
            &ArchiveToken::new("secret-token".to_owned()),
            &document,
            &DerivedRepresentations::default(),
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
    fn each_answer_of_the_reception_reads_as_what_the_application_does_next() {
        let document = DocumentIdentifier::parse(DOCUMENT).unwrap();
        let status_body = format!(r#"{{"document_id":"{DOCUMENT}","status":"processing","failure_reason":null}}"#);
        let problem = Some("application/problem+json");
        let refusal =
            br#"{"type":"about:blank","title":"Problem","status":415,"detail":"The thumbnail must be a JPEG"}"#;

        assert_eq!(
            read_submission_answer(202, Some("application/json"), status_body.as_bytes()),
            SubmissionAnswer::Archived {
                document: document.clone(),
                already_held: false
            }
        );
        assert_eq!(
            read_submission_answer(200, Some("application/json"), status_body.as_bytes()),
            SubmissionAnswer::Archived {
                document,
                already_held: true
            }
        );
        assert_eq!(
            read_submission_answer(202, Some("text/html"), b"<html>"),
            SubmissionAnswer::ArchiveUnavailable
        );
        assert_eq!(
            read_submission_answer(415, problem, refusal),
            SubmissionAnswer::Rejected {
                reason: "The thumbnail must be a JPEG".to_owned()
            }
        );
        assert_eq!(
            read_submission_answer(422, None, b""),
            SubmissionAnswer::Rejected {
                reason: "The archive refused the document with status 422.".to_owned()
            }
        );
        assert_eq!(
            read_submission_answer(401, problem, b"{}"),
            SubmissionAnswer::TokenRefused
        );
        assert_eq!(
            read_submission_answer(403, problem, b"{}"),
            SubmissionAnswer::NotPermitted
        );
        assert_eq!(
            read_submission_answer(403, Some("text/html"), b"Forbidden"),
            SubmissionAnswer::RouteUnknown
        );
        assert_eq!(
            read_submission_answer(503, problem, b"{}"),
            SubmissionAnswer::ArchiveUnavailable
        );
    }
}
