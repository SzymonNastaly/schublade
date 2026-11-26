//! What every client of one Schublade archive shares: the archive's address, the token and where
//! it is kept, what the token may do, the authorized HTTP exchange, the conditions every route
//! answers alike, the names of contents and records, and the clock. The collector and the local
//! copy both depend on this crate, so that neither depends on the other.

mod archive_address;
mod archive_authorization;
mod archive_exchange;
mod archive_identifiers;
mod archive_token;
mod clock;
mod credential_storage;
mod document_submission;
mod ingest_submission;

pub use archive_address::{ArchiveAddress, ArchiveAddressRefusal};
pub use archive_authorization::{ArchiveAuthorization, PermissionLevel, UNRESTRICTED_SCOPE_DIGEST, read_authorization};
pub use archive_exchange::{ArchiveCondition, ArchiveDownload, ArchiveExchange, ArchiveResponse, DownloadFailure};
pub use archive_identifiers::{ContentDigest, DocumentIdentifier, is_record_identifier};
pub use archive_token::ArchiveToken;
pub use clock::{Clock, ManualClock, SystemClock, Timestamp};
#[cfg(target_os = "macos")]
pub use credential_storage::KeychainCredentialStore;
#[cfg(target_os = "ios")]
pub use credential_storage::SharedKeychainCredentialStore;
pub use credential_storage::{
    CredentialStorageFailure, CredentialStore, FixedCredentialStore, RememberingCredentialStore,
    TOKEN_ENVIRONMENT_VARIABLE,
};
pub use document_submission::{
    DerivedRepresentations, DocumentReception, MAXIMUM_DOCUMENT_BYTES, MAXIMUM_TEXT_BYTES, MAXIMUM_THUMBNAIL_BYTES,
    PreparedSubmission, SubmissionAnswer, SubmissionPreparationFailure, SubmissionRoute, compose_document_text,
    is_readable_text_layer, prepare_submission, read_document_reception, read_submission_answer, send_document,
};
pub use ingest_submission::{
    INGEST_PATH, PreparedIngestSubmission, SubmissionMediaType, prepare_ingest_submission,
    read_ingest_submission_answer,
};
