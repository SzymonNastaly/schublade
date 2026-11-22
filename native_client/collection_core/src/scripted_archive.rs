//! An in-process archive with scripted answers and failures, for scenario tests that run in
//! milliseconds. It keeps the server's rules: one document per content, `deleted` for a content
//! whose document was deleted, and 409 for a PUT of it.

use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;

use crate::archive_client::ArchiveClient;
use crate::archive_connection::ArchiveCondition;
use crate::content_synchronization::{LookupAnswer, SubmissionAuthorization, SubmissionOutcome};
use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus};
use crate::file_system_observation::VerifiedContent;

#[derive(Debug, Default)]
struct Script {
    contents: BTreeMap<ContentDigest, LookupAnswer>,
    documents: BTreeMap<DocumentIdentifier, DocumentStatus>,
    /// Each request takes the next condition instead of answering, until the queue is empty.
    conditions: VecDeque<ArchiveCondition>,
    /// The next lookup of a digest answers this instead of the archive's record, once per entry.
    lookup_overrides: BTreeMap<ContentDigest, VecDeque<LookupAnswer>>,
    lookups: Vec<Vec<ContentDigest>>,
    submissions: Vec<ContentDigest>,
    status_reads: Vec<DocumentIdentifier>,
}

#[derive(Debug, Default)]
pub struct ScriptedArchive {
    script: Mutex<Script>,
}

impl ScriptedArchive {
    pub fn new() -> ScriptedArchive {
        ScriptedArchive::default()
    }

    fn script(&self) -> std::sync::MutexGuard<'_, Script> {
        self.script.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The archive holds this content in this document.
    pub fn hold(&self, digest: ContentDigest, document: DocumentIdentifier, status: DocumentStatus) {
        let mut script = self.script();
        script.contents.insert(digest, LookupAnswer::Present(document.clone()));
        script.documents.insert(document, status);
    }

    /// The owner deleted the document that held this content.
    pub fn delete(&self, digest: &ContentDigest) {
        let mut script = self.script();
        if let Some(LookupAnswer::Present(document)) = script.contents.insert(*digest, LookupAnswer::Deleted) {
            script.documents.remove(&document);
        }
    }

    pub fn set_document_status(&self, document: &DocumentIdentifier, status: DocumentStatus) {
        self.script().documents.insert(document.clone(), status);
    }

    /// The next request answers with this condition instead of its answer.
    pub fn fail_next(&self, condition: ArchiveCondition) {
        self.script().conditions.push_back(condition);
    }

    /// The next lookup of this digest answers as given, whatever the archive records: the
    /// window in which another device uploaded, or the owner deleted, between lookup and PUT.
    pub fn answer_next_lookup(&self, digest: ContentDigest, answer: LookupAnswer) {
        self.script()
            .lookup_overrides
            .entry(digest)
            .or_default()
            .push_back(answer);
    }

    /// Whether the archive holds a document for this content.
    pub fn holds(&self, digest: &ContentDigest) -> bool {
        matches!(self.script().contents.get(digest), Some(LookupAnswer::Present(_)))
    }

    pub fn submission_count(&self, digest: &ContentDigest) -> usize {
        self.script()
            .submissions
            .iter()
            .filter(|submitted| *submitted == digest)
            .count()
    }

    pub fn lookups(&self) -> Vec<Vec<ContentDigest>> {
        self.script().lookups.clone()
    }

    pub fn status_reads(&self) -> Vec<DocumentIdentifier> {
        self.script().status_reads.clone()
    }

    /// A deterministic identifier per content, so a scenario can name the document it expects.
    pub fn document_of(digest: &ContentDigest) -> DocumentIdentifier {
        let hexadecimal = digest.hexadecimal();
        DocumentIdentifier::parse(&format!(
            "{}-{}-4{}-8{}-{}",
            &hexadecimal[..8],
            &hexadecimal[8..12],
            &hexadecimal[13..16],
            &hexadecimal[17..20],
            &hexadecimal[20..32]
        ))
        .unwrap_or_else(|| unreachable!("the groups are lowercase hexadecimal of the right lengths"))
    }
}

impl ArchiveClient for ScriptedArchive {
    fn look_up(&self, digests: &[ContentDigest]) -> Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition> {
        let mut script = self.script();
        script.lookups.push(digests.to_vec());
        if let Some(condition) = script.conditions.pop_front() {
            return Err(condition);
        }
        let mut answers = Vec::with_capacity(digests.len());
        for digest in digests {
            let overridden = script.lookup_overrides.get_mut(digest).and_then(VecDeque::pop_front);
            let answer =
                overridden.unwrap_or_else(|| script.contents.get(digest).cloned().unwrap_or(LookupAnswer::Absent));
            answers.push((*digest, answer));
        }
        Ok(answers)
    }

