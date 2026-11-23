//! What a window reads from the copy, against the scripted archive: the difference of two
//! listings, the search of German paperwork, and the files of originals.

mod scenario_support;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::{Duration, SystemTime};

use archive_access::{ArchiveToken, ContentDigest, DocumentIdentifier, Timestamp};
use archive_replica::replica_records::{
    CalendarDate, DocumentCondition, DocumentRecord, ExtractedField, FieldValue, IngestionStage, PersonAssignment,
    SenderIdentifier, SenderRecord,
};
use archive_replica::{
    ArchiveReader, DocumentListing, LibraryScope, ListingDifference, ListingOrder, ListingRequest, ListingRow, Replica,
    ReplicaEvent, ReplicaQueries, ReplicaStore, RepresentationRefusal, RowPassage, SynchronizationInput,
    SynchronizationState, WakeReason, exchange_page, listing_difference,
};
use scenario_support::{ARCHIVE_ORIGIN, Generator, START, TOKEN, attach, identifier, start_replica, status_after};
use scripted_archive::ScriptedArchive;
use sha2::{Digest, Sha256};

fn document_identifier(number: usize) -> DocumentIdentifier {
    DocumentIdentifier::parse(&identifier(5, number)).unwrap()
}

/// An archived letter of the household. A scenario changes what it is about.
fn letter(number: usize, title: &str, date: &str) -> DocumentRecord {
    DocumentRecord {
        identifier: document_identifier(number),
        condition: DocumentCondition::Archived,
        title: Some(title.to_owned()),
        document_date: CalendarDate::parse(date),
        sender: None,
        category: None,
        person: PersonAssignment::Household,
        summary: None,
        media_type: "application/pdf".to_owned(),
        byte_size: 184_233,
        page_count: Some(1),
        original: None,
        arrived_at: Timestamp(START.0 + i64::try_from(number).unwrap()),
        tags: BTreeSet::new(),
        fields: BTreeMap::new(),
    }
}

/// A file the archive is still reading, which has neither a title nor a date.
fn arriving(number: usize) -> DocumentRecord {
    DocumentRecord {
        condition: DocumentCondition::Arriving(IngestionStage::Processing),
        title: None,
        document_date: None,
        person: PersonAssignment::Unassigned,
        ..letter(number, "", "")
    }
}

/// A copy filled page by page, without the threads of a `Replica`, and what a window lists
/// from it.
struct ListedCopy {
    archive: ScriptedArchive,
    store: ReplicaStore,
    queries: ReplicaQueries,
    _directory: tempfile::TempDir,
}

impl ListedCopy {
    fn of_an_empty_archive() -> ListedCopy {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("replica.sqlite");
        let archive = ScriptedArchive::with_page_entries(4);
        let mut store = ReplicaStore::open(&path).unwrap();
        let fingerprint = ArchiveToken::new(TOKEN.to_owned()).fingerprint();
        store
            .attach(ARCHIVE_ORIGIN, &archive.read_authorization().unwrap(), &fingerprint)
            .unwrap();
        ListedCopy {
            archive,
            store,
            queries: ReplicaQueries::open(&path).unwrap(),
            _directory: directory,
        }
    }

    fn list(&mut self, request: &ListingRequest) -> DocumentListing {
        loop {
            match exchange_page(&mut self.store, &self.archive, START).unwrap() {
                Some(SynchronizationInput::PageApplied { complete: true, .. }) => break,
                Some(SynchronizationInput::PageApplied { complete: false, .. }) => {}
                other => panic!("{other:?}"),
            }
        }
        self.queries.list_documents(request, START).unwrap()
    }
}

fn rows_of(listing: &DocumentListing) -> Vec<ListingRow> {
    listing.rows(0, listing.row_count()).to_vec()
}

/// What a table view makes of a difference: it removes rows at positions of the old rows, then
/// inserts and redraws rows at positions of the new ones.
fn applied(
    preceding: &DocumentListing,
    following: &DocumentListing,
    difference: &ListingDifference,
) -> Vec<ListingRow> {
    let mut rows = rows_of(preceding);
    for position in difference.removed_positions.iter().rev() {
        rows.remove(*position);
    }
    for position in &difference.inserted_positions {
        rows.insert(*position, following.rows(*position, 1)[0].clone());
    }
    for position in &difference.revised_positions {
        rows[*position] = following.rows(*position, 1)[0].clone();
    }
    rows
}

