//! The scripted archive over HTTP, answering every route of `notes/client_protocol.md` from one
//! `ScriptedArchive` model so that an uploaded file appears in the journal and in a library that
//! follows it.
//!
//! Prints `listening http://127.0.0.1:<port>` and runs until standard input closes. With
//! `--legacy-reception` it answers the reception's paths as an archive older than the reception.

use std::io::{Read, Write};
use std::sync::{Mutex, PoisonError};

use archive_access::{ArchiveCondition, ContentDigest, INGEST_PATH, PermissionLevel, SubmissionRoute};
use scripted_archive::ScriptedArchive;

mod client_protocol;
mod document_reception;
mod document_seeding;
mod paced_reception;

use client_protocol::{
    ingest, look_up, serve_authorization, serve_changes, serve_document_original, serve_document_status,
    serve_document_text, serve_document_thumbnail, submit,
};
use document_reception::{access_refusal, receive_document, reception_route};
use document_seeding::{restrict_to_category, seed_corpus, seed_document_endpoint};
use paced_reception::{limit_receive_buffer, read_body};

const DEFAULT_TOKEN: &str = "scripted-ingest-token";
const AUTHORIZATION_PATH: &str = "/api/v1/authorization";
const CHANGES_PATH: &str = "/api/v1/changes";
const LOOKUP_PATH: &str = "/api/v1/contents/lookup";
const CONTENT_PATH_PREFIX: &str = "/api/v1/contents/";
const DOCUMENT_PATH_PREFIX: &str = "/api/v1/documents/";
const HELD_DIGESTS_PATH: &str = "/scripted/held";
const SEED_DOCUMENT_PATH: &str = "/scripted/documents";
const TOKEN_PATH: &str = "/scripted/token";

enum Body {
    Text(String),
    Bytes(Vec<u8>),
    Empty,
}

struct Answer {
    status: u16,
    content_type: Option<String>,
    headers: Vec<(&'static str, String)>,
    body: Body,
}

impl Answer {
    fn json(status: u16, value: serde_json::Value) -> Answer {
        Answer {
            status,
            content_type: Some("application/json".to_owned()),
            headers: Vec::new(),
            body: Body::Text(value.to_string()),
        }
    }

    fn problem(status: u16, detail: &str) -> Answer {
        Answer {
            status,
            content_type: Some("application/problem+json".to_owned()),
            headers: Vec::new(),
            body: Body::Text(
                serde_json::json!({
                    "type": "about:blank",
                    "title": "Problem",
                    "status": status,
                    "detail": detail,
                })
                .to_string(),
            ),
        }
    }

    fn from_condition(condition: ArchiveCondition) -> Answer {
        match condition {
            ArchiveCondition::CredentialRefused => Answer::problem(401, "The bearer token is invalid"),
            ArchiveCondition::CredentialInsufficient => {
                Answer::problem(403, "This token lacks the permission for this route")
            }
            ArchiveCondition::ProtocolViolation { detail } => Answer::problem(400, &detail),
            ArchiveCondition::ServiceUnavailable { retry_after } => Answer {
                status: 503,
                content_type: Some("application/problem+json".to_owned()),
                headers: vec![("Retry-After", retry_after.as_secs().to_string())],
                body: Body::Text(
                    serde_json::json!({
                        "type": "about:blank",
                        "title": "Problem",
                        "status": 503,
                        "detail": "Service unavailable",
                    })
                    .to_string(),
                ),
            },
            ArchiveCondition::RouteUnknown | ArchiveCondition::ConnectionFailed | ArchiveCondition::TimedOut => {
                Answer::problem(500, "Unexpected scripted condition")
            }
            ArchiveCondition::ServerError => Answer::problem(500, "Server error"),
        }
    }
}

fn split_url(url: &str) -> (&str, Option<&str>) {
    match url.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (url, None),
    }
}

/// What the router reads and changes.
struct ScriptedServer {
    archive: ScriptedArchive,
    /// The `Authorization` header the archive accepts. `POST /scripted/token` replaces it, as an
    /// owner's revocation replaces the token a client holds.
    accepted_authorization: String,
    /// Whether the archive is older than the reception, so that Cloudflare Access answers its
    /// paths.
    legacy_reception: bool,
}

