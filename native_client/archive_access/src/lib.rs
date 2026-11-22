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

pub use archive_address::{ArchiveAddress, ArchiveAddressRefusal};
pub use archive_authorization::{ArchiveAuthorization, PermissionLevel, read_authorization};
pub use archive_exchange::{ArchiveCondition, ArchiveExchange, ArchiveResponse};
pub use archive_identifiers::{ContentDigest, DocumentIdentifier, is_record_identifier};
pub use archive_token::ArchiveToken;
pub use clock::{Clock, ManualClock, SystemClock, Timestamp};
#[cfg(target_os = "macos")]
pub use credential_storage::KeychainCredentialStore;
pub use credential_storage::{
    CredentialStorageFailure, CredentialStore, FixedCredentialStore, RememberingCredentialStore,
    TOKEN_ENVIRONMENT_VARIABLE,
};