/// A heading by its name, a document by its number.
fn outline(listing: &DocumentListing) -> Vec<String> {
    rows_of(listing)
        .iter()
        .map(|row| match row {
            ListingRow::Heading(heading) => format!("{heading:?}"),
            ListingRow::Document(row) => {
                let number = row.identifier.as_str().rsplit('-').next().unwrap();
                format!("document {}", usize::from_str_radix(number, 16).unwrap())
            }
        })
        .collect()
}

#[test]
fn the_difference_of_two_listings_applied_to_the_first_gives_the_second() {
    let by_date = ListingRequest::Browse {
        scope: LibraryScope::AllDocuments,
        order: ListingOrder::DocumentDate,
    };
    let by_title = ListingRequest::Browse {
        scope: LibraryScope::AllDocuments,
        order: ListingOrder::Title,
    };

    // One change of each kind, with the positions a table view receives.
    let mut copy = ListedCopy::of_an_empty_archive();
    copy.archive.put_document(letter(1, "Stromrechnung", "2026-09-22"));
    copy.archive.put_document(letter(2, "Mietvertrag", "2026-08-03"));
    copy.archive.put_document(arriving(3));
    let first = copy.list(&by_date);
    assert_eq!(first.heading_positions(), &[0, 2, 4]);
    assert_eq!(
        outline(&first),
        [
            "Arriving",
            "document 3",
            "Period { year: 2026, month: 9 }",
            "document 1",
            "Period { year: 2026, month: 8 }",
            "document 2"
        ]
    );
    copy.archive.delete_document(&document_identifier(1));
    copy.archive
        .put_document(letter(2, "Mietvertrag mit Nachtrag", "2026-08-03"));
    copy.archive
        .put_document(letter(3, "Nebenkostenabrechnung", "2026-08-20"));
    copy.archive.put_document(letter(4, "Kontoauszug", "2026-09-01"));
    let second = copy.list(&by_date);
    assert_eq!(second.heading_positions(), &[0, 2]);
    assert_eq!(
        outline(&second),
        [
            "Period { year: 2026, month: 9 }",
            "document 4",
            "Period { year: 2026, month: 8 }",
            "document 3",
            "document 2"
        ]
    );
    let difference = listing_difference(&first, &second);
    assert_eq!(
        difference,
        ListingDifference {
            // The Arriving heading, document 3 where it stood, and the deleted document 1.
            removed_positions: vec![0, 1, 3],
            // The new document 4, and document 3 under its month.
            inserted_positions: vec![1, 3],
            // The retitled document 2.
            revised_positions: vec![4],
        }
    );
    assert_eq!(applied(&first, &second, &difference), rows_of(&second));

    // Seeded changes: insertions, removals, revisions, and documents that change their section.
    let months = ["2026-09-22", "2026-09-03", "2026-08-14", "2026-07-30", "2025-12-01"];
    let titles = [
        "Abrechnung",
        "Bescheid",
        "Mahnung",
        "Police",
        "Quittung",
        "Ärztliche Bescheinigung",
    ];
    for seed in 0..40 {
        let mut generator = Generator(seed);
        let mut copy = ListedCopy::of_an_empty_archive();
        let mut held: Vec<usize> = Vec::new();
        let mut created = 0;
        let mut preceding = [copy.list(&by_date), copy.list(&by_title)];
        for step in 0..12 {
            for _ in 0..1 + generator.below(4) {
                let existing = generator.pick(&held).copied();
                let title = *generator.pick(&titles).unwrap();
                let date = *generator.pick(&months).unwrap();
                match (generator.below(10), existing) {
                    (0..=3, _) | (_, None) => {
                        created += 1;
                        held.push(created);
                        let document = if generator.chance(30) {
                            arriving(created)
                        } else {
                            letter(created, title, date)
                        };
                        copy.archive.put_document(document);
                    }
                    (4..=5, Some(number)) => {
                        held.retain(|held| *held != number);
                        copy.archive.delete_document(&document_identifier(number));
                    }
                    // An arriving document settles, a letter moves to another month, or only
                    // its title changes.
                    (_, Some(number)) => copy.archive.put_document(letter(number, title, date)),
                }
            }
            for (preceding, request) in preceding.iter_mut().zip([&by_date, &by_title]) {
                let following = copy.list(request);
                let expected_headings: Vec<usize> = rows_of(&following)
                    .into_iter()
                    .enumerate()
                    .filter_map(|(position, row)| matches!(row, ListingRow::Heading(_)).then_some(position))
                    .collect();
                assert_eq!(following.heading_positions(), expected_headings.as_slice());
                let difference = listing_difference(preceding, &following);
                assert_eq!(
                    applied(preceding, &following, &difference),
                    rows_of(&following),
                    "seed {seed}, step {step}, {request:?}: {difference:?}"
                );
                *preceding = following;
            }
        }
    }
}

