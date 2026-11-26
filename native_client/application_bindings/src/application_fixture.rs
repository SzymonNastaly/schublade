//! What the tests of this crate share: an `ApplicationCore` over the one unified `ScriptedArchive`
//! running on the wall clock with short intervals, plus helpers to follow both halves' statuses.

use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

use archive_access::{
    ArchiveAddress, ArchiveToken, CredentialStore, FixedCredentialStore, PermissionLevel, RememberingCredentialStore,
};
use archive_replica::{ArchiveReader, Replica, ReplicaSettings, SynchronizationTiming};
use collection_core::{ArchiveClient, CollectorSettings, SystemClock, TimingPolicy};
use scripted_archive::ScriptedArchive;

use crate::{
    ApplicationCore, ApplicationFault, CollectionPlacement, Collector, CollectorStatus, Library, LibraryStatus,
};

pub(crate) const ARCHIVE_ADDRESS: &str = "https://archive.example.org";
pub(crate) const TOKEN: &str = "sch_fixture_token";
pub(crate) const ANSWER_LIMIT: Duration = Duration::from_secs(30);

pub(crate) struct ApplicationFixture {
    pub(crate) directory: tempfile::TempDir,
    pub(crate) archive: Arc<ScriptedArchive>,
    pub(crate) core: Arc<ApplicationCore>,
}

impl ApplicationFixture {
    pub(crate) fn start(collection: CollectionPlacement) -> ApplicationFixture {
        let directory = tempfile::tempdir().unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let credentials = Arc::new(RememberingCredentialStore::new(Box::new(FixedCredentialStore::new(
            None,
        ))));
        let core = start_over_archive(directory.path(), &archive, &credentials, collection);
        ApplicationFixture {
            directory,
            archive,
            core,
        }
    }

    /// Simulates a crash after attaching the replica and writing the credential, before the
    /// collector could be connected, then starts a fresh `ApplicationCore` on the same directory.
    pub(crate) fn start_crash_repair() -> ApplicationFixture {
        let directory = tempfile::tempdir().unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let credentials = Arc::new(RememberingCredentialStore::new(Box::new(FixedCredentialStore::new(
            None,
        ))));
        let address = ArchiveAddress::parse(ARCHIVE_ADDRESS).unwrap();
        let token = ArchiveToken::new(TOKEN.to_owned());
        credentials.write(&address, &token).unwrap();

        let authorization = archive.read_authorization().unwrap();
        assert_eq!(authorization.permission_level, PermissionLevel::Read);
        let reader: Arc<dyn ArchiveReader> = Arc::clone(&archive) as Arc<dyn ArchiveReader>;
        let (replica, _events) = Replica::start(ReplicaSettings {
            database_path: directory.path().join("replica.sqlite"),
            representation_directory: directory.path().join("cache"),
            original_byte_limit: Some(1_000_000),
            credential_store: Box::new(Arc::clone(&credentials)),
            archive_readers: Box::new(move |_, _| Arc::clone(&reader)),
            timing: SynchronizationTiming::default(),
            clock: Arc::new(SystemClock),
        })
        .unwrap();
        replica.attach_archive(address, token, authorization).unwrap();
        replica.shutdown();

        let core = start_over_archive(directory.path(), &archive, &credentials, CollectionPlacement::Collector);
        ApplicationFixture {
            directory,
            archive,
            core,
        }
    }

    /// A new directory inside the fixture's own, as text.
    pub(crate) fn create_directory(&self, relative: &str) -> String {
        let directory = self.directory.path().join(relative);
        std::fs::create_dir_all(&directory).unwrap();
        directory.to_str().unwrap().to_owned()
    }
}

