//! The scripted archive over HTTP, answering every route of `notes/client_protocol.md` from one
//! `ScriptedArchive` model so that an uploaded file appears in the journal and in a library that
//! follows it.
//!
//! Prints `listening http://127.0.0.1:<port>` and runs until standard input closes.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};

use archive_access::{ArchiveCondition, ContentDigest, DocumentIdentifier, INGEST_PATH, PermissionLevel, Timestamp};
use archive_replica::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, ExtractedField, FieldValue,
    JournalCursor, JournalPage, PersonAssignment, RemovedRecord, SenderIdentifier, SenderRecord, TagIdentifier,
};
use archive_replica::{ArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
use collection_core::ArchiveClient;
use collection_core::candidate_classification::{ContentKind, MAXIMUM_CONTENT_BYTES, identify_content_kind};
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
            content_type: Some(
                identify_content_kind(&bytes)
                    .map_or("application/octet-stream", |kind| kind.media_type())
                    .to_owned(),
            ),
            headers: Vec::new(),
            body: Body::Bytes(bytes),
        },
        Ok(ThumbnailAnswer::Absent) => Answer::problem(404, "No thumbnail exists for this document"),
        Err(archive_access::DownloadFailure::Archive(condition)) => Answer::from_condition(condition),
        Err(archive_access::DownloadFailure::Destination(error)) => Answer::problem(500, &error.to_string()),
    }
}

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

const STATUSES_WITHOUT_REASON: [&str; 6] = [
    "awaiting_rendering",
    "processing",
    "extracting",
    "recognizing_text",
    "classifying",
    "archived",
];
const FAILURE_REASONS: [&str; 4] = [
    "unreadable_file",
    "page_limit_exceeded",
    "unreadable_page",
    "processing_error",
];

