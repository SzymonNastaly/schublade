//! Documents sent to the scripted archive as the clients send them: a body that
//! `prepare_submission` wrote for the iPhone, put to the reception and read by
//! `read_submission_answer`, the parts a collector puts with `send_document`, and the multipart body
//! of `prepare_ingest_submission` posted to the ingest route.

use std::io::{BufRead, BufReader};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

use archive_access::{
    ArchiveAddress, ArchiveDownload, ArchiveExchange, ArchiveToken, ContentDigest, DerivedRepresentations,
    SubmissionAnswer, SubmissionMediaType, SubmissionRoute, compose_document_text, prepare_ingest_submission,
    prepare_submission, read_ingest_submission_answer, read_submission_answer, send_document,
};
use sha2::{Digest, Sha256};

const TOKEN: &str = "scripted-person-upload-token";

/// The server ends when its standard input closes, which dropping this does.
struct ScriptedArchiveServer {
    process: Child,
    _input: ChildStdin,
    address: ArchiveAddress,
}

impl ScriptedArchiveServer {
    fn start(options: &[&str]) -> ScriptedArchiveServer {
        let mut process = Command::new(env!("CARGO_BIN_EXE_scripted-archive-server"))
            .args(["--token", TOKEN])
            .args(options)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let input = process.stdin.take().unwrap();
        let mut line = String::new();
        BufReader::new(process.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let address = ArchiveAddress::parse(line.trim().strip_prefix("listening ").unwrap()).unwrap();
        ScriptedArchiveServer {
            process,
            _input: input,
            address,
        }
    }

    fn send(&self, contents: &[u8], file_name: &str, token: &str) -> SubmissionAnswer {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join(file_name);
        std::fs::write(&document, contents).unwrap();
        let body = directory.path().join("request_body");
        let prepared = prepare_ingest_submission(
            &self.address,
            &ArchiveToken::new(token.to_owned()),
            &document,
            file_name,
            SubmissionMediaType::Pdf,
            &body,
        )
        .unwrap();
        let answer = ureq::post(&prepared.url)
            .header("Content-Type", &prepared.content_type)
            .header("Authorization", &prepared.authorization)
            .config()
            .http_status_as_error(false)
            .build()
            .send(std::fs::read(&body).unwrap())
            .unwrap();
        let status = answer.status().as_u16();
        read_ingest_submission_answer(status, &answer.into_body().read_to_vec().unwrap())
    }

    fn exchange(&self) -> ArchiveExchange {
        ArchiveExchange::new(&self.address, &ArchiveToken::new(TOKEN.to_owned()))
    }

    /// Writes the body as the iPhone writes it and puts it to the reception as its background
    /// transfer does.
    fn submit(&self, original: &[u8], derived: &DerivedRepresentations) -> SubmissionAnswer {
        let directory = tempfile::tempdir().unwrap();
        let document = directory.path().join("Scan.pdf");
        std::fs::write(&document, original).unwrap();
        let body = directory.path().join("request_body");
        let prepared = prepare_submission(
            &self.address,
            &ArchiveToken::new(TOKEN.to_owned()),
            &document,
            derived,
            &body,
        )
        .unwrap();
        let mut request = ureq::put(&prepared.url).config().http_status_as_error(false).build();
        for (name, value) in &prepared.headers {
            request = request.header(name, value);
        }
        let answer = request.send(std::fs::read(&body).unwrap()).unwrap();
        let status = answer.status().as_u16();
        let content_type = answer
            .headers()
            .get("Content-Type")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        read_submission_answer(
            status,
            content_type.as_deref(),
            &answer.into_body().read_to_vec().unwrap(),
        )
    }
}

impl Drop for ScriptedArchiveServer {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

#[test]
fn a_sent_scan_is_archived_once_and_the_archive_answers_each_refusal() {
    let server = ScriptedArchiveServer::start(&[]);
    let scan = b"%PDF-1.4\nA letter from the Stadtwerke\n%%EOF\n";

    let SubmissionAnswer::Archived { document, already_held } = server.send(scan, "Scan.pdf", TOKEN) else {
        panic!("the first upload of a scan is archived");
    };
    assert!(!already_held);
    assert_eq!(
        server.send(scan, "Scan again.pdf", TOKEN),
        SubmissionAnswer::Archived {
            document,
            already_held: true
        }
    );
    assert_eq!(
        server.send(b"plain notes", "notes.pdf", TOKEN),
        SubmissionAnswer::Rejected {
            reason: "Only PDF, JPEG, PNG, and WebP files can be archived.".to_owned()
        }
    );
    assert_eq!(
        server.send(scan, "Scan.pdf", "revoked-token"),
        SubmissionAnswer::TokenRefused
    );
}

#[test]
fn a_posted_token_replaces_the_one_the_archive_accepts() {
    let server = ScriptedArchiveServer::start(&[]);
    let scan = b"%PDF-1.4\nA letter from the tax office\n%%EOF\n";
    let replacement = ureq::post(format!("{}/scripted/token", server.address.origin()))
        .send("another-token\n")
        .unwrap();
    assert_eq!(replacement.status().as_u16(), 204);

    assert_eq!(server.send(scan, "Scan.pdf", TOKEN), SubmissionAnswer::TokenRefused);
    assert!(matches!(
        server.send(scan, "Scan.pdf", "another-token"),
        SubmissionAnswer::Archived {
            already_held: false,
            ..
        }
    ));
}

#[test]
fn the_archive_answers_other_requests_while_it_reads_a_paced_upload() {
    let server = ScriptedArchiveServer::start(&["--ingest-pace", "10000"]);
    let scan = [b"%PDF-1.4\n".as_slice(), &[b'x'; 10_000]].concat();
    std::thread::scope(|scope| {
        let upload = scope.spawn(|| server.send(&scan, "Scan.pdf", TOKEN));
        std::thread::sleep(Duration::from_millis(300));
        let asked = Instant::now();
        let held = ureq::get(format!("{}/scripted/held", server.address.origin()))
            .call()
            .unwrap();
        assert_eq!(held.status().as_u16(), 200);
        let waited = asked.elapsed();
        assert!(
            waited < Duration::from_millis(500),
            "the archive answered after {waited:?}, so it waited for the upload"
        );
        assert!(matches!(
            upload.join().unwrap(),
            SubmissionAnswer::Archived {
                already_held: false,
                ..
            }
        ));
    });
}

#[test]
fn a_document_reaches_the_reception_with_its_text_and_thumbnail_once_on_either_route() {
    let server = ScriptedArchiveServer::start(&[]);
    let exchange = server.exchange();
    let scan = b"%PDF-1.4\nA letter from the Stadtwerke\n%%EOF\n";
    let thumbnail = vec![0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9];
    let derived = DerivedRepresentations {
        page_texts: vec!["Stadtwerke Talbrück GmbH".to_owned(), String::new()],
        thumbnail: Some(thumbnail.clone()),
    };

    let SubmissionAnswer::Archived { document, already_held } = server.submit(scan, &derived) else {
        panic!("the first submission of a scan is archived");
    };
    assert!(!already_held);
    assert_eq!(
        server.submit(scan, &derived),
        SubmissionAnswer::Archived {
            document: document.clone(),
            already_held: true
        }
    );
    let text = exchange
        .get(&format!("/api/v1/documents/{}/text", document.as_str()))
        .unwrap();
    assert_eq!(text.body(), compose_document_text(&derived.page_texts));
    let mut served_thumbnail = Vec::new();
    let downloaded = exchange
        .download(
            &format!("/api/v1/documents/{}/thumbnail", document.as_str()),
            &mut served_thumbnail,
            200_000,
        )
        .unwrap();
    assert!(matches!(downloaded, ArchiveDownload::Written));
    assert_eq!(served_thumbnail, thumbnail);

    let collected = b"%PDF-1.4\nA letter from the tax office\n%%EOF\n";
    let digest = ContentDigest::from_bytes(Sha256::digest(collected).into());
    let send = || {
        send_document(
            &exchange,
            SubmissionRoute::CollectedDocuments,
            &digest,
            &derived,
            collected,
        )
        .unwrap()
        .status()
    };
    assert_eq!((send(), send()), (202, 200));
}
