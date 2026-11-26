//! `POST /scripted/documents`, the corpus of `--seed`, and the scope of `--restrict-to-category`:
//! how a test or a screen examination puts documents into the archive.

use std::collections::{BTreeMap, BTreeSet};

use archive_access::{ContentDigest, DocumentIdentifier, Timestamp};
use archive_replica::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, ExtractedField, FailureReason,
    FieldValue, IngestionStage, PersonAssignment, SenderIdentifier, SenderRecord,
};
use collection_core::candidate_classification::{ContentKind, identify_content_kind};
use collection_core::file_system_observation::content_digest_of;
use scripted_archive::{ArchiveScope, ScriptedArchive};
use sha2::{Digest, Sha256};

use crate::Answer;

/// `POST /scripted/documents`: names one document by `identifier` or by `content_sha256` and
/// creates or revises it. A key present in the request replaces what the document holds, and an
/// absent or null key keeps it.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SeedDocumentRequest {
    identifier: Option<String>,
    /// The SHA-256 of bytes a person uploaded, naming the document that holds them.
    content_sha256: Option<String>,
    status: Option<String>,
    failure_reason: Option<String>,
    title: Option<String>,
    document_date: Option<String>,
    sender_name: Option<String>,
    category_name: Option<String>,
    summary: Option<String>,
    page_count: Option<u32>,
    text: Option<String>,
    original_utf8: Option<String>,
    /// A file on the server's machine whose bytes are the original, as a screen examination seeds
    /// real PDFs and pictures.
    original_file: Option<String>,
    thumbnail_file: Option<String>,
    /// Extracted fields by key: text as a string, a number, or a date as `{"date": "2026-10-20"}`.
    fields: Option<BTreeMap<String, serde_json::Value>>,
}

enum SeedTarget {
    Existing(Box<DocumentRecord>),
    Created(DocumentIdentifier),
}

/// The condition a request names, refused unless the archive knows its status and failure reason.
fn seed_condition(status: Option<&str>, failure_reason: Option<&str>) -> Result<Option<DocumentCondition>, String> {
    if failure_reason.is_some() && status != Some("failed") {
        return Err("Only the status failed takes a failure_reason".to_owned());
    }
    let Some(status) = status else {
        return Ok(None);
    };
    match DocumentCondition::parse(status, failure_reason) {
        None => Err("The status failed takes a failure_reason".to_owned()),
        Some(DocumentCondition::Arriving(IngestionStage::Unrecognized(status))) => {
            Err(format!("Unknown status {status}"))
        }
        Some(DocumentCondition::Failed(FailureReason::Unrecognized(reason))) => {
            Err(format!("Unknown failure_reason {reason}"))
        }
        condition => Ok(condition),
    }
}

fn seed_field_value(key: &str, value: serde_json::Value) -> Result<FieldValue, String> {
    let date = |object: &serde_json::Map<String, serde_json::Value>| {
        (object.len() == 1)
            .then(|| object.get("date")?.as_str().and_then(CalendarDate::parse))
            .flatten()
    };
    match value {
        serde_json::Value::String(text) => Ok(FieldValue::Text(text)),
        serde_json::Value::Number(number) if let Some(number) = number.as_f64() => Ok(FieldValue::Number(number)),
        serde_json::Value::Object(object) if let Some(date) = date(&object) => Ok(FieldValue::Date(date)),
        _ => Err(format!(
            "The field {key} is not a string, a number, or {{\"date\": \"YYYY-MM-DD\"}}"
        )),
    }
}

fn read_seed_file(path: &str) -> Result<Vec<u8>, Answer> {
    std::fs::read(path).map_err(|error| Answer::problem(400, &format!("Cannot read {path}: {error}")))
}

fn seed_sender(archive: &ScriptedArchive, name: String) -> SenderIdentifier {
    let identifier = SenderIdentifier::parse(&deterministic_identifier(2, &name)).unwrap_or_else(|| unreachable!());
    archive.put_sender(SenderRecord {
        identifier: identifier.clone(),
        name,
    });
    identifier
}

