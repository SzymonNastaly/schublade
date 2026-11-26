//! The routes of `notes/client_protocol.md` and `POST /api/documents/ingest`, each answered from the
//! `ScriptedArchive` as the Worker answers it.

use archive_access::{ArchiveCondition, ContentDigest, DocumentIdentifier, PermissionLevel, Timestamp};
use archive_replica::replica_records::{
    CategoryIdentifier, DocumentRecord, FieldValue, JournalCursor, JournalPage, PersonAssignment, RemovedRecord,
    SenderIdentifier, TagIdentifier,
};
use archive_replica::{ArchiveReader, OriginalAnswer, PageAnswer, ThumbnailAnswer};
use collection_core::ArchiveClient;
use collection_core::candidate_classification::identify_content_kind;
use collection_core::content_synchronization::LookupAnswer;
use collection_core::domain_types::DocumentStatus;
use scripted_archive::{ScriptedArchive, UploadOutcome};

use crate::{Answer, Body};

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

pub fn serve_authorization(archive: &ScriptedArchive, query: Option<&str>) -> Answer {
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

pub fn serve_changes(archive: &ScriptedArchive, query: Option<&str>) -> Answer {
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

pub fn document_status_answer(status: u16, document: &DocumentIdentifier, document_status: &DocumentStatus) -> Answer {
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

pub fn look_up(archive: &ScriptedArchive, body: &[u8]) -> Answer {
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

pub fn serve_document_status(archive: &ScriptedArchive, identifier: &str) -> Answer {
    let Some(document) = DocumentIdentifier::parse(identifier) else {
        return Answer::problem(404, "No document has the identifier");
    };
    match archive.read_document_status(&document) {
        Ok(Some(status)) => document_status_answer(200, &document, &status),
        Ok(None) => Answer::problem(404, "No document has the identifier"),
        Err(condition) => Answer::from_condition(condition),
    }
}

pub fn serve_document_text(archive: &ScriptedArchive, identifier: &str, query: Option<&str>) -> Answer {
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

pub fn serve_document_original(
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

pub fn serve_document_thumbnail(archive: &ScriptedArchive, identifier: &str, query: Option<&str>) -> Answer {
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
pub fn ingest(archive: &ScriptedArchive, content_type: Option<&str>, body: &[u8]) -> Answer {
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
