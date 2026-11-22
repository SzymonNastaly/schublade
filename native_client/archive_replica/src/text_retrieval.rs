//! The retrieval of extracted texts: two lanes, threads that each read the texts of one
//! assignment from the archive and hand them to the coordinator, which writes them. A lane reads
//! and writes no state. What awaits its text is derived from the records, so an assignment that
//! is lost with its process is planned again.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};

use archive_access::{ArchiveCondition, ContentDigest, DocumentIdentifier};

use crate::archive_reader::ArchiveReader;
use crate::replica_coordinator::CoordinatorInput;

/// As many assignments as run at once.
pub(crate) const TEXT_LANES: usize = 2;

/// The texts one lane reads before it reports. Each report is one transaction and one content
/// revision, so a first fill of thousands of texts makes a list read itself again a few times a
/// second and not once per text.
pub(crate) const TEXTS_PER_ASSIGNMENT: usize = 25;

/// An archived document without its text, with the content the text will be retrieved for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AwaitedText {
    pub document: DocumentIdentifier,
    pub original: Option<ContentDigest>,
}

/// What the archive answered for the text of a document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetrievedText {
    pub document: DocumentIdentifier,
    /// The content the document showed when its text was requested.
    pub original: Option<ContentDigest>,
    /// `None` when the archive holds no text of the document.
    pub markdown: Option<String>,
}

pub(crate) struct TextAssignment {
    pub(crate) reader: Arc<dyn ArchiveReader>,
    pub(crate) documents: Vec<AwaitedText>,
}

/// The end of one assignment.
pub(crate) struct TextReport {
    /// Every document of the assignment, which is no longer in flight.
    pub(crate) assigned: Vec<DocumentIdentifier>,
    pub(crate) retrieved: Vec<RetrievedText>,
    /// The condition that ended the assignment before its last document.
    pub(crate) interruption: Option<ArchiveCondition>,
}

pub(crate) struct TextLanes {
    assignments: Sender<TextAssignment>,
}

impl TextLanes {
    /// Starts the lanes. They end with the coordinator, which holds the only sender of
    /// assignments.
    pub(crate) fn start(inbox: &Sender<CoordinatorInput>) -> TextLanes {
        let (assignments, assigned) = channel::<TextAssignment>();
        let assigned = Arc::new(Mutex::new(assigned));
        for lane in 0..TEXT_LANES {
            let assigned = Arc::clone(&assigned);
            let inbox = inbox.clone();
            std::thread::Builder::new()
                .name(format!("replica-text-{lane}"))
                .spawn(move || {
                    while let Some(assignment) = next_assignment(&assigned) {
                        if inbox
                            .send(CoordinatorInput::TextsRetrieved(retrieve(assignment)))
                            .is_err()
                        {
                            return;
                        }
                    }
                })
                .expect("the system starts a text lane");
        }
        TextLanes { assignments }
    }

    pub(crate) fn assign(&self, assignment: TextAssignment) {
        // The lanes outlive every assignment the coordinator sends.
        let _ = self.assignments.send(assignment);
    }
}

/// Holds the lock only while it waits, so the other lane takes the next assignment.
fn next_assignment(assigned: &Mutex<Receiver<TextAssignment>>) -> Option<TextAssignment> {
    assigned.lock().unwrap_or_else(PoisonError::into_inner).recv().ok()
}

fn retrieve(assignment: TextAssignment) -> TextReport {
    let mut report = TextReport {
        assigned: assignment
            .documents
            .iter()
            .map(|awaited| awaited.document.clone())
            .collect(),
        retrieved: Vec::new(),
        interruption: None,
    };
    for awaited in assignment.documents {
        match retrieve_text(assignment.reader.as_ref(), awaited) {
            Ok(retrieved) => report.retrieved.push(retrieved),
            Err(condition) => {
                report.interruption = Some(condition);
                break;
            }
        }
    }
    report
}

/// One request of a document's text. An answer this client cannot read counts as no text, so
/// that one document never holds back the texts of the documents older than it. Every other
/// condition says something of the archive and not of the document.
pub(crate) fn retrieve_text(
    reader: &dyn ArchiveReader,
    awaited: AwaitedText,
) -> Result<RetrievedText, ArchiveCondition> {
    let markdown = match reader.read_text(&awaited.document) {
        Ok(markdown) => markdown,
        Err(ArchiveCondition::ProtocolViolation { detail }) => {
            eprintln!(
                "replica: the text of {} is left out: {detail}",
                awaited.document.as_str()
            );
            None
        }
        Err(condition) => return Err(condition),
    };
    Ok(RetrievedText {
        document: awaited.document,
        original: awaited.original,
        markdown,
    })
}
