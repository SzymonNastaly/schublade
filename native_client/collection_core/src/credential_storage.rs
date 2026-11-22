//! Where the ingest token lives, keyed by the archive origin so a lost database leaves it
//! findable. The database keeps only the token's fingerprint.

use std::sync::Mutex;

use crate::archive_client::{ArchiveAddress, IngestToken};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CredentialStorageFailure {
    pub detail: String,
}

pub trait CredentialStore: Send + Sync {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure>;
    fn write(&self, address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure>;
}

/// A token given at start, from `SCHUBLADE_INGEST_TOKEN` or from a test. `write` keeps the token
/// in memory for the rest of the process.
pub struct FixedCredentialStore {
    token: Mutex<Option<String>>,
}

pub const TOKEN_ENVIRONMENT_VARIABLE: &str = "SCHUBLADE_INGEST_TOKEN";

impl FixedCredentialStore {
    pub fn new(token: Option<String>) -> FixedCredentialStore {
        FixedCredentialStore {
            token: Mutex::new(
                token
                    .map(|token| token.trim().to_owned())
                    .filter(|token| !token.is_empty()),
            ),
        }
    }

    pub fn from_environment() -> FixedCredentialStore {
        FixedCredentialStore::new(std::env::var(TOKEN_ENVIRONMENT_VARIABLE).ok())
    }
}

impl CredentialStore for FixedCredentialStore {
    fn read(&self, _address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure> {
        Ok(self
            .token
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
            .map(IngestToken::new))
    }

    fn write(&self, _address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure> {
        *self.token.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(token.secret().to_owned());
        Ok(())
    }
}

/// The macOS Keychain through `keyring`: one item per archive origin under the given service name.
#[cfg(target_os = "macos")]
pub struct KeychainCredentialStore {
    service: String,
}

#[cfg(target_os = "macos")]
impl KeychainCredentialStore {
    pub fn new(service: &str) -> KeychainCredentialStore {
        KeychainCredentialStore {
            service: service.to_owned(),
        }
    }

    fn entry(&self, address: &ArchiveAddress) -> Result<keyring::Entry, CredentialStorageFailure> {
        keyring::Entry::new(&self.service, &address.origin()).map_err(|error| CredentialStorageFailure {
            detail: error.to_string(),
        })
    }
}

#[cfg(target_os = "macos")]
impl CredentialStore for KeychainCredentialStore {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<IngestToken>, CredentialStorageFailure> {
        match self.entry(address)?.get_password() {
            Ok(token) => Ok(Some(IngestToken::new(token))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(CredentialStorageFailure {
                detail: error.to_string(),
            }),
        }
    }

    fn write(&self, address: &ArchiveAddress, token: &IngestToken) -> Result<(), CredentialStorageFailure> {
        self.entry(address)?
            .set_password(token.secret())
            .map_err(|error| CredentialStorageFailure {
                detail: error.to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fixed_store_answers_every_address_with_its_one_token_and_keeps_a_written_one() {
        let address = ArchiveAddress::parse("https://archive.example.org").unwrap();
        let empty = FixedCredentialStore::new(Some("  ".to_owned()));
        assert!(empty.read(&address).unwrap().is_none());

        let store = FixedCredentialStore::new(Some("first\n".to_owned()));
        assert_eq!(store.read(&address).unwrap().unwrap().secret(), "first");
        store.write(&address, &IngestToken::new("second".to_owned())).unwrap();
        assert_eq!(store.read(&address).unwrap().unwrap().secret(), "second");
    }
}
