//! Coordinator command and refusal scenarios moved out of `collection_coordinator.rs` so that
//! `collection_core` integration tests share one `scripted_archive` crate with `archive_replica`.

use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::Duration;

use archive_access::{ArchiveAddress, ArchiveCondition, ArchiveToken, Clock, ManualClock};
use collection_core::file_system_observation::content_digest_of;
use collection_core::folder_admission::FolderAdmission;
use collection_core::state_store::StoreOpenFailure;
use collection_core::{
    ArchiveClient, AttentionItem, Collector, CollectorEvent, CollectorSettings, CollectorStatus, CommandRefusal,
    ConnectionStatus, FolderIdentifier, StartFailure, Timestamp, TimingPolicy,
};
use scripted_archive::ScriptedArchive;

const HOUR: Duration = Duration::from_secs(60 * 60);

fn timing() -> TimingPolicy {
    TimingPolicy {
        full_walk_interval: HOUR,
        document_follow_window: Duration::ZERO,
        ..TimingPolicy::default()
    }
}

fn start(
    database: &Path,
    archive: &Arc<ScriptedArchive>,
    clock: &Arc<ManualClock>,
) -> (Collector, Receiver<CollectorEvent>) {
    let archive: Arc<dyn ArchiveClient> = archive.clone();
    let clock: Arc<dyn Clock> = clock.clone();
    Collector::start(CollectorSettings::with_fixed_archive(
        database.to_path_buf(),
        archive,
        clock,
        timing(),
    ))
    .unwrap()
}

/// Waits until nothing can be done now, then moves the clock to the next deadline within the
/// horizon and waits again, until no deadline within the horizon remains.
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

#[test]
fn one_file_is_surveyed_then_submitted_once_after_the_decision() {
    let temporary = tempfile::tempdir().unwrap();
    let folder_root = temporary.path().join("Downloads");
    std::fs::create_dir(&folder_root).unwrap();
    std::fs::write(folder_root.join("Invoice.pdf"), b"%PDF-1.7 one invoice").unwrap();
    let archive = Arc::new(ScriptedArchive::new());
    let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
    let (collector, events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);
    collector
        .connect_archive(
            ArchiveAddress::parse("https://archive.example.org").unwrap(),
            ArchiveToken::new("token".to_owned()),
        )
        .unwrap();
    let folder = collector.enroll_folder(folder_root.clone()).unwrap();

    let surveyed = settle(&collector, &clock, Duration::from_secs(60));

    let digest = content_digest_of(b"%PDF-1.7 one invoice");
    assert_eq!(archive.submission_count(&digest), 0);
    assert_eq!(surveyed.folders[0].admission, FolderAdmission::AwaitingDecision);
    let backlog = surveyed.backlog.clone().expect("the folder awaits its decision");
    assert_eq!(
        (backlog.candidate_files, backlog.files_new, backlog.new_contents),
        (1, 1, 1)
    );
    assert_eq!(surveyed.folders[0].backlog.as_ref(), Some(&backlog));
    assert_eq!(surveyed.archive_origin.as_deref(), Some("https://archive.example.org"));
    assert_eq!(
        surveyed.attention,
        vec![AttentionItem::BacklogAwaitsDecision { folders: vec![folder] }]
    );

    collector.decide_backlog(&[folder]).unwrap();
    let collected = settle(&collector, &clock, Duration::from_secs(60));

    assert_eq!(archive.submission_count(&digest), 1);
    assert_eq!(collected.counts.contents_present, 1);
    assert_eq!(collected.backlog, None);
    assert_eq!(collected.recent_receipts.len(), 1);
    assert_eq!(collected.recent_receipts[0].file_name, "Invoice.pdf");
    let received = events
        .try_iter()
        .find(|event| matches!(event, CollectorEvent::DocumentReceived { .. }));
    assert_eq!(
        received,
        Some(CollectorEvent::DocumentReceived {
            document_link: format!(
                "https://archive.example.org/documents/{}",
                ScriptedArchive::document_of(&digest).as_str()
            ),
            file_name: "Invoice.pdf".to_owned(),
        })
    );
}

#[test]
fn the_probe_of_an_unreachable_archive_raises_the_revision() {
    let temporary = tempfile::tempdir().unwrap();
    let folder_root = temporary.path().join("Downloads");
    std::fs::create_dir(&folder_root).unwrap();
    std::fs::write(folder_root.join("Invoice.pdf"), b"%PDF-1.7 one invoice").unwrap();
    let archive = Arc::new(ScriptedArchive::new());
    archive.fail_next(ArchiveCondition::ConnectionFailed);
    let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
    let (collector, _events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);
    collector
        .connect_archive(
            ArchiveAddress::parse("https://archive.example.org").unwrap(),
            ArchiveToken::new("token".to_owned()),
        )
        .unwrap();
    let folder = collector.enroll_folder(folder_root).unwrap();
    let next_attempt_at = loop {
        let status = collector.wait_until_idle(Duration::from_secs(30)).unwrap();
        if let ConnectionStatus::Unreachable { next_attempt_at, .. } = status.connection {
            break next_attempt_at;
        }
        clock.set(status.next_scheduled_at.expect("the lookup is due later"));
    };

    // Without a folder, the probe has no request to send, so nothing after it raises the
    // revision on its behalf.
    collector.withdraw_folder(folder).unwrap();
    let withdrawn = collector.status().unwrap();
    clock.set(next_attempt_at);
    let probing = collector.status().unwrap();

    assert!(matches!(withdrawn.connection, ConnectionStatus::Unreachable { .. }));
    assert_eq!(probing.connection, ConnectionStatus::Checking);
    assert!(
        probing.revision > withdrawn.revision,
        "{} after {}",
        probing.revision,
        withdrawn.revision
    );
}

