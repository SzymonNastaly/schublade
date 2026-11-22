//! Where the token lives, keyed by the archive origin so a lost database leaves it findable. A
//! database keeps only the token's fingerprint.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use crate::archive_address::ArchiveAddress;
use crate::archive_token::ArchiveToken;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CredentialStorageFailure {
    pub detail: String,
}

pub trait CredentialStore: Send + Sync {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure>;
    fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure>;
}

impl<Store: CredentialStore + ?Sized> CredentialStore for std::sync::Arc<Store> {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
        (**self).read(address)
    }

    fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
        (**self).write(address, token)
    }
}

fn locked<Value>(mutex: &Mutex<Value>) -> MutexGuard<'_, Value> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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
    fn read(&self, _address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
        Ok(locked(&self.token).clone().map(ArchiveToken::new))
    }

    fn write(&self, _address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
        *locked(&self.token) = Some(token.secret().to_owned());
        Ok(())
    }
}

/// Reads its inner store once per origin and answers later reads from memory, so two cores that
/// each read at start cause one Keychain read and at most one prompt. The read holds the lock, so
/// two concurrent first reads still read the inner store once. A write passes through and
/// forgets the origin, so the next read asks the inner store again. A failed read is not kept.
pub struct RememberingCredentialStore {
    inner: Box<dyn CredentialStore>,
    remembered: Mutex<BTreeMap<String, Option<String>>>,
}

impl RememberingCredentialStore {
    pub fn new(inner: Box<dyn CredentialStore>) -> RememberingCredentialStore {
        RememberingCredentialStore {
            inner,
            remembered: Mutex::new(BTreeMap::new()),
        }
    }
}

impl CredentialStore for RememberingCredentialStore {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
        let mut remembered = locked(&self.remembered);
        if let Some(secret) = remembered.get(&address.origin()) {
            return Ok(secret.clone().map(ArchiveToken::new));
        }
        let token = self.inner.read(address)?;
        remembered.insert(address.origin(), token.as_ref().map(|token| token.secret().to_owned()));
        Ok(token)
    }

    fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
        let mut remembered = locked(&self.remembered);
        let written = self.inner.write(address, token);
        remembered.remove(&address.origin());
        written
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
    fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
        match self.entry(address)?.get_password() {
            Ok(token) => Ok(Some(ArchiveToken::new(token))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(CredentialStorageFailure {
                detail: error.to_string(),
            }),
        }
    }

    fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
        self.entry(address)?
            .set_password(token.secret())
            .map_err(|error| CredentialStorageFailure {
                detail: error.to_string(),
            })
    }
}

/// The iPhone's Keychain: one generic password per archive origin under the given service name,
/// in the access group the application and its share extension share when one is named. The item
/// stays readable while the phone is locked after its first unlock, so a background refresh or an
/// upload's answer can read it, and it never leaves the device.
#[cfg(target_os = "ios")]
pub struct SharedKeychainCredentialStore {
    service: String,
    access_group: Option<String>,
}

#[cfg(target_os = "ios")]
impl SharedKeychainCredentialStore {
    pub fn new(service: &str, access_group: Option<&str>) -> SharedKeychainCredentialStore {
        SharedKeychainCredentialStore {
            service: service.to_owned(),
            access_group: access_group.map(str::to_owned),
        }
    }

    fn item(&self, address: &ArchiveAddress) -> security_framework::passwords::PasswordOptions {
        let mut options =
            security_framework::passwords::PasswordOptions::new_generic_password(&self.service, &address.origin());
        if let Some(group) = &self.access_group {
            options.set_access_group(group);
        }
        options
    }
}

#[cfg(target_os = "ios")]
fn keychain_failure(error: security_framework::base::Error) -> CredentialStorageFailure {
    CredentialStorageFailure {
        detail: error.to_string(),
    }
}

#[cfg(target_os = "ios")]
const KEYCHAIN_ITEM_NOT_FOUND: i32 = -25300;

#[cfg(target_os = "ios")]
impl CredentialStore for SharedKeychainCredentialStore {
    fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
        match security_framework::passwords::generic_password(self.item(address)) {
            Ok(secret) => String::from_utf8(secret)
                .map(|secret| Some(ArchiveToken::new(secret)))
                .map_err(|_| CredentialStorageFailure {
                    detail: "The stored token is not text".to_owned(),
                }),
            Err(error) if error.code() == KEYCHAIN_ITEM_NOT_FOUND => Ok(None),
            Err(error) => Err(keychain_failure(error)),
        }
    }

    /// Removes the item and adds it again, because an update matches on the query, and a query
    /// that names the accessibility would miss an item written with another.
    fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
        match security_framework::passwords::delete_generic_password_options(self.item(address)) {
            Err(error) if error.code() != KEYCHAIN_ITEM_NOT_FOUND => return Err(keychain_failure(error)),
            _ => {}
        }
        let mut item = self.item(address);
        let accessibility = security_framework::access_control::SecAccessControl::create_with_protection(
            Some(security_framework::access_control::ProtectionMode::AccessibleAfterFirstUnlockThisDeviceOnly),
            0,
        )
        .map_err(keychain_failure)?;
        item.set_access_control(accessibility);
        security_framework::passwords::set_generic_password_options(token.secret().as_bytes(), item)
            .map_err(keychain_failure)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[test]
    fn a_fixed_store_answers_every_address_with_its_one_token_and_keeps_a_written_one() {
        let address = ArchiveAddress::parse("https://archive.example.org").unwrap();
        let empty = FixedCredentialStore::new(Some("  ".to_owned()));
        assert!(empty.read(&address).unwrap().is_none());

        let store = FixedCredentialStore::new(Some("first\n".to_owned()));
        assert_eq!(store.read(&address).unwrap().unwrap().secret(), "first");
        store.write(&address, &ArchiveToken::new("second".to_owned())).unwrap();
        assert_eq!(store.read(&address).unwrap().unwrap().secret(), "second");
    }

    struct CountedStore {
        store: FixedCredentialStore,
        reads: Arc<AtomicUsize>,
    }

    impl CredentialStore for CountedStore {
        fn read(&self, address: &ArchiveAddress) -> Result<Option<ArchiveToken>, CredentialStorageFailure> {
            self.reads.fetch_add(1, Ordering::SeqCst);
            self.store.read(address)
        }

        fn write(&self, address: &ArchiveAddress, token: &ArchiveToken) -> Result<(), CredentialStorageFailure> {
            self.store.write(address, token)
        }
    }

    #[test]
    fn a_remembering_store_reads_its_inner_store_once_until_a_write() {
        let address = ArchiveAddress::parse("https://archive.example.org").unwrap();
        let reads = Arc::new(AtomicUsize::new(0));
        let store = RememberingCredentialStore::new(Box::new(CountedStore {
            store: FixedCredentialStore::new(Some("first".to_owned())),
            reads: Arc::clone(&reads),
        }));
        let read = || store.read(&address).unwrap().unwrap().secret().to_owned();

        assert_eq!((read(), read()), ("first".to_owned(), "first".to_owned()));
        assert_eq!(reads.load(Ordering::SeqCst), 1);

        store.write(&address, &ArchiveToken::new("second".to_owned())).unwrap();
        assert_eq!((read(), read()), ("second".to_owned(), "second".to_owned()));
        assert_eq!(reads.load(Ordering::SeqCst), 2);
    }
}
