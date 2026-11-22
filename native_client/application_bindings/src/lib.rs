//! The collector as an application sees it: one function that starts it and one object with
//! seven methods. An application links this crate as a static library and reaches it through the
//! bindings that `application_bindings_generator` writes.
//!
//! What this crate keeps from every application, so that none repeats it:
//! - following the status by revision (`status_following`);
//! - the wait of every call, which runs on a thread of the `blocking` pool, so the thread that
//!   polls an exported future never waits on the coordinator, the network, or the Keychain;
//! - the second start after an unreadable database, and the credential check before a
//!   connection is stored;
//! - every derivation a screen needs from the core's status (`published_status`).

uniffi::setup_scaffolding!();

#[cfg(test)]
mod collector_fixture;
mod published_status;
mod refusals;
mod status_following;

use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, PoisonError, RwLock};

use collection_core::archive_connection::ArchiveCondition;
use collection_core::state_store::StoreOpenFailure;
use collection_core::{
    ArchiveAddress, CollectorEvent, CollectorSettings, CredentialStore, FixedCredentialStore, HttpArchiveClient,
    IngestToken, StartFailure,
};

pub use published_status::{
    Activity, ArchiveConnection, AttentionItem, BacklogSummary, CollectionProgress, CollectorStatus,
    ConnectionCondition, ContentRefusalReason, DocumentOutcome, FolderAdmission, FolderIdentifier, FolderReference,
    FolderStatus, FolderUnavailability, Receipt, SkipReason, SkippedCount, SuspensionReason,
};
pub use refusals::{
    CollectorFault, CollectorStartFailure, ConnectionRefusal, DecisionRefusal, EnrollmentRefusal, WithdrawalRefusal,
};

use published_status::publish;
use refusals::{collector_fault, connection_refusal, decision_refusal, enrollment_refusal, withdrawal_refusal};
use status_following::RevisionAnnouncements;

/// Where the collector keeps its state and its token.
#[derive(uniffi::Record, Clone, Debug)]
pub struct CollectorConfiguration {
    /// The directory that holds `collector.sqlite`. It is created when missing.
    pub data_directory: String,
    pub credential_storage: CredentialStorage,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum CredentialStorage {
    /// One Keychain item per archive origin under this service name.
    #[cfg(target_os = "macos")]
    Keychain { service_name: String },
    /// The token lives only in this process, for a run that must not touch the Keychain.
    ProcessMemory,
}

impl CredentialStorage {
    fn store(&self) -> Box<dyn CredentialStore> {
        match self {
            #[cfg(target_os = "macos")]
            CredentialStorage::Keychain { service_name } => {
                Box::new(collection_core::KeychainCredentialStore::new(service_name))
            }
            CredentialStorage::ProcessMemory => Box::new(FixedCredentialStore::new(None)),
        }
    }
}

/// Tries an address and a token against the archive before the core stores either.
type CredentialVerification = Box<dyn Fn(&ArchiveAddress, &IngestToken) -> Result<(), ArchiveCondition> + Send + Sync>;

/// Starts the collector on `collector.sqlite` in the data directory.
#[uniffi::export]
pub async fn start_collector(configuration: CollectorConfiguration) -> Result<Arc<Collector>, CollectorStartFailure> {
    blocking::unblock(move || {
        let CollectorConfiguration {
            data_directory,
            credential_storage,
        } = configuration;
        let data_directory = PathBuf::from(data_directory);
        std::fs::create_dir_all(&data_directory).map_err(|error| CollectorStartFailure::DataDirectoryUnavailable {
            detail: error.to_string(),
        })?;
        let settings = || CollectorSettings::new(data_directory.join("collector.sqlite"), credential_storage.store());
        let started = match collection_core::Collector::start(settings()) {
            // The core renamed the database aside, so the second start opens a new one.
            Err(StartFailure::Store(StoreOpenFailure::Unreadable { .. })) => {
                collection_core::Collector::start(settings())
            }
            started => started,
        };
        let (core, events) = started?;
        Ok(Collector::following(
            core,
            events,
            Box::new(|address, token| HttpArchiveClient::new(address, token).verify_credential()),
        ))
    })
    .await
}

#[derive(uniffi::Object)]
pub struct Collector {
    /// `None` once `shutdown` ran. A call holds the read lock while the core answers it, so
    /// `shutdown` takes the core out between calls and consumes it.
    core: RwLock<Option<collection_core::Collector>>,
    announcements: Arc<RevisionAnnouncements>,
    credential_verification: CredentialVerification,
}

#[uniffi::export]
impl Collector {
    /// The first status whose revision exceeds `revision`, or the current status for `None`. A
    /// caller that passes back each answer's revision never sees an older status after a newer
    /// one and never misses the last change. A waiting read ends with a newer status or with
    /// `CollectorFault::Stopped` after `shutdown`.
    pub async fn status_after(self: Arc<Self>, revision: Option<u64>) -> Result<CollectorStatus, CollectorFault> {
        if let Some(known) = revision {
            self.announcements.announcement_above(known).await;
        }
        blocking::unblock(move || self.with_core(read_status)).await
    }

