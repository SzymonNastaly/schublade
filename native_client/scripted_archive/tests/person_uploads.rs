//! A person's upload as the iPhone sends it: a body written by `prepare_submission`, posted to the
//! scripted archive's ingest route, and its answer read by `read_submission_answer`.

use std::io::{BufRead, BufReader};
use std::process::{Child, ChildStdin, Command, Stdio};

use archive_access::{
    ArchiveAddress, ArchiveToken, SubmissionAnswer, SubmissionMediaType, prepare_submission, read_submission_answer,
};

const TOKEN: &str = "scripted-person-upload-token";

/// The server ends when its standard input closes, which dropping this does.
struct ScriptedArchiveServer {
    process: Child,
    _input: ChildStdin,
    address: ArchiveAddress,
}

impl ScriptedArchiveServer {
    fn start() -> ScriptedArchiveServer {
        let mut process = Command::new(env!("CARGO_BIN_EXE_scripted-archive-server"))
            .args(["--token", TOKEN])
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
        let prepared = prepare_submission(
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
        read_submission_answer(status, &answer.into_body().read_to_vec().unwrap())
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
    let server = ScriptedArchiveServer::start();
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
