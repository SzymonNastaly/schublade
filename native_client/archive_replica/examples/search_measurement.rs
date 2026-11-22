//! Measures the copy's search on synthetic German paperwork: 5,000 documents with about 8,000
//! bytes of text each, built from compounds, umlauts, amounts, and dates. It prints the time to
//! write a page of 250 documents and their texts, the size of the file, and the time of listings
//! and searches as a window asks them, each as the median and the range of its runs.
//!
//! `cargo run --release -p archive_replica --example search_measurement`

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use archive_access::{ArchiveAuthorization, DocumentIdentifier, PermissionLevel, Timestamp};
use archive_replica::replica_records::{
    CalendarDate, CategoryIdentifier, CategoryRecord, DocumentCondition, DocumentRecord, ExtractedField, FieldValue,
    JournalCursor, JournalPage, PersonAssignment, SenderIdentifier, SenderRecord, TagIdentifier, TagRecord,
};
use archive_replica::{
    LibraryScope, ListingOrder, ListingRequest, ListingRow, ReplicaQueries, ReplicaStore, RetrievedText, RowPassage,
};

const DOCUMENTS: usize = 5_000;
const DOCUMENTS_PER_PAGE: usize = 250;
const TEXTS_PER_TRANSACTION: usize = 25;
const WORDS_PER_TEXT: usize = 1_000;
const RUNS: usize = 9;
const NOW: Timestamp = Timestamp(1_790_000_000_000);

const FUNCTION_WORDS: &[&str] = &[
    "und", "der", "die", "das", "Sie", "Ihre", "wir", "bitte", "für", "mit", "von", "zum", "zur", "den", "dem", "ein",
    "eine", "ist", "sind", "wird", "werden", "nicht", "auch", "bei", "nach", "über", "unter", "bis", "aus", "auf",
    "in", "im", "an", "am", "oder", "dass", "wie", "als", "zu", "es", "haben", "hat", "kann", "können", "uns",
    "unsere", "Ihnen", "Ihrer", "diesem", "dieser", "folgende", "gemäß", "sowie", "jedoch", "bereits", "weitere",
    "vom", "des", "fällig", "gültig",
];
const COMPOUND_BEGINNINGS: &[&str] = &[
    "Haftpflicht",
    "Hausrat",
    "Strom",
    "Gas",
    "Nebenkosten",
    "Steuer",
    "Einkommen",
    "Lohn",
    "Miet",
    "Kranken",
    "Renten",
    "Unfall",
    "Rechtsschutz",
    "Kfz",
    "Wohn",
    "Grund",
    "Betriebs",
    "Heiz",
    "Wasser",
    "Abwasser",
    "Müll",
    "Rundfunk",
    "Telefon",
    "Internet",
    "Mobilfunk",
    "Konto",
    "Depot",
    "Kredit",
    "Darlehens",
    "Bauspar",
    "Lebens",
    "Zahn",
    "Arzt",
    "Pflege",
    "Kinder",
    "Eltern",
    "Schul",
    "Studien",
    "Arbeits",
    "Dienst",
    "Reise",
    "Fahrzeug",
    "Führerschein",
    "Melde",
    "Geburts",
    "Heirats",
    "Erb",
    "Schenkungs",
    "Spenden",
    "Mitglieds",
    "Vereins",
    "Jahres",
    "Monats",
    "Quartals",
    "Schluss",
    "Zwischen",
    "Voraus",
    "Nach",
    "Rück",
    "Gut",
];
const COMPOUND_ENDINGS: &[&str] = &[
    "versicherung",
    "rechnung",
    "abrechnung",
    "bescheid",
    "vertrag",
    "bescheinigung",
    "kündigung",
    "mahnung",
    "zahlung",
    "erstattung",
    "beitrag",
    "police",
    "nachweis",
    "auszug",
    "mitteilung",
    "bestätigung",
    "erklärung",
    "vollmacht",
    "antrag",
    "änderung",
    "gebühr",
    "kosten",
    "steuer",
    "zulage",
    "pauschale",
    "quittung",
    "beleg",
    "übersicht",
    "aufstellung",
    "erinnerung",
    "anpassung",
    "verlängerung",
    "nummer",
    "datum",
    "betrag",
    "summe",
    "saldo",
    "anteil",
    "vorauszahlung",
    "nachzahlung",
    "guthaben",
    "forderung",
    "leistung",
    "lieferung",
    "verbrauch",
    "zählerstand",
    "tarif",
    "frist",
    "anlage",
    "schreiben",
];
const SENDERS: &[&str] = &[
    "Stadtwerke Talbrück",
    "Nordlicht Assekuranz AG",
    "Finanzamt Talbrück",
    "Hausverwaltung Becker",
    "Zahnarztpraxis Dr. Wiśniewska",
    "Sparkasse Talbrück",
    "Techniker Krankenkasse",
    "Deutsche Rentenversicherung",
    "Nordkabel Kommunikation GmbH",
    "Baumarkt Öztürk",
    "Autohaus Lindqvist",
    "Gemeinde Talbrück",
    "Kinderarztpraxis Müller",
    "Energieversorgung Süd",
    "Wohnungsbaugenossenschaft Aue",
    "Musikschule Talbrück",
];
const CATEGORIES: &[&str] = &[
    "Rechnung",
    "Vertrag",
    "Steuer",
    "Versicherung",
    "Kontoauszug",
    "Quittung",
    "Bescheinigung",
    "Schreiben",
];
const TAGS: &[&str] = &[
    "strom",
    "wohnung",
    "auto",
    "steuer 2025",
    "kinder",
    "gesundheit",
    "arbeit",
    "bank",
];