/// Follows the replica until it has read the journal's end and every text.
fn settled(replica: &Replica, events: &Receiver<ReplicaEvent>, held_revision: u64) -> u64 {
    let mut revision = held_revision;
    loop {
        let status = status_after(replica, events, revision);
        revision = status.revision;
        if matches!(status.synchronization, SynchronizationState::Following { .. })
            && status.documents_awaiting_text == 0
        {
            return revision;
        }
    }
}

/// The rows of a search: a heading by its name, a document by its title, with the excerpt of
/// its text when the row shows one.
fn found(replica: &Replica, text: &str) -> Vec<String> {
    let request = ListingRequest::Search {
        scope: LibraryScope::AllDocuments,
        text: text.to_owned(),
    };
    let listing = replica.list_documents(&request, None).unwrap().listing;
    rows_of(&listing)
        .into_iter()
        .map(|row| match row {
            ListingRow::Heading(heading) => format!("{heading:?}"),
            ListingRow::Document(row) => match (row.title.unwrap(), row.passage) {
                (title, Some(RowPassage::Excerpt(excerpt))) => format!("{title}: {excerpt}"),
                (title, Some(RowPassage::Summary(_)) | None) => title,
            },
        })
        .collect()
}

#[test]
fn a_search_finds_german_paperwork_by_its_details_first_and_then_by_its_text() {
    let archive = Arc::new(ScriptedArchive::with_page_entries(250));
    let insurer = SenderIdentifier::parse(&identifier(2, 1)).unwrap();
    let utility = SenderIdentifier::parse(&identifier(2, 2)).unwrap();
    archive.put_sender(SenderRecord {
        identifier: insurer.clone(),
        name: "Nordlicht Assekuranz AG".to_owned(),
    });
    archive.put_sender(SenderRecord {
        identifier: utility.clone(),
        name: "Stadtwerke Talbrück".to_owned(),
    });
    let papers = [
        (
            1,
            "Haftpflichtversicherung Beitragsrechnung",
            "2026-01-15",
            Some(&insurer),
            "Sehr geehrter Herr Becker,\n\nfür das Jahr 2026 berechnen wir Ihnen den Beitrag von 72,09 EUR.",
        ),
        (
            2,
            "Hausratversicherung Nachtrag",
            "2025-11-03",
            Some(&insurer),
            "Der Nachtrag ersetzt die Police vom 1. März 2024.",
        ),
        (
            3,
            "Kündigung des Mietvertrags",
            "2026-03-02",
            None,
            "# Bestätigung\n\nSehr geehrte Frau Becker,\n\nwir bestätigen den Eingang Ihres Schreibens vom 27. Februar. \
             Die Versicherung des Gebäudes bleibt bis zur Übergabe der Wohnung bestehen, und die Kaution erhalten \
             Sie nach der Abnahme mit der letzten Nebenkostenabrechnung zurück.\n\nMit freundlichen Grüßen",
        ),
        (
            4,
            "Jahresabrechnung Strom",
            "2026-02-10",
            Some(&utility),
            "| Zähler | Stand |\n|---|---|\n| 1 EMH 0012 | 48.213 |\n\nIhr Zählerstand am 31.12.2025 betrug 48.213 kWh.",
        ),
    ];
    for (number, title, date, sender, text) in papers {
        archive.put_document(DocumentRecord {
            sender: sender.cloned(),
            ..letter(number, title, date)
        });
        archive.put_text(&document_identifier(number), text);
    }
    let directory = tempfile::tempdir().unwrap();
    let (replica, events) = start_replica(&archive, directory.path(), None);
    attach(&replica, &archive);
    let revision = settled(&replica, &events, 0);

    // The second half of a compound in a title, the newest first, then a word of a text with
    // the passage around it. "Stadtwerke" holds no "versicherung", so the fourth is not found.
    assert_eq!(
        found(&replica, "versicherung"),
        [
            "DetailsMatched",
            "Haftpflichtversicherung Beitragsrechnung",
            "Hausratversicherung Nachtrag",
            "TextMatched",
            "Kündigung des Mietvertrags: Die Versicherung des Gebäudes bleibt bis zur Übergabe der Wohnung \
             bestehen, und die Kaution erhalten Sie nach der Abnahme mit der letzten Nebenkostenabrechnung …"
        ]
    );
    // An umlaut typed without its dots.
    assert_eq!(
        found(&replica, "kundigung"),
        ["DetailsMatched", "Kündigung des Mietvertrags"]
    );
    // The beginning of a word of a text, whose excerpt leaves the table's marks out.
    assert_eq!(
        found(&replica, "zählerst"),
        [
            "TextMatched",
            "Jahresabrechnung Strom: Ihr Zählerstand am 31.12.2025 betrug 48.213 kWh."
        ]
    );
    // Every term must be found, each in the details or in the text. The passage opens with a
    // whole word, because its sentence begins further back than a passage reaches.
    assert_eq!(
        found(&replica, "nordlicht 72,09"),
        [
            "TextMatched",
            "Haftpflichtversicherung Beitragsrechnung: … Jahr 2026 berechnen wir Ihnen den Beitrag von 72,09 EUR."
        ]
    );

    assert_eq!(
        found(&replica, "stadtwerke"),
        ["DetailsMatched", "Jahresabrechnung Strom"]
    );
    archive.put_sender(SenderRecord {
        identifier: utility,
        name: "Talbrücker Energie GmbH".to_owned(),
    });
    replica.wake(WakeReason::PersonRequested);
    let revision = settled(&replica, &events, revision);
    assert_eq!(found(&replica, "stadtwerke"), [] as [&str; 0]);
    assert_eq!(found(&replica, "energie"), ["DetailsMatched", "Jahresabrechnung Strom"]);

    // Search coverage for document_date, spaced IBANs, 1-2 char detail terms, quoted/punctuated
    // terms, thousands-grouped numbers, umlaut/sharp-s variants, NUL safety, NFD & multi-part
    // excerpts, and clearing old text hits when original_sha256 changes.
    let practice = SenderIdentifier::parse(&identifier(2, 3)).unwrap();
    archive.put_sender(SenderRecord {
        identifier: practice.clone(),
        name: "Kinderarztpraxis Müller".to_owned(),
    });
    archive.put_document(DocumentRecord {
        sender: Some(practice),
        fields: BTreeMap::from([
            (
                "due_date".to_owned(),
                ExtractedField {
                    value: FieldValue::Date(CalendarDate::parse("2026-04-01").unwrap()),
                    confidence: None,
                },
            ),
            (
                "amount".to_owned(),
                ExtractedField {
                    value: FieldValue::Number(1234.50),
                    confidence: None,
                },
            ),
            (
                "iban".to_owned(),
                ExtractedField {
                    value: FieldValue::Text("DE89370400440532013000".to_owned()),
                    confidence: None,
                },
            ),
            (
                "address".to_owned(),
                ExtractedField {
                    value: FieldValue::Text("Hauptstraße 5".to_owned()),
                    confidence: None,
                },
            ),
        ]),
        ..letter(5, "O2 Mobilfunk Anschluss", "2026-03-15")
    });
    let digest_a = content_of(b"version-a");
    let digest_b = content_of(b"version-b");
    archive.put_document(DocumentRecord {
        original: Some(digest_a),
        ..letter(6, "Schreiben ohne Umlaut", "2026-03-10")
    });
    archive.put_text(
        &document_identifier(6),
        "Ku\u{0308}ndigung zum Monatsende. Nach 72 Tage folgt ein langer Absatz bis nach der \
         achtundvierzigsten Stelle fuer 72,09 EUR als eigener Auszug.",
    );
    replica.wake(WakeReason::PersonRequested);
    let revision = settled(&replica, &events, revision);

    for query in [
        "15.03.2026",
        "2026-03-15",
        "01.04.2026",
        "2026-04-01",
        "DE89 3704 0044 0532 0130 00",
        "O2 Mobilfunk",
        "Hauptstraße 5",
        "Hauptstrasse",
        "\"Müller\"",
        "Müller,",
        "1.234,50",
        "Mueller",
        "Mobil\0funk",
    ] {
        assert_eq!(
            found(&replica, query),
            ["DetailsMatched", "O2 Mobilfunk Anschluss"],
            "query {query:?}"
        );
    }
    assert_eq!(found(&replica, "Rech\0nung"), found(&replica, "Rechnung"));
    assert_eq!(found(&replica, "a\0b"), found(&replica, "ab"));
    assert_eq!(found(&replica, "a\0"), found(&replica, "a"));
    let kuendigung = found(&replica, "Ku\u{0308}ndigung");
    assert_eq!(kuendigung[0], "DetailsMatched");
    assert!(
        kuendigung
            .iter()
            .any(|row| row.starts_with("Schreiben ohne Umlaut:") && row.contains("Ku\u{0308}ndigung")),
        "{kuendigung:?}"
    );
    let decimal_hits = found(&replica, "72,09");
    assert_eq!(decimal_hits[0], "TextMatched");
    assert!(
        decimal_hits
            .iter()
            .any(|row| row.starts_with("Schreiben ohne Umlaut:") && row.contains("72,09 EUR")),
        "{decimal_hits:?}"
    );
    assert_eq!(
        found(&replica, "Monatsende"),
        [
            "TextMatched",
            "Schreiben ohne Umlaut: Ku\u{0308}ndigung zum Monatsende. Nach 72 Tage folgt ein langer Absatz bis nach \
             der achtundvierzigsten Stelle fuer 72,09 EUR als eigener Auszug."
        ]
    );

    archive.put_document(DocumentRecord {
        original: Some(digest_b),
        ..letter(6, "Schreiben ohne Umlaut", "2026-03-10")
    });
    archive.put_text(&document_identifier(6), "Neuer Inhalt ohne das alte Wort.");
    replica.wake(WakeReason::PersonRequested);
    settled(&replica, &events, revision);
    assert_eq!(found(&replica, "Monatsende"), [] as [&str; 0]);
    let replaced = found(&replica, "Neuer");
    assert!(replaced.iter().any(|row| row.contains("Neuer Inhalt")), "{replaced:?}");
}

