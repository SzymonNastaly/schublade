//! The seam to the archive. `ArchiveClient` returns domain outcomes only, and no wire type leaves
//! this module; `archive_connection::consequences` decides what each outcome means.

use std::time::Duration;

use sha2::{Digest, Sha256};

use crate::archive_connection::ArchiveCondition;
use crate::content_synchronization::{LookupAnswer, SubmissionAuthorization, SubmissionOutcome};
use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus};
use crate::file_system_observation::VerifiedContent;

/// An archive origin, `https://` (or `http://` for a local server).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveAddress(url::Url);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveAddressRefusal {
    pub detail: String,
}

impl ArchiveAddress {
    /// Keeps the origin only; a pasted path such as `/settings` is dropped.
    pub fn parse(text: &str) -> Result<ArchiveAddress, ArchiveAddressRefusal> {
        let refusal = |detail: &str| ArchiveAddressRefusal {
            detail: detail.to_owned(),
        };
        let url = url::Url::parse(text.trim()).map_err(|error| refusal(&format!("{error}")))?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(refusal("The archive address must start with https://"));
        }
        if url.host_str().is_none() {
            return Err(refusal("The archive address must name a host"));
        }
        let origin = url.origin().ascii_serialization();
        url::Url::parse(&origin)
            .map(ArchiveAddress)
            .map_err(|error| refusal(&format!("{error}")))
    }

    /// Without a trailing slash, as `request.url` names it on the server.
    pub fn origin(&self) -> String {
        self.0.origin().ascii_serialization()
    }
}

/// The bearer token. Never logged, never stored in the database, never serialized.
pub struct IngestToken(String);

impl IngestToken {
    pub fn new(token: String) -> IngestToken {
        IngestToken(token.trim().to_owned())
    }

    /// The token itself, for the credential store and the request header only.
    pub fn secret(&self) -> &str {
        &self.0
    }

    /// SHA-256 of the token as hexadecimal, the only form the database holds.
    pub fn fingerprint(&self) -> String {
        Sha256::digest(self.0.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

impl std::fmt::Debug for IngestToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("IngestToken(..)")
    }
}

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
    ) -> Result<SubmissionOutcome, ArchiveCondition>;

    /// `GET /api/v1/documents/{id}`. `Ok(None)` is a 404.
    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition>;
}

/// Seconds only, as the server sends; 900 when missing or unreadable.
pub fn parse_retry_after(header: Option<&str>) -> Duration {
    const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(900);
    header
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_RETRY_AFTER)
}

const BASE_TIMEOUT: Duration = Duration::from_secs(30);
/// One second of PUT time per this many bytes, on top of the base timeout.
const BYTES_PER_TIMEOUT_SECOND: u64 = 50_000;
const MAXIMUM_ANSWER_BYTES: u64 = 256_000;

/// Speaks the protocol over HTTP with `ureq`. `ureq::Agent` is cheap to clone.
#[derive(Clone)]
pub struct HttpArchiveClient {
    agent: ureq::Agent,
    origin: String,
    authorization_header: String,
    base_timeout: Duration,
}

impl HttpArchiveClient {
    pub fn new(address: &ArchiveAddress, token: &IngestToken) -> HttpArchiveClient {
        HttpArchiveClient::with_base_timeout(address, token, BASE_TIMEOUT)
    }

    /// `base_timeout` bounds a lookup and a status read, and a PUT gets one second more per
    /// 50,000 bytes. Tests shorten it.
    pub fn with_base_timeout(
        address: &ArchiveAddress,
        token: &IngestToken,
        base_timeout: Duration,
    ) -> HttpArchiveClient {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(base_timeout))
            .build()
            .new_agent();
        HttpArchiveClient {
            agent,
            origin: address.origin(),
            authorization_header: format!("Bearer {}", token.0),
            base_timeout,
        }
    }

    /// Tries a pasted address and token before they are stored: one lookup of a digest that no
    /// file has, which every route answers only for a token with the ingest level.
    pub fn verify_credential(&self) -> Result<(), ArchiveCondition> {
        self.look_up(&[ContentDigest::from_bytes([0; 32])]).map(|_| ())
    }

    fn answer_of(
        &self,
        sent: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    ) -> Result<Answer, ArchiveCondition> {
        let mut response = sent.map_err(|error| match error {
            ureq::Error::Timeout(_) => ArchiveCondition::TimedOut,
            _ => ArchiveCondition::ConnectionFailed,
        })?;
        let status = response.status().as_u16();
        let retry_after = response
            .headers()
            .get("Retry-After")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let body = response
            .body_mut()
            .with_config()
            .limit(MAXIMUM_ANSWER_BYTES)
            .read_to_string()
            .map_err(|_| ArchiveCondition::ConnectionFailed)?;
        Ok(Answer {
            status,
            retry_after,
            body,
        })
    }
}

/// One HTTP answer, read whole, before it becomes a domain outcome.
struct Answer {
    status: u16,
    retry_after: Option<String>,
    body: String,
}

impl Answer {
    /// The conditions every route shares. `Ok(())` means the route reads the status itself.
    fn shared_condition(&self) -> Result<(), ArchiveCondition> {
        Err(match self.status {
            401 => ArchiveCondition::CredentialRefused,
            403 => ArchiveCondition::CredentialInsufficient,
            500 => ArchiveCondition::ServerError,
            503 => ArchiveCondition::ServiceUnavailable {
                retry_after: parse_retry_after(self.retry_after.as_deref()),
            },
            _ => return Ok(()),
        })
    }

