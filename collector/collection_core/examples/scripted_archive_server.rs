//! The scripted archive over HTTP, for an end-to-end test of an application: the three routes of
//! the collection protocol answered from a `ScriptedArchive`, so that the real HTTP client meets
//! the archive of the scenarios.
//!
//! The server prints `listening http://127.0.0.1:<port>` and serves until its standard input
//! closes, so a test that dies takes the server with it. `GET /scripted/held` answers the digests
//! the archive holds, one per line. Every request carries `Authorization: Bearer
//! scripted-ingest-token`, and any other request is answered 401.

use std::collections::BTreeSet;
use std::io::Read;

use collection_core::ScriptedArchive;
use collection_core::archive_client::ArchiveClient;
use collection_core::content_synchronization::{
    ArchiveStanding, ContentRecord, LookupAnswer, SubmissionFailures, SubmissionOutcome, authorize_submission,
};
use collection_core::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus, Timestamp, TimingPolicy};
use collection_core::file_system_observation::VerifiedContent;

const AUTHORIZATION: &str = "Bearer scripted-ingest-token";
const LOOKUP_PATH: &str = "/api/v1/contents/lookup";
const CONTENT_PATH_PREFIX: &str = "/api/v1/contents/";
const DOCUMENT_PATH_PREFIX: &str = "/api/v1/documents/";
const HELD_DIGESTS_PATH: &str = "/scripted/held";

struct Answer {
    status: u16,
    content_type: &'static str,
    body: String,
}

fn json(status: u16, body: serde_json::Value) -> Answer {
    Answer {
        status,
        content_type: "application/json",
        body: body.to_string(),
    }
}

fn problem(status: u16, detail: &str) -> Answer {
    Answer {
        status,
        content_type: "application/problem+json",
        body: serde_json::json!({ "type": "about:blank", "title": "Problem", "status": status, "detail": detail })
            .to_string(),
    }
}

fn document_status(status: u16, document: &DocumentIdentifier, document_status: &DocumentStatus) -> Answer {
    let failure_reason = match document_status {
        DocumentStatus::Failed { failure_reason } => failure_reason.clone(),
        _ => None,
    };
    json(
        status,
        serde_json::json!({
            "document_id": document.as_str(),
            "status": document_status.name(),
            "failure_reason": failure_reason,
        }),
    )
}

#[derive(serde::Deserialize)]
struct LookupRequest {
    sha256: Vec<String>,
}

fn look_up(archive: &ScriptedArchive, body: &[u8]) -> Answer {
    let digests = serde_json::from_slice::<LookupRequest>(body).ok().and_then(|request| {
        request
            .sha256
            .iter()
            .map(|text| ContentDigest::parse_hexadecimal(text))
            .collect::<Option<Vec<ContentDigest>>>()
    });
    let Some(digests) = digests else {
        return problem(400, "Send a JSON object with the digests under sha256");
    };
    let contents: Vec<serde_json::Value> = archive
        .look_up(&digests)
        .unwrap_or_else(|_| unreachable!("no condition is scripted"))
        .iter()
        .map(|(digest, answer)| match answer {
            LookupAnswer::Absent => serde_json::json!({ "sha256": digest.hexadecimal(), "state": "absent" }),
            LookupAnswer::Present(document) => serde_json::json!({
                "sha256": digest.hexadecimal(),
                "state": "present",
                "document_id": document.as_str(),
            }),
            LookupAnswer::Deleted => serde_json::json!({ "sha256": digest.hexadecimal(), "state": "deleted" }),
        })
        .collect();
    json(200, serde_json::json!({ "contents": contents }))
}