fn seed_condition(status: Option<&str>, failure_reason: Option<&str>) -> Result<Option<DocumentCondition>, String> {
    match (status, failure_reason) {
        (None, None) => Ok(None),
        (Some("failed"), Some(reason)) if FAILURE_REASONS.contains(&reason) => {
            Ok(DocumentCondition::parse("failed", Some(reason)))
        }
        (Some("failed"), _) => Err(format!(
            "The status failed takes a failure_reason of {}",
            FAILURE_REASONS.join(", ")
        )),
        (Some(status), None) if STATUSES_WITHOUT_REASON.contains(&status) => Ok(DocumentCondition::parse(status, None)),
        (Some(status), None) => Err(format!("Unknown status {status}")),
        (_, Some(_)) => Err("Only the status failed takes a failure_reason".to_owned()),
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
    let identifier = CategoryIdentifier::parse(&deterministic_identifier(3, &name)).unwrap_or_else(|| unreachable!());
    archive.put_category(CategoryRecord {
        identifier: identifier.clone(),
        name,
        expected_fields: vec!["amount".to_owned(), "currency".to_owned()],
    });
    identifier
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

fn seed_document_endpoint(archive: &ScriptedArchive, body: &[u8]) -> Answer {
    match seed_document(archive, body) {
        Ok(identifier) => Answer::json(200, serde_json::json!({ "document_id": identifier.as_str() })),
        Err(answer) => answer,
    }
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
    /// Bytes per second at which the body of an upload to the ingest route is read, so a screen
    /// examination can show an upload under way.
    ingest_pace: Option<usize>,
}

/// Reads a body whole, or at `pace` bytes per second, a tenth of a second at a time.
fn read_body(reader: &mut dyn Read, pace: Option<usize>, body: &mut Vec<u8>) -> std::io::Result<()> {
    let Some(pace) = pace else {
        return reader.read_to_end(body).map(|_| ());
    };
    let mut chunk = vec![0; (pace / 10).max(1)];
    loop {
        let read = reader.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        body.extend_from_slice(&chunk[..read]);
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

fn parse_options() -> Options {
    let mut args = std::env::args().skip(1);
    let mut options = Options {
        token: DEFAULT_TOKEN.to_owned(),
        permission: PermissionLevel::Read,
        seed: 0,
        ingest_pace: None,
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
        let pace = options.ingest_pace.filter(|_| request.url() == INGEST_PATH);
        let answer = if read_body(request.as_reader(), pace, &mut body).is_err() {
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

#[cfg(test)]
mod tests {
    use super::*;
    use archive_replica::replica_records::FailureReason;
    use serde_json::json;

    fn request(archive: &ScriptedArchive, method: tiny_http::Method, url: &str, body: Vec<u8>) -> Answer {
        let headers = RequestHeaders {
            if_none_match: None,
            content_type: Some("application/json"),
        };
        route_request(archive, true, &method, url, headers, body)
    }

    /// The status and the JSON body of `POST /scripted/documents`.
    fn seed(archive: &ScriptedArchive, body: serde_json::Value) -> (u16, serde_json::Value) {
        let answer = request(
            archive,
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
        let archive = ScriptedArchive::new();
        let scan = b"%PDF-1.7 a scanned letter";
        let (document, content) = uploaded(&archive, scan);
        let PageAnswer::Page(uploaded_page) = archive.read_changes(None).unwrap() else {
            panic!("expected a page");
        };
        assert_eq!(uploaded_page.documents[0].condition.status_name(), "processing");

        let answer = seed(
            &archive,
            json!({ "content_sha256": content, "status": "recognizing_text" }),
        );
        assert_eq!(answer, (200, json!({ "document_id": document.as_str() })));
        let PageAnswer::Page(following) = archive.read_changes(Some(&uploaded_page.cursor)).unwrap() else {
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
        assert_eq!(seed(&archive, classifying).0, 200);
        assert_eq!(
            seed(
                &archive,
                json!({ "identifier": document.as_str(), "status": "archived" })
            )
            .0,
            200
        );
        let filed = archive.document(&document).unwrap();
        assert_eq!(filed.condition, DocumentCondition::Archived);
        assert_eq!(filed.title.as_deref(), Some("Water bill"));
        assert_eq!(filed.page_count, Some(2));
        assert_eq!(filed.media_type, "application/pdf");
        assert_eq!(filed.original, Some(content_digest_of(scan)));
        assert_eq!(archive.records().senders[0].name, "Stadtwerke");
    }

    #[test]
    fn a_failed_status_records_its_reason() {
        let archive = ScriptedArchive::new();
        let (document, content) = uploaded(&archive, b"%PDF-1.7 a blurred photograph");
        let failed = json!({ "content_sha256": content, "status": "failed", "failure_reason": "unreadable_page" });
        assert_eq!(seed(&archive, failed).0, 200);
        assert_eq!(
            archive.document(&document).unwrap().condition,
            DocumentCondition::Failed(FailureReason::UnreadablePage)
        );
    }

    #[test]
    fn a_new_document_is_archived_with_typed_fields() {
        let archive = ScriptedArchive::new();
        let identifier = "60000000-0000-4000-8000-000000000001";
        let fields = json!({
            "invoice_number": "2026-10-20",
            "due_date": { "date": "2026-10-20" },
            "amount": 72.09,
        });
        assert_eq!(
            seed(&archive, json!({ "identifier": identifier, "fields": fields })).0,
            200
        );
        let document = archive
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
        let archive = ScriptedArchive::new();
        let (document, content) = uploaded(&archive, b"%PDF-1.7 an uploaded scan");
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
                "The status failed takes a failure_reason of unreadable_file, page_limit_exceeded, unreadable_page, \
                 processing_error",
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
            let (answered_status, answer) = seed(&archive, body.clone());
            assert_eq!(
                (answered_status, answer["detail"].as_str()),
                (status, Some(detail)),
                "{body}"
            );
        }
        let (status, answer) = seed(
            &archive,
            json!({ "identifier": document.as_str(), "titel": "Water bill" }),
        );
        assert_eq!(status, 400);
        assert!(
            answer["detail"]
                .as_str()
                .unwrap()
                .starts_with("Invalid request for /scripted/documents: unknown field `titel`")
        );
        let unchanged = archive.document(&document).unwrap();
        assert_eq!(unchanged.condition.status_name(), "processing");
        assert_eq!(unchanged.fields.len(), 0);
        assert_eq!(archive.records().documents.len(), 1);
    }

    #[test]
    fn a_thumbnail_is_served_with_the_media_type_of_its_bytes() {
        let archive = ScriptedArchive::new();
        let directory = tempfile::tempdir().unwrap();
        let picture = directory.path().join("first_page.jpg");
        std::fs::write(&picture, [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).unwrap();
        let portable_document = directory.path().join("first_page.pdf");
        std::fs::write(&portable_document, b"%PDF-1.7 a page").unwrap();
        let identifier = "60000000-0000-4000-8000-000000000003";

        let refused = seed(
            &archive,
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
            seed(&archive, json!({ "identifier": identifier, "thumbnail_file": picture })).0,
            200
        );
        let thumbnail = request(
            &archive,
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
