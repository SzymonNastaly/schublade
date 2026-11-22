//! The authorized exchange with one archive over `ureq`, and the conditions every route answers
//! alike. A route reads only the statuses it defines itself, from `ArchiveResponse::status`.

use std::time::Duration;

use crate::archive_address::ArchiveAddress;
use crate::archive_token::ArchiveToken;

/// Every way an archive request can fail to produce an answer of its route.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArchiveCondition {
    /// 401.
    CredentialRefused,
    /// 403.
    CredentialInsufficient,
    /// 503.
    ServiceUnavailable {
        retry_after: Duration,
    },
    ConnectionFailed,
    TimedOut,
    /// 500.
    ServerError,
    /// 400, 404 on a route, 405, or a body that does not parse: a bug on one side.
    ProtocolViolation {
        detail: String,
    },
}

/// Seconds only, as the server sends; 900 when missing or unreadable.
fn parse_retry_after(header: Option<&str>) -> Duration {
    const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(900);
    header
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_RETRY_AFTER)
}

/// The conditions of a status that every route shares, or `None` for a status the route reads.
fn shared_condition(status: u16, retry_after: Option<&str>) -> Option<ArchiveCondition> {
    Some(match status {
        401 => ArchiveCondition::CredentialRefused,
        403 => ArchiveCondition::CredentialInsufficient,
        500 => ArchiveCondition::ServerError,
        503 => ArchiveCondition::ServiceUnavailable {
            retry_after: parse_retry_after(retry_after),
        },
        _ => return None,
    })
}

const BASE_TIMEOUT: Duration = Duration::from_secs(30);
/// One second of PUT time per this many bytes, on top of the base timeout.
const BYTES_PER_TIMEOUT_SECOND: u64 = 50_000;
const MAXIMUM_ANSWER_BYTES: u64 = 256_000;

/// Sends requests to one archive with the token's `Authorization` header. `ureq::Agent` is cheap
/// to clone, so threads share the exchange.
#[derive(Clone)]
pub struct ArchiveExchange {
    agent: ureq::Agent,
    origin: String,
    authorization_header: String,
    base_timeout: Duration,
}

impl ArchiveExchange {
    pub fn new(address: &ArchiveAddress, token: &ArchiveToken) -> ArchiveExchange {
        ArchiveExchange::with_base_timeout(address, token, BASE_TIMEOUT)
    }

    /// `base_timeout` bounds a GET and a POST, and a PUT gets one second more per 50,000 bytes.
    /// Tests shorten it.
    pub fn with_base_timeout(
        address: &ArchiveAddress,
        token: &ArchiveToken,
        base_timeout: Duration,
    ) -> ArchiveExchange {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(base_timeout))
            .build()
            .new_agent();
        ArchiveExchange {
            agent,
            origin: address.origin(),
            authorization_header: format!("Bearer {}", token.secret()),
            base_timeout,
        }
    }

    /// `path` starts with `/`.
    pub fn get(&self, path: &str) -> Result<ArchiveResponse, ArchiveCondition> {
        let sent = self
            .agent
            .get(format!("{}{path}", self.origin))
            .header("Authorization", &self.authorization_header)
            .call();
        response_of(sent)
    }

    pub fn post_json(&self, path: &str, body: &[u8]) -> Result<ArchiveResponse, ArchiveCondition> {
        let sent = self
            .agent
            .post(format!("{}{path}", self.origin))
            .header("Authorization", &self.authorization_header)
            .header("Content-Type", "application/json")
            .send(body);
        response_of(sent)
    }

    pub fn put_octets(&self, path: &str, octets: &[u8]) -> Result<ArchiveResponse, ArchiveCondition> {
        let octet_count = u64::try_from(octets.len()).unwrap_or(u64::MAX);
        let timeout = self.base_timeout + Duration::from_secs(octet_count / BYTES_PER_TIMEOUT_SECOND);
        let sent = self
            .agent
            .put(format!("{}{path}", self.origin))
            .config()
            .timeout_global(Some(timeout))
            .build()
            .header("Authorization", &self.authorization_header)
            .header("Content-Type", "application/octet-stream")
            .send(octets);
        response_of(sent)
    }
}

/// The body is read whole, up to the limit, before the shared conditions are read, so an answer
/// cut off on the way is a connection failure whatever its status.
fn response_of(
    sent: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
) -> Result<ArchiveResponse, ArchiveCondition> {
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
    match shared_condition(status, retry_after.as_deref()) {
        Some(condition) => Err(condition),
        None => Ok(ArchiveResponse { status, body }),
    }
}

/// An answer whose status no route shares, read whole, for its route to read.
pub struct ArchiveResponse {
    status: u16,
    body: String,
}

impl ArchiveResponse {
    pub fn status(&self) -> u16 {
        self.status
    }

    pub fn body(&self) -> &str {
        &self.body
    }

    /// The condition for a status or a body the route does not define, with the problem
    /// document's detail sentence when it has one.
    pub fn protocol_violation(&self) -> ArchiveCondition {
        let detail = serde_json::from_str::<ProblemDetails>(&self.body)
            .ok()
            .and_then(|problem| problem.detail)
            .unwrap_or_else(|| self.body.chars().take(200).collect());
        ArchiveCondition::ProtocolViolation {
            detail: format!("{}: {detail}", self.status),
        }
    }
}

#[derive(serde::Deserialize)]
struct ProblemDetails {
    detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

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