fn content_of(bytes: &[u8]) -> ContentDigest {
    ContentDigest::from_bytes(Sha256::digest(bytes).into())
}

/// The names of the files in a directory, in their order, with the bytes they hold together.
fn files_in(directory: &Path) -> (Vec<String>, u64) {
    let mut names = Vec::new();
    let mut bytes = 0;
    for entry in std::fs::read_dir(directory).unwrap() {
        let entry = entry.unwrap();
        names.push(entry.file_name().into_string().unwrap());
        bytes += entry.metadata().unwrap().len();
    }
    names.sort();
    (names, bytes)
}

#[test]
fn an_original_is_downloaded_once_kept_only_when_its_bytes_are_its_content_and_evicted_by_age() {
    let archive = Arc::new(ScriptedArchive::with_page_entries(250));
    let scan = |number: u8| vec![number; 400];
    for number in 1..=5_u8 {
        // The record of the fifth names a content that its file does not hold.
        let named = if number == 5 { scan(0) } else { scan(number) };
        archive.put_document(DocumentRecord {
            original: Some(content_of(&named)),
            ..letter(usize::from(number), "Scan", "2026-09-22")
        });
        archive.put_original(&document_identifier(usize::from(number)), &scan(number));
    }
    let directory = tempfile::tempdir().unwrap();
    let originals = directory.path().join("representations").join("originals");
    let name = |number: u8| format!("{}.pdf", content_of(&scan(number)).hexadecimal());
    let (replica, events) = start_replica(&archive, directory.path(), Some(1_000));
    attach(&replica, &archive);
    settled(&replica, &events, 0);

    assert_eq!(replica.kept_original(&document_identifier(1)), Ok(None));
    let first: PathBuf = replica.original(&document_identifier(1)).unwrap();
    assert_eq!(first, originals.join(name(1)));
    assert_eq!(std::fs::read(&first).unwrap(), scan(1));
    assert_eq!(replica.original(&document_identifier(1)), Ok(first.clone()));
    assert_eq!(replica.kept_original(&document_identifier(1)), Ok(Some(first.clone())));
    assert_eq!(archive.original_downloads(), 1);

    assert_eq!(
        replica.original(&document_identifier(5)),
        Err(RepresentationRefusal::ContentDiffers)
    );
    assert_eq!(files_in(&originals), (vec![name(1)], 400));

    // The first original was read two minutes ago. The third brings the originals above their
    // 1,000 bytes, so the first goes.
    std::fs::File::open(&first)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(120))
        .unwrap();
    replica.original(&document_identifier(2)).unwrap();
    replica.original(&document_identifier(3)).unwrap();
    let mut kept = vec![name(2), name(3)];
    kept.sort();
    assert_eq!(files_in(&originals), (kept.clone(), 800));

    // The fourth does so again, but the others were read within the last minute and stay.
    replica.original(&document_identifier(4)).unwrap();
    kept.push(name(4));
    kept.sort();
    assert_eq!(files_in(&originals), (kept, 1_200));

    // After restart, aged excess files are evicted on open while a file with a future
    // modification time (clock step-back) is treated as recent and kept.
    replica.shutdown();
    std::fs::File::open(originals.join(name(2)))
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(120))
        .unwrap();
    std::fs::File::open(originals.join(name(4)))
        .unwrap()
        .set_modified(SystemTime::now() + Duration::from_secs(3_600))
        .unwrap();
    let (reopened, _) = start_replica(&archive, directory.path(), Some(1_000));
    reopened.shutdown();
    let mut after_open = vec![name(3), name(4)];
    after_open.sort();
    assert_eq!(files_in(&originals), (after_open, 800));
}