    /// Tries the address and the token against the archive, and only then stores them, so a
    /// token the archive refuses is answered here and never suspends the collector later.
    pub async fn connect_archive(self: Arc<Self>, address: String, token: String) -> Result<(), ConnectionRefusal> {
        blocking::unblock(move || {
            let address = ArchiveAddress::parse(&address).map_err(|_| ConnectionRefusal::AddressInvalid)?;
            let token = IngestToken::new(token);
            (self.credential_verification)(&address, &token)?;
            self.with_core(|core| core.connect_archive(address, token).map_err(connection_refusal))
        })
        .await
    }

    /// Starts the survey of a folder. Nothing in it uploads before `decide_backlog`.
    pub async fn enroll_folder(self: Arc<Self>, root: String) -> Result<FolderReference, EnrollmentRefusal> {
        blocking::unblock(move || {
            self.with_core(|core| match core.enroll_folder(PathBuf::from(root)) {
                Ok(folder) => Ok(folder_reference(core, folder)?),
                Err(refusal) => Err(enrollment_refusal(refusal, |folder| folder_reference(core, folder))),
            })
        })
        .await
    }

    /// Stops collecting from a folder. The archive keeps what it received.
    pub async fn withdraw_folder(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), WithdrawalRefusal> {
        blocking::unblock(move || {
            self.with_core(|core| core.withdraw_folder(folder.into()).map_err(withdrawal_refusal))
        })
        .await
    }

    /// Uploads the backlog of exactly this folder and collects from it from then on.
    pub async fn decide_backlog(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), DecisionRefusal> {
        blocking::unblock(move || {
            self.with_core(|core| {
                core.decide_backlog(&[folder.into()])
                    .map_err(|refusal| decision_refusal(refusal, |folder| folder_reference(core, folder)))
            })
        })
        .await
    }

    /// The system woke from sleep: the collector probes the archive and walks every folder.
    pub fn system_resumed(&self) {
        // Only `shutdown` holds the write lock, and a collector that stops needs no walk.
        if let Ok(core) = self.core.try_read()
            && let Some(core) = core.as_ref()
        {
            core.notify_system_resumed();
        }
    }

    /// Stops the coordinator after its current batch, which ends every waiting read. A second
    /// call finds nothing to stop.
    pub async fn shutdown(self: Arc<Self>) {
        blocking::unblock(move || {
            let core = self.core.write().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(core) = core {
                core.shutdown();
            }
        })
        .await;
    }
}

impl Collector {
    /// The exported object over a started core. A test passes a core that reaches the scripted
    /// archive, and a verification that asks the same archive.
    fn following(
        core: collection_core::Collector,
        events: Receiver<CollectorEvent>,
        credential_verification: CredentialVerification,
    ) -> Arc<Collector> {
        Arc::new(Collector {
            core: RwLock::new(Some(core)),
            announcements: RevisionAnnouncements::follow(events),
            credential_verification,
        })
    }