fn start_over_archive(
    directory: &Path,
    archive: &Arc<ScriptedArchive>,
    credentials: &Arc<RememberingCredentialStore>,
    collection: CollectionPlacement,
) -> Arc<ApplicationCore> {
    let started_collector = match collection {
        CollectionPlacement::Collector => {
            let client: Arc<dyn ArchiveClient> = Arc::clone(archive) as Arc<dyn ArchiveClient>;
            let timing = TimingPolicy {
                stabilization_interval: Duration::from_millis(20),
                hint_coalescing_interval: Duration::from_millis(10),
                status_coalescing_interval: Duration::from_millis(10),
                document_follow_window: Duration::ZERO,
                ..TimingPolicy::default()
            };
            let settings = CollectorSettings {
                database_path: directory.join("collector.sqlite"),
                credential_store: Box::new(Arc::clone(credentials)),
                archive_clients: Box::new(move |_, _| Arc::clone(&client)),
                document_reader: Arc::new(collection_core::EmptyDocumentReader),
                timing,
                submission_concurrency: 2,
                clock: Arc::new(SystemClock),
            };
            Some(collection_core::Collector::start(settings).unwrap())
        }
        CollectionPlacement::Absent => None,
    };

    let reader: Arc<dyn ArchiveReader> = Arc::clone(archive) as Arc<dyn ArchiveReader>;
    let replica_timing = SynchronizationTiming {
        unsettled_interval: Duration::from_millis(25),
        attended_interval: Duration::from_millis(50),
        ..SynchronizationTiming::default()
    };
    let started_replica = Replica::start(ReplicaSettings {
        database_path: directory.join("replica.sqlite"),
        representation_directory: directory.join("cache"),
        original_byte_limit: Some(1_000_000),
        credential_store: Box::new(Arc::clone(credentials)),
        archive_readers: Box::new(move |_, _| Arc::clone(&reader)),
        timing: replica_timing,
        clock: Arc::new(SystemClock),
    })
    .unwrap();

    let authorizing = Arc::clone(archive);
    ApplicationCore::assemble(
        started_collector,
        started_replica,
        Arc::clone(credentials),
        Box::new(move |_, _| authorizing.read_authorization()),
    )
    .unwrap()
}

pub(crate) fn read_collector_after(
    collector: &Arc<Collector>,
    revision: Option<u64>,
) -> Receiver<Result<CollectorStatus, ApplicationFault>> {
    let (answer, answered) = channel();
    let collector = Arc::clone(collector);
    std::thread::spawn(move || {
        let _ = answer.send(pollster::block_on(collector.status_after(revision)));
    });
    answered
}

pub(crate) fn read_library_after(
    library: &Arc<Library>,
    revision: Option<u64>,
) -> Receiver<Result<LibraryStatus, ApplicationFault>> {
    let (answer, answered) = channel();
    let library = Arc::clone(library);
    std::thread::spawn(move || {
        let _ = answer.send(pollster::block_on(library.status_after(revision)));
    });
    answered
}

pub(crate) fn follow_collector_until(
    collector: &Arc<Collector>,
    reached: impl Fn(&CollectorStatus) -> bool,
) -> Vec<CollectorStatus> {
    let mut followed: Vec<CollectorStatus> = Vec::new();
    loop {
        let revision = followed.last().map(|status| status.revision);
        let status = read_collector_after(collector, revision)
            .recv_timeout(ANSWER_LIMIT)
            .expect("the collector status read answers")
            .unwrap();
        let finished = reached(&status);
        followed.push(status);
        if finished {
            return followed;
        }
    }
}

pub(crate) fn follow_library_until(
    library: &Arc<Library>,
    reached: impl Fn(&LibraryStatus) -> bool,
) -> Vec<LibraryStatus> {
    let mut followed: Vec<LibraryStatus> = Vec::new();
    loop {
        let revision = followed.last().map(|status| status.revision);
        let status = read_library_after(library, revision)
            .recv_timeout(ANSWER_LIMIT)
            .expect("the library status read answers")
            .unwrap();
        let finished = reached(&status);
        followed.push(status);
        if finished {
            return followed;
        }
    }
}

pub(crate) fn copy_tree(source: &Path, target: &Path) {
    std::fs::create_dir_all(target).unwrap();
    for entry in std::fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        let destination = target.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &destination);
        } else {
            std::fs::copy(entry.path(), &destination).unwrap();
        }
    }
}
