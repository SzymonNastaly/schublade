//! The scripted archive over HTTP, answering every route of `notes/client_protocol.md` from one
//! `ScriptedArchive` model so that an uploaded file appears in the journal and in a library that
//! follows it.
//!
//! Prints `listening http://127.0.0.1:<port>` and runs until standard input closes.

use std::io::{Read, Write};

use archive_access::{ArchiveCondition, ContentDigest, INGEST_PATH, PermissionLevel};
use scripted_archive::ScriptedArchive;

mod client_protocol;
mod document_seeding;
mod paced_reception;

use client_protocol::{
    ingest, look_up, serve_authorization, serve_changes, serve_document_original, serve_document_status,
    serve_document_text, serve_document_thumbnail, submit,
};
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

fn route_request(
    archive: &ScriptedArchive,
    authorized: bool,
    method: &tiny_http::Method,
    url: &str,
    headers: RequestHeaders<'_>,
    body: Vec<u8>,
) -> Answer {
    let RequestHeaders {
        if_none_match,
        content_type,
    } = headers;
    use tiny_http::Method;
    let (path, query) = split_url(url);
    if path == HELD_DIGESTS_PATH && *method == Method::Get {
        let held = archive
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
    if path == SEED_DOCUMENT_PATH && *method == Method::Post {
        return seed_document_endpoint(archive, &body);
    }
    if !authorized {
        return Answer::problem(401, "Send the scripted bearer token");
    }
    let mut answer = match (method, path) {
        (Method::Get, AUTHORIZATION_PATH) => serve_authorization(archive, query),
        (Method::Get, CHANGES_PATH) => serve_changes(archive, query),
        (Method::Post, LOOKUP_PATH) => look_up(archive, &body),
        (Method::Post, INGEST_PATH) => ingest(archive, content_type, &body),
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
                serve_document_original(archive, id, query, if_none_match)
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

/// The request headers a route reads.
struct RequestHeaders<'request> {
    if_none_match: Option<&'request str>,
    content_type: Option<&'request str>,
}

struct Options {
    token: String,
    permission: PermissionLevel,
    seed: usize,
    /// Bytes per second at which the body of an upload to the ingest route is read, so a screen
    /// examination can show an upload under way.
    ingest_pace: Option<usize>,
    restricted_category: Option<String>,
}

/// `POST /scripted/token` with a new token as its body: from then on the archive accepts only that
/// token, as an archive does once its owner revokes the one a client holds.
fn replaced_token(method: &tiny_http::Method, url: &str, body: &[u8]) -> Option<String> {
    if *method != tiny_http::Method::Post || url != TOKEN_PATH {
        return None;
    }
    let token = std::str::from_utf8(body).ok()?.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

fn parse_options() -> Options {
    let mut args = std::env::args().skip(1);
    let mut options = Options {
        token: DEFAULT_TOKEN.to_owned(),
        permission: PermissionLevel::Read,
        seed: 0,
        ingest_pace: None,
        restricted_category: None,
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
            other => panic!("unknown option: {other}"),
        }
    }
    options
}

fn main() {
    let options = parse_options();
    let mut expected_auth = format!("Bearer {}", options.token);
    let archive = ScriptedArchive::new();
    archive.set_permission_level(options.permission);
    if let Some(name) = &options.restricted_category {
        restrict_to_category(&archive, name);
    }
    if options.seed > 0 {
        seed_corpus(&archive, options.seed);
    }

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a local port is free");
    if let Some(pace) = options.ingest_pace {
        limit_receive_buffer(&listener, pace / 10);
    }
    let server = tiny_http::Server::from_listener(listener, None).expect("the listener serves HTTP");
    println!("listening http://{}", server.server_addr());
    let _ = std::io::stdout().flush();
    std::thread::spawn(|| {
        let _ = std::io::stdin().lock().read_to_end(&mut Vec::new());
        std::process::exit(0);
    });

    for mut request in server.incoming_requests() {
        let authorized = request
            .headers()
            .iter()
            .any(|header| header.field.equiv("Authorization") && header.value.as_str() == expected_auth);
        let header = |name: &'static str| {
            request
                .headers()
                .iter()
                .find(|header| header.field.equiv(name))
                .map(|header| header.value.as_str().to_owned())
        };
        let (if_none_match, content_type) = (header("If-None-Match"), header("Content-Type"));
        let mut body = Vec::new();
        let pace = options.ingest_pace.filter(|_| request.url() == INGEST_PATH);
        let answer = if read_body(request.as_reader(), pace, &mut body).is_err() {
            Answer::problem(400, "The body could not be read")
        } else if let Some(token) = replaced_token(request.method(), request.url(), &body) {
            expected_auth = format!("Bearer {token}");
            Answer {
                status: 204,
                content_type: None,
                headers: Vec::new(),
                body: Body::Empty,
            }
        } else {
            let (method, url) = (request.method().clone(), request.url().to_owned());
            let headers = RequestHeaders {
                if_none_match: if_none_match.as_deref(),
                content_type: content_type.as_deref(),
            };
            route_request(&archive, authorized, &method, &url, headers, body)
        };
        let mut headers = Vec::new();
        if let Some(content_type) = answer.content_type {
            headers.push(
                tiny_http::Header::from_bytes("Content-Type", content_type).expect("a content type is a header value"),
            );
        }
        for (name, value) in answer.headers {
            headers.push(tiny_http::Header::from_bytes(name, value).expect("valid HTTP header"));
        }
        let mut response: tiny_http::Response<std::io::Cursor<Vec<u8>>> = match answer.body {
            Body::Text(text) => tiny_http::Response::from_data(text.into_bytes()),
            Body::Bytes(bytes) => tiny_http::Response::from_data(bytes),
            Body::Empty => tiny_http::Response::from_data(Vec::new()),
        }
        .with_status_code(answer.status);
        for header in headers {
            response = response.with_header(header);
        }
        let _ = request.respond(response);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_post_of_a_token_to_its_path_replaces_the_token() {
        use tiny_http::Method;
        assert_eq!(
            replaced_token(&Method::Post, TOKEN_PATH, b"another-token\n"),
            Some("another-token".to_owned())
        );
        assert_eq!(replaced_token(&Method::Post, TOKEN_PATH, b"  "), None);
        assert_eq!(replaced_token(&Method::Get, TOKEN_PATH, b"another-token"), None);
        assert_eq!(
            replaced_token(&Method::Post, SEED_DOCUMENT_PATH, b"another-token"),
            None
        );
    }
}