fn seed_category(archive: &ScriptedArchive, name: String) -> CategoryIdentifier {
    let identifier = category_identifier(&name);
    archive.put_category(CategoryRecord {
        identifier: identifier.clone(),
        name,
        expected_fields: vec!["amount".to_owned(), "currency".to_owned()],
    });
    identifier
}

/// The identifier a seeded category of this name receives, before or after it is seeded.
fn category_identifier(name: &str) -> CategoryIdentifier {
    CategoryIdentifier::parse(&deterministic_identifier(3, name)).unwrap_or_else(|| unreachable!())
}

/// Lets the token read only the documents of the category with this name, as a token issued for
/// part of the archive does, so the iPhone shows how it explains that such a token cannot send.
pub fn restrict_to_category(archive: &ScriptedArchive, name: &str) {
    archive.restrict_scope(ArchiveScope {
        allowed_categories: Some(BTreeSet::from([category_identifier(name)])),
        ..ArchiveScope::default()
    });
}

fn deterministic_identifier(kind: u8, name: &str) -> String {
    let hash = Sha256::digest(name.as_bytes());
    let hex: String = hash.iter().take(6).map(|byte| format!("{byte:02x}")).collect();
    format!("{kind:08x}-0000-4000-8000-{hex}")
}

/// Reads and checks the whole request before it writes anything, so a refused request leaves the
/// archive as it was.
fn seed_document(archive: &ScriptedArchive, body: &[u8]) -> Result<DocumentIdentifier, Answer> {
    let refuse = |detail: &str| Answer::problem(400, detail);
    let request: SeedDocumentRequest = serde_json::from_slice(body)
        .map_err(|error| refuse(&format!("Invalid request for /scripted/documents: {error}")))?;
    let target = match (request.identifier.as_deref(), request.content_sha256.as_deref()) {
        (Some(identifier), None) => {
            let identifier =
                DocumentIdentifier::parse(identifier).ok_or_else(|| refuse("Invalid document identifier"))?;
            match archive.document(&identifier) {
                Some(document) => SeedTarget::Existing(Box::new(document)),
                None => SeedTarget::Created(identifier),
            }
        }
        (None, Some(digest)) => {
            let digest = ContentDigest::parse_hexadecimal(digest)
                .ok_or_else(|| refuse("content_sha256 is not 64 lowercase hexadecimal digits"))?;
            let document = archive
                .document_holding(&digest)
                .ok_or_else(|| Answer::problem(404, "No document holds this content"))?;
            SeedTarget::Existing(Box::new(document))
        }
        _ => {
            return Err(refuse(
                "Name the document by exactly one of identifier and content_sha256",
            ));
        }
    };
    let condition = seed_condition(request.status.as_deref(), request.failure_reason.as_deref())
        .map_err(|detail| refuse(&detail))?;
    let original = match (request.original_utf8, request.original_file) {
        (None, None) => None,
        (Some(text), None) => Some(text.into_bytes()),
        (None, Some(path)) => Some(read_seed_file(&path)?),
        (Some(_), Some(_)) => return Err(refuse("Give the original as original_utf8 or original_file, not both")),
    };
    if original.is_some() && matches!(target, SeedTarget::Existing(_)) {
        return Err(refuse("A document keeps the original it was created with"));
    }
    let thumbnail = request.thumbnail_file.map(|path| read_seed_file(&path)).transpose()?;
    if let Some(bytes) = &thumbnail
        && matches!(identify_content_kind(bytes), None | Some(ContentKind::PortableDocument))
    {
        return Err(refuse("thumbnail_file is not a JPEG, PNG, or WebP picture"));
    }
    let document_date = request
        .document_date
        .map(|text| CalendarDate::parse(&text).ok_or_else(|| refuse("document_date is not a day as YYYY-MM-DD")))
        .transpose()?;
    let fields = request
        .fields
        .map(|fields| {
            fields
                .into_iter()
                .map(|(key, value)| {
                    let value = seed_field_value(&key, value).map_err(|detail| refuse(&detail))?;
                    let field = ExtractedField {
                        value,
                        confidence: Some(0.95),
                    };
                    Ok((key, field))
                })
                .collect::<Result<BTreeMap<_, _>, Answer>>()
        })
        .transpose()?;

    let mut document = match target {
        SeedTarget::Existing(document) => *document,
        SeedTarget::Created(identifier) => DocumentRecord {
            identifier,
            condition: DocumentCondition::Archived,
            title: None,
            document_date: None,
            sender: None,
            category: None,
            person: PersonAssignment::Household,
            summary: None,
            media_type: "application/pdf".to_owned(),
            byte_size: 0,
            page_count: None,
            original: None,
            arrived_at: Timestamp(1_790_000_000_000),
            tags: BTreeSet::new(),
            fields: BTreeMap::new(),
        },
    };
    if let Some(bytes) = &original {
        if let Some(kind) = identify_content_kind(bytes) {
            kind.media_type().clone_into(&mut document.media_type);
        }
        document.byte_size = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        document.original = Some(content_digest_of(bytes));
    }
    if let Some(condition) = condition {
        document.condition = condition;
    }
    document.title = request.title.or(document.title);
    document.document_date = document_date.or(document.document_date);
    document.sender = request
        .sender_name
        .map(|name| seed_sender(archive, name))
        .or(document.sender);
    document.category = request
        .category_name
        .map(|name| seed_category(archive, name))
        .or(document.category);
    document.summary = request.summary.or(document.summary);
    document.page_count = request.page_count.or(document.page_count);
    if let Some(fields) = fields {
        document.fields = fields;
    }
    let identifier = document.identifier.clone();
    archive.put_document(document);
    if let Some(bytes) = original {
        archive.put_original(&identifier, &bytes);
    }
    if let Some(bytes) = thumbnail {
        archive.put_thumbnail(&identifier, &bytes);
    }
    if let Some(text) = request.text {
        archive.put_text(&identifier, &text);
    }
    Ok(identifier)
}

