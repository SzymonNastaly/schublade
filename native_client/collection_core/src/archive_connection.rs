//! The connection machine, a singleton, and the one table that says what each archive answer
//! means for the connection and for the content it was about. The archive client returns
//! answers; it never decides their consequence.

use std::time::Duration;

use archive_access::ArchiveCondition;

use crate::content_synchronization::{
    ContentEvent, LookupAnswer, SubmissionFailure, SubmissionOutcome, back_off_after,
};
use crate::domain_types::{ContentDigest, DocumentStatus, Timestamp, TimingPolicy};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectionState {
    Unconfigured,
    Available,
    Unreachable {
        since: Timestamp,
        attempt: u32,
        retry_at: Timestamp,
    },
    /// Half open: exactly one archive request may run, and its answer decides. `attempt` counts
    /// the failed probes so far; a probe after Deferred starts at zero.
    Probing {
        since: Timestamp,
        attempt: u32,
    },
    /// 503 with Retry-After: the archive still records digests of older documents.
    Deferred {
        until: Timestamp,
    },
    /// Persisted. Left only by a new token.
    Suspended {
        reason: SuspensionReason,
        since: Timestamp,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub enum SuspensionReason {
    /// 401: the token is unknown or revoked.
    CredentialRefused,
    /// 403: the token lacks the ingest level.
    CredentialInsufficient,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectionEvent {
    Configured,
    /// Any answer that is not one of the conditions below.
    Answered,
    ConnectionFailed {
        at: Timestamp,
    },
    ServiceUnavailable {
        retry_after: Duration,
        at: Timestamp,
    },
    CredentialRefused {
        at: Timestamp,
    },
    CredentialInsufficient {
        at: Timestamp,
    },
    TimerElapsed {
        at: Timestamp,
    },
    SystemResumed {
        at: Timestamp,
    },
}

/// The whole connection machine.
///
/// Invariants:
/// - Suspended is left only by Configured.
/// - Answered moves Probing to Available and leaves every other state as it is.
/// - A credential answer suspends from any state but Unconfigured and Suspended, and a 503
///   defers from those states, because each carries a fact about the archive whatever request
///   brought it.
/// - The attempt grows by one per failed probe; the delay is capped by the last back-off.
pub fn advance_connection(current: &ConnectionState, event: ConnectionEvent, timing: &TimingPolicy) -> ConnectionState {
    use ConnectionEvent as Event;
    use ConnectionState::{Available, Deferred, Probing, Suspended, Unconfigured, Unreachable};
    match (current, event) {
        (_, Event::Configured) => Available,
        (Unconfigured, _) => Unconfigured,
        (Suspended { .. }, _) => current.clone(),
        (_, Event::CredentialRefused { at }) => Suspended {
            reason: SuspensionReason::CredentialRefused,
            since: at,
        },
        (_, Event::CredentialInsufficient { at }) => Suspended {
            reason: SuspensionReason::CredentialInsufficient,
            since: at,
        },
        (_, Event::ServiceUnavailable { retry_after, at }) => Deferred {
            until: at.after(retry_after),
        },
        (Available, Event::ConnectionFailed { at }) => unreachable(at, at, 1, timing),
        (Probing { since, attempt }, Event::ConnectionFailed { at }) => unreachable(*since, at, attempt + 1, timing),
        (Probing { .. }, Event::Answered) => Available,
        (
            Unreachable {
                since,
                attempt,
                retry_at,
            },
            Event::TimerElapsed { at },
        ) if at >= *retry_at => Probing {
            since: *since,
            attempt: *attempt,
        },
        (Unreachable { since, attempt, .. }, Event::SystemResumed { .. }) => Probing {
            since: *since,
            attempt: *attempt,
        },
        (Deferred { until }, Event::TimerElapsed { at }) if at >= *until => Probing { since: at, attempt: 0 },
        (current, _) => current.clone(),
    }
}

fn unreachable(since: Timestamp, failed_at: Timestamp, attempt: u32, timing: &TimingPolicy) -> ConnectionState {
    let retry_at = failed_at.after(back_off_after(attempt, timing.connection_back_off));
    ConnectionState::Unreachable {
        since,
        attempt,
        retry_at,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestCapacity {
    None,
    /// Probing: one request across the lookup, submission, and status lanes together.
    Single,
    Unlimited,
}

pub fn request_capacity(state: &ConnectionState) -> RequestCapacity {
    match state {
        ConnectionState::Available => RequestCapacity::Unlimited,
        ConnectionState::Probing { .. } => RequestCapacity::Single,
        ConnectionState::Unconfigured
        | ConnectionState::Unreachable { .. }
        | ConnectionState::Deferred { .. }
        | ConnectionState::Suspended { .. } => RequestCapacity::None,
    }
}

/// When the coordinator must wake to deliver `TimerElapsed`.
pub fn next_timer(state: &ConnectionState) -> Option<Timestamp> {
    match state {
        ConnectionState::Unreachable { retry_at, .. } => Some(*retry_at),
        ConnectionState::Deferred { until } => Some(*until),
        ConnectionState::Unconfigured
        | ConnectionState::Available
        | ConnectionState::Probing { .. }
        | ConnectionState::Suspended { .. } => None,
    }
}

/// The delay before the n-th probe, from `timing.connection_back_off`; the last delay repeats.
pub fn connection_back_off(attempt: u32, timing: &TimingPolicy) -> Duration {
    back_off_after(attempt, timing.connection_back_off)
}

/// Why a submission produced no outcome: a condition every route shares, or one its route adds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmissionCondition {
    Archive(ArchiveCondition),
    /// 422: the archive read other bytes than the digest names.
    DigestDisagreement,
    /// The archive is older than the reception of collected documents, so nothing was sent and
    /// the collector holds its submissions until the owner updates it.
    ReceptionAbsent,
    /// Asking whether the archive offers the reception met a condition, so nothing was sent and
    /// the content is not to blame.
    ReceptionUnknown(ArchiveCondition),
}

impl From<ArchiveCondition> for SubmissionCondition {
    fn from(condition: ArchiveCondition) -> SubmissionCondition {
        SubmissionCondition::Archive(condition)
    }
}

/// What the archive answered to one request, with the content the request was about.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArchiveAnswer {
    Lookup {
        answer: Result<Vec<(ContentDigest, LookupAnswer)>, ArchiveCondition>,
    },
    Submission {
        content: ContentDigest,
        answer: Result<SubmissionOutcome, SubmissionCondition>,
    },
    DocumentStatus {
        content: ContentDigest,
        answer: Result<Option<DocumentStatus>, ArchiveCondition>,
    },
}

/// What one answer means: one connection event, the content events it carries, and what it shows
/// of the archive's reception of collected documents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Consequences {
    pub connection: ConnectionEvent,
    pub contents: Vec<(ContentDigest, ContentEvent)>,
    pub reception: Option<ReceptionFinding>,
}

/// What a submission showed of the reception: the reception answered it, or the archive lacks it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceptionFinding {
    Offered,
    Absent,
}

/// Whether the archive takes collected documents, as the last submission found. Held only in
/// memory, so a start assumes it does and its first submission asks again. Lookups and status
/// reads go on either way, because the collector's other routes are older than the reception.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceptionStanding {
    Assumed,
    /// The archive is older than the reception. Submissions wait until `recheck_at`, and the next
    /// one asks again.
    Absent {
        recheck_at: Timestamp,
    },
}