/// What the router reads of a request besides its body.
pub struct ArchiveRequest<'request> {
    method: &'request tiny_http::Method,
    url: &'request str,
    headers: &'request [(String, String)],
}

impl ArchiveRequest<'_> {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(field, _)| field.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// The `/scripted/` routes answer without the token, so a test or an examination can arrange the
/// archive while the client's token is refused.
fn route_request(server: &mut ScriptedServer, request: &ArchiveRequest<'_>, body: Vec<u8>) -> Answer {
    use tiny_http::Method;
    let (path, query) = split_url(request.url);
    match (request.method, path) {
        (Method::Get, HELD_DIGESTS_PATH) => {
            let held = server
                .archive
                .held_digests()
                .into_iter()
                .map(|digest| digest.hexadecimal() + "\n")
                .collect();
            return Answer {
                status: 200,
                content_type: Some("text/plain".to_owned()),
                headers: Vec::new(),
                body: Body::Text(held),
            };
        }
        (Method::Post, SEED_DOCUMENT_PATH) => return seed_document_endpoint(&server.archive, &body),
        (Method::Post, TOKEN_PATH) => return replace_token(server, &body),
        _ => {}
    }
    if reception_route(path).is_some() {
        if server.legacy_reception {
            return access_refusal();
        }
        if *request.method != Method::Put {
            let mut refusal = Answer::problem(405, "Send this request with PUT");
            refusal.headers.push(("Allow", "PUT".to_owned()));
            return refusal;
        }
    }
    if request.header("Authorization") != Some(server.accepted_authorization.as_str()) {
        return Answer::problem(401, "Send the scripted bearer token");
    }
    let archive = &server.archive;
    let mut answer = match (request.method, path) {
        (Method::Get, AUTHORIZATION_PATH) => serve_authorization(archive, query),
        (Method::Get, CHANGES_PATH) => serve_changes(archive, query),
        (Method::Post, LOOKUP_PATH) => look_up(archive, &body),
        (Method::Post, INGEST_PATH) => ingest(archive, request.header("Content-Type"), &body),
        (Method::Put, path) if let Some((route, digest)) = reception_route(path) => {
            receive_document(archive, route, digest, request, query, &body)
        }
        (Method::Put, path)
            if let Some(digest) = path
                .strip_prefix(CONTENT_PATH_PREFIX)
                .and_then(ContentDigest::parse_hexadecimal) =>
        {
            submit(archive, digest, body)
        }
        (Method::Get, path) if let Some(rest) = path.strip_prefix(DOCUMENT_PATH_PREFIX) => {
            if let Some(id) = rest.strip_suffix("/text") {
                serve_document_text(archive, id, query)
            } else if let Some(id) = rest.strip_suffix("/original") {
                serve_document_original(archive, id, query, request.header("If-None-Match"))
            } else if let Some(id) = rest.strip_suffix("/thumbnail") {
                serve_document_thumbnail(archive, id, query)
            } else {
                serve_document_status(archive, rest)
            }
        }
        _ => Answer::problem(404, "The scripted archive has no such route"),
    };
    answer.headers.push(("Cache-Control", "no-store".to_owned()));
    answer
}

/// `POST /scripted/token` with a new token as its body: from then on the archive accepts only that
/// token.
fn replace_token(server: &mut ScriptedServer, body: &[u8]) -> Answer {
    let token = std::str::from_utf8(body).map(str::trim).unwrap_or_default();
    if token.is_empty() {
        return Answer::problem(400, "Send the token the archive accepts from now on as the body");
    }
    server.accepted_authorization = format!("Bearer {token}");
    Answer {
        status: 204,
        content_type: None,
        headers: Vec::new(),
        body: Body::Empty,
    }
}

struct Options {
    token: String,
    permission: PermissionLevel,
    seed: usize,
    /// Bytes per second at which the body of a person's upload, to the ingest route or the
    /// reception, is read, so a screen examination can show an upload under way.
    ingest_pace: Option<usize>,
    restricted_category: Option<String>,
    legacy_reception: bool,
}