/// SplitMix64: the same documents on every machine.
struct Generator(u64);

impl Generator {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut mixed = self.0;
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        mixed ^ (mixed >> 31)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound as u64) as usize
    }

    fn pick<'words>(&mut self, words: &[&'words str]) -> &'words str {
        words[self.below(words.len())]
    }

    /// One of the 3,000 compounds. The square makes a few of them common and most of them rare,
    /// as the words of real letters are.
    fn compound(&mut self) -> String {
        let all = COMPOUND_BEGINNINGS.len() * COMPOUND_ENDINGS.len();
        let common = self.below(all) * self.below(all) / all;
        format!(
            "{}{}",
            COMPOUND_BEGINNINGS[common % COMPOUND_BEGINNINGS.len()],
            COMPOUND_ENDINGS[common / COMPOUND_BEGINNINGS.len()]
        )
    }

    fn text(&mut self, number: usize) -> String {
        let mut text = String::from("# Schreiben\n\nSehr geehrte Damen und Herren,\n\n");
        for word in 0..WORDS_PER_TEXT {
            match self.below(100) {
                0..55 => text.push_str(self.pick(FUNCTION_WORDS)),
                55..85 => text.push_str(&self.compound()),
                85..93 => {
                    let ending = self.pick(COMPOUND_ENDINGS);
                    text.extend(ending.chars().take(1).flat_map(char::to_uppercase));
                    text.push_str(&ending[ending.chars().next().map_or(0, char::len_utf8)..]);
                }
                93..96 => text.push_str(&format!(
                    "{}.{:03},{:02}",
                    self.below(9),
                    self.below(1_000),
                    self.below(100)
                )),
                96..98 => text.push_str(&format!(
                    "{:02}.{:02}.{}",
                    1 + self.below(28),
                    1 + self.below(12),
                    2018 + self.below(9)
                )),
                _ => text.push_str(&format!(
                    "NK-{}-{:05}",
                    2018 + self.below(9),
                    number * 7 + self.below(7)
                )),
            }
            text.push_str(if word % 14 == 13 { ".\n" } else { " " });
        }
        text.push_str("\nMit freundlichen Grüßen\n");
        text
    }
}

fn identifier(kind: u8, number: usize) -> String {
    format!("{kind:08x}-0000-4000-8000-{number:012x}")
}

