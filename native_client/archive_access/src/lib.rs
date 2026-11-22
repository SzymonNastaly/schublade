//! What every client of one Schublade archive shares: the archive's address, the token and where
//! it is kept, the authorized HTTP exchange, and the conditions every route answers alike. The
//! collector depends on this crate, and so will the local copy, so that neither depends on the other.

mod archive_address;
mod archive_exchange;
mod archive_token;
mod credential_storage;

pub use archive_address::{ArchiveAddress, ArchiveAddressRefusal};
pub use archive_exchange::{ArchiveCondition, ArchiveExchange, ArchiveResponse};
pub use archive_token::ArchiveToken;
#[cfg(target_os = "macos")]
pub use credential_storage::KeychainCredentialStore;
pub use credential_storage::{
    CredentialStorageFailure, CredentialStore, FixedCredentialStore, RememberingCredentialStore,
    TOKEN_ENVIRONMENT_VARIABLE,
};