pub fn seed_document_endpoint(archive: &ScriptedArchive, body: &[u8]) -> Answer {
    match seed_document(archive, body) {
        Ok(identifier) => Answer::json(200, serde_json::json!({ "document_id": identifier.as_str() })),
        Err(answer) => answer,
    }
}

pub fn seed_corpus(archive: &ScriptedArchive, count: usize) {
    let sender = SenderIdentifier::parse("20000000-0000-4000-8000-000000000001").unwrap();
    archive.put_sender(SenderRecord {
        identifier: sender.clone(),
        name: "Stadtwerke Talbrück GmbH".to_owned(),
    });
    let category = CategoryIdentifier::parse("30000000-0000-4000-8000-000000000001").unwrap();
    archive.put_category(CategoryRecord {
        identifier: category.clone(),
        name: "Invoice".to_owned(),
        expected_fields: vec!["amount".to_owned(), "currency".to_owned()],
    });
    let pdf_bytes = b"%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer << /Size 4 /Root 1 0 R >>\nstartxref\n190\n%%EOF\n";
    let digest = content_digest_of(pdf_bytes);
    for index in 1..=count {
        let id = DocumentIdentifier::parse(&format!("50000000-0000-4000-8000-{index:012x}")).unwrap();
        let mut fields = BTreeMap::new();
        fields.insert(
            "amount".to_owned(),
            archive_replica::replica_records::ExtractedField {
                value: FieldValue::Number(72.09),
                confidence: Some(0.95),
            },
        );
        fields.insert(
            "currency".to_owned(),
            archive_replica::replica_records::ExtractedField {
                value: FieldValue::Text("EUR".to_owned()),
                confidence: Some(0.99),
            },
        );
        archive.put_document(DocumentRecord {
            identifier: id.clone(),
            condition: DocumentCondition::Archived,
            title: Some(format!("Haftpflichtversicherung Rechnung {index}")),
            document_date: CalendarDate::parse("2026-09-22"),
            sender: Some(sender.clone()),
            category: Some(category.clone()),
            person: PersonAssignment::Household,
            summary: Some(format!("Annual electricity statement {index}.")),
            media_type: "application/pdf".to_owned(),
            byte_size: u64::try_from(pdf_bytes.len()).unwrap_or(0),
            page_count: Some(1),
            original: Some(digest),
            arrived_at: Timestamp(1_790_000_000_000 + i64::try_from(index).unwrap_or(0) * 1_000),
            tags: BTreeSet::new(),
            fields,
        });
        archive.put_original(&id, pdf_bytes);
        archive.put_text(&id, &format!("Rechnung Nummer {index} für Haftpflichtversicherung."));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ArchiveRequest, Body, DOCUMENT_PATH_PREFIX, SEED_DOCUMENT_PATH, ScriptedServer, route_request};
    use archive_replica::{ArchiveReader, PageAnswer};
    use scripted_archive::UploadOutcome;
    use serde_json::json;

    const AUTHORIZATION: &str = "Bearer scripted-seeding-token";

    fn seeding_server() -> ScriptedServer {
        ScriptedServer {
            archive: ScriptedArchive::new(),
            accepted_authorization: AUTHORIZATION.to_owned(),
            legacy_reception: false,
        }
    }

    fn request(server: &mut ScriptedServer, method: tiny_http::Method, url: &str, body: Vec<u8>) -> Answer {
        let headers = [
            ("Authorization".to_owned(), AUTHORIZATION.to_owned()),
            ("Content-Type".to_owned(), "application/json".to_owned()),
        ];
        let request = ArchiveRequest {
            method: &method,
            url,
            headers: &headers,
        };
        route_request(server, &request, body)
    }

    /// The status and the JSON body of `POST /scripted/documents`.
    fn seed(server: &mut ScriptedServer, body: serde_json::Value) -> (u16, serde_json::Value) {
        let answer = request(
            server,
            tiny_http::Method::Post,
            SEED_DOCUMENT_PATH,
            body.to_string().into_bytes(),
        );
        let Body::Text(text) = answer.body else {
            panic!("the seed route answers JSON");
        };
        (answer.status, serde_json::from_str(&text).unwrap())
    }

    fn uploaded(archive: &ScriptedArchive, bytes: &[u8]) -> (DocumentIdentifier, String) {
        let UploadOutcome::Accepted(document) = archive.upload(bytes) else {
            panic!("new bytes become a document");
        };
        (document, content_digest_of(bytes).hexadecimal())
    }

    #[test]
    fn an_uploaded_scan_moves_through_ingestion_to_its_filed_title() {
        let mut server = seeding_server();
        let scan = b"%PDF-1.7 a scanned letter";
        let (document, content) = uploaded(&server.archive, scan);
        let PageAnswer::Page(uploaded_page) = server.archive.read_changes(None).unwrap() else {
            panic!("expected a page");
        };
        assert_eq!(uploaded_page.documents[0].condition.status_name(), "processing");

        let answer = seed(
            &mut server,
            json!({ "content_sha256": content, "status": "recognizing_text" }),
        );
        assert_eq!(answer, (200, json!({ "document_id": document.as_str() })));
        let PageAnswer::Page(following) = server.archive.read_changes(Some(&uploaded_page.cursor)).unwrap() else {
            panic!("expected a page");
        };
        let stages: Vec<(&str, &str)> = following
            .documents
            .iter()
            .map(|record| (record.identifier.as_str(), record.condition.status_name()))
            .collect();
        assert_eq!(stages, vec![(document.as_str(), "recognizing_text")]);

        let classifying = json!({
            "content_sha256": content,
            "status": "classifying",
            "title": "Water bill",
            "sender_name": "Stadtwerke",
            "page_count": 2,
        });
        assert_eq!(seed(&mut server, classifying).0, 200);
        assert_eq!(
            seed(
                &mut server,
                json!({ "identifier": document.as_str(), "status": "archived" })
            )
            .0,
            200
        );
        let filed = server.archive.document(&document).unwrap();
        assert_eq!(filed.condition, DocumentCondition::Archived);
        assert_eq!(filed.title.as_deref(), Some("Water bill"));
        assert_eq!(filed.page_count, Some(2));
        assert_eq!(filed.media_type, "application/pdf");
        assert_eq!(filed.original, Some(content_digest_of(scan)));
        assert_eq!(server.archive.records().senders[0].name, "Stadtwerke");
    }

    #[test]
    fn a_token_restricted_to_a_category_reads_only_its_documents() {
        let mut server = seeding_server();
        restrict_to_category(&server.archive, "Invoice");
        for (identifier, category) in [
            ("60000000-0000-4000-8000-000000000001", "Invoice"),
            ("60000000-0000-4000-8000-000000000002", "Receipt"),
        ] {
            let document = json!({ "identifier": identifier, "title": category, "category_name": category });
            assert_eq!(seed(&mut server, document).0, 200);
        }
        assert!(server.archive.read_authorization().unwrap().restricted);
        let titles: Vec<Option<String>> = server
            .archive
            .admitted_records()
            .documents
            .into_iter()
            .map(|document| document.title)
            .collect();
        assert_eq!(titles, vec![Some("Invoice".to_owned())]);
    }

    #[test]
    fn a_failed_status_records_its_reason() {
        let mut server = seeding_server();
        let (document, content) = uploaded(&server.archive, b"%PDF-1.7 a blurred photograph");
        let failed = json!({ "content_sha256": content, "status": "failed", "failure_reason": "unreadable_page" });
        assert_eq!(seed(&mut server, failed).0, 200);
        assert_eq!(
            server.archive.document(&document).unwrap().condition,
            DocumentCondition::Failed(FailureReason::UnreadablePage)
        );
    }

    #[test]
    fn a_new_document_is_archived_with_typed_fields() {
        let mut server = seeding_server();
        let identifier = "60000000-0000-4000-8000-000000000001";
        let fields = json!({
            "invoice_number": "2026-10-20",
            "due_date": { "date": "2026-10-20" },
            "amount": 72.09,
        });
        assert_eq!(
            seed(&mut server, json!({ "identifier": identifier, "fields": fields })).0,
            200
        );
        let document = server
            .archive
            .document(&DocumentIdentifier::parse(identifier).unwrap())
            .unwrap();
        assert_eq!(document.condition, DocumentCondition::Archived);
        assert_eq!(document.page_count, None);
        let values: Vec<(&str, &FieldValue)> = document
            .fields
            .iter()
            .map(|(key, field)| (key.as_str(), &field.value))
            .collect();
        assert_eq!(
            values,
            vec![
                ("amount", &FieldValue::Number(72.09)),
                (
                    "due_date",
                    &FieldValue::Date(CalendarDate::parse("2026-10-20").unwrap())
                ),
                ("invoice_number", &FieldValue::Text("2026-10-20".to_owned())),
            ]
        );
    }

    #[test]
    fn a_seed_request_with_loose_input_is_refused_and_writes_nothing() {
        let mut server = seeding_server();
        let (document, content) = uploaded(&server.archive, b"%PDF-1.7 an uploaded scan");
        let absent_content = "0".repeat(64);
        let refusals = [
            (
                json!({ "identifier": document.as_str(), "content_sha256": content }),
                400,
                "Name the document by exactly one of identifier and content_sha256",
            ),
            (
                json!({ "title": "Water bill" }),
                400,
                "Name the document by exactly one of identifier and content_sha256",
            ),
            (
                json!({ "content_sha256": absent_content }),
                404,
                "No document holds this content",
            ),
            (
                json!({ "content_sha256": content.to_uppercase() }),
                400,
                "content_sha256 is not 64 lowercase hexadecimal digits",
            ),
            (
                json!({ "identifier": document.as_str(), "status": "filed" }),
                400,
                "Unknown status filed",
            ),
            (
                json!({ "identifier": document.as_str(), "status": "failed" }),
                400,
                "The status failed takes a failure_reason",
            ),
            (
                json!({ "identifier": document.as_str(), "status": "failed", "failure_reason": "smudged_page" }),
                400,
                "Unknown failure_reason smudged_page",
            ),
            (
                json!({ "identifier": document.as_str(), "status": "archived", "failure_reason": "unreadable_page" }),
                400,
                "Only the status failed takes a failure_reason",
            ),
            (
                json!({ "identifier": "60000000-0000-4000-8000-000000000002", "original_utf8": "%PDF", "original_file": "/a.pdf" }),
                400,
                "Give the original as original_utf8 or original_file, not both",
            ),
            (
                json!({ "identifier": document.as_str(), "original_utf8": "%PDF-1.7 another scan" }),
                400,
                "A document keeps the original it was created with",
            ),
            (
                json!({ "identifier": document.as_str(), "document_date": "2026-02-30" }),
                400,
                "document_date is not a day as YYYY-MM-DD",
            ),
            (
                json!({ "identifier": document.as_str(), "fields": { "amount": 72.09, "paid": true } }),
                400,
                "The field paid is not a string, a number, or {\"date\": \"YYYY-MM-DD\"}",
            ),
            (
                json!({ "identifier": document.as_str(), "fields": { "due_date": null } }),
                400,
                "The field due_date is not a string, a number, or {\"date\": \"YYYY-MM-DD\"}",
            ),
        ];
        for (body, status, detail) in refusals {
            let (answered_status, answer) = seed(&mut server, body.clone());
            assert_eq!(
                (answered_status, answer["detail"].as_str()),
                (status, Some(detail)),
                "{body}"
            );
        }
        let (status, answer) = seed(
            &mut server,
            json!({ "identifier": document.as_str(), "titel": "Water bill" }),
        );
        assert_eq!(status, 400);
        assert!(
            answer["detail"]
                .as_str()
                .unwrap()
                .starts_with("Invalid request for /scripted/documents: unknown field `titel`")
        );
        let unchanged = server.archive.document(&document).unwrap();
        assert_eq!(unchanged.condition.status_name(), "processing");
        assert_eq!(unchanged.fields.len(), 0);
        assert_eq!(server.archive.records().documents.len(), 1);
    }

    #[test]
    fn a_thumbnail_is_served_with_the_media_type_of_its_bytes() {
        let mut server = seeding_server();
        let directory = tempfile::tempdir().unwrap();
        let picture = directory.path().join("first_page.jpg");
        std::fs::write(&picture, [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).unwrap();
        let portable_document = directory.path().join("first_page.pdf");
        std::fs::write(&portable_document, b"%PDF-1.7 a page").unwrap();
        let identifier = "60000000-0000-4000-8000-000000000003";

        let refused = seed(
            &mut server,
            json!({ "identifier": identifier, "thumbnail_file": portable_document }),
        );
        assert_eq!(
            refused,
            (
                400,
                json!({
                    "type": "about:blank",
                    "title": "Problem",
                    "status": 400,
                    "detail": "thumbnail_file is not a JPEG, PNG, or WebP picture",
                })
            )
        );
        assert_eq!(
            seed(
                &mut server,
                json!({ "identifier": identifier, "thumbnail_file": picture })
            )
            .0,
            200
        );
        let thumbnail = request(
            &mut server,
            tiny_http::Method::Get,
            &format!("{DOCUMENT_PATH_PREFIX}{identifier}/thumbnail"),
            Vec::new(),
        );
        assert_eq!(
            (thumbnail.status, thumbnail.content_type.as_deref()),
            (200, Some("image/jpeg"))
        );
    }
}
