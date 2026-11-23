//! The scripted archive over HTTP, answering every route of `notes/client_protocol.md` from one
//! `ScriptedArchive` model so that an uploaded file appears in the journal and in a library that
//! follows it.
//!
//! Prints `listening http://127.0.0.1:<port>` and runs until standard input closes.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};

use archive_access::{ArchiveCondition, ContentDigest, DocumentIdentifier, INGEST_PATH, PermissionLevel, Timestamp};
use archive_replica::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, FieldValue, JournalCursor,
    JournalPage, PersonAssignment, RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier,
};
use archive_replica::{ArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
use collection_core::ArchiveClient;
use collection_core::candidate_classification::{MAXIMUM_CONTENT_BYTES, identify_content_kind};
use collection_core::content_synchronization::{
    ArchiveStanding, ContentRecord, LookupAnswer, SubmissionFailures, SubmissionOutcome, authorize_submission,
};
use collection_core::domain_types::{DocumentStatus, TimingPolicy};
use collection_core::file_system_observation::{VerifiedContent, content_digest_of};
use scripted_archive::{ScriptedArchive, UploadOutcome};
use sha2::{Digest, Sha256};

const DEFAULT_TOKEN: &str = "scripted-ingest-token";
const AUTHORIZATION_PATH: &str = "/api/v1/authorization";
const CHANGES_PATH: &str = "/api/v1/changes";
const LOOKUP_PATH: &str = "/api/v1/contents/lookup";
const CONTENT_PATH_PREFIX: &str = "/api/v1/contents/";
const DOCUMENT_PATH_PREFIX: &str = "/api/v1/documents/";
const HELD_DIGESTS_PATH: &str = "/scripted/held";
const SEED_DOCUMENT_PATH: &str = "/scripted/documents";

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

fn format_timestamp(timestamp: Timestamp) -> String {
    let total_seconds = timestamp.0.div_euclid(1_000);
    let milliseconds = timestamp.0.rem_euclid(1_000);
    let days = total_seconds.div_euclid(86_400);
    let seconds_of_day = total_seconds.rem_euclid(86_400);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year_base = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    };
    let year = year_base + i64::from(month <= 2);
    if milliseconds == 0 {
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
    } else {
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{milliseconds:03}Z")
    }
}

fn serve_authorization(archive: &ScriptedArchive, query: Option<&str>) -> Answer {
    if query.is_some() {
        return Answer::problem(400, "This request takes no parameters");
    }
    match archive.read_authorization() {
        Ok(authorization) => Answer::json(
            200,
            serde_json::json!({
                "journal_identifier": authorization.journal_identifier,
                "token": {
                    "description": authorization.token_description,
                    "permission_level": authorization.permission_level.name(),
                    "restricted": authorization.restricted,
                    "scope_digest": authorization.scope_digest,
                }
            }),
        ),
        Err(condition) => Answer::from_condition(condition),
    }
}

fn wire_document(document: &DocumentRecord) -> serde_json::Value {
    let person = match &document.person {
        PersonAssignment::Household => serde_json::json!({ "kind": "household" }),
        PersonAssignment::Unassigned => serde_json::json!({ "kind": "unassigned" }),
        PersonAssignment::Member(member) => serde_json::json!({
            "kind": "member",
            "member_id": member.as_str(),
        }),
    };
    let fields: Vec<serde_json::Value> = document
        .fields
        .iter()
        .map(|(key, field)| {
            let (field_type, value) = match &field.value {
                FieldValue::Text(text) => ("text", serde_json::Value::String(text.clone())),
                FieldValue::Number(number) => ("number", serde_json::json!(*number)),
                FieldValue::Date(date) => ("date", serde_json::Value::String(date.iso_text())),
            };
            serde_json::json!({
                "key": key,
                "type": field_type,
                "value": value,
                "confidence": field.confidence,
            })
        })
        .collect();
    let tag_ids: Vec<&str> = document.tags.iter().map(TagIdentifier::as_str).collect();
    serde_json::json!({
        "status": document.condition.status_name(),
        "failure_reason": document.condition.failure_reason_name(),
        "title": document.title,
        "document_date": document.document_date.map(|date| date.iso_text()),
        "sender_id": document.sender.as_ref().map(SenderIdentifier::as_str),
        "category_id": document.category.as_ref().map(CategoryIdentifier::as_str),
        "person": person,
        "summary": document.summary,
        "media_type": document.media_type,
        "byte_size": document.byte_size,
        "page_count": document.page_count,
        "original_sha256": document.original.as_ref().map(ContentDigest::hexadecimal),
        "arrived_at": format_timestamp(document.arrived_at),
        "tag_ids": tag_ids,
        "fields": fields,
    })
}