impl ReceptionStanding {
    pub fn permits_submission(&self, now: Timestamp) -> bool {
        match self {
            ReceptionStanding::Assumed => true,
            ReceptionStanding::Absent { recheck_at } => now >= *recheck_at,
        }
    }

    /// When the coordinator must wake to plan the submissions it held, while that lies ahead.
    pub fn next_timer(&self, now: Timestamp) -> Option<Timestamp> {
        match self {
            ReceptionStanding::Absent { recheck_at } if *recheck_at > now => Some(*recheck_at),
            ReceptionStanding::Absent { .. } | ReceptionStanding::Assumed => None,
        }
    }
}

pub fn advance_reception(finding: ReceptionFinding, at: Timestamp, timing: &TimingPolicy) -> ReceptionStanding {
    match finding {
        ReceptionFinding::Offered => ReceptionStanding::Assumed,
        ReceptionFinding::Absent => ReceptionStanding::Absent {
            recheck_at: at.after(timing.reception_recheck_interval),
        },
    }
}

/// The one table that decides what an answer means. A PUT timeout and a PUT 500 count against
/// the content, so one file cannot stall the collector; every condition also reaches the
/// connection.
pub fn consequences(answer: ArchiveAnswer, at: Timestamp) -> Consequences {
    let consequences = |connection, contents| Consequences {
        connection,
        contents,
        reception: None,
    };
    let reception = |finding, consequences: Consequences| Consequences {
        reception: Some(finding),
        ..consequences
    };
    match answer {
        ArchiveAnswer::Lookup { answer: Ok(answers) } => consequences(
            ConnectionEvent::Answered,
            answers
                .into_iter()
                .map(|(digest, answer)| (digest, ContentEvent::LookupAnswered { answer, at }))
                .collect(),
        ),
        ArchiveAnswer::Submission {
            content,
            answer: Ok(outcome),
        } => reception(
            ReceptionFinding::Offered,
            consequences(
                ConnectionEvent::Answered,
                vec![(content, ContentEvent::SubmissionAnswered { outcome, at })],
            ),
        ),
        ArchiveAnswer::DocumentStatus {
            content,
            answer: Ok(status),
        } => consequences(
            ConnectionEvent::Answered,
            vec![(content, ContentEvent::DocumentStatusRead { status, at })],
        ),
        ArchiveAnswer::Submission {
            content,
            answer: Err(condition),
        } => {
            let failed = |failure| vec![(content, ContentEvent::SubmissionFailed { failure, at })];
            match condition {
                SubmissionCondition::Archive(ArchiveCondition::ServerError) => {
                    consequences(ConnectionEvent::Answered, failed(SubmissionFailure::ServerError))
                }
                SubmissionCondition::DigestDisagreement => reception(
                    ReceptionFinding::Offered,
                    consequences(ConnectionEvent::Answered, failed(SubmissionFailure::DigestDisagreement)),
                ),
                SubmissionCondition::ReceptionAbsent => reception(
                    ReceptionFinding::Absent,
                    consequences(ConnectionEvent::Answered, vec![]),
                ),
                SubmissionCondition::ReceptionUnknown(condition) => {
                    consequences(connection_event(condition, at), vec![])
                }
                SubmissionCondition::Archive(ArchiveCondition::TimedOut) => consequences(
                    ConnectionEvent::ConnectionFailed { at },
                    failed(SubmissionFailure::TimedOut),
                ),
                SubmissionCondition::Archive(other) => consequences(connection_event(other, at), vec![]),
            }
        }
        ArchiveAnswer::Lookup { answer: Err(condition) }
        | ArchiveAnswer::DocumentStatus {
            answer: Err(condition), ..
        } => consequences(connection_event(condition, at), vec![]),
    }
}