    fn protocol_violation(&self) -> ArchiveCondition {
        let detail = serde_json::from_str::<ProblemDetails>(&self.body)
            .ok()
            .and_then(|problem| problem.detail)
            .unwrap_or_else(|| self.body.chars().take(200).collect());
        ArchiveCondition::ProtocolViolation {
            detail: format!("{}: {detail}", self.status),
        }
    }

    fn document_status(&self) -> Result<(DocumentIdentifier, DocumentStatus), ArchiveCondition> {
        let answer: DocumentStatusAnswer = serde_json::from_str(&self.body).map_err(|_| self.protocol_violation())?;
        let document = DocumentIdentifier::parse(&answer.document_id).ok_or_else(|| self.protocol_violation())?;
        let status =
            DocumentStatus::parse(&answer.status, answer.failure_reason).ok_or_else(|| self.protocol_violation())?;
        Ok((document, status))
    }
}

#[derive(serde::Deserialize)]
struct ProblemDetails {
    detail: Option<String>,
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
        let sent = self
            .agent
            .post(format!("{}/api/v1/contents/lookup", self.origin))
            .header("Authorization", &self.authorization_header)
            .header("Content-Type", "application/json")
            .send(&body[..]);
        let answer = self.answer_of(sent)?;
        answer.shared_condition()?;
        if answer.status != 200 {
            return Err(answer.protocol_violation());
        }
        let answers: LookupAnswers = serde_json::from_str(&answer.body).map_err(|_| answer.protocol_violation())?;
        if answers.contents.len() != digests.len() {
            return Err(answer.protocol_violation());
        }
        digests
            .iter()
            .zip(answers.contents)
            .map(|(digest, content)| {
                if content.sha256 != digest.hexadecimal() {
                    return Err(answer.protocol_violation());
                }
                let lookup = match (content.state.as_str(), content.document_id) {
                    ("absent", _) => LookupAnswer::Absent,
                    ("deleted", _) => LookupAnswer::Deleted,
                    ("present", Some(document)) => LookupAnswer::Present(
                        DocumentIdentifier::parse(&document).ok_or_else(|| answer.protocol_violation())?,
                    ),
                    _ => return Err(answer.protocol_violation()),
                };
                Ok((*digest, lookup))
            })
            .collect()
    }

    fn submit(
        &self,
        authorization: SubmissionAuthorization,
        content: VerifiedContent,
    ) -> Result<SubmissionOutcome, ArchiveCondition> {
        assert_eq!(
            authorization.digest(),
            content.digest(),
            "a submission's authorization and content must name the same digest"
        );
        let byte_count = u64::try_from(content.bytes().len()).unwrap_or(u64::MAX);
        let timeout = self.base_timeout + Duration::from_secs(byte_count / BYTES_PER_TIMEOUT_SECOND);
        let sent = self
            .agent
            .put(format!(
                "{}/api/v1/contents/{}",
                self.origin,
                authorization.digest().hexadecimal()
            ))
            .config()
            .timeout_global(Some(timeout))
            .build()
            .header("Authorization", &self.authorization_header)
            .header("Content-Type", "application/octet-stream")
            .send(content.bytes());
        let answer = self.answer_of(sent)?;
        answer.shared_condition()?;
        Ok(match answer.status {
            202 => {
                let (document, status) = answer.document_status()?;
                SubmissionOutcome::Accepted { document, status }
            }
            200 => {
                let (document, status) = answer.document_status()?;
                SubmissionOutcome::AlreadyHeld { document, status }
            }
            409 => SubmissionOutcome::Deleted,
            413 => SubmissionOutcome::TooLarge,
            415 => SubmissionOutcome::UnacceptedKind,
            422 => return Err(ArchiveCondition::DigestDisagreement),
            _ => return Err(answer.protocol_violation()),
        })
    }

    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition> {
        let sent = self
            .agent
            .get(format!("{}/api/v1/documents/{}", self.origin, document.as_str()))
            .header("Authorization", &self.authorization_header)
            .call();
        let answer = self.answer_of(sent)?;
        answer.shared_condition()?;
        match answer.status {
            200 => Ok(Some(answer.document_status()?.1)),
            404 => Ok(None),
            _ => Err(answer.protocol_violation()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_archive_address_keeps_only_the_origin() {
        let address = ArchiveAddress::parse(" https://Archive.Example.org/settings?tab=tokens ").unwrap();
        assert_eq!(address.origin(), "https://archive.example.org");
        assert_eq!(
            ArchiveAddress::parse("http://localhost:3000/").unwrap().origin(),
            "http://localhost:3000"
        );
        assert!(ArchiveAddress::parse("archive.example.org").is_err());
        assert!(ArchiveAddress::parse("ftp://archive.example.org").is_err());
        assert!(ArchiveAddress::parse("https://").is_err());
    }

    #[test]
    fn a_token_shows_only_its_fingerprint() {
        let token = IngestToken::new("secret-token\n".to_owned());
        assert_eq!(
            token.fingerprint(),
            "930bbdc51b6aed5c2a5678fd6e28dee7a05e8a4b643cfc0b4427c3efb86c0d94"
        );
        assert_eq!(format!("{token:?}"), "IngestToken(..)");
        assert_ne!(token.fingerprint(), IngestToken::new("other".to_owned()).fingerprint());
    }

    #[test]
    fn retry_after_reads_seconds_and_falls_back_to_fifteen_minutes() {
        assert_eq!(parse_retry_after(Some("120")), Duration::from_secs(120));
        assert_eq!(parse_retry_after(Some(" 7 ")), Duration::from_secs(7));
        assert_eq!(
            parse_retry_after(Some("Wed, 21 Oct 2026 07:28:00 GMT")),
            Duration::from_secs(900)
        );
        assert_eq!(parse_retry_after(None), Duration::from_secs(900));
    }
}
