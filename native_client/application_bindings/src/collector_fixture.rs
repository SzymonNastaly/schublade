//! What the tests of this crate share: a collector over the core's scripted archive that runs on
//! the wall clock with short intervals, and reads that a test can find waiting.

use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

use collection_core::domain_types::ContentDigest;
use collection_core::{ArchiveClient, CollectorSettings, SystemClock, TimingPolicy};
use scripted_archive::ScriptedArchive;

use crate::{Collector, CollectorFault, CollectorStatus};

pub(crate) const ARCHIVE_ADDRESS: &str = "https://archive.example.org";
pub(crate) const TOKEN: &str = "sch_fixture_token";
pub(crate) const ANSWER_LIMIT: Duration = Duration::from_secs(30);

pub(crate) struct CollectorFixture {
    pub(crate) directory: tempfile::TempDir,
    pub(crate) archive: Arc<ScriptedArchive>,
    pub(crate) collector: Arc<Collector>,
}

impl CollectorFixture {
    pub(crate) fn start() -> CollectorFixture {
        let directory = tempfile::tempdir().unwrap();
        let archive = Arc::new(ScriptedArchive::new());
        let client: Arc<dyn ArchiveClient> = archive.clone();
        let timing = TimingPolicy {
            stabilization_interval: Duration::from_millis(20),
            hint_coalescing_interval: Duration::from_millis(10),
            status_coalescing_interval: Duration::from_millis(10),
            document_follow_window: Duration::ZERO,
            ..TimingPolicy::default()
        };
        let settings = CollectorSettings::with_fixed_archive(
            directory.path().join("collector.sqlite"),
            client,
            Arc::new(SystemClock),
            timing,
        );
        let (core, events) = collection_core::Collector::start(settings).unwrap();
        let verifying = Arc::clone(&archive);
        let collector = Collector::following(
            core,
            events,
            Box::new(move |_, _| verifying.look_up(&[ContentDigest::from_bytes([0; 32])]).map(|_| ())),
        );
        CollectorFixture {
            directory,
            archive,
            collector,
        }
    }

    /// A new directory inside the fixture's own, as text.
    pub(crate) fn create_directory(&self, relative: &str) -> String {
        let directory = self.directory.path().join(relative);
        std::fs::create_dir_all(&directory).unwrap();
        directory.to_str().unwrap().to_owned()
    }
}

/// The answer of `status_after` from a thread of its own.
pub(crate) fn read_after(
    collector: &Arc<Collector>,
    revision: Option<u64>,
) -> Receiver<Result<CollectorStatus, CollectorFault>> {
    let (answer, answered) = channel();
    let collector = Arc::clone(collector);
    std::thread::spawn(move || {
        // A test that failed earlier no longer listens.
        let _ = answer.send(pollster::block_on(collector.status_after(revision)));
    });
    answered
}

/// Follows the status from its current one until `reached` holds, and answers every status on
/// the way.
pub(crate) fn follow_until(
    collector: &Arc<Collector>,
    reached: impl Fn(&CollectorStatus) -> bool,
) -> Vec<CollectorStatus> {
    let mut followed: Vec<CollectorStatus> = Vec::new();
    loop {
        let revision = followed.last().map(|status| status.revision);
        let status = read_after(collector, revision)
            .recv_timeout(ANSWER_LIMIT)
            .expect("the read answers")
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