#[test]
fn a_person_sees_the_space_originals_hold_lowers_their_limit_and_removes_them() {
    let archive = Arc::new(ScriptedArchive::with_page_entries(250));
    let scan = |number: u8| vec![number; 400];
    for number in 1..=3_u8 {
        archive.put_document(DocumentRecord {
            original: Some(content_of(&scan(number))),
            ..letter(usize::from(number), "Scan", "2026-09-22")
        });
        archive.put_original(&document_identifier(usize::from(number)), &scan(number));
    }
    let directory = tempfile::tempdir().unwrap();
    let originals = directory.path().join("representations").join("originals");
    let (replica, events) = start_replica(&archive, directory.path(), None);
    attach(&replica, &archive);
    settled(&replica, &events, 0);

    for number in 1..=3 {
        replica.original(&document_identifier(number)).unwrap();
    }
    assert_eq!(replica.original_storage(), (1_200, None));

    // Two were read long ago, so a limit of 500 bytes keeps only the one read last.
    for number in 1..=2_u8 {
        let name = format!("{}.pdf", content_of(&scan(number)).hexadecimal());
        std::fs::File::open(originals.join(name))
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(120 * u64::from(4 - number)))
            .unwrap();
    }
    replica.set_original_storage_limit(Some(500));
    assert_eq!(replica.original_storage(), (400, Some(500)));

    // The one handed out a moment ago may be about to open elsewhere, so it stays until it ages.
    replica.remove_downloaded_originals();
    assert_eq!(replica.original_storage(), (400, Some(500)));
    let third = format!("{}.pdf", content_of(&scan(3)).hexadecimal());
    std::fs::File::open(originals.join(third))
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(120))
        .unwrap();
    replica.remove_downloaded_originals();
    assert_eq!(replica.original_storage(), (0, Some(500)));
    assert_eq!(files_in(&originals), (vec![], 0));
    let downloads = archive.original_downloads();
    replica.original(&document_identifier(3)).unwrap();
    assert_eq!(archive.original_downloads(), downloads + 1);
    replica.shutdown();
}
