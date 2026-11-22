//! What the scenarios of both test files share: the seeded generator, the identifiers of a
//! script, and a whole `Replica` over the scripted archive.

use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::Duration;

use archive_access::{ArchiveAddress, ArchiveToken, FixedCredentialStore, ManualClock, Timestamp};
use archive_replica::{ArchiveReader, Replica, ReplicaEvent, ReplicaSettings, ReplicaStatus, SynchronizationTiming};
use scripted_archive::ScriptedArchive;

pub const START: Timestamp = Timestamp(1_790_000_000_000);
pub const ARCHIVE_ORIGIN: &str = "https://archive.example.org";
pub const TOKEN: &str = "schublade_scenario_token";

/// SplitMix64: the same numbers for a seed on every machine.
pub struct Generator(pub u64);

impl Generator {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut mixed = self.0;
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        mixed ^ (mixed >> 31)
    }

    pub fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next() % u64::try_from(bound).unwrap()).unwrap()
    }

    pub fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    pub fn pick<'items, Item>(&mut self, items: &'items [Item]) -> Option<&'items Item> {
        (!items.is_empty()).then(|| &items[self.below(items.len())])
    }
}

/// An identifier that names its kind in its first group and its number in its last.
pub fn identifier(kind: u8, number: usize) -> String {
    format!("{kind:08x}-0000-4000-8000-{number:012x}")
}

/// A replica that reads the scripted archive, with `replica.sqlite` and the representations in
/// `directory`, the clock at `START`, and no token of an earlier run.
pub fn start_replica(
    archive: &Arc<ScriptedArchive>,
    directory: &Path,
    original_byte_limit: Option<u64>,
) -> (Replica, Receiver<ReplicaEvent>) {
    let reader: Arc<dyn ArchiveReader> = archive.clone();
    Replica::start(ReplicaSettings {
        database_path: directory.join("replica.sqlite"),
        representation_directory: directory.join("representations"),
        original_byte_limit,
        credential_store: Box::new(FixedCredentialStore::new(None)),
        archive_readers: Box::new(move |_, _| Arc::clone(&reader)),
        timing: SynchronizationTiming::default(),
        clock: Arc::new(ManualClock::starting_at(START)),
    })
    .unwrap()
}

/// The connection flow of an application: read what the token may do, then attach.
pub fn attach(replica: &Replica, archive: &ScriptedArchive) {
    replica
        .attach_archive(
            ArchiveAddress::parse(ARCHIVE_ORIGIN).unwrap(),
            ArchiveToken::new(TOKEN.to_owned()),
            archive.read_authorization().unwrap(),
        )
        .unwrap();
}

/// Waits for an announcement above the revision a follower holds, then reads the status.
pub fn status_after(replica: &Replica, events: &Receiver<ReplicaEvent>, held_revision: u64) -> ReplicaStatus {
    loop {
        let ReplicaEvent::StatusChanged { revision } = events
            .recv_timeout(Duration::from_secs(30))
            .expect("the replica announces a change");
        if revision > held_revision {
            let status = replica.status();
            assert!(status.revision >= revision, "{} after {revision}", status.revision);
            return status;
        }
    }
}
