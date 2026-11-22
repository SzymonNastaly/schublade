//! The HTTP reader against a local server that answers the two files of
//! `test_fixtures/client_protocol`, which the Worker's test answers for a seeded archive. The files
//! are the one wire format of both implementations.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Cursor;
use std::thread;
use std::time::Duration;

use archive_access::{
    ArchiveAddress, ArchiveAuthorization, ArchiveCondition, ArchiveToken, ContentDigest, DocumentIdentifier,
    PermissionLevel, Timestamp,
};
use archive_replica::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, ExtractedField, FailureReason,
    FieldValue, IngestionStage, JournalCursor, JournalPage, MemberIdentifier, MemberRecord, PersonAssignment,
    RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use archive_replica::{ArchiveReader, HttpArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};

const AUTHORIZATION: &str = include_str!("../../../test_fixtures/client_protocol/authorization.json");
const CHANGES_PAGE: &str = include_str!("../../../test_fixtures/client_protocol/changes_page.json");

const MEMBER: &str = "50617283-94a5-4fb6-90c7-18293a4b5c6d";
const SENDER: &str = "3e4f5061-7283-4d94-bea5-f60718293a4b";
const CATEGORY: &str = "0b1c2d3e-4f50-4a61-8b72-c3d4e5f60718";
const ELECTRICITY_TAG: &str = "4f506172-8394-4ea5-8fb6-0718293a4b5c";
const TAXATION_TAG: &str = "6a7b8c9d-0e1f-4a2b-8c3d-4e5f60718293";

