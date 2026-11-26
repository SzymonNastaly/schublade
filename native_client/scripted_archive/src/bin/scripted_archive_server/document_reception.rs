//! `PUT /api/v1/submitted_documents/{sha256}` and `PUT /api/v1/collected_documents/{sha256}`,
//! answered in the order of `receiveDocument` in `src/ingestion/document_reception.ts`.

use archive_access::{
    ContentDigest, MAXIMUM_DOCUMENT_BYTES, MAXIMUM_TEXT_BYTES, MAXIMUM_THUMBNAIL_BYTES, SubmissionRoute,
};
use archive_replica::ArchiveReader;
use collection_core::ArchiveClient;
use collection_core::candidate_classification::identify_content_kind;
use collection_core::content_synchronization::LookupAnswer;
use collection_core::domain_types::DocumentStatus;
use scripted_archive::{ReceivedRepresentations, ScriptedArchive};
use sha2::{Digest, Sha256};

use crate::client_protocol::document_status_answer;
use crate::{Answer, ArchiveRequest};

/// The route and digest of a reception path, or `None` for every other path.
pub fn reception_route(path: &str) -> Option<(SubmissionRoute, ContentDigest)> {
    let digest = ContentDigest::parse_hexadecimal(path.rsplit_once('/')?.1)?;
    [SubmissionRoute::SubmittedDocuments, SubmissionRoute::CollectedDocuments]
        .into_iter()
        .find(|route| route.path(&digest) == path)
        .map(|route| (route, digest))
}

struct ReceptionLayout {
    text_bytes: usize,
    thumbnail_bytes: usize,
    page_count: Option<u32>,
}

/// The layout of a body from its headers alone, or the refusal `parseReceptionHeaders` answers.
fn read_layout(request: &ArchiveRequest<'_>, query: Option<&str>) -> Result<ReceptionLayout, Answer> {
    if query.is_some() {
        return Err(Answer::problem(400, "This route defines no query parameter"));
    }
    let decimal = |name: &str| -> Result<Option<usize>, ()> {
        match request.header(name) {
            None => Ok(None),
            Some(value) if (1..=10).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_digit()) => {
                value.parse().map(Some).map_err(|_| ())
            }
            Some(_) => Err(()),
        }
    };
    let (Ok(text_bytes), Ok(thumbnail_bytes), Ok(page_count)) = (
        decimal("Schublade-Text-Byte-Count"),
        decimal("Schublade-Thumbnail-Byte-Count"),
        decimal("Schublade-Page-Count"),
    ) else {
        return Err(Answer::problem(
            400,
            "The byte counts and the page count must be decimal numbers",
        ));
    };
    let page_count = match page_count.map(u32::try_from) {
        None => None,
        Some(Ok(count)) if count > 0 => Some(count),
        Some(_) => return Err(Answer::problem(400, "The page count must be at least 1")),
    };
    let content_length = match decimal("Content-Length") {
        Ok(Some(length)) => length,
        Ok(None) => return Err(Answer::problem(411, "Send the body with a Content-Length")),
        Err(()) => return Err(Answer::problem(400, "Content-Length must be a decimal number")),
    };
    let (text_bytes, thumbnail_bytes) = (text_bytes.unwrap_or(0), thumbnail_bytes.unwrap_or(0));
    let original_bytes = content_length.saturating_sub(text_bytes + thumbnail_bytes);
    if original_bytes == 0 {
        return Err(Answer::problem(
            400,
            "The body holds no byte of the original after the text and the thumbnail",
        ));
    }
    if text_bytes > MAXIMUM_TEXT_BYTES {
        return Err(Answer::problem(413, "The text is larger than 2 MB"));
    }
    if thumbnail_bytes > MAXIMUM_THUMBNAIL_BYTES {
        return Err(Answer::problem(413, "The thumbnail is larger than 200 KB"));
    }
    if u64::try_from(original_bytes).unwrap_or(u64::MAX) > MAXIMUM_DOCUMENT_BYTES {
        return Err(Answer::problem(413, "The file is larger than 25 MB"));
    }
    Ok(ReceptionLayout {
        text_bytes,
        thumbnail_bytes,
        page_count,
    })
}

/// One document to the reception, behind a token the router accepted.
pub fn receive_document(
    archive: &ScriptedArchive,
    route: SubmissionRoute,
    digest: ContentDigest,
    request: &ArchiveRequest<'_>,
    query: Option<&str>,
    body: &[u8],
) -> Answer {
    if archive
        .read_authorization()
        .is_ok_and(|authorization| authorization.restricted)
    {
        let adding = match route {
            SubmissionRoute::SubmittedDocuments => "Adding documents",
            SubmissionRoute::CollectedDocuments => "A collector",
        };
        return Answer::problem(
            403,
            &format!("This API token is restricted to a part of the archive. {adding} needs an unrestricted token."),
        );
    }
    let standing = archive.content_standing(&digest);
    if route == SubmissionRoute::CollectedDocuments && standing == LookupAnswer::Deleted {
        return Answer::problem(
            409,
            "The owner deleted this document. Only an upload through the browser brings it back.",
        );
    }
    let layout = match read_layout(request, query) {
        Ok(layout) => layout,
        Err(refusal) => return refusal,
    };
    if let LookupAnswer::Present(document) = standing {
        let status = archive
            .read_document_status(&document)
            .ok()
            .flatten()
            .unwrap_or(DocumentStatus::Processing);
        return document_status_answer(200, &document, &status);
    }
    let Some((text, rest)) = body.split_at_checked(layout.text_bytes) else {
        return Answer::problem(400, "The body is shorter than its Content-Length");
    };
    let Some((thumbnail, original)) = rest.split_at_checked(layout.thumbnail_bytes) else {
        return Answer::problem(400, "The body is shorter than its Content-Length");
    };
    if !thumbnail.is_empty() && !thumbnail.starts_with(&[0xff, 0xd8, 0xff]) {
        return Answer::problem(415, "The thumbnail must be a JPEG");
    }
    if identify_content_kind(original).is_none() {
        return Answer::problem(415, "Only PDF, JPEG, PNG, and WebP files can be archived.");
    }
    if ContentDigest::from_bytes(Sha256::digest(original).into()) != digest {
        return Answer::problem(422, "The original does not have the SHA-256 in the path");
    }
    let document = archive.receive(
        original,
        ReceivedRepresentations {
            text: (!text.is_empty()).then(|| String::from_utf8_lossy(text).into_owned()),
            thumbnail: (!thumbnail.is_empty()).then(|| thumbnail.to_vec()),
            page_count: layout.page_count,
        },
    );
    document_status_answer(202, &document, &DocumentStatus::Processing)
}
