//! The content machine. A content is one exact byte sequence named by its SHA-256; its standing
//! says what the archive holds for it, as far as this collector knows. Resting states only:
//! "LookingUp" and "Submitting" are content reservations the coordinator holds in memory.

use std::time::Duration;

use crate::domain_types::{ContentDigest, DocumentIdentifier, DocumentStatus, Timestamp, TimingPolicy};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArchiveStanding {
    Unresolved,
    Absent {
        looked_up_at: Timestamp,
        failures: SubmissionFailures,
    },
    Present(PresentDocument),
    /// The owner deleted the document. Terminal: never looked up again, never submitted.
    Deleted,
    /// The archive refused the bytes for good. Terminal.
    Refused(RefusalReason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SubmissionFailures {
    pub count: u32,
    pub retry_not_before: Option<Timestamp>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PresentDocument {
    pub document: DocumentIdentifier,
    pub status: Option<DocumentStatus>,
    pub status_read_at: Option<Timestamp>,
    /// Set only when this collector's PUT answered 202. Feeds the recent receipts.
    pub received_at: Option<Timestamp>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub enum RefusalReason {
    TooLarge,
    UnacceptedKind,
}

/// One row of `contents`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContentRecord {
    pub digest: ContentDigest,
    pub standing: ArchiveStanding,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LookupAnswer {
    Absent,
    Present(DocumentIdentifier),
    Deleted,
}

/// The domain outcome of a PUT that the archive answered about the content itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmissionOutcome {
    /// 202: a new document.
    Accepted {
        document: DocumentIdentifier,
        status: DocumentStatus,
    },
    /// 200: the archive held the bytes already.
    AlreadyHeld {
        document: DocumentIdentifier,
        status: DocumentStatus,
    },
    /// 409: the owner deleted the document that held these bytes.
    Deleted,
    /// 413.
    TooLarge,
    /// 415.
    UnacceptedKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmissionFailure {
    /// 422: the body's digest differed from the path's. The bytes were verified locally, so this
    /// is corruption in transit; it is retried.
    DigestDisagreement,
    /// 500.
    ServerError,
    TimedOut,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ContentEvent {
    LookupAnswered {
        answer: LookupAnswer,
        at: Timestamp,
    },
    SubmissionAnswered {
        outcome: SubmissionOutcome,
        at: Timestamp,
    },
    SubmissionFailed {
        failure: SubmissionFailure,
        at: Timestamp,
    },
    /// `None` is a 404: the document no longer exists.
    DocumentStatusRead {
        status: Option<DocumentStatus>,
        at: Timestamp,
    },
}

/// The whole content machine.
///
/// Invariants:
/// - Deleted and Refused never change.
/// - Present changes only to Present (a status read) or to Deleted (a 404, or a lookup that says
///   deleted).
/// - A failure never leaves Absent and never resets `looked_up_at`.
/// - An answer for a standing it does not apply to leaves the standing as it is.
pub fn advance_content(current: &ArchiveStanding, event: ContentEvent, timing: &TimingPolicy) -> ArchiveStanding {
    use ArchiveStanding::{Absent, Deleted, Present, Refused, Unresolved};
    match (current, event) {
        (Deleted, _) => Deleted,
        (Refused(reason), _) => Refused(*reason),
        (Unresolved | Absent { .. }, ContentEvent::LookupAnswered { answer, at }) => match answer {
            LookupAnswer::Absent => Absent {
                looked_up_at: at,
                failures: failures_of(current),
            },
            LookupAnswer::Present(document) => Present(PresentDocument {
                document,
                status: None,
                status_read_at: None,
                received_at: None,
            }),
            LookupAnswer::Deleted => Deleted,
        },
        (
            Present(_),
            ContentEvent::LookupAnswered {
                answer: LookupAnswer::Deleted,
                ..
            },
        ) => Deleted,
        (Unresolved | Absent { .. }, ContentEvent::SubmissionAnswered { outcome, at }) => match outcome {
            SubmissionOutcome::Accepted { document, status } => Present(PresentDocument {
                document,
                status: Some(status),
                status_read_at: Some(at),
                received_at: Some(at),
            }),
            SubmissionOutcome::AlreadyHeld { document, status } => Present(PresentDocument {
                document,
                status: Some(status),
                status_read_at: Some(at),
                received_at: None,
            }),
            SubmissionOutcome::Deleted => Deleted,
            SubmissionOutcome::TooLarge => Refused(RefusalReason::TooLarge),
            SubmissionOutcome::UnacceptedKind => Refused(RefusalReason::UnacceptedKind),
        },
        (Absent { looked_up_at, failures }, ContentEvent::SubmissionFailed { at, .. }) => {
            let count = failures.count + 1;
            Absent {
                looked_up_at: *looked_up_at,
                failures: SubmissionFailures {
                    count,
                    retry_not_before: Some(at.after(submission_back_off(count, timing))),
                },
            }
        }
        (Present(document), ContentEvent::DocumentStatusRead { status, at }) => match status {
            Some(status) => Present(PresentDocument {
                status: Some(status),
                status_read_at: Some(at),
                ..document.clone()
            }),
            None => Deleted,
        },
        (current, _) => current.clone(),
    }
}

fn failures_of(standing: &ArchiveStanding) -> SubmissionFailures {
    match standing {
        ArchiveStanding::Absent { failures, .. } => *failures,
        _ => SubmissionFailures::default(),
    }
}

/// Permission for exactly one PUT of one content. Only `authorize_submission` constructs it, and
/// the archive client consumes it. A PUT of a Present, Deleted, Refused, or stale content
/// therefore does not compile.
#[derive(Debug, PartialEq, Eq)]
pub struct SubmissionAuthorization {
    digest: ContentDigest,
    looked_up_at: Timestamp,
}

impl SubmissionAuthorization {
    pub fn digest(&self) -> ContentDigest {
        self.digest
    }

    pub fn looked_up_at(&self) -> Timestamp {
        self.looked_up_at
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmissionHindrance {
    NotAbsent,
    BackingOff {
        until: Timestamp,
    },
    /// The planner puts the content into the next lookup batch instead.
    LookupStale,
}

pub fn authorize_submission(
    record: &ContentRecord,
    now: Timestamp,
    timing: &TimingPolicy,
) -> Result<SubmissionAuthorization, SubmissionHindrance> {
    let ArchiveStanding::Absent { looked_up_at, failures } = &record.standing else {
        return Err(SubmissionHindrance::NotAbsent);
    };
    if let Some(until) = failures.retry_not_before.filter(|until| *until > now) {
        return Err(SubmissionHindrance::BackingOff { until });
    }
    if now.elapsed_since(*looked_up_at) >= timing.lookup_validity {
        return Err(SubmissionHindrance::LookupStale);
    }
    Ok(SubmissionAuthorization {
        digest: record.digest,
        looked_up_at: *looked_up_at,
    })
}

/// The delay after the n-th consecutive failure, from `timing.submission_back_off`; the last
/// delay repeats.
pub fn submission_back_off(failures: u32, timing: &TimingPolicy) -> Duration {
    back_off_after(failures, timing.submission_back_off)
}

pub(crate) fn back_off_after(attempt: u32, delays: &[Duration]) -> Duration {
    let index = usize::try_from(attempt.saturating_sub(1)).unwrap_or(usize::MAX);
    delays
        .get(index.min(delays.len().saturating_sub(1)))
        .copied()
        .unwrap_or(Duration::ZERO)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINUTE: i64 = 60_000;

    fn digest() -> ContentDigest {
        ContentDigest::from_bytes([0xAB; 32])
    }

    fn document() -> DocumentIdentifier {
        DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f60718293").unwrap()
    }

    fn absent(looked_up_at: i64, count: u32, retry_not_before: Option<i64>) -> ArchiveStanding {
        ArchiveStanding::Absent {
            looked_up_at: Timestamp(looked_up_at),
            failures: SubmissionFailures {
                count,
                retry_not_before: retry_not_before.map(Timestamp),
            },
        }
    }

    fn present(
        status: Option<DocumentStatus>,
        status_read_at: Option<i64>,
        received_at: Option<i64>,
    ) -> ArchiveStanding {
        ArchiveStanding::Present(PresentDocument {
            document: document(),
            status,
            status_read_at: status_read_at.map(Timestamp),
            received_at: received_at.map(Timestamp),
        })
    }

    fn lookup(answer: LookupAnswer, at: i64) -> ContentEvent {
        ContentEvent::LookupAnswered {
            answer,
            at: Timestamp(at),
        }
    }

    fn answered(outcome: SubmissionOutcome, at: i64) -> ContentEvent {
        ContentEvent::SubmissionAnswered {
            outcome,
            at: Timestamp(at),
        }
    }

    fn failed(failure: SubmissionFailure, at: i64) -> ContentEvent {
        ContentEvent::SubmissionFailed {
            failure,
            at: Timestamp(at),
        }
    }

    fn status_read(status: Option<DocumentStatus>, at: i64) -> ContentEvent {
        ContentEvent::DocumentStatusRead {
            status,
            at: Timestamp(at),
        }
    }

    #[test]
    fn the_content_machine_follows_the_transition_table() {
        use ArchiveStanding::{Deleted, Refused, Unresolved};
        let accepted = SubmissionOutcome::Accepted {
            document: document(),
            status: DocumentStatus::Processing,
        };
        let already_held = SubmissionOutcome::AlreadyHeld {
            document: document(),
            status: DocumentStatus::Archived,
        };
        let cases: Vec<(&str, ArchiveStanding, ContentEvent, ArchiveStanding)> = vec![
            (
                "an absent answer resolves a new content",
                Unresolved,
                lookup(LookupAnswer::Absent, 10),
                absent(10, 0, None),
            ),
            (
                "a present answer resolves to the document",
                Unresolved,
                lookup(LookupAnswer::Present(document()), 10),
                present(None, None, None),
            ),
            (
                "a deleted answer is terminal",
                Unresolved,
                lookup(LookupAnswer::Deleted, 10),
                Deleted,
            ),
            (
                "a fresh absent answer keeps the failure count",
                absent(10, 2, Some(900)),
                lookup(LookupAnswer::Absent, 20),
                absent(20, 2, Some(900)),
            ),
            (
                "a present content keeps its document on a late present answer",
                present(Some(DocumentStatus::Archived), Some(5), Some(5)),
                lookup(LookupAnswer::Present(document()), 10),
                present(Some(DocumentStatus::Archived), Some(5), Some(5)),
            ),
            (
                "a present content becomes deleted on a deleted answer",
                present(None, None, None),
                lookup(LookupAnswer::Deleted, 10),
                Deleted,
            ),
            (
                "a deleted content never changes",
                Deleted,
                lookup(LookupAnswer::Absent, 10),
                Deleted,
            ),
            (
                "a refused content never changes",
                Refused(RefusalReason::TooLarge),
                lookup(LookupAnswer::Absent, 10),
                Refused(RefusalReason::TooLarge),
            ),
            (
                "202 makes the content present and received",
                absent(10, 0, None),
                answered(accepted.clone(), 30),
                present(Some(DocumentStatus::Processing), Some(30), Some(30)),
            ),
            (
                "200 makes the content present without a receipt",
                absent(10, 0, None),
                answered(already_held, 30),
                present(Some(DocumentStatus::Archived), Some(30), None),
            ),
            (
                "409 makes the content deleted",
                absent(10, 0, None),
                answered(SubmissionOutcome::Deleted, 30),
                Deleted,
            ),
            (
                "413 refuses the content for good",
                absent(10, 0, None),
                answered(SubmissionOutcome::TooLarge, 30),
                Refused(RefusalReason::TooLarge),
            ),
            (
                "415 refuses the content for good",
                absent(10, 0, None),
                answered(SubmissionOutcome::UnacceptedKind, 30),
                Refused(RefusalReason::UnacceptedKind),
            ),
            (
                "a submission answer for a present content changes nothing",
                present(None, None, None),
                answered(accepted, 30),
                present(None, None, None),
            ),
            (
                "the first failure backs off one minute",
                absent(10, 0, None),
                failed(SubmissionFailure::ServerError, 30),
                absent(10, 1, Some(30 + MINUTE)),
            ),
            (
                "the second failure backs off five minutes",
                absent(10, 1, Some(0)),
                failed(SubmissionFailure::DigestDisagreement, 30),
                absent(10, 2, Some(30 + 5 * MINUTE)),
            ),
            (
                "the seventh failure backs off a day like the sixth",
                absent(10, 6, Some(0)),
                failed(SubmissionFailure::TimedOut, 30),
                absent(10, 7, Some(30 + 24 * 60 * MINUTE)),
            ),
            (
                "a failure for an unresolved content changes nothing",
                Unresolved,
                failed(SubmissionFailure::TimedOut, 30),
                Unresolved,
            ),
            (
                "a status read updates a present document",
                present(Some(DocumentStatus::Processing), Some(30), Some(30)),
                status_read(Some(DocumentStatus::Archived), 90),
                present(Some(DocumentStatus::Archived), Some(90), Some(30)),
            ),
            (
                "a 404 on the document makes the content deleted",
                present(Some(DocumentStatus::Processing), Some(30), Some(30)),
                status_read(None, 90),
                Deleted,
            ),
            (
                "a status read for an absent content changes nothing",
                absent(10, 0, None),
                status_read(Some(DocumentStatus::Archived), 90),
                absent(10, 0, None),
            ),
        ];
        let timing = TimingPolicy::default();
        for (name, current, event, expected) in cases {
            assert_eq!(advance_content(&current, event, &timing), expected, "{name}");
        }
    }

    #[test]
    fn only_a_fresh_absent_answer_outside_its_back_off_authorizes_a_submission() {
        let timing = TimingPolicy::default();
        let record = |standing| ContentRecord {
            digest: digest(),
            standing,
        };
        let now = Timestamp(100 * MINUTE);

        let authorization =
            authorize_submission(&record(absent(95 * MINUTE, 2, Some(99 * MINUTE))), now, &timing).unwrap();
        assert_eq!(authorization.digest(), digest());
        assert_eq!(authorization.looked_up_at(), Timestamp(95 * MINUTE));

        assert_eq!(
            authorize_submission(&record(absent(95 * MINUTE, 1, Some(101 * MINUTE))), now, &timing),
            Err(SubmissionHindrance::BackingOff {
                until: Timestamp(101 * MINUTE)
            })
        );
        assert_eq!(
            authorize_submission(&record(absent(90 * MINUTE, 0, None)), now, &timing),
            Err(SubmissionHindrance::LookupStale)
        );
        assert_eq!(
            authorize_submission(&record(absent(90 * MINUTE + 1, 0, None)), now, &timing).map(|_| ()),
            Ok(())
        );
        for standing in [
            ArchiveStanding::Unresolved,
            present(None, None, None),
            ArchiveStanding::Deleted,
            ArchiveStanding::Refused(RefusalReason::UnacceptedKind),
        ] {
            assert_eq!(
                authorize_submission(&record(standing), now, &timing),
                Err(SubmissionHindrance::NotAbsent)
            );
        }
    }
}