#[test]
fn the_reader_parses_the_fixtures_into_the_records_they_hold() {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let address = ArchiveAddress::parse(&format!("http://{}", server.server_addr())).unwrap();
    let serving = thread::spawn(move || {
        for request in server.incoming_requests().take(2) {
            let body = match request.url() {
                "/api/v1/authorization" => AUTHORIZATION,
                "/api/v1/changes?after=fc26a0aaf01faa9625397c1e4322b36c.27" => CHANGES_PAGE,
                path => panic!("no fixture answers {path}"),
            };
            let content_type = tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap();
            request
                .respond(tiny_http::Response::from_string(body).with_header(content_type))
                .unwrap();
        }
    });
    let reader = HttpArchiveReader::new(&address, &ArchiveToken::new("schublade_fixture_token".to_owned()));

    let authorization = reader.read_authorization();
    let page = reader.read_changes(JournalCursor::parse("fc26a0aaf01faa9625397c1e4322b36c.27").as_ref());
    serving.join().unwrap();

    assert_eq!(
        authorization,
        Ok(ArchiveAuthorization {
            journal_identifier: "fc26a0aaf01faa9625397c1e4322b36c".to_owned(),
            token_description: "MacBook of Jonas".to_owned(),
            permission_level: PermissionLevel::Read,
            restricted: false,
            scope_digest: "6cd8cec706fa11110d83fb46f97df1f9be43b4c570f3390e7c7f6a5173f595e6".to_owned(),
        })
    );
    let unclassified = |identifier: &str,
                        condition: DocumentCondition,
                        media_type: &str,
                        byte_size: u64,
                        page_count: Option<u32>,
                        original: Option<&str>,
                        arrived_at: i64| DocumentRecord {
        identifier: DocumentIdentifier::parse(identifier).unwrap(),
        condition,
        title: None,
        document_date: None,
        sender: None,
        category: None,
        person: PersonAssignment::Unassigned,
        summary: None,
        media_type: media_type.to_owned(),
        byte_size,
        page_count,
        original: original.map(|digest| ContentDigest::parse_hexadecimal(digest).unwrap()),
        arrived_at: Timestamp(arrived_at),
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    };
    let field =
        |key: &str, value: FieldValue, confidence: Option<f64>| (key.to_owned(), ExtractedField { value, confidence });
    assert_eq!(
        page,
        Ok(PageAnswer::Page(JournalPage {
            cursor: JournalCursor::parse("fc26a0aaf01faa9625397c1e4322b36c.38").unwrap(),
            complete: true,
            remaining_entries: 0,
            members: vec![MemberRecord {
                identifier: MemberIdentifier::parse(MEMBER).unwrap(),
                display_name: "Mira Wiśniewska".to_owned(),
            }],
            senders: vec![SenderRecord {
                identifier: SenderIdentifier::parse(SENDER).unwrap(),
                name: "Stadtwerke Talbrück GmbH".to_owned(),
            }],
            categories: vec![CategoryRecord {
                identifier: CategoryIdentifier::parse(CATEGORY).unwrap(),
                name: "Invoice".to_owned(),
                expected_fields: ["amount", "currency", "due_date", "iban", "invoice_number"]
                    .map(str::to_owned)
                    .to_vec(),
            }],
            tags: vec![
                TagRecord {
                    identifier: TagIdentifier::parse(ELECTRICITY_TAG).unwrap(),
                    name: "strom".to_owned(),
                    color_hex: None,
                },
                TagRecord {
                    identifier: TagIdentifier::parse(TAXATION_TAG).unwrap(),
                    name: "steuer 2026".to_owned(),
                    color_hex: Some("#2f6fde".to_owned()),
                },
            ],
            documents: vec![
                DocumentRecord {
                    identifier: DocumentIdentifier::parse("4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11").unwrap(),
                    condition: DocumentCondition::Archived,
                    title: Some("Stadtwerke Talbrück Electricity Annual Statement 2025-2026".to_owned()),
                    document_date: CalendarDate::parse("2026-09-22"),
                    sender: SenderIdentifier::parse(SENDER),
                    category: CategoryIdentifier::parse(CATEGORY),
                    person: PersonAssignment::Household,
                    summary: Some("Annual electricity statement with an additional payment of 72.09 euros.".to_owned()),
                    media_type: "application/pdf".to_owned(),
                    byte_size: 184_233,
                    page_count: Some(1),
                    original: ContentDigest::parse_hexadecimal(
                        "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
                    ),
                    arrived_at: Timestamp(1_790_151_242_000),
                    tags: BTreeSet::from([
                        TagIdentifier::parse(ELECTRICITY_TAG).unwrap(),
                        TagIdentifier::parse(TAXATION_TAG).unwrap(),
                    ]),
                    fields: BTreeMap::from([
                        field("amount", FieldValue::Number(72.09), Some(0.94)),
                        field("currency", FieldValue::Text("EUR".to_owned()), Some(0.99)),
                        field(
                            "due_date",
                            FieldValue::Date(CalendarDate::parse("2026-10-06").unwrap()),
                            None
                        ),
                    ]),
                },
                DocumentRecord {
                    identifier: DocumentIdentifier::parse("7c8d9e0f-1a2b-4c3d-9e4f-5a6b7c8d9e0f").unwrap(),
                    condition: DocumentCondition::Archived,
                    title: Some("Handwritten Note on the Bicycle Repair".to_owned()),
                    person: PersonAssignment::Member(MemberIdentifier::parse(MEMBER).unwrap()),
                    summary: Some("A handwritten note that lists the parts replaced on a bicycle.".to_owned()),
                    ..unclassified(
                        "7c8d9e0f-1a2b-4c3d-9e4f-5a6b7c8d9e0f",
                        DocumentCondition::Archived,
                        "image/jpeg",
                        2_381_954,
                        Some(1),
                        Some("5b6c7d8e9fa0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6"),
                        1_790_962_890_000,
                    )
                },
                unclassified(
                    "8d9e0f1a-2b3c-4d4e-8f5a-6b7c8d9e0f1a",
                    DocumentCondition::Arriving(IngestionStage::RecognizingText),
                    "application/pdf",
                    912_004,
                    Some(3),
                    Some("c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8"),
                    1_791_093_791_000,
                ),
                unclassified(
                    "9e0f1a2b-3c4d-4e5f-9a6b-7c8d9e0f1a2b",
                    DocumentCondition::Failed(FailureReason::UnreadablePage),
                    "image/png",
                    48_213,
                    None,
                    None,
                    1_788_124_787_000,
                ),
            ],
            removed: vec![
                RemovedRecord::Sender(SenderIdentifier::parse("2d3e4f50-6172-4839-a4b5-c6d7e8f90a1b").unwrap()),
                RemovedRecord::Document(DocumentIdentifier::parse("61728394-a5b6-4c7d-8e9f-0a1b2c3d4e5f").unwrap()),
            ],
        }))
    );
}