fn wire_page(page: &JournalPage) -> serde_json::Value {
    let mut changes = Vec::new();
    for member in &page.members {
        changes.push(serde_json::json!({
            "record": "household_member",
            "id": member.identifier.as_str(),
            "change": "upsert",
            "household_member": { "display_name": member.display_name },
        }));
    }
    for sender in &page.senders {
        changes.push(serde_json::json!({
            "record": "sender",
            "id": sender.identifier.as_str(),
            "change": "upsert",
            "sender": { "name": sender.name },
        }));
    }
    for category in &page.categories {
        changes.push(serde_json::json!({
            "record": "category",
            "id": category.identifier.as_str(),
            "change": "upsert",
            "category": {
                "name": category.name,
                "expected_fields": category.expected_fields,
            },
        }));
    }
    for tag in &page.tags {
        changes.push(serde_json::json!({
            "record": "tag",
            "id": tag.identifier.as_str(),
            "change": "upsert",
            "tag": {
                "name": tag.name,
                "color_hex": tag.color_hex,
            },
        }));
    }
    for document in &page.documents {
        changes.push(serde_json::json!({
            "record": "document",
            "id": document.identifier.as_str(),
            "change": "upsert",
            "document": wire_document(document),
        }));
    }
    for removed in &page.removed {
        let (record, id) = match removed {
            RemovedRecord::Document(id) => ("document", id.as_str()),
            RemovedRecord::Member(id) => ("household_member", id.as_str()),
            RemovedRecord::Sender(id) => ("sender", id.as_str()),
            RemovedRecord::Category(id) => ("category", id.as_str()),
            RemovedRecord::Tag(id) => ("tag", id.as_str()),
        };
        changes.push(serde_json::json!({
            "record": record,
            "id": id,
            "change": "removal",
        }));
    }
    serde_json::json!({
        "changes": changes,
        "cursor": page.cursor.as_str(),
        "complete": page.complete,
        "remaining": page.remaining_entries,
    })
}

fn serve_changes(archive: &ScriptedArchive, query: Option<&str>) -> Answer {
    let after = match query {
        None => None,
        Some(query) => match query.strip_prefix("after=") {
            Some(cursor) if !cursor.contains('&') => match JournalCursor::parse(cursor) {
                Some(cursor) => Some(cursor),
                None => {
                    return Answer::problem(
                        400,
                        "The cursor is not one this archive answered. Send the cursor of the last page as it came.",
                    );
                }
            },
            _ => return Answer::problem(400, "The journal takes only the parameter after"),
        },
    };
    match archive.read_changes(after.as_ref()) {
        Ok(PageAnswer::Page(page)) => Answer::json(200, wire_page(&page)),
        Ok(PageAnswer::JournalReplaced) => Answer::problem(
            410,
            "This archive holds no such position. Read the journal from the start.",
        ),
        Err(condition) => Answer::from_condition(condition),
    }
}

fn document_status_answer(status: u16, document: &DocumentIdentifier, document_status: &DocumentStatus) -> Answer {
    let failure_reason = match document_status {
        DocumentStatus::Failed { failure_reason } => failure_reason.clone(),
        _ => None,
    };
    Answer::json(
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
        return Answer::problem(400, "Send a JSON object with the digests under sha256");
    };
    let answers = match archive.look_up(&digests) {
        Ok(answers) => answers,
        Err(condition) => return Answer::from_condition(condition),
    };
    let contents: Vec<serde_json::Value> = answers
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
    Answer::json(200, serde_json::json!({ "contents": contents }))
}