fn document(generator: &mut Generator, number: usize) -> DocumentRecord {
    let (year, month) = (2018 + generator.below(9), 1 + generator.below(12));
    let mut fields = BTreeMap::new();
    let mut field = |key: &str, value: FieldValue| {
        fields.insert(
            key.to_owned(),
            ExtractedField {
                value,
                confidence: Some(0.9),
            },
        )
    };
    field("amount", FieldValue::Number(generator.below(200_000) as f64 / 100.0));
    field("currency", FieldValue::Text("EUR".to_owned()));
    field(
        "due_date",
        FieldValue::Date(CalendarDate::parse(&format!("{year}-{month:02}-28")).unwrap()),
    );
    field("iban", FieldValue::Text(format!("DE2893024580{number:010}")));
    field("invoice_number", FieldValue::Text(format!("RE-{year}-{number:05}")));
    let summary: Vec<String> = (0..25)
        .map(|word| {
            if word % 3 == 0 {
                generator.compound()
            } else {
                generator.pick(FUNCTION_WORDS).to_owned()
            }
        })
        .collect();
    DocumentRecord {
        identifier: DocumentIdentifier::parse(&identifier(5, number)).unwrap(),
        condition: DocumentCondition::Archived,
        title: Some(format!("{} {month:02}/{year}", generator.compound())),
        document_date: CalendarDate::parse(&format!("{year}-{month:02}-15")),
        sender: SenderIdentifier::parse(&identifier(2, generator.below(SENDERS.len()))),
        category: CategoryIdentifier::parse(&identifier(3, generator.below(CATEGORIES.len()))),
        person: PersonAssignment::Household,
        summary: Some(summary.join(" ")),
        media_type: "application/pdf".to_owned(),
        byte_size: 184_233,
        page_count: Some(2),
        original: None,
        arrived_at: Timestamp(NOW.0 - 86_400_000 * (DOCUMENTS - number) as i64),
        tags: (0..generator.below(4))
            .filter_map(|_| TagIdentifier::parse(&identifier(4, generator.below(TAGS.len()))))
            .collect::<BTreeSet<TagIdentifier>>(),
        fields,
    }
}

/// The median and the range of the runs, in milliseconds.
fn summary(mut runs: Vec<Duration>) -> String {
    runs.sort();
    let milliseconds = |duration: Duration| duration.as_secs_f64() * 1_000.0;
    format!(
        "{:8.2} ms  ({:.2} to {:.2}, {} runs)",
        milliseconds(runs[runs.len() / 2]),
        milliseconds(runs[0]),
        milliseconds(runs[runs.len() - 1]),
        runs.len()
    )
}