fn parse_options() -> Options {
    let mut args = std::env::args().skip(1);
    let mut options = Options {
        token: DEFAULT_TOKEN.to_owned(),
        permission: PermissionLevel::Read,
        seed: 0,
        ingest_pace: None,
        restricted_category: None,
        legacy_reception: false,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--token" => {
                options.token = args.next().expect("--token requires a value");
            }
            "--permission" => {
                let value = args.next().expect("--permission requires a value");
                options.permission = PermissionLevel::parse(&value).expect("unknown permission level");
            }
            "--seed" => {
                let value = args.next().expect("--seed requires a count");
                options.seed = value.parse().expect("--seed requires an integer");
            }
            "--ingest-pace" => {
                let value = args.next().expect("--ingest-pace requires bytes per second");
                options.ingest_pace = Some(value.parse().expect("--ingest-pace requires an integer"));
            }
            "--restrict-to-category" => {
                options.restricted_category = Some(args.next().expect("--restrict-to-category requires a name"));
            }
            "--legacy-reception" => options.legacy_reception = true,
            other => panic!("unknown option: {other}"),
        }
    }
    options
}

fn main() {
    let options = parse_options();
    let server = ScriptedServer {
        archive: ScriptedArchive::new(),
        accepted_authorization: format!("Bearer {}", options.token),
        legacy_reception: options.legacy_reception,
    };
    server.archive.set_permission_level(options.permission);
    if let Some(name) = &options.restricted_category {
        restrict_to_category(&server.archive, name);
    }
    if options.seed > 0 {
        seed_corpus(&server.archive, options.seed);
    }

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a local port is free");
    if let Some(pace) = options.ingest_pace {
        limit_receive_buffer(&listener, pace / 10);
    }
    let http_server = tiny_http::Server::from_listener(listener, None).expect("the listener serves HTTP");
    println!("listening http://{}", http_server.server_addr());
    let _ = std::io::stdout().flush();
    std::thread::spawn(|| {
        let _ = std::io::stdin().lock().read_to_end(&mut Vec::new());
        std::process::exit(0);
    });
    // Each request is read on a thread of its own, so a paced upload holds back no other request,
    // and the router takes one request at a time.
    let server = Mutex::new(server);
    std::thread::scope(|scope| {
        for request in http_server.incoming_requests() {
            scope.spawn(|| answer_request(&server, options.ingest_pace, request));
        }
    });
}

/// Reads the body of a request, at `ingest_pace` for a person's upload, routes it, and sends the
/// answer.
fn answer_request(server: &Mutex<ScriptedServer>, ingest_pace: Option<usize>, mut request: tiny_http::Request) {
    let headers: Vec<(String, String)> = request
        .headers()
        .iter()
        .map(|header| {
            (
                header.field.as_str().as_str().to_owned(),
                header.value.as_str().to_owned(),
            )
        })
        .collect();
    let persons_upload = request.url() == INGEST_PATH
        || reception_route(request.url()).is_some_and(|(route, _)| route == SubmissionRoute::SubmittedDocuments);
    let pace = ingest_pace.filter(|_| persons_upload);
    let mut body = Vec::new();
    let answer = if read_body(request.as_reader(), pace, &mut body).is_err() {
        Answer::problem(400, "The body could not be read")
    } else {
        let routed = ArchiveRequest {
            method: request.method(),
            url: request.url(),
            headers: &headers,
        };
        route_request(
            &mut server.lock().unwrap_or_else(PoisonError::into_inner),
            &routed,
            body,
        )
    };
    let mut response = match answer.body {
        Body::Text(text) => tiny_http::Response::from_data(text.into_bytes()),
        Body::Bytes(bytes) => tiny_http::Response::from_data(bytes),
        Body::Empty => tiny_http::Response::from_data(Vec::new()),
    }
    .with_status_code(answer.status);
    if let Some(content_type) = answer.content_type {
        response = response.with_header(
            tiny_http::Header::from_bytes("Content-Type", content_type).expect("a content type is a header value"),
        );
    }
    for (name, value) in answer.headers {
        response = response.with_header(tiny_http::Header::from_bytes(name, value).expect("valid HTTP header"));
    }
    let _ = request.respond(response);
}
