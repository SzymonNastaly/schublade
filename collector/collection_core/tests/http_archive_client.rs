//! The HTTP client against a local server that answers from a script, one request each, so every
//! status the protocol can answer is parsed once.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use collection_core::archive_client::{ArchiveAddress, ArchiveClient, HttpArchiveClient, IngestToken};
use collection_core::archive_connection::ArchiveCondition;
use collection_core::content_synchronization::{
    ArchiveStanding, ContentRecord, LookupAnswer, SubmissionAuthorization, SubmissionFailures, SubmissionOutcome,
    authorize_submission,
};
use collection_core::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus, Timestamp, TimingPolicy};
use collection_core::file_system_observation::VerifiedContent;

const TOKEN: &str = "sch_test_token";
const DOCUMENT: &str = "4c5d6e7f-8091-4a2b-9c3d-4e5f60718293";

struct ScriptedResponse {
    status: u16,
    headers: Vec<(&'static str, String)>,
    body: String,
    delay: Duration,
}

fn problem(status: u16, detail: &str) -> ScriptedResponse {
    ScriptedResponse {
        status,
        headers: vec![("Content-Type", "application/problem+json".to_owned())],
        body: format!(r#"{{"type":"about:blank","title":"Problem","status":{status},"detail":"{detail}"}}"#),
        delay: Duration::ZERO,
    }
}

fn json(status: u16, body: &str) -> ScriptedResponse {
    ScriptedResponse {
        status,
        headers: vec![("Content-Type", "application/json".to_owned())],
        body: body.to_owned(),
        delay: Duration::ZERO,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecordedRequest {
    method: String,
    path: String,
    authorization: Option<String>,
    body: Vec<u8>,
}

struct TestArchive {
    server: Arc<tiny_http::Server>,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    responses: Arc<Mutex<VecDeque<ScriptedResponse>>>,
    address: ArchiveAddress,
}

impl TestArchive {
    fn start(responses: Vec<ScriptedResponse>) -> TestArchive {
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let responses = Arc::new(Mutex::new(VecDeque::from(responses)));
        let address = ArchiveAddress::parse(&format!("http://{}", server.server_addr())).unwrap();
        let (serving, recorded, script) = (Arc::clone(&server), Arc::clone(&requests), Arc::clone(&responses));
        thread::spawn(move || {
            while let Ok(mut request) = serving.recv() {
                let mut body = Vec::new();
                request.as_reader().read_to_end(&mut body).unwrap();
                let authorization = request
                    .headers()
                    .iter()
                    .find(|header| header.field.equiv("Authorization"))
                    .map(|header| header.value.as_str().to_owned());
                recorded.lock().unwrap().push(RecordedRequest {
                    method: request.method().as_str().to_owned(),
                    path: request.url().to_owned(),
                    authorization,
                    body,
                });
                let Some(scripted) = script.lock().unwrap().pop_front() else {
                    let _ =
                        request.respond(tiny_http::Response::from_string("no scripted answer").with_status_code(599));
                    continue;
                };
                thread::sleep(scripted.delay);
                let mut response = tiny_http::Response::from_string(scripted.body).with_status_code(scripted.status);
                for (name, value) in scripted.headers {
                    response = response.with_header(tiny_http::Header::from_bytes(name, value).unwrap());
                }
                let _ = request.respond(response);
            }
        });
        TestArchive {
            server,
            requests,
            responses,
            address,
        }
    }

    fn client(&self) -> HttpArchiveClient {
        HttpArchiveClient::with_base_timeout(
            &self.address,
            &IngestToken::new(TOKEN.to_owned()),
            Duration::from_millis(500),
        )
    }

    fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for TestArchive {
    fn drop(&mut self) {
        self.responses.lock().unwrap().clear();
        self.server.unblock();
    }
}

fn digest(byte: u8) -> ContentDigest {
    ContentDigest::from_bytes([byte; 32])
}

fn document() -> DocumentIdentifier {
    DocumentIdentifier::parse(DOCUMENT).unwrap()
}

fn authorization(digest: ContentDigest) -> SubmissionAuthorization {
    let record = ContentRecord {
        digest,
        standing: ArchiveStanding::Absent {
            looked_up_at: Timestamp(0),
            failures: SubmissionFailures::default(),
        },
    };
    authorize_submission(&record, Timestamp(1), &TimingPolicy::default()).unwrap()
}

#[test]
fn a_lookup_sends_the_digests_with_the_token_and_reads_each_answer_in_order() {
    let answer = format!(
        r#"{{"contents":[{{"sha256":"{}","state":"absent"}},{{"sha256":"{}","state":"present","document_id":"{DOCUMENT}"}},{{"sha256":"{}","state":"deleted"}}]}}"#,
        digest(1).hexadecimal(),
        digest(2).hexadecimal(),
        digest(3).hexadecimal()
    );
    let archive = TestArchive::start(vec![json(200, &answer)]);

    let answers = archive.client().look_up(&[digest(1), digest(2), digest(3)]).unwrap();

    assert_eq!(
        answers,
        vec![
            (digest(1), LookupAnswer::Absent),
            (digest(2), LookupAnswer::Present(document())),
            (digest(3), LookupAnswer::Deleted),
        ]
    );
    let requests = archive.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        (requests[0].method.as_str(), requests[0].path.as_str()),
        ("POST", "/api/v1/contents/lookup")
    );
    assert_eq!(requests[0].authorization.as_deref(), Some("Bearer sch_test_token"));
    let sent: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert_eq!(
        sent,
        serde_json::json!({ "sha256": [digest(1).hexadecimal(), digest(2).hexadecimal(), digest(3).hexadecimal()] })
    );
}

#[test]
fn a_lookup_whose_answer_names_other_digests_is_a_protocol_violation() {
    let answer = format!(
        r#"{{"contents":[{{"sha256":"{}","state":"absent"}}]}}"#,
        digest(9).hexadecimal()
    );
    let archive = TestArchive::start(vec![
        json(200, &answer),
        json(200, r#"{"contents":[]}"#),
        json(200, "not json"),
    ]);
    let client = archive.client();

    for _ in 0..3 {
        assert!(matches!(
            client.look_up(&[digest(1)]),
            Err(ArchiveCondition::ProtocolViolation { .. })
        ));
    }
}

#[test]
fn a_submission_sends_the_bytes_under_their_digest_and_reads_every_answer_of_the_put() {
    let content = VerifiedContent::from_bytes(b"%PDF-1.7 the bytes".to_vec());
    let digest = content.digest();
    let status = format!(r#"{{"document_id":"{DOCUMENT}","status":"processing","failure_reason":null}}"#);
    let archive = TestArchive::start(vec![
        json(202, &status),
        json(200, &status),
        problem(409, "The owner deleted this document."),
        problem(413, "The file is larger than 25 MB"),
        problem(415, "Only PDF, JPEG, PNG, and WebP files can be archived."),
        problem(422, "The body has another SHA-256"),
        problem(405, "Send this request with PUT"),
    ]);
    let client = archive.client();
    let submit = || client.submit(authorization(digest), content.clone());

    let accepted = submit();
    let already_held = submit();
    let deleted = submit();
    let too_large = submit();
    let unaccepted = submit();
    let disagreement = submit();
    let violation = submit();

    assert_eq!(
        accepted,
        Ok(SubmissionOutcome::Accepted {
            document: document(),
            status: DocumentStatus::Processing
        })
    );
    assert_eq!(
        already_held,
        Ok(SubmissionOutcome::AlreadyHeld {
            document: document(),
            status: DocumentStatus::Processing
        })
    );
    assert_eq!(deleted, Ok(SubmissionOutcome::Deleted));
    assert_eq!(too_large, Ok(SubmissionOutcome::TooLarge));
    assert_eq!(unaccepted, Ok(SubmissionOutcome::UnacceptedKind));
    assert_eq!(disagreement, Err(ArchiveCondition::DigestDisagreement));
    assert_eq!(
        violation,
        Err(ArchiveCondition::ProtocolViolation {
            detail: "405: Send this request with PUT".to_owned()
        })
    );
    let first = &archive.requests()[0];
    assert_eq!(first.method, "PUT");
    assert_eq!(first.path, format!("/api/v1/contents/{}", digest.hexadecimal()));
    assert_eq!(first.body, b"%PDF-1.7 the bytes");
}

#[test]
fn the_conditions_every_route_shares_are_read_from_the_status_and_retry_after() {
    let unavailable_with_retry = ScriptedResponse {
        headers: vec![
            ("Retry-After", "120".to_owned()),
            ("Content-Type", "application/problem+json".to_owned()),
        ],
        ..problem(503, "The archive is still recording the digests of its documents.")
    };
    let archive = TestArchive::start(vec![
        problem(401, "Send a valid API token"),
        problem(403, "The API token does not permit ingesting documents"),
        problem(500, "The archive could not complete the request."),
        unavailable_with_retry,
        problem(503, "Later"),
        problem(400, "Send a JSON object"),
    ]);
    let client = archive.client();

    let conditions: Vec<_> = (0..6).map(|_| client.look_up(&[digest(1)]).unwrap_err()).collect();

    assert_eq!(
        conditions,
        vec![
            ArchiveCondition::CredentialRefused,
            ArchiveCondition::CredentialInsufficient,
            ArchiveCondition::ServerError,
            ArchiveCondition::ServiceUnavailable {
                retry_after: Duration::from_secs(120)
            },
            ArchiveCondition::ServiceUnavailable {
                retry_after: Duration::from_secs(900)
            },
            ArchiveCondition::ProtocolViolation {
                detail: "400: Send a JSON object".to_owned()
            },
        ]
    );
}

#[test]
fn a_document_status_is_read_with_its_failure_reason_and_a_404_is_no_document() {
    let archive = TestArchive::start(vec![
        json(
            200,
            &format!(r#"{{"document_id":"{DOCUMENT}","status":"failed","failure_reason":"unreadable_file"}}"#),
        ),
        problem(404, "No document has the identifier"),
        json(
            200,
            &format!(r#"{{"document_id":"{DOCUMENT}","status":"vanished","failure_reason":null}}"#),
        ),
    ]);
    let client = archive.client();

    let failed = client.read_document_status(&document());
    let unknown = client.read_document_status(&document());
    let unreadable = client.read_document_status(&document());

    assert_eq!(
        failed,
        Ok(Some(DocumentStatus::Failed {
            failure_reason: Some("unreadable_file".to_owned())
        }))
    );
    assert_eq!(unknown, Ok(None));
    assert!(matches!(unreadable, Err(ArchiveCondition::ProtocolViolation { .. })));
    assert_eq!(archive.requests()[0].path, format!("/api/v1/documents/{DOCUMENT}"));
}

#[test]
fn a_silent_server_times_out_and_a_closed_port_is_a_connection_failure() {
    let archive = TestArchive::start(vec![ScriptedResponse {
        delay: Duration::from_secs(2),
        ..json(200, "{}")
    }]);
    let client = archive.client();
    assert_eq!(
        client.read_document_status(&document()),
        Err(ArchiveCondition::TimedOut)
    );

    let closed = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let address = ArchiveAddress::parse(&format!("http://{}", closed.server_addr())).unwrap();
    drop(closed);
    let unreachable = HttpArchiveClient::with_base_timeout(
        &address,
        &IngestToken::new(TOKEN.to_owned()),
        Duration::from_millis(500),
    );
    assert_eq!(
        unreachable.read_document_status(&document()),
        Err(ArchiveCondition::ConnectionFailed)
    );
}

#[test]
fn a_credential_is_verified_by_one_lookup_that_names_no_file() {
    let zero_digest = "0".repeat(64);
    let archive = TestArchive::start(vec![
        json(
            200,
            &format!(r#"{{"contents":[{{"sha256":"{zero_digest}","state":"absent"}}]}}"#),
        ),
        problem(401, "Send a valid API token"),
        problem(403, "The API token does not permit ingesting documents"),
        problem(404, "Not found"),
    ]);
    let client = archive.client();

    let answers: Vec<_> = (0..4).map(|_| client.verify_credential()).collect();

    assert_eq!(
        answers,
        vec![
            Ok(()),
            Err(ArchiveCondition::CredentialRefused),
            Err(ArchiveCondition::CredentialInsufficient),
            Err(ArchiveCondition::ProtocolViolation {
                detail: "404: Not found".to_owned()
            }),
        ]
    );
    let sent: serde_json::Value = serde_json::from_slice(&archive.requests()[0].body).unwrap();
    assert_eq!(sent, serde_json::json!({ "sha256": [zero_digest] }));
}