fn submit(archive: &ScriptedArchive, digest: ContentDigest, body: Vec<u8>) -> Answer {
    let content = VerifiedContent::from_bytes(body);
    if content.digest() != digest {
        return Answer::problem(422, "The body has another SHA-256");
    }
    if u64::try_from(content.bytes().len()).unwrap_or(u64::MAX) > MAXIMUM_CONTENT_BYTES {
        return Answer::problem(413, "The file is larger than 25 MB");
    }
    if identify_content_kind(content.bytes()).is_none() {
        return Answer::problem(415, "Only PDF, JPEG, PNG, and WebP files can be archived.");
    }
    let record = ContentRecord {
        digest,
        standing: ArchiveStanding::Absent {
            looked_up_at: Timestamp(0),
            failures: SubmissionFailures::default(),
        },
    };
    let authorization = authorize_submission(&record, Timestamp(0), &TimingPolicy::default())
        .unwrap_or_else(|_| unreachable!("a content looked up at this moment is authorized"));
    match archive.submit(authorization, content) {
        Ok(SubmissionOutcome::Accepted { document, status }) => document_status_answer(202, &document, &status),
        Ok(SubmissionOutcome::AlreadyHeld { document, status }) => document_status_answer(200, &document, &status),
        Ok(SubmissionOutcome::Deleted) => Answer::problem(409, "The owner deleted this document."),
        Ok(SubmissionOutcome::TooLarge) => Answer::problem(413, "The file is larger than 25 MB"),
        Ok(SubmissionOutcome::UnacceptedKind) => {
            Answer::problem(415, "Only PDF, JPEG, PNG, and WebP files can be archived.")
        }
        Err(condition) => {
            let condition = match condition {
                collection_core::archive_connection::SubmissionCondition::Archive(condition) => condition,
                collection_core::archive_connection::SubmissionCondition::DigestDisagreement => {
                    return Answer::problem(422, "The body has another SHA-256");
                }
            };
            Answer::from_condition(condition)
        }
    }
}

fn serve_document_status(archive: &ScriptedArchive, identifier: &str) -> Answer {
    let Some(document) = DocumentIdentifier::parse(identifier) else {
        return Answer::problem(404, "No document has the identifier");
    };
    match archive.read_document_status(&document) {
        Ok(Some(status)) => document_status_answer(200, &document, &status),
        Ok(None) => Answer::problem(404, "No document has the identifier"),
        Err(condition) => Answer::from_condition(condition),
    }
}

fn serve_document_text(archive: &ScriptedArchive, identifier: &str, query: Option<&str>) -> Answer {
    if query.is_some() {
        return Answer::problem(400, "This request takes no parameters");
    }
    let Some(document) = DocumentIdentifier::parse(identifier) else {
        return Answer::problem(404, "No document has the identifier");
    };
    match archive.read_text(&document) {
        Ok(Some(text)) => Answer {
            status: 200,
            content_type: Some("text/markdown; charset=utf-8".to_owned()),
            headers: Vec::new(),
            body: Body::Text(text),
        },
        Ok(None) => Answer::problem(404, "No extracted text exists for this document"),
        Err(condition) => Answer::from_condition(condition),
    }
}

fn etag_matches(if_none_match: Option<&str>, etag: &str) -> bool {
    let Some(header) = if_none_match else {
        return false;
    };
    let quoted = format!("\"{etag}\"");
    header
        .split(',')
        .map(str::trim)
        .any(|candidate| candidate == "*" || candidate == quoted || candidate == etag)
}

fn serve_document_original(
    archive: &ScriptedArchive,
    identifier: &str,
    query: Option<&str>,
    if_none_match: Option<&str>,
) -> Answer {
    if query.is_some() {
        return Answer::problem(400, "This request takes no parameters");
    }
    if archive.permission_level() < PermissionLevel::Read {
        return Answer::from_condition(ArchiveCondition::CredentialInsufficient);
    }
    let Some(document) = DocumentIdentifier::parse(identifier) else {
        return Answer::problem(404, "No document has the identifier");
    };
    match archive.read_original_content(&document) {
        Ok(content) => {
            if let Some(digest) = content.digest {
                let hex = digest.hexadecimal();
                if etag_matches(if_none_match, &hex) {
                    return Answer {
                        status: 304,
                        content_type: None,
                        headers: vec![("ETag", format!("\"{hex}\""))],
                        body: Body::Empty,
                    };
                }
                return Answer {
                    status: 200,
                    content_type: Some(content.media_type),
                    headers: vec![("ETag", format!("\"{hex}\""))],
                    body: Body::Bytes(content.bytes),
                };
            }
            Answer {
                status: 200,
                content_type: Some(content.media_type),
                headers: Vec::new(),
                body: Body::Bytes(content.bytes),
            }
        }
        Err(OriginalAnswer::DocumentAbsent) => Answer::problem(404, "No document has the identifier"),
        Err(OriginalAnswer::NotPrinted) => Answer::problem(409, "The archive has not printed this email to a PDF yet"),
        Err(OriginalAnswer::Received) => unreachable!(),
    }
}