    fn with_core<Answer, Refusal: From<CollectorFault>>(
        &self,
        call: impl FnOnce(&collection_core::Collector) -> Result<Answer, Refusal>,
    ) -> Result<Answer, Refusal> {
        match self.core.read().unwrap_or_else(PoisonError::into_inner).as_ref() {
            Some(core) => call(core),
            None => Err(CollectorFault::Stopped.into()),
        }
    }
}

fn read_status(core: &collection_core::Collector) -> Result<CollectorStatus, CollectorFault> {
    core.status().map(publish).map_err(collector_fault)
}

/// The folder as the status lists it, for an answer that names a folder.
fn folder_reference(
    core: &collection_core::Collector,
    folder: collection_core::FolderIdentifier,
) -> Result<FolderReference, CollectorFault> {
    read_status(core)?
        .folders
        .into_iter()
        .map(|listed| listed.folder)
        .find(|listed| listed.identifier == folder.into())
        .ok_or_else(|| CollectorFault::Unexpected {
            detail: format!("Folder {} is no longer enrolled", folder.value()),
        })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use collection_core::archive_connection::ArchiveCondition;

    use super::*;
    use crate::collector_fixture::{ARCHIVE_ADDRESS, CollectorFixture, TOKEN, follow_until};

    #[test]
    fn every_refusal_of_the_core_reaches_the_command_that_caused_it() {
        let fixture = CollectorFixture::start();
        let collector = || Arc::clone(&fixture.collector);
        let connect =
            |address: &str| pollster::block_on(collector().connect_archive(address.to_owned(), TOKEN.to_owned()));
        let enroll = |root: &str| pollster::block_on(collector().enroll_folder(root.to_owned()));
        let withdraw = |value: i64| pollster::block_on(collector().withdraw_folder(FolderIdentifier { value }));
        let decide = |value: i64| pollster::block_on(collector().decide_backlog(FolderIdentifier { value }));
        let root = fixture.create_directory("Scans");
        let inner = fixture.create_directory("Scans/2026");
        let absent = format!("{root}/absent");
        std::fs::write(format!("{root}/letter.pdf"), b"%PDF-1.7 a letter").unwrap();
        let folder = FolderReference {
            identifier: FolderIdentifier { value: 1 },
            root: root.clone(),
        };

        assert_eq!(connect("archive.example.org"), Err(ConnectionRefusal::AddressInvalid));
        fixture.archive.fail_next(ArchiveCondition::CredentialRefused);
        assert_eq!(connect(ARCHIVE_ADDRESS), Err(ConnectionRefusal::TokenRefused));
        assert_eq!(
            pollster::block_on(collector().status_after(None)).unwrap().archive,
            ArchiveConnection::NotConfigured
        );

        assert_eq!(
            enroll(&absent),
            Err(EnrollmentRefusal::NotADirectory { root: absent.clone() })
        );
        assert_eq!(enroll(&root), Ok(folder.clone()));
        assert_eq!(
            enroll(&root),
            Err(EnrollmentRefusal::AlreadyEnrolled { folder: folder.clone() })
        );
        assert_eq!(
            enroll(&inner),
            Err(EnrollmentRefusal::OverlapsEnrolledFolder { folder: folder.clone() })
        );

        // Without an archive no content is resolved, so the survey cannot end before this.
        assert_eq!(
            decide(1),
            Err(DecisionRefusal::SurveyIncomplete { folder: folder.clone() })
        );
        assert_eq!(decide(7), Err(DecisionRefusal::FolderUnknown));
        assert_eq!(withdraw(7), Err(WithdrawalRefusal::FolderUnknown));

        assert_eq!(connect(ARCHIVE_ADDRESS), Ok(()));
        assert_eq!(
            connect("https://other.example.org"),
            Err(ConnectionRefusal::ArchiveDiffers {
                connected_host: "archive.example.org".to_owned()
            })
        );
        follow_until(&fixture.collector, |status| {
            matches!(status.folders[0].admission, FolderAdmission::AwaitingDecision { .. })
        });
        assert_eq!(decide(1), Ok(()));
        assert_eq!(decide(1), Err(DecisionRefusal::AlreadyDecided { folder }));

        pollster::block_on(collector().shutdown());
        let stopped = CollectorFault::Stopped;
        assert_eq!(
            connect(ARCHIVE_ADDRESS),
            Err(ConnectionRefusal::Collector { fault: stopped.clone() })
        );
        assert_eq!(
            enroll(&root),
            Err(EnrollmentRefusal::Collector { fault: stopped.clone() })
        );
        assert_eq!(
            withdraw(1),
            Err(WithdrawalRefusal::Collector { fault: stopped.clone() })
        );
        assert_eq!(decide(1), Err(DecisionRefusal::Collector { fault: stopped }));
    }
}