#[test]
fn the_reader_handles_representation_routes_and_shared_error_classifications() {
    let document = DocumentIdentifier::parse("4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11").unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let address = ArchiveAddress::parse(&format!("http://{}", server.server_addr())).unwrap();
    let serving = thread::spawn(move || {
        for (index, request) in server.incoming_requests().take(11).enumerate() {
            let response: tiny_http::Response<Cursor<Vec<u8>>> = match (index, request.url()) {
                (0, path) if path.ends_with("/text") => {
                    tiny_http::Response::from_string("# Extracted").with_status_code(200)
                }
                (1, path) if path.ends_with("/text") => {
                    tiny_http::Response::from_data(vec![0xFF, 0xFE, 0xFD]).with_status_code(200)
                }
                (2, path) if path.ends_with("/text") => {
                    tiny_http::Response::from_string("missing").with_status_code(404)
                }
                (3, path) if path.ends_with("/original") => {
                    tiny_http::Response::from_data(b"%PDF-1.7".to_vec()).with_status_code(200)
                }
                (4, path) if path.ends_with("/original") => {
                    tiny_http::Response::from_string("unprinted").with_status_code(409)
                }
                (5, path) if path.ends_with("/original") => {
                    tiny_http::Response::from_string("deleted").with_status_code(404)
                }
                (6, path) if path.ends_with("/thumbnail") => {
                    tiny_http::Response::from_data(b"\x89PNG".to_vec()).with_status_code(200)
                }
                (7, path) if path.ends_with("/thumbnail") => {
                    tiny_http::Response::from_string("no thumb").with_status_code(404)
                }
                (8, "/api/v1/changes") => {
                    let header =
                        tiny_http::Header::from_bytes("Content-Type", "Application/Problem+JSON; charset=utf-8")
                            .unwrap();
                    tiny_http::Response::from_string("{}")
                        .with_status_code(403)
                        .with_header(header)
                }
                (9, "/api/v1/changes") => {
                    let header = tiny_http::Header::from_bytes("Content-Type", "text/html").unwrap();
                    tiny_http::Response::from_string("Access denied")
                        .with_status_code(403)
                        .with_header(header)
                }
                (10, "/api/v1/changes") => {
                    let header = tiny_http::Header::from_bytes("Retry-After", "42").unwrap();
                    tiny_http::Response::from_data(vec![0xFF, 0x80])
                        .with_status_code(503)
                        .with_header(header)
                }
                other => panic!("unexpected request: {other:?}"),
            };
            request.respond(response).unwrap();
        }
    });
    let reader = HttpArchiveReader::new(&address, &ArchiveToken::new("schublade_fixture_token".to_owned()));

    assert_eq!(reader.read_text(&document), Ok(Some("# Extracted".to_owned())));
    assert!(matches!(
        reader.read_text(&document),
        Err(ArchiveCondition::ProtocolViolation { .. })
    ));
    assert_eq!(reader.read_text(&document), Ok(None));

    let mut original = Vec::new();
    assert_eq!(
        reader.download_original(&document, &mut original).unwrap(),
        OriginalAnswer::Received
    );
    assert_eq!(original, b"%PDF-1.7");
    assert_eq!(
        reader.download_original(&document, &mut Vec::new()).unwrap(),
        OriginalAnswer::NotPrinted
    );
    assert_eq!(
        reader.download_original(&document, &mut Vec::new()).unwrap(),
        OriginalAnswer::DocumentAbsent
    );

    let mut thumbnail = Vec::new();
    assert_eq!(
        reader.download_thumbnail(&document, &mut thumbnail).unwrap(),
        ThumbnailAnswer::Received
    );
    assert_eq!(thumbnail, b"\x89PNG");
    assert_eq!(
        reader.download_thumbnail(&document, &mut Vec::new()).unwrap(),
        ThumbnailAnswer::Absent
    );

    assert_eq!(reader.read_changes(None), Err(ArchiveCondition::CredentialInsufficient));
    assert_eq!(reader.read_changes(None), Err(ArchiveCondition::RouteUnknown));
    assert_eq!(
        reader.read_changes(None),
        Err(ArchiveCondition::ServiceUnavailable {
            retry_after: Duration::from_secs(42),
        })
    );
    serving.join().unwrap();
}