fn serve_document_thumbnail(archive: &ScriptedArchive, identifier: &str, query: Option<&str>) -> Answer {
    if query.is_some() {
        return Answer::problem(400, "This request takes no parameters");
    }
    let Some(document) = DocumentIdentifier::parse(identifier) else {
        return Answer::problem(404, "No document has the identifier");
    };
    let mut bytes = Vec::new();
    match archive.download_thumbnail(&document, &mut bytes) {
        Ok(ThumbnailAnswer::Received) => Answer {
            status: 200,
            content_type: Some("image/png".to_owned()),
            headers: Vec::new(),
            body: Body::Bytes(bytes),
        },
        Ok(ThumbnailAnswer::Absent) => Answer::problem(404, "No thumbnail exists for this document"),
        Err(archive_access::DownloadFailure::Archive(condition)) => Answer::from_condition(condition),
        Err(archive_access::DownloadFailure::Destination(error)) => Answer::problem(500, &error.to_string()),
    }
}

#[derive(serde::Deserialize)]
struct SeedDocumentRequest {
    identifier: String,
    title: Option<String>,
    document_date: Option<String>,
    sender_name: Option<String>,
    category_name: Option<String>,
    summary: Option<String>,
    text: Option<String>,
    original_utf8: Option<String>,
    /// A file on the server's machine whose bytes are the original, as a screen examination seeds
    /// real PDFs and pictures.
    original_file: Option<String>,
    /// A picture on the server's machine that the thumbnail route serves.
    thumbnail_file: Option<String>,
    /// Extracted fields by key: a number, a date as `2026-10-20`, or text.
    #[serde(default)]
    fields: BTreeMap<String, serde_json::Value>,
}

fn deterministic_identifier(kind: u8, name: &str) -> String {
    let hash = Sha256::digest(name.as_bytes());
    let hex: String = hash.iter().take(6).map(|byte| format!("{byte:02x}")).collect();
    format!("{kind:08x}-0000-4000-8000-{hex}")
}

fn seed_document_endpoint(archive: &ScriptedArchive, body: &[u8]) -> Answer {
    let Ok(request) = serde_json::from_slice::<SeedDocumentRequest>(body) else {
        return Answer::problem(400, "Invalid JSON for /scripted/documents");
    };
    let Some(identifier) = DocumentIdentifier::parse(&request.identifier) else {
        return Answer::problem(400, "Invalid document identifier");
    };
    let sender = request.sender_name.map(|name| {
        let sender_id = SenderIdentifier::parse(&deterministic_identifier(2, &name)).unwrap_or_else(|| unreachable!());
        archive.put_sender(SenderRecord {
            identifier: sender_id.clone(),
            name,
        });
        sender_id
    });
    let category = request.category_name.map(|name| {
        let category_id =
            CategoryIdentifier::parse(&deterministic_identifier(3, &name)).unwrap_or_else(|| unreachable!());
        archive.put_category(CategoryRecord {
            identifier: category_id.clone(),
            name,
            expected_fields: vec!["amount".to_owned(), "currency".to_owned()],
        });
        category_id
    });
    let document_date = request.document_date.as_deref().and_then(CalendarDate::parse);
    let original_bytes = match (request.original_utf8, request.original_file) {
        (_, Some(path)) => match std::fs::read(&path) {
            Ok(bytes) => Some(bytes),
            Err(error) => return Answer::problem(400, &format!("Cannot read {path}: {error}")),
        },
        (text, None) => text.map(String::into_bytes),
    };
    let byte_size = original_bytes
        .as_ref()
        .map_or(0, |bytes| u64::try_from(bytes.len()).unwrap_or(u64::MAX));
    let digest = original_bytes.as_deref().map(content_digest_of);
    let thumbnail_bytes = match request
        .thumbnail_file
        .map(|path| std::fs::read(&path).map_err(|error| (path, error)))
    {
        Some(Ok(bytes)) => Some(bytes),
        Some(Err((path, error))) => return Answer::problem(400, &format!("Cannot read {path}: {error}")),
        None => None,
    };
    let media_type = original_bytes
        .as_deref()
        .and_then(identify_content_kind)
        .map_or("application/pdf", |kind| kind.media_type())
        .to_owned();
    let fields = request
        .fields
        .into_iter()
        .filter_map(|(key, value)| {
            let value = match value {
                serde_json::Value::Number(number) => FieldValue::Number(number.as_f64()?),
                serde_json::Value::String(text) => {
                    CalendarDate::parse(&text).map_or(FieldValue::Text(text), FieldValue::Date)
                }
                _ => return None,
            };
            Some((
                key,
                archive_replica::replica_records::ExtractedField {
                    value,
                    confidence: Some(0.95),
                },
            ))
        })
        .collect();
    archive.put_document(DocumentRecord {
        identifier: identifier.clone(),
        condition: DocumentCondition::Archived,
        title: request.title,
        document_date,
        sender,
        category,
        person: PersonAssignment::Household,
        summary: request.summary,
        media_type,
        byte_size,
        page_count: Some(1),
        original: digest,
        arrived_at: Timestamp(1_790_000_000_000),
        tags: BTreeSet::new(),
        fields,
    });
    if let Some(bytes) = original_bytes {
        archive.put_original(&identifier, &bytes);
    }
    if let Some(bytes) = thumbnail_bytes {
        archive.put_thumbnail(&identifier, &bytes);
    }
    if let Some(text) = request.text {
        archive.put_text(&identifier, &text);
    }
    Answer::json(200, serde_json::json!({ "document_id": identifier.as_str() }))
}

