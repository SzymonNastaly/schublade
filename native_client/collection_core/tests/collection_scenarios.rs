//! The corpus scenarios: a Collector against the scripted archive with a manual clock, on a copy
//! of test_fixtures/collection_corpus, judged against test_fixtures/expected_collection.json.
//! No scenario sleeps; the clock moves to each deadline the status reports.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use archive_access::{ArchiveAddress, ArchiveCondition, ArchiveToken, FixedCredentialStore};
use collection_core::candidate_classification::{DisregardReason, ExclusionReason};
use collection_core::content_synchronization::LookupAnswer;
use collection_core::domain_types::{ContentDigest, DocumentStatus};
use collection_core::folder_admission::{FolderAdmission, FolderAvailability};
use collection_core::{
    ArchiveClient, AttentionItem, Clock, Collector, CollectorEvent, CollectorSettings, CollectorStatus, CommandRefusal,
    ConnectionStatus, FolderIdentifier, ManualClock, ScriptedArchive, Timestamp, TimingPolicy,
};

const CORPUS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test_fixtures/collection_corpus");
const EXPECTED: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../test_fixtures/expected_collection.json"
);
const FOLDER_ROOTS: [&str; 4] = ["Downloads", "Desktop", "Documents/Scans", "Cloud Storage"];
const TOKEN: &str = "sch_scenario_token";
const START: Timestamp = Timestamp(1_700_000_000_000);
const MINUTE: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(60 * 60);

#[derive(serde::Deserialize)]
struct ExpectedCollection {
    files: Vec<ExpectedFile>,
}

#[derive(serde::Deserialize)]
struct ExpectedFile {
    path: String,
    sha256: String,
    outcome: ExpectedOutcome,
}

#[derive(serde::Deserialize)]
struct ExpectedOutcome {
    kind: String,
}

impl ExpectedFile {
    fn digest(&self) -> ContentDigest {
        ContentDigest::parse_hexadecimal(&self.sha256).unwrap()
    }
}

struct Corpus {
    directory: tempfile::TempDir,
    expected: ExpectedCollection,
}

impl Corpus {
    fn copy_to_temporary_directory() -> Corpus {
        let directory = tempfile::tempdir().unwrap();
        copy_tree(Path::new(CORPUS), directory.path());
        let expected = serde_json::from_str(&std::fs::read_to_string(EXPECTED).unwrap()).unwrap();
        Corpus { directory, expected }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.directory.path().join(relative)
    }

    fn database_path(&self) -> PathBuf {
        self.directory.path().join("collector.sqlite")
    }

    fn folder_roots(&self) -> Vec<PathBuf> {
        FOLDER_ROOTS.iter().map(|root| self.path(root)).collect()
    }

    fn candidates(&self) -> Vec<&ExpectedFile> {
        self.expected
            .files
            .iter()
            .filter(|file| file.outcome.kind != "ignored")
            .collect()
    }

    fn candidate_digests(&self) -> BTreeSet<ContentDigest> {
        self.candidates().iter().map(|file| file.digest()).collect()
    }

    fn ignored(&self) -> Vec<&ExpectedFile> {
        self.expected
            .files
            .iter()
            .filter(|file| file.outcome.kind == "ignored")
            .collect()
    }

    fn digest_of(&self, relative: &str) -> ContentDigest {
        self.expected
            .files
            .iter()
            .find(|file| file.path == relative)
            .unwrap_or_else(|| panic!("{relative} is in the corpus"))
            .digest()
    }
}