    fn submit(
        &self,
        authorization: SubmissionAuthorization,
        content: VerifiedContent,
    ) -> Result<SubmissionOutcome, ArchiveCondition> {
        let digest = authorization.digest();
        assert_eq!(
            digest,
            content.digest(),
            "a submission's authorization and content must name the same digest"
        );
        let mut script = self.script();
        script.submissions.push(digest);
        if let Some(condition) = script.conditions.pop_front() {
            return Err(condition);
        }
        Ok(match script.contents.get(&digest).cloned() {
            Some(LookupAnswer::Deleted) => SubmissionOutcome::Deleted,
            Some(LookupAnswer::Present(document)) => {
                let status = script
                    .documents
                    .get(&document)
                    .cloned()
                    .unwrap_or(DocumentStatus::Processing);
                SubmissionOutcome::AlreadyHeld { document, status }
            }
            Some(LookupAnswer::Absent) | None => {
                let document = ScriptedArchive::document_of(&digest);
                script.contents.insert(digest, LookupAnswer::Present(document.clone()));
                script.documents.insert(document.clone(), DocumentStatus::Processing);
                SubmissionOutcome::Accepted {
                    document,
                    status: DocumentStatus::Processing,
                }
            }
        })
    }

    fn read_document_status(&self, document: &DocumentIdentifier) -> Result<Option<DocumentStatus>, ArchiveCondition> {
        let mut script = self.script();
        script.status_reads.push(document.clone());
        if let Some(condition) = script.conditions.pop_front() {
            return Err(condition);
        }
        Ok(script.documents.get(document).cloned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content_synchronization::{ArchiveStanding, ContentRecord, SubmissionFailures, authorize_submission};
    use crate::domain_types::{Timestamp, TimingPolicy};

    fn authorization(digest: ContentDigest) -> SubmissionAuthorization {
        let record = ContentRecord {
            digest,
            standing: ArchiveStanding::Absent {
                looked_up_at: Timestamp(0),
                failures: SubmissionFailures::default(),
            },
        };
        authorize_submission(&record, Timestamp(1), &TimingPolicy::default()).unwrap()
    }

    #[test]
    fn the_scripted_archive_keeps_the_servers_rules() {
        let archive = ScriptedArchive::new();
        let content = VerifiedContent::from_bytes(b"%PDF-1.7 scripted".to_vec());
        let digest = content.digest();
        let other = ContentDigest::from_bytes([7; 32]);

        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Absent)]
        );
        let accepted = archive.submit(authorization(digest), content.clone()).unwrap();
        let document = ScriptedArchive::document_of(&digest);
        assert_eq!(
            accepted,
            SubmissionOutcome::Accepted {
                document: document.clone(),
                status: DocumentStatus::Processing
            }
        );
        assert_eq!(
            archive.look_up(&[digest, other]).unwrap(),
            vec![
                (digest, LookupAnswer::Present(document.clone())),
                (other, LookupAnswer::Absent)
            ]
        );
        archive.set_document_status(&document, DocumentStatus::Archived);
        assert_eq!(
            archive.submit(authorization(digest), content.clone()).unwrap(),
            SubmissionOutcome::AlreadyHeld {
                document: document.clone(),
                status: DocumentStatus::Archived
            }
        );
        assert_eq!(
            archive.read_document_status(&document).unwrap(),
            Some(DocumentStatus::Archived)
        );

        archive.delete(&digest);
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Deleted)]
        );
        assert_eq!(
            archive.submit(authorization(digest), content).unwrap(),
            SubmissionOutcome::Deleted
        );
        assert_eq!(archive.read_document_status(&document).unwrap(), None);

        archive.fail_next(ArchiveCondition::TimedOut);
        assert_eq!(archive.look_up(&[digest]), Err(ArchiveCondition::TimedOut));
        assert_eq!(archive.look_up(&[digest]).unwrap().len(), 1);
        assert_eq!(archive.submission_count(&digest), 3);
        assert_eq!(archive.lookups().len(), 5);

        archive.answer_next_lookup(digest, LookupAnswer::Absent);
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Absent)]
        );
        assert_eq!(
            archive.look_up(&[digest]).unwrap(),
            vec![(digest, LookupAnswer::Deleted)]
        );
        assert!(!archive.holds(&digest));
        let held = VerifiedContent::from_bytes(b"%PDF-1.7 held".to_vec());
        archive.submit(authorization(held.digest()), held.clone()).unwrap();
        assert!(archive.holds(&held.digest()));
        assert_eq!(archive.status_reads(), vec![document.clone(), document]);
    }
}