fn seed_corpus(archive: &ScriptedArchive, count: usize) {
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

/// The files of a `multipart/form-data` body in fields named `files`, each with its file name.
/// `None` when the content type names no boundary or the body does not follow it.
fn multipart_files(content_type: Option<&str>, body: &[u8]) -> Option<Vec<(String, Vec<u8>)>> {
    let boundary = content_type?
        .strip_prefix("multipart/form-data")?
        .split(';')
        .find_map(|parameter| parameter.trim().strip_prefix("boundary="))?
        .trim_matches('"');
    let delimiter = format!("--{boundary}").into_bytes();
    let position = |haystack: &[u8], needle: &[u8]| haystack.windows(needle.len()).position(|window| window == needle);
    let mut rest = &body[position(body, &delimiter)? + delimiter.len()..];
    let mut files = Vec::new();
    while !rest.starts_with(b"--") {
        rest = rest.strip_prefix(b"\r\n")?;
        let headers_end = position(rest, b"\r\n\r\n")?;
        let headers = String::from_utf8_lossy(&rest[..headers_end]).into_owned();
        rest = &rest[headers_end + 4..];
        let content_end = position(rest, &[b"\r\n".as_slice(), &delimiter].concat())?;
        let file_name = headers
            .split("filename=\"")
            .nth(1)
            .and_then(|tail| tail.split('"').next())
            .map(str::to_owned);
        if headers.contains("name=\"files\"")
            && let Some(file_name) = file_name
        {
            files.push((file_name, rest[..content_end].to_vec()));
        }
        rest = &rest[content_end + 2 + delimiter.len()..];
    }
    Some(files)
}

/// `POST /api/documents/ingest`: each file of the body answered as `src/ingestion/document_upload.ts`
/// answers it.
fn ingest(archive: &ScriptedArchive, content_type: Option<&str>, body: &[u8]) -> Answer {
    let Some(files) = multipart_files(content_type, body) else {
        return Answer::json(
            400,
            serde_json::json!({ "error": "Send the documents as multipart form fields named files" }),
        );
    };
    let outcomes: Vec<serde_json::Value> = files
        .into_iter()
        .map(|(file_name, bytes)| match archive.upload(&bytes) {
            UploadOutcome::Accepted(document) => serde_json::json!({
                "kind": "accepted", "fileName": file_name, "documentId": document.as_str(),
            }),
            UploadOutcome::AlreadyArchived(document) => serde_json::json!({
                "kind": "already_archived", "fileName": file_name, "documentId": document.as_str(),
            }),
            UploadOutcome::Rejected(reason) => serde_json::json!({
                "kind": "rejected", "fileName": file_name, "reason": reason,
            }),
        })
        .collect();
    Answer::json(200, serde_json::json!({ "outcomes": outcomes }))
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
}

fn parse_options() -> Options {
    let mut args = std::env::args().skip(1);
    let mut options = Options {
        token: DEFAULT_TOKEN.to_owned(),
        permission: PermissionLevel::Read,
        seed: 0,
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
            other => panic!("unknown option: {other}"),
        }
    }
    options
}

fn main() {
    let options = parse_options();
    let expected_auth = format!("Bearer {}", options.token);
    let archive = ScriptedArchive::new();
    archive.set_permission_level(options.permission);
    if options.seed > 0 {
        seed_corpus(&archive, options.seed);
    }

    let server = tiny_http::Server::http("127.0.0.1:0").expect("a local port is free");
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
        let answer = if request.as_reader().read_to_end(&mut body).is_err() {
            Answer::problem(400, "The body could not be read")
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
