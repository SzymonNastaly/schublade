//! The seam to the archive. `ArchiveClient` returns domain outcomes only, and no wire type leaves
//! this module; `archive_connection::consequences` decides what each outcome means.

use std::time::Duration;

use archive_access::{ArchiveAddress, ArchiveCondition, ArchiveExchange, ArchiveResponse, ArchiveToken};

use crate::archive_connection::SubmissionCondition;
use crate::content_synchronization::{LookupAnswer, SubmissionAuthorization, SubmissionOutcome};
use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus};
use crate::file_system_observation::VerifiedContent;

/// The three requests of the collection protocol, answered in domain terms. Shared by the worker
/// threads.
pub trait ArchiveClient: Send + Sync {
    /// `POST /api/v1/contents/lookup` with 1 to 1000 digests. Answers in request order; an answer
    /// whose digests differ from the request is a protocol violation.
    fn look_up(&self, digests: &[ContentDigest]) -> Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition>;

    /// `PUT /api/v1/contents/{sha256}`. Consumes the authorization, so one authorization is one
    /// PUT; the content's digest must equal the authorization's.
    fn submit(
        &self,
        authorization: SubmissionAuthorization,
        content: VerifiedContent,
    ) -> Result<SubmissionOutcome, SubmissionCondition>;

    /// `GET /api/v1/documents/{id}`. `Ok(None)` is a 404.
    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition>;
}

/// Speaks the protocol over HTTP through one `ArchiveExchange`.
#[derive(Clone)]
pub struct HttpArchiveClient {
    exchange: ArchiveExchange,
}

impl HttpArchiveClient {
    pub fn new(address: &ArchiveAddress, token: &ArchiveToken) -> HttpArchiveClient {
        HttpArchiveClient {
            exchange: ArchiveExchange::new(address, token),
        }
    }

    /// `base_timeout` bounds a lookup and a status read, and a PUT gets one second more per
    /// 50,000 bytes. Tests shorten it.
    pub fn with_base_timeout(
        address: &ArchiveAddress,
        token: &ArchiveToken,
        base_timeout: Duration,
    ) -> HttpArchiveClient {
        HttpArchiveClient {
            exchange: ArchiveExchange::with_base_timeout(address, token, base_timeout),
        }
    }

    /// Tries a pasted address and token before they are stored: one lookup of a digest that no
    /// file has, which every route answers only for a token with the ingest level.
    pub fn verify_credential(&self) -> Result<(), ArchiveCondition> {
        self.look_up(&[ContentDigest::from_bytes([0; 32])]).map(|_| ())
    }
}

fn document_status(response: &ArchiveResponse) -> Result<(DocumentIdentifier, DocumentStatus), ArchiveCondition> {
    let answer: DocumentStatusAnswer =
        serde_json::from_str(response.body()).map_err(|_| response.protocol_violation())?;
    let document = DocumentIdentifier::parse(&answer.document_id).ok_or_else(|| response.protocol_violation())?;
    let status =
        DocumentStatus::parse(&answer.status, answer.failure_reason).ok_or_else(|| response.protocol_violation())?;
    Ok((document, status))
}

#[derive(serde::Serialize)]
struct LookupRequest<'digests> {
    sha256: &'digests [String],
}

#[derive(serde::Deserialize)]
struct LookupAnswers {
    contents: Vec<ContentStateAnswer>,
}

#[derive(serde::Deserialize)]
struct ContentStateAnswer {
    sha256: String,
    state: String,
    document_id: Option<String>,
}

#[derive(serde::Deserialize)]
struct DocumentStatusAnswer {
    document_id: String,
    status: String,
    failure_reason: Option<String>,
}

impl ArchiveClient for HttpArchiveClient {
    fn look_up(&self, digests: &[ContentDigest]) -> Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition> {
        let hexadecimal: Vec<String> = digests.iter().map(ContentDigest::hexadecimal).collect();
        let body = serde_json::to_vec(&LookupRequest { sha256: &hexadecimal })
            .map_err(|_| ArchiveCondition::ConnectionFailed)?;
        let response = self.exchange.post_json("/api/v1/contents/lookup", &body)?;
        if response.status() != 200 {
            return Err(response.protocol_violation());
        }
        let answers: LookupAnswers =
            serde_json::from_str(response.body()).map_err(|_| response.protocol_violation())?;
        if answers.contents.len() != digests.len() {
            return Err(response.protocol_violation());
        }
        digests
            .iter()
            .zip(answers.contents)
            .map(|(digest, content)| {
                if content.sha256 != digest.hexadecimal() {
                    return Err(response.protocol_violation());
                }
                let lookup = match (content.state.as_str(), content.document_id) {
                    ("absent", _) => LookupAnswer::Absent,
                    ("deleted", _) => LookupAnswer::Deleted,
                    ("present", Some(document)) => LookupAnswer::Present(
                        DocumentIdentifier::parse(&document).ok_or_else(|| response.protocol_violation())?,
                    ),
                    _ => return Err(response.protocol_violation()),
                };
                Ok((*digest, lookup))
            })
            .collect()
    }

    fn submit(
        &self,
        authorization: SubmissionAuthorization,
        content: VerifiedContent,
    ) -> Result<SubmissionOutcome, SubmissionCondition> {
        assert_eq!(
            authorization.digest(),
            content.digest(),
            "a submission's authorization and content must name the same digest"
        );
        let response = self.exchange.put_octets(
            &format!("/api/v1/contents/{}", authorization.digest().hexadecimal()),
            content.bytes(),
        )?;
        Ok(match response.status() {
            202 => {
                let (document, status) = document_status(&response)?;
                SubmissionOutcome::Accepted { document, status }
            }
            200 => {
                let (document, status) = document_status(&response)?;
                SubmissionOutcome::AlreadyHeld { document, status }
            }
            409 => SubmissionOutcome::Deleted,
            413 => SubmissionOutcome::TooLarge,
            415 => SubmissionOutcome::UnacceptedKind,
            422 => return Err(SubmissionCondition::DigestDisagreement),
            _ => return Err(response.protocol_violation().into()),
        })
    }

    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition> {
        let response = self.exchange.get(&format!("/api/v1/documents/{}", document.as_str()))?;
        match response.status() {
            200 => Ok(Some(document_status(&response)?.1)),
            404 => Ok(None),
            _ => Err(response.protocol_violation()),
        }
    }
}