#[test]
fn the_commands_refuse_overlapping_folders_and_an_early_decision() {
    let temporary = tempfile::tempdir().unwrap();
    let downloads = temporary.path().join("Downloads");
    std::fs::create_dir_all(downloads.join("Scans")).unwrap();
    std::fs::write(downloads.join("Invoice.pdf"), b"%PDF-1.7 still stabilizing").unwrap();
    let archive = Arc::new(ScriptedArchive::new());
    let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
    let (collector, _events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);

    let folder = collector.enroll_folder(downloads.clone()).unwrap();
    assert_eq!(
        collector.enroll_folder(downloads.join("Scans")),
        Err(CommandRefusal::FolderOverlapsEnrolledFolder { folder })
    );
    assert_eq!(
        collector.enroll_folder(temporary.path().to_path_buf()),
        Err(CommandRefusal::FolderOverlapsEnrolledFolder { folder })
    );
    assert_eq!(
        collector.enroll_folder(downloads.clone()),
        Err(CommandRefusal::FolderAlreadyEnrolled { folder })
    );
    assert!(matches!(
        collector.enroll_folder(temporary.path().join("Missing")),
        Err(CommandRefusal::FolderRootNotADirectory { .. })
    ));
    assert_eq!(
        collector.decide_backlog(&[folder]),
        Err(CommandRefusal::SurveyIncomplete { folder })
    );
    assert_eq!(
        collector.decide_backlog(&[FolderIdentifier::new(99)]),
        Err(CommandRefusal::FolderUnknown {
            folder: FolderIdentifier::new(99)
        })
    );
    let status = collector.status().unwrap();
    assert_eq!(status.attention, vec![AttentionItem::ArchiveNotConfigured]);
    collector.withdraw_folder(folder).unwrap();
    assert_eq!(
        collector.withdraw_folder(folder),
        Err(CommandRefusal::FolderUnknown { folder })
    );
    assert!(collector.status().unwrap().folders.is_empty());
}

#[test]
fn a_second_collector_on_one_database_is_refused_until_the_first_stops() {
    let temporary = tempfile::tempdir().unwrap();
    let database = temporary.path().join("collector.sqlite");
    let archive = Arc::new(ScriptedArchive::new());
    let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
    let (first, _events) = start(&database, &archive, &clock);

    let second = Collector::start(CollectorSettings::with_fixed_archive(
        database.clone(),
        archive.clone(),
        clock.clone(),
        timing(),
    ));
    assert!(matches!(
        second,
        Err(StartFailure::Store(StoreOpenFailure::InUse { lock_path }))
            if lock_path == temporary.path().join("collector.sqlite.lock")
    ));

    first.shutdown();
    let (third, _events) = start(&database, &archive, &clock);
    assert!(third.status().is_ok());
}

#[test]
fn another_archive_is_refused_once_the_collector_holds_records_of_the_connected_one() {
    let temporary = tempfile::tempdir().unwrap();
    let downloads = temporary.path().join("Downloads");
    std::fs::create_dir(&downloads).unwrap();
    std::fs::write(downloads.join("Invoice.pdf"), b"%PDF-1.7 one invoice").unwrap();
    let archive = Arc::new(ScriptedArchive::new());
    let clock = Arc::new(ManualClock::starting_at(Timestamp(1_700_000_000_000)));
    let (collector, _events) = start(&temporary.path().join("collector.sqlite"), &archive, &clock);
    let connected = || ArchiveAddress::parse("https://archive.example.org").unwrap();
    let other = || ArchiveAddress::parse("https://other.example.org").unwrap();
    let token = |secret: &str| ArchiveToken::new(secret.to_owned());
    let refused = Err(CommandRefusal::ArchiveOriginDiffers {
        connected_origin: "https://archive.example.org".to_owned(),
    });

    collector.connect_archive(other(), token("first")).unwrap();
    collector.connect_archive(connected(), token("first")).unwrap();
    let folder = collector.enroll_folder(downloads).unwrap();
    assert_eq!(collector.connect_archive(other(), token("first")), refused);
    assert_eq!(
        collector.locked_archive_origin().unwrap().as_deref(),
        Some("https://archive.example.org")
    );

    settle(&collector, &clock, Duration::from_secs(60));
    collector.withdraw_folder(folder).unwrap();
    assert_eq!(collector.connect_archive(other(), token("first")), refused);

    collector.connect_archive(connected(), token("second")).unwrap();
    assert_eq!(
        collector.status().unwrap().archive_origin.as_deref(),
        Some("https://archive.example.org")
    );
}