fn connection_event(condition: ArchiveCondition, at: Timestamp) -> ConnectionEvent {
    match condition {
        ArchiveCondition::CredentialRefused => ConnectionEvent::CredentialRefused { at },
        ArchiveCondition::CredentialInsufficient => ConnectionEvent::CredentialInsufficient { at },
        ArchiveCondition::ServiceUnavailable { retry_after } => ConnectionEvent::ServiceUnavailable { retry_after, at },
        // The lookup and the status read exist in every archive, so one that does not offer them
        // violates the protocol. A submission reads RouteUnknown as `ReceptionAbsent` before this.
        ArchiveCondition::RouteUnknown
        | ArchiveCondition::ConnectionFailed
        | ArchiveCondition::TimedOut
        | ArchiveCondition::ServerError
        | ArchiveCondition::ProtocolViolation { .. } => ConnectionEvent::ConnectionFailed { at },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_types::DocumentIdentifier;

    const SECOND: i64 = 1_000;

    fn digest(byte: u8) -> ContentDigest {
        ContentDigest::from_bytes([byte; 32])
    }

    fn unreachable(since: i64, attempt: u32, retry_at: i64) -> ConnectionState {
        ConnectionState::Unreachable {
            since: Timestamp(since),
            attempt,
            retry_at: Timestamp(retry_at),
        }
    }

    fn probing(since: i64, attempt: u32) -> ConnectionState {
        ConnectionState::Probing {
            since: Timestamp(since),
            attempt,
        }
    }

    #[test]
    fn the_connection_machine_follows_the_transition_table() {
        use ConnectionEvent as Event;
        use ConnectionState::{Available, Deferred, Suspended, Unconfigured};
        let suspended = Suspended {
            reason: SuspensionReason::CredentialRefused,
            since: Timestamp(5),
        };
        let unavailable = Event::ServiceUnavailable {
            retry_after: Duration::from_secs(900),
            at: Timestamp(10 * SECOND),
        };
        let cases: Vec<(&str, ConnectionState, ConnectionEvent, ConnectionState)> = vec![
            (
                "configuring makes the archive available",
                Unconfigured,
                Event::Configured,
                Available,
            ),
            (
                "unconfigured ignores answers",
                Unconfigured,
                Event::Answered,
                Unconfigured,
            ),
            (
                "the first failure backs off fifteen seconds",
                Available,
                Event::ConnectionFailed {
                    at: Timestamp(10 * SECOND),
                },
                unreachable(10 * SECOND, 1, 25 * SECOND),
            ),
            (
                "a 503 defers until retry-after",
                Available,
                unavailable.clone(),
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
            ),
            (
                "a 401 suspends",
                Available,
                Event::CredentialRefused { at: Timestamp(5) },
                Suspended {
                    reason: SuspensionReason::CredentialRefused,
                    since: Timestamp(5),
                },
            ),
            (
                "a 403 suspends",
                Available,
                Event::CredentialInsufficient { at: Timestamp(5) },
                Suspended {
                    reason: SuspensionReason::CredentialInsufficient,
                    since: Timestamp(5),
                },
            ),
            (
                "an answer keeps the archive available",
                Available,
                Event::Answered,
                Available,
            ),
            (
                "the timer before retry_at changes nothing",
                unreachable(10 * SECOND, 1, 25 * SECOND),
                Event::TimerElapsed {
                    at: Timestamp(24 * SECOND),
                },
                unreachable(10 * SECOND, 1, 25 * SECOND),
            ),
            (
                "the timer at retry_at probes",
                unreachable(10 * SECOND, 1, 25 * SECOND),
                Event::TimerElapsed {
                    at: Timestamp(25 * SECOND),
                },
                probing(10 * SECOND, 1),
            ),
            (
                "a wake probes at once",
                unreachable(10 * SECOND, 3, 100 * SECOND),
                Event::SystemResumed {
                    at: Timestamp(20 * SECOND),
                },
                probing(10 * SECOND, 3),
            ),
            (
                "a failure while unreachable does not count",
                unreachable(10 * SECOND, 1, 25 * SECOND),
                Event::ConnectionFailed {
                    at: Timestamp(12 * SECOND),
                },
                unreachable(10 * SECOND, 1, 25 * SECOND),
            ),
            (
                "an answered probe makes the archive available",
                probing(10 * SECOND, 1),
                Event::Answered,
                Available,
            ),
            (
                "a failed probe backs off further and keeps since",
                probing(10 * SECOND, 1),
                Event::ConnectionFailed {
                    at: Timestamp(26 * SECOND),
                },
                unreachable(10 * SECOND, 2, 56 * SECOND),
            ),
            (
                "the probe back-off is capped at fifteen minutes",
                probing(10 * SECOND, 9),
                Event::ConnectionFailed {
                    at: Timestamp(26 * SECOND),
                },
                unreachable(10 * SECOND, 10, 926 * SECOND),
            ),
            (
                "a probe answered with 503 defers",
                probing(0, 2),
                unavailable,
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
            ),
            (
                "a probe answered with 401 suspends",
                probing(0, 2),
                Event::CredentialRefused { at: Timestamp(5) },
                Suspended {
                    reason: SuspensionReason::CredentialRefused,
                    since: Timestamp(5),
                },
            ),
            (
                "the timer before until keeps deferring",
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
                Event::TimerElapsed {
                    at: Timestamp(909 * SECOND),
                },
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
            ),
            (
                "the timer at until probes afresh",
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
                Event::TimerElapsed {
                    at: Timestamp(910 * SECOND),
                },
                probing(910 * SECOND, 0),
            ),
            (
                "a wake while deferred keeps the archive's wish",
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
                Event::SystemResumed {
                    at: Timestamp(20 * SECOND),
                },
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
            ),
            (
                "suspended ignores answers",
                suspended.clone(),
                Event::Answered,
                suspended.clone(),
            ),
            (
                "suspended ignores a wake",
                suspended.clone(),
                Event::SystemResumed {
                    at: Timestamp(20 * SECOND),
                },
                suspended.clone(),
            ),
            ("a new token leaves suspended", suspended, Event::Configured, Available),
            (
                "a new token leaves unreachable",
                unreachable(10 * SECOND, 1, 25 * SECOND),
                Event::Configured,
                Available,
            ),
            (
                "a new token leaves deferred",
                Deferred {
                    until: Timestamp(910 * SECOND),
                },
                Event::Configured,
                Available,
            ),
        ];
        let timing = TimingPolicy::default();
        for (name, current, event, expected) in cases {
            assert_eq!(advance_connection(&current, event, &timing), expected, "{name}");
        }
    }

    #[test]
    fn capacity_and_timers_follow_the_state() {
        use ConnectionState::{Available, Deferred, Suspended, Unconfigured};
        let suspended = Suspended {
            reason: SuspensionReason::CredentialInsufficient,
            since: Timestamp(5),
        };
        assert_eq!(request_capacity(&Available), RequestCapacity::Unlimited);
        assert_eq!(request_capacity(&probing(0, 1)), RequestCapacity::Single);
        for state in [
            &Unconfigured,
            &unreachable(0, 1, 15 * SECOND),
            &Deferred { until: Timestamp(9) },
            &suspended,
        ] {
            assert_eq!(request_capacity(state), RequestCapacity::None, "{state:?}");
        }
        assert_eq!(
            next_timer(&unreachable(0, 1, 15 * SECOND)),
            Some(Timestamp(15 * SECOND))
        );
        assert_eq!(next_timer(&Deferred { until: Timestamp(9) }), Some(Timestamp(9)));
        for state in [&Unconfigured, &Available, &probing(0, 1), &suspended] {
            assert_eq!(next_timer(state), None, "{state:?}");
        }
    }

    #[test]
    fn every_archive_answer_has_one_consequence() {
        use ArchiveCondition as Condition;
        use ConnectionEvent as Event;
        let at = Timestamp(7);
        let document = DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f60718293").unwrap();
        let accepted = SubmissionOutcome::Accepted {
            document: document.clone(),
            status: DocumentStatus::Processing,
        };
        let submission = |answer| ArchiveAnswer::Submission {
            content: digest(1),
            answer,
        };
        let lookup = |answer| ArchiveAnswer::Lookup { answer };
        let status = |answer| ArchiveAnswer::DocumentStatus {
            content: digest(1),
            answer,
        };
        let failed = |failure| vec![(digest(1), ContentEvent::SubmissionFailed { failure, at })];
        let retry_after = Duration::from_secs(900);
        type Expected = (ConnectionEvent, Vec<(ContentDigest, ContentEvent)>);
        let cases: Vec<(&str, ArchiveAnswer, Expected)> = vec![
            (
                "lookup 200 answers each digest",
                lookup(Ok(vec![
                    (digest(1), LookupAnswer::Absent),
                    (digest(2), LookupAnswer::Present(document.clone())),
                ])),
                (
                    Event::Answered,
                    vec![
                        (
                            digest(1),
                            ContentEvent::LookupAnswered {
                                answer: LookupAnswer::Absent,
                                at,
                            },
                        ),
                        (
                            digest(2),
                            ContentEvent::LookupAnswered {
                                answer: LookupAnswer::Present(document.clone()),
                                at,
                            },
                        ),
                    ],
                ),
            ),
            (
                "PUT 202 answers the content",
                submission(Ok(accepted.clone())),
                (
                    Event::Answered,
                    vec![(digest(1), ContentEvent::SubmissionAnswered { outcome: accepted, at })],
                ),
            ),
            (
                "PUT 409 answers the content as deleted",
                submission(Ok(SubmissionOutcome::Deleted)),
                (
                    Event::Answered,
                    vec![(
                        digest(1),
                        ContentEvent::SubmissionAnswered {
                            outcome: SubmissionOutcome::Deleted,
                            at,
                        },
                    )],
                ),
            ),
            (
                "PUT 415 answers the content as refused",
                submission(Ok(SubmissionOutcome::UnacceptedKind)),
                (
                    Event::Answered,
                    vec![(
                        digest(1),
                        ContentEvent::SubmissionAnswered {
                            outcome: SubmissionOutcome::UnacceptedKind,
                            at,
                        },
                    )],
                ),
            ),
            (
                "PUT 422 fails the content and answers the connection",
                submission(Err(SubmissionCondition::DigestDisagreement)),
                (Event::Answered, failed(SubmissionFailure::DigestDisagreement)),
            ),
            (
                "PUT 500 fails the content and answers the connection",
                submission(Err(Condition::ServerError.into())),
                (Event::Answered, failed(SubmissionFailure::ServerError)),
            ),
            (
                "PUT timeout fails the content and the connection",
                submission(Err(Condition::TimedOut.into())),
                (Event::ConnectionFailed { at }, failed(SubmissionFailure::TimedOut)),
            ),
            (
                "PUT 401 suspends and leaves the content",
                submission(Err(Condition::CredentialRefused.into())),
                (Event::CredentialRefused { at }, vec![]),
            ),
            (
                "PUT 503 defers and leaves the content",
                submission(Err(Condition::ServiceUnavailable { retry_after }.into())),
                (Event::ServiceUnavailable { retry_after, at }, vec![]),
            ),
            (
                "PUT connection failure leaves the content",
                submission(Err(Condition::ConnectionFailed.into())),
                (Event::ConnectionFailed { at }, vec![]),
            ),
            (
                "lookup 500 fails the connection",
                lookup(Err(Condition::ServerError)),
                (Event::ConnectionFailed { at }, vec![]),
            ),
            (
                "lookup 400 fails the connection",
                lookup(Err(Condition::ProtocolViolation {
                    detail: "400".to_owned(),
                })),
                (Event::ConnectionFailed { at }, vec![]),
            ),
            (
                "lookup 403 suspends",
                lookup(Err(Condition::CredentialInsufficient)),
                (Event::CredentialInsufficient { at }, vec![]),
            ),
            (
                "status 200 answers the content",
                status(Ok(Some(DocumentStatus::Archived))),
                (
                    Event::Answered,
                    vec![(
                        digest(1),
                        ContentEvent::DocumentStatusRead {
                            status: Some(DocumentStatus::Archived),
                            at,
                        },
                    )],
                ),
            ),
            (
                "status 404 answers the content",
                status(Ok(None)),
                (
                    Event::Answered,
                    vec![(digest(1), ContentEvent::DocumentStatusRead { status: None, at })],
                ),
            ),
            (
                "status timeout fails the connection only",
                status(Err(Condition::TimedOut)),
                (Event::ConnectionFailed { at }, vec![]),
            ),
        ];
        for (name, answer, expected) in cases {
            let Consequences {
                connection,
                contents,
                reception: _,
            } = consequences(answer, at);
            assert_eq!((connection, contents), expected, "{name}");
        }
    }

    #[test]
    fn a_submission_shows_whether_the_archive_offers_the_reception() {
        use ArchiveCondition as Condition;
        let at = Timestamp(7);
        let submission = |answer| ArchiveAnswer::Submission {
            content: digest(1),
            answer,
        };
        let cases: Vec<(&str, ArchiveAnswer, Option<ReceptionFinding>)> = vec![
            (
                "an outcome shows the reception",
                submission(Ok(SubmissionOutcome::Deleted)),
                Some(ReceptionFinding::Offered),
            ),
            (
                "a 422 shows the reception",
                submission(Err(SubmissionCondition::DigestDisagreement)),
                Some(ReceptionFinding::Offered),
            ),
            (
                "an archive without the reception shows its absence",
                submission(Err(SubmissionCondition::ReceptionAbsent)),
                Some(ReceptionFinding::Absent),
            ),
            (
                "a 500 shows nothing",
                submission(Err(Condition::ServerError.into())),
                None,
            ),
            (
                "an unanswered question shows nothing",
                submission(Err(SubmissionCondition::ReceptionUnknown(Condition::ServerError))),
                None,
            ),
        ];
        for (name, answer, expected) in cases {
            assert_eq!(consequences(answer, at).reception, expected, "{name}");
        }
        assert_eq!(
            consequences(submission(Err(SubmissionCondition::ReceptionAbsent)), at).contents,
            vec![],
            "a held submission counts no failure against its content"
        );
        assert_eq!(
            consequences(
                submission(Err(SubmissionCondition::ReceptionUnknown(Condition::TimedOut))),
                at
            ),
            Consequences {
                connection: ConnectionEvent::ConnectionFailed { at },
                contents: vec![],
                reception: None,
            },
            "a question that timed out fails the connection and not the content"
        );
    }
}