fn copy_tree(source: &Path, target: &Path) {
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

fn timing() -> TimingPolicy {
    TimingPolicy {
        full_walk_interval: HOUR,
        document_follow_window: Duration::ZERO,
        ..TimingPolicy::default()
    }
}

/// One collector over the corpus with its archive and clock, and the helpers every scenario
/// shares.
struct Scenario {
    corpus: Corpus,
    archive: Arc<ScriptedArchive>,
    clock: Arc<ManualClock>,
    collector: Collector,
    events: Receiver<CollectorEvent>,
    folders: Vec<FolderIdentifier>,
}

impl Scenario {
    fn start() -> Scenario {
        let corpus = Corpus::copy_to_temporary_directory();
        let archive = Arc::new(ScriptedArchive::new());
        let clock = Arc::new(ManualClock::starting_at(START));
        let (collector, events) = start_collector(&corpus, &archive, &clock);
        collector
            .connect_archive(
                ArchiveAddress::parse("https://archive.example.org").unwrap(),
                ArchiveToken::new(TOKEN.to_owned()),
            )
            .unwrap();
        Scenario {
            corpus,
            archive,
            clock,
            collector,
            events,
            folders: Vec::new(),
        }
    }

    fn enroll_every_folder(&mut self) {
        self.folders = self
            .corpus
            .folder_roots()
            .into_iter()
            .map(|root| self.collector.enroll_folder(root).unwrap())
            .collect();
    }

    /// Enrolls, surveys, and decides every folder, then settles.
    fn collect_everything(&mut self) -> CollectorStatus {
        self.enroll_every_folder();
        self.settle(MINUTE);
        self.collector.decide_backlog(&self.folders).unwrap();
        self.settle(MINUTE)
    }

    /// Waits until nothing can be done now, moves the clock to the next deadline within the
    /// horizon, and repeats until no deadline within the horizon remains.
    fn settle(&self, horizon: Duration) -> CollectorStatus {
        settle(&self.collector, &self.clock, horizon)
    }

    /// Settles repeatedly, in real time, until the predicate holds: for work that a file system
    /// event brings, whose arrival no clock controls.
    fn settle_until(&self, predicate: impl Fn(&CollectorStatus) -> bool) -> CollectorStatus {
        let started = Instant::now();
        loop {
            let status = self.settle(MINUTE);
            if predicate(&status) {
                return status;
            }
            assert!(started.elapsed() < Duration::from_secs(20), "no progress: {status:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// A new Collector on the same database, as after a quit.
    fn restart(self) -> Scenario {
        self.collector.shutdown();
        let (collector, events) = start_collector(&self.corpus, &self.archive, &self.clock);
        Scenario {
            collector,
            events,
            ..self
        }
    }

    fn submission_counts(&self) -> BTreeMap<ContentDigest, usize> {
        self.corpus
            .candidate_digests()
            .into_iter()
            .map(|digest| (digest, self.archive.submission_count(&digest)))
            .collect()
    }

    fn assert_every_candidate_submitted_once(&self) {
        let once: BTreeMap<ContentDigest, usize> = self
            .corpus
            .candidate_digests()
            .into_iter()
            .map(|digest| (digest, 1))
            .collect();
        assert_eq!(self.submission_counts(), once);
        self.assert_no_ignored_file_submitted();
    }

    fn assert_no_ignored_file_submitted(&self) {
        for ignored in self.corpus.ignored() {
            assert_eq!(
                self.archive.submission_count(&ignored.digest()),
                0,
                "{} must never be submitted",
                ignored.path
            );
        }
    }
}

fn start_collector(
    corpus: &Corpus,
    archive: &Arc<ScriptedArchive>,
    clock: &Arc<ManualClock>,
) -> (Collector, Receiver<CollectorEvent>) {
    let archive: Arc<dyn ArchiveClient> = archive.clone();
    let clock: Arc<dyn Clock> = clock.clone();
    let settings = CollectorSettings {
        credential_store: Box::new(FixedCredentialStore::new(Some(TOKEN.to_owned()))),
        ..CollectorSettings::with_fixed_archive(corpus.database_path(), archive, clock, timing())
    };
    Collector::start(settings).unwrap()
}

fn settle(collector: &Collector, clock: &ManualClock, horizon: Duration) -> CollectorStatus {
    let limit = clock.now().after(horizon);
    loop {
        let status = collector.wait_until_idle(Duration::from_secs(30)).unwrap();
        match status.next_scheduled_at {
            Some(at) if at > clock.now() && at <= limit => clock.set(at),
            _ => return status,
        }
    }
}

fn held_count(scenario: &Scenario) -> usize {
    scenario
        .corpus
        .candidate_digests()
        .iter()
        .filter(|digest| scenario.archive.holds(digest))
        .count()
}

#[test]
fn the_survey_counts_the_backlog_and_submits_nothing_before_the_decision() {
    let mut scenario = Scenario::start();
    let shared_invoice = scenario.corpus.digest_of("Downloads/Invoice-PLK-2026-004817.pdf");
    scenario.archive.hold(
        shared_invoice,
        ScriptedArchive::document_of(&shared_invoice),
        DocumentStatus::Archived,
    );
    scenario.enroll_every_folder();

    let status = scenario.settle(MINUTE);

    let zero: BTreeMap<ContentDigest, usize> = scenario
        .corpus
        .candidate_digests()
        .into_iter()
        .map(|digest| (digest, 0))
        .collect();
    assert_eq!(scenario.submission_counts(), zero);
    assert!(
        status
            .folders
            .iter()
            .all(|folder| folder.admission == FolderAdmission::AwaitingDecision),
        "{:?}",
        status.folders
    );
    let backlog = status.backlog.expect("every folder awaits its decision");
    assert_eq!(backlog.folders, scenario.folders);
    assert_eq!(backlog.candidate_files, 35);
    assert_eq!(backlog.files_already_archived, 3);
    assert_eq!(backlog.files_new, 32);
    assert_eq!(backlog.new_contents, 32);
    assert_eq!(backlog.files_deleted_from_archive, 0);
    assert_eq!(backlog.files_under_examination, 0);
    assert_eq!(backlog.unreadable_files, 0);
    assert_eq!(backlog.excluded_files, 2);
    assert_eq!(
        backlog.excluded_files_by_reason,
        BTreeMap::from([
            (ExclusionReason::EmptyFile, 1),
            (ExclusionReason::UnrecognizedContent, 1)
        ])
    );
    assert_eq!(
        backlog.disregarded_files,
        BTreeMap::from([(DisregardReason::IncompleteDownload, 2)])
    );
    assert_eq!(
        status.attention,
        vec![AttentionItem::BacklogAwaitsDecision {
            folders: scenario.folders.clone()
        }]
    );
    assert_eq!(status.counts.contents_present, 1);
    assert_eq!(status.counts.contents_awaiting_submission, 32);
    let own_backlogs: Vec<(Vec<FolderIdentifier>, u64, u64)> = status
        .folders
        .iter()
        .map(|folder| {
            let own = folder.backlog.as_ref().expect("each folder has its own counts");
            (own.folders.clone(), own.candidate_files, own.files_new)
        })
        .collect();
    let folder = |index: usize| vec![scenario.folders[index]];
    assert_eq!(
        own_backlogs,
        vec![
            (folder(0), 16, 15),
            (folder(1), 3, 2),
            (folder(2), 10, 10),
            (folder(3), 6, 5)
        ]
    );
}

#[test]
fn the_decision_submits_each_distinct_content_once_and_never_an_ignored_file() {
    let mut scenario = Scenario::start();

    let status = scenario.collect_everything();

    scenario.assert_every_candidate_submitted_once();
    assert_eq!(status.counts.contents_present, 33);
    assert_eq!(status.counts.contents_awaiting_submission, 0);
    assert_eq!(status.backlog, None);
    assert!(
        status
            .folders
            .iter()
            .all(|folder| matches!(folder.admission, FolderAdmission::Collecting { .. }))
    );
    let received: Vec<String> = scenario
        .events
        .try_iter()
        .filter_map(|event| match event {
            CollectorEvent::DocumentReceived { file_name, .. } => Some(file_name),
            CollectorEvent::StatusChanged { .. } => None,
        })
        .collect();
    assert_eq!(received.len(), 33);
    assert!(received.contains(&"Jahresabrechnung_Strom_2026.pdf".to_owned()));
    assert_eq!(status.recent_receipts.len(), 20);
    assert!(
        status.recent_receipts[0]
            .document_link
            .starts_with("https://archive.example.org/documents/")
    );
}

#[test]
fn a_restart_on_the_same_database_submits_nothing_again() {
    let mut scenario = Scenario::start();
    scenario.collect_everything();
    let lookups_before = scenario.archive.lookups().len();

    let scenario = scenario.restart();
    scenario.clock.advance(HOUR / 2);
    let status = scenario.settle(MINUTE);

    scenario.assert_every_candidate_submitted_once();
    assert_eq!(status.counts.contents_present, 33);
    assert_eq!(status.counts.paths_digested, 35);
    assert_eq!(
        scenario.archive.lookups().len(),
        lookups_before,
        "present contents are never looked up again"
    );
}

#[test]
fn a_file_added_after_the_decision_is_submitted_without_a_decision() {
    let mut scenario = Scenario::start();
    scenario.collect_everything();
    let bytes = b"%PDF-1.7 a new invoice downloaded after the decision".to_vec();
    let digest = collection_core::file_system_observation::content_digest_of(&bytes);

    std::fs::write(scenario.corpus.path("Downloads/Rechnung (6).pdf"), &bytes).unwrap();
    let status = scenario.settle_until(|_| scenario.archive.holds(&digest));

    assert_eq!(scenario.archive.submission_count(&digest), 1);
    assert_eq!(status.backlog, None);
    assert_eq!(status.counts.paths_digested, 36);
    scenario.assert_every_candidate_submitted_once();
}

#[test]
fn a_rename_submits_nothing() {
    let mut scenario = Scenario::start();
    scenario.collect_everything();

    std::fs::rename(
        scenario.corpus.path("Downloads/Meldebescheinigung.pdf"),
        scenario.corpus.path("Downloads/Meldebescheinigung 2026.pdf"),
    )
    .unwrap();
    scenario.collector.notify_system_resumed();
    let status = scenario.settle(MINUTE);

    scenario.assert_every_candidate_submitted_once();
    assert_eq!(status.counts.paths_digested, 35);
    assert_eq!(status.counts.contents_present, 33);
}

#[test]
fn a_modified_file_submits_its_new_content() {
    let mut scenario = Scenario::start();
    scenario.collect_everything();
    let path = scenario.corpus.path("Downloads/Rechnung.pdf");
    let old = scenario.corpus.digest_of("Downloads/Rechnung.pdf");
    let mut bytes = std::fs::read(&path).unwrap();
    bytes.extend_from_slice(b"\n%% corrected");
    let new = collection_core::file_system_observation::content_digest_of(&bytes);

    std::fs::write(&path, &bytes).unwrap();
    scenario.collector.notify_system_resumed();
    let status = scenario.settle(MINUTE);

    assert_eq!(scenario.archive.submission_count(&old), 1);
    assert_eq!(scenario.archive.submission_count(&new), 1);
    assert!(scenario.archive.holds(&new));
    assert_eq!(status.counts.contents_present, 34, "the old content row stays present");
    assert_eq!(status.counts.paths_digested, 35);
}

#[test]
fn a_deleted_content_is_never_submitted_and_a_409_ends_the_matter() {
    let mut scenario = Scenario::start();
    let deleted_before = scenario.corpus.digest_of("Downloads/AGB_Nordkabel.pdf");
    scenario.archive.hold(
        deleted_before,
        ScriptedArchive::document_of(&deleted_before),
        DocumentStatus::Archived,
    );
    scenario.archive.delete(&deleted_before);
    let deleted_between = scenario.corpus.digest_of("Downloads/Versicherungsschein_Hausrat.pdf");
    scenario.archive.hold(
        deleted_between,
        ScriptedArchive::document_of(&deleted_between),
        DocumentStatus::Archived,
    );
    scenario.archive.delete(&deleted_between);
    scenario
        .archive
        .answer_next_lookup(deleted_between, LookupAnswer::Absent);

    let status = scenario.collect_everything();

    assert_eq!(scenario.archive.submission_count(&deleted_before), 0);
    assert_eq!(
        scenario.archive.submission_count(&deleted_between),
        1,
        "one PUT, answered 409"
    );
    assert!(!scenario.archive.holds(&deleted_before));
    assert!(!scenario.archive.holds(&deleted_between));
    assert_eq!(status.counts.contents_deleted, 2);
    assert_eq!(status.counts.contents_present, 31);
    assert_eq!(status.counts.contents_awaiting_submission, 0);
    assert_eq!(held_count(&scenario), 31);

    scenario.clock.advance(HOUR);
    scenario.settle(MINUTE);
    assert_eq!(scenario.archive.submission_count(&deleted_between), 1, "never retried");
}

#[test]
fn a_503_with_retry_after_defers_the_submissions_until_it_passes() {
    let mut scenario = Scenario::start();
    scenario.enroll_every_folder();
    scenario.settle(MINUTE);
    scenario.archive.fail_next(ArchiveCondition::ServiceUnavailable {
        retry_after: Duration::from_secs(120),
    });
    let decided_at = scenario.clock.now();
    scenario.collector.decide_backlog(&scenario.folders).unwrap();

    let deferred = scenario.settle(MINUTE);

    let ConnectionStatus::Deferred { until } = deferred.connection else {
        panic!("the connection defers: {:?}", deferred.connection)
    };
    assert_eq!(until, decided_at.after(Duration::from_secs(120)));
    // With two submission lanes, the PUT already in flight when the 503 arrived completes.
    assert!(
        held_count(&scenario) <= 1,
        "nothing more reaches the archive while deferred"
    );
    assert!(deferred.counts.contents_awaiting_submission >= 32);
    assert_eq!(deferred.next_scheduled_at, Some(until));

    let resumed = scenario.settle(3 * MINUTE);

    assert_eq!(
        resumed.connection,
        ConnectionStatus::Connected {
            archive_origin: "https://archive.example.org".to_owned()
        }
    );
    assert_eq!(held_count(&scenario), 33);
    scenario.assert_no_ignored_file_submitted();
}

#[test]
fn a_401_suspends_until_a_new_token_resumes() {
    let mut scenario = Scenario::start();
    scenario.enroll_every_folder();
    scenario.settle(MINUTE);
    scenario.archive.fail_next(ArchiveCondition::CredentialRefused);
    scenario.collector.decide_backlog(&scenario.folders).unwrap();

    let suspended = scenario.settle(MINUTE);

    assert!(
        matches!(suspended.connection, ConnectionStatus::Suspended { .. }),
        "{:?}",
        suspended.connection
    );
    // With two submission lanes, the PUT already in flight when the 401 arrived completes.
    let held_while_suspended = held_count(&scenario);
    assert!(held_while_suspended <= 1, "{held_while_suspended}");
    assert!(
        suspended
            .attention
            .iter()
            .any(|item| matches!(item, AttentionItem::CredentialSuspended { .. }))
    );

    let address = ArchiveAddress::parse("https://archive.example.org").unwrap();
    scenario
        .collector
        .connect_archive(address.clone(), ArchiveToken::new(TOKEN.to_owned()))
        .unwrap();
    let same_token = scenario.settle(MINUTE);
    assert!(
        matches!(same_token.connection, ConnectionStatus::Suspended { .. }),
        "the same token stays suspended: {:?}",
        same_token.connection
    );
    assert_eq!(held_count(&scenario), held_while_suspended);

    scenario
        .collector
        .connect_archive(address, ArchiveToken::new("sch_replacement_token".to_owned()))
        .unwrap();
    let resumed = scenario.settle(MINUTE);

    assert_eq!(
        resumed.connection,
        ConnectionStatus::Connected {
            archive_origin: "https://archive.example.org".to_owned()
        }
    );
    assert_eq!(held_count(&scenario), 33);
    // The PUT the 401 refused counted no failure, so its content was submitted again under the
    // new token; every other content once.
    let counts = scenario.submission_counts();
    assert_eq!(counts.values().sum::<usize>(), 34);
    assert_eq!(counts.values().filter(|count| **count == 2).count(), 1);
    scenario.assert_no_ignored_file_submitted();
}

#[test]
fn a_folder_whose_root_disappears_keeps_its_rows_and_resumes_when_it_returns() {
    let mut scenario = Scenario::start();
    let collected = scenario.collect_everything();
    assert_eq!(collected.counts.paths_digested, 35);
    let downloads = scenario.corpus.path("Downloads");
    let away = scenario.corpus.path("Downloads (unmounted)");

    std::fs::rename(&downloads, &away).unwrap();
    scenario.collector.notify_system_resumed();
    let missing = scenario.settle(MINUTE);

    assert_eq!(missing.counts.paths_digested, 35, "a missing root removes no rows");
    assert_eq!(missing.folders[0].availability, FolderAvailability::Missing);
    assert!(missing.attention.contains(&AttentionItem::FolderUnavailable {
        folder: scenario.folders[0],
        availability: FolderAvailability::Missing,
    }));

    let bytes = b"%PDF-1.7 arrived while the volume was away".to_vec();
    let digest = collection_core::file_system_observation::content_digest_of(&bytes);
    std::fs::write(away.join("Arrived.pdf"), &bytes).unwrap();
    std::fs::rename(&away, &downloads).unwrap();
    scenario.collector.notify_system_resumed();
    let returned = scenario.settle(MINUTE);

    assert_eq!(returned.folders[0].availability, FolderAvailability::Available);
    assert_eq!(returned.counts.paths_digested, 36);
    assert_eq!(scenario.archive.submission_count(&digest), 1);
    scenario.assert_every_candidate_submitted_once();
    assert_eq!(
        scenario.collector.decide_backlog(&[scenario.folders[0]]),
        Err(CommandRefusal::BacklogAlreadyDecided {
            folder: scenario.folders[0]
        })
    );
}