fn main() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("replica.sqlite");
    let mut store = ReplicaStore::open(&path).unwrap();
    store
        .attach(
            "https://archive.example.org",
            &ArchiveAuthorization {
                journal_identifier: "0".repeat(32),
                token_description: "Measurement".to_owned(),
                permission_level: PermissionLevel::Read,
                restricted: false,
                scope_digest: "0".repeat(64),
            },
            "measurement",
        )
        .unwrap();

    let mut generator = Generator(0x5C4B_1ADE);
    let mut texts = Vec::with_capacity(DOCUMENTS);
    let mut page_runs = Vec::new();
    let mut cursor = None;
    for page_number in 0..DOCUMENTS / DOCUMENTS_PER_PAGE {
        let documents: Vec<DocumentRecord> = (0..DOCUMENTS_PER_PAGE)
            .map(|index| document(&mut generator, page_number * DOCUMENTS_PER_PAGE + index + 1))
            .collect();
        texts.extend(documents.iter().map(|document| RetrievedText {
            document: document.identifier.clone(),
            original: None,
            markdown: None,
        }));
        // As the archive sends a page: with every record its documents refer to.
        let page = JournalPage {
            cursor: JournalCursor::parse(&format!("measurement.{page_number}")).unwrap(),
            complete: false,
            remaining_entries: 0,
            members: Vec::new(),
            senders: (0..SENDERS.len())
                .map(|number| SenderRecord {
                    identifier: SenderIdentifier::parse(&identifier(2, number)).unwrap(),
                    name: SENDERS[number].to_owned(),
                })
                .collect(),
            categories: (0..CATEGORIES.len())
                .map(|number| CategoryRecord {
                    identifier: CategoryIdentifier::parse(&identifier(3, number)).unwrap(),
                    name: CATEGORIES[number].to_owned(),
                    expected_fields: vec!["amount".to_owned(), "due_date".to_owned()],
                })
                .collect(),
            tags: (0..TAGS.len())
                .map(|number| TagRecord {
                    identifier: TagIdentifier::parse(&identifier(4, number)).unwrap(),
                    name: TAGS[number].to_owned(),
                    color_hex: None,
                })
                .collect(),
            documents,
            removed: Vec::new(),
        };
        let started = Instant::now();
        store.apply_page(cursor.as_ref(), &page, NOW).unwrap();
        page_runs.push(started.elapsed());
        cursor = Some(page.cursor);
    }
    let after_records = std::fs::metadata(&path).unwrap().len()
        + std::fs::metadata(path.with_extension("sqlite-wal")).map_or(0, |wal| wal.len());

    let mut text_bytes = 0;
    let mut text_runs = Vec::new();
    for (number, text) in texts.iter_mut().enumerate() {
        let markdown = generator.text(number + 1);
        text_bytes += markdown.len();
        text.markdown = Some(markdown);
    }
    for transaction in texts.chunks(TEXTS_PER_TRANSACTION) {
        let started = Instant::now();
        store.record_texts(transaction).unwrap();
        text_runs.push(started.elapsed());
    }
    let text_total: Duration = text_runs.iter().sum();
    drop(store);
    let file_bytes = std::fs::metadata(&path).unwrap().len();

    println!(
        "{DOCUMENTS} documents, {:.1} kB of text each",
        text_bytes as f64 / DOCUMENTS as f64 / 1_000.0
    );
    println!(
        "a page of {DOCUMENTS_PER_PAGE} documents, records and detail search rows   {}",
        summary(page_runs)
    );
    println!(
        "{TEXTS_PER_TRANSACTION} texts in one transaction, stored and indexed            {}",
        summary(text_runs)
    );
    println!(
        "the texts of {DOCUMENTS_PER_PAGE} documents                                {:8.2} ms  (mean)",
        text_total.as_secs_f64() * 1_000.0 * DOCUMENTS_PER_PAGE as f64 / DOCUMENTS as f64
    );
    println!(
        "the file with the records and the detail index, with its log     {:6.1} MB",
        after_records as f64 / 1e6
    );
    println!(
        "the file with the texts and the text index, log checkpointed     {:6.1} MB",
        file_bytes as f64 / 1e6
    );

    let mut queries = ReplicaQueries::open(&path).unwrap();
    let mut measure = |label: &str, request: ListingRequest| -> Duration {
        let mut runs = Vec::with_capacity(RUNS);
        let mut shown = (0, 0, 0);
        for _ in 0..RUNS {
            let started = Instant::now();
            let listing = queries.list_documents(&request, NOW).unwrap();
            runs.push(started.elapsed());
            let rows = listing.rows(0, listing.row_count());
            let excerpts = rows
                .iter()
                .filter(|row| matches!(row, ListingRow::Document(row) if matches!(row.passage, Some(RowPassage::Excerpt(_)))))
                .count();
            shown = (
                listing.document_count(),
                listing.row_count() - listing.document_count(),
                excerpts,
            );
        }
        runs.sort();
        let median = runs[RUNS / 2];
        println!(
            "{label:<34} {:>5} documents, {:>2} headings, {:>5} excerpts   {}",
            shown.0,
            shown.1,
            shown.2,
            summary(runs)
        );
        median
    };
    let search = |text: &str| ListingRequest::Search {
        scope: LibraryScope::AllDocuments,
        text: text.to_owned(),
    };
    measure(
        "every document by date",
        ListingRequest::Browse {
            scope: LibraryScope::AllDocuments,
            order: ListingOrder::DocumentDate,
        },
    );
    measure(
        "every document by title",
        ListingRequest::Browse {
            scope: LibraryScope::AllDocuments,
            order: ListingOrder::Title,
        },
    );
    measure("an IBAN (one document)", search("DE28930245800000000417"));
    measure("\"gutschreiben\" (the rarest compound)", search("gutschreiben"));
    measure("\"talbrück kündigung\"", search("talbrück kündigung"));
    measure("\"versicherung\" (most documents)", search("versicherung"));
    measure("\"geehrte\" (opens every text)", search("geehrte"));
    measure("\"grüßen\" (closes every text)", search("grüßen"));
    let typed = "versicherung";
    let mut keystrokes = Duration::ZERO;
    for length in 1..=typed.len() {
        keystrokes += measure(&format!("typed: \"{}\"", &typed[..length]), search(&typed[..length]));
    }
    println!(
        "the twelve keystrokes of \"{typed}\" together, by their medians   {:8.2} ms",
        keystrokes.as_secs_f64() * 1_000.0
    );
}