fn submit(
    archive: &ScriptedArchive,
    submitted: &mut BTreeSet<ContentDigest>,
    digest: ContentDigest,
    body: Vec<u8>,
) -> Answer {
    let content = VerifiedContent::from_bytes(body);
    if content.digest() != digest {
        return problem(422, "The body has another SHA-256");
    }
    // The archive decides about every content a collector sends, so each PUT is authorized.
    let record = ContentRecord {
        digest,
        standing: ArchiveStanding::Absent {
            looked_up_at: Timestamp(0),
            failures: SubmissionFailures::default(),
        },
    };
    let authorization = authorize_submission(&record, Timestamp(0), &TimingPolicy::default())
        .unwrap_or_else(|_| unreachable!("a content looked up at this moment is authorized"));
    submitted.insert(digest);
    match archive
        .submit(authorization, content)
        .unwrap_or_else(|_| unreachable!("no condition is scripted"))
    {
        SubmissionOutcome::Accepted { document, status } => document_status(202, &document, &status),
        SubmissionOutcome::AlreadyHeld { document, status } => document_status(200, &document, &status),
        SubmissionOutcome::Deleted => problem(409, "The owner deleted this document."),
        SubmissionOutcome::TooLarge => problem(413, "The file is larger than 25 MB"),
        SubmissionOutcome::UnacceptedKind => problem(415, "Only PDF, JPEG, PNG, and WebP files can be archived."),
    }
}

fn read_document_status(archive: &ScriptedArchive, identifier: &str) -> Answer {
    let status = DocumentIdentifier::parse(identifier)
        .and_then(|document| Some((archive.read_document_status(&document).ok()??, document)));
    match status {
        Some((status, document)) => document_status(200, &document, &status),
        None => problem(404, "No document has the identifier"),
    }
}

fn answer(
    archive: &ScriptedArchive,
    submitted: &mut BTreeSet<ContentDigest>,
    method: &tiny_http::Method,
    path: &str,
    body: Vec<u8>,
) -> Answer {
    use tiny_http::Method;
    match (method, path) {
        (Method::Post, LOOKUP_PATH) => look_up(archive, &body),
        (Method::Put, path)
            if let Some(digest) = path
                .strip_prefix(CONTENT_PATH_PREFIX)
                .and_then(ContentDigest::parse_hexadecimal) =>
        {
            submit(archive, submitted, digest, body)
        }
        (Method::Get, path) if let Some(identifier) = path.strip_prefix(DOCUMENT_PATH_PREFIX) => {
            read_document_status(archive, identifier)
        }
        (Method::Get, HELD_DIGESTS_PATH) => Answer {
            status: 200,
            content_type: "text/plain",
            body: submitted
                .iter()
                .filter(|digest| archive.holds(digest))
                .map(|digest| digest.hexadecimal() + "\n")
                .collect(),
        },
        _ => problem(404, "The scripted archive has no such route"),
    }
}

fn main() {
    let server = tiny_http::Server::http("127.0.0.1:0").expect("a local port is free");
    println!("listening http://{}", server.server_addr());
    std::thread::spawn(|| {
        let _ = std::io::stdin().lock().read_to_end(&mut Vec::new());
        std::process::exit(0);
    });

    let archive = ScriptedArchive::new();
    let mut submitted = BTreeSet::new();
    for mut request in server.incoming_requests() {
        let authorized = request
            .headers()
            .iter()
            .any(|header| header.field.equiv("Authorization") && header.value.as_str() == AUTHORIZATION);
        let mut body = Vec::new();
        let answer = if !authorized {
            problem(401, "Send the scripted ingest token")
        } else if request.as_reader().read_to_end(&mut body).is_err() {
            problem(400, "The body could not be read")
        } else {
            let (method, path) = (request.method().clone(), request.url().to_owned());
            answer(&archive, &mut submitted, &method, &path, body)
        };
        let content_type = tiny_http::Header::from_bytes("Content-Type", answer.content_type)
            .expect("a content type is a header value");
        let _ = request.respond(
            tiny_http::Response::from_string(answer.body)
                .with_status_code(answer.status)
                .with_header(content_type),
        );
    }
}
