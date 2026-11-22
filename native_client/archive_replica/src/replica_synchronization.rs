//! The synchronization as a pure machine: when the copy requests a page, what a failure means,
//! and how long it waits. It reads no clock, no network, and no store. The cursor is not here:
//! the store holds it, written in the transaction of the page that produced it.

use std::time::Duration;

use archive_access::{ArchiveCondition, Timestamp};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SynchronizationState {
    /// No archive is followed. Nothing is requested.
    Disconnected,
    /// The first fill: the copy has not yet reached the journal's end. Pages back to back.
    Filling {
        /// An upper bound of the journal entries still to come.
        remaining_entries: u64,
    },
    /// The copy held everything when its last page was read. Waits for a wake or the deadline.
    Following { next_request_at: Timestamp },
    /// A wake or the deadline came, or a page said that more follow. Pages back to back.
    CatchingUp,
    /// A request failed in a way that can pass.
    Unreachable {
        since: Timestamp,
        /// The failed requests in a row.
        attempts: u32,
        retry_at: Timestamp,
        condition: ArchiveCondition,
    },
    /// The archive refused the token. Nothing is requested until a new connection.
    Suspended { reason: SuspensionReason },
    /// The archive is older than the route of the changes. Asked again once an hour.
    ArchiveOutdated { retry_at: Timestamp },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SuspensionReason {
    /// 401: the token is unknown or revoked.
    CredentialRefused,
    /// 403 with a problem document: the token may not read, or excludes a tag that no longer
    /// exists.
    CredentialInsufficient,
}

/// Why the application asks for a synchronization now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WakeReason {
    ApplicationActivated,
    SystemResumed,
    /// The collector's archive accepted a document a moment ago.
    DocumentAccepted,
    PersonRequested,
}

/// Whether a window shows the library. It sets how long `Following` waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attendance {
    Attended,
    Unattended,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SynchronizationInput {
    /// An archive is followed, from the start or from a new connection. `fill_complete` is the
    /// store's.
    ConnectionEstablished {
        fill_complete: bool,
    },
    /// A page was applied and its cursor stored.
    PageApplied {
        complete: bool,
        /// The store's, after the page: whether the copy ever reached the journal's end.
        fill_complete: bool,
        remaining_entries: u64,
        /// The documents in ingestion that the copy holds.
        unsettled_documents: u64,
    },
    /// The archive answered 410, and the copy was discarded.
    JournalReplaced,
    RequestFailed(ArchiveCondition),
    Woken(WakeReason),
    /// The time of the last `AwaitDeadline` came.
    DeadlineReached,
}

/// What the coordinator does next. Without an effect it waits for an input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SynchronizationEffect {
    /// Request the page after the stored cursor now.
    RequestPage,
    /// Wait for an input, and give `DeadlineReached` at this time when none came first.
    AwaitDeadline(Timestamp),
}

/// The intervals of the machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SynchronizationTiming {
    /// Between requests while the copy holds a document in ingestion.
    pub unsettled_interval: Duration,
    /// Between requests while a window shows the library.
    pub attended_interval: Duration,
    /// Between requests otherwise.
    pub unattended_interval: Duration,
    /// After the first failed request. Tripled with every further one.
    pub first_retry: Duration,
    pub longest_retry: Duration,
    /// Between requests to an archive that lacks the route.
    pub outdated_archive_interval: Duration,
}

impl Default for SynchronizationTiming {
    fn default() -> SynchronizationTiming {
        SynchronizationTiming {
            unsettled_interval: Duration::from_secs(5),
            attended_interval: Duration::from_secs(60),
            unattended_interval: Duration::from_secs(15 * 60),
            first_retry: Duration::from_secs(5),
            longest_retry: Duration::from_secs(5 * 60),
            outdated_archive_interval: Duration::from_secs(60 * 60),
        }
    }
}

/// The whole policy of the synchronization, total over every state and input.
///
/// Invariants:
/// - `Suspended` and `Disconnected` are left only by `ConnectionEstablished`.
/// - A page that reaches the journal's end leads to `Following` from every state that requests.
/// - A wake requests at once while the copy follows. While the archive is unreachable, only a
///   wake that a person or the system caused does, because an accepted document can come many
///   times a minute and must not undo the back-off.
/// - Every match names its states, inputs, conditions, and reasons, so a new one does not compile
///   until someone decides what it means.
pub fn advance_synchronization(
    state: SynchronizationState,
    input: SynchronizationInput,
    attendance: Attendance,
    now: Timestamp,
    timing: &SynchronizationTiming,
) -> (SynchronizationState, Option<SynchronizationEffect>) {
    use SynchronizationInput as Input;
    use SynchronizationState::{ArchiveOutdated, CatchingUp, Disconnected, Filling, Following, Suspended, Unreachable};
    use WakeReason::{ApplicationActivated, DocumentAccepted, PersonRequested, SystemResumed};
    let (state, requests) = match (state, input) {
        (
            Disconnected
            | Filling { .. }
            | Following { .. }
            | CatchingUp
            | Unreachable { .. }
            | Suspended { .. }
            | ArchiveOutdated { .. },
            Input::ConnectionEstablished { fill_complete },
        ) => {
            if fill_complete {
                (CatchingUp, true)
            } else {
                (Filling { remaining_entries: 0 }, true)
            }
        }
        (
            state @ (Disconnected | Suspended { .. }),
            Input::PageApplied { .. }
            | Input::JournalReplaced
            | Input::RequestFailed(_)
            | Input::Woken(ApplicationActivated | SystemResumed | DocumentAccepted | PersonRequested)
            | Input::DeadlineReached,
        ) => (state, false),
        (
            Filling { .. } | Following { .. } | CatchingUp | Unreachable { .. } | ArchiveOutdated { .. },
            Input::JournalReplaced,
        ) => (Filling { remaining_entries: 0 }, true),
        (
            Filling { .. } | Following { .. } | CatchingUp | Unreachable { .. } | ArchiveOutdated { .. },
            Input::PageApplied {
                complete,
                fill_complete,
                remaining_entries,
                unsettled_documents,
            },
        ) => match (complete, fill_complete) {
            (true, _) => {
                let interval = match (unsettled_documents, attendance) {
                    (1.., _) => timing.unsettled_interval,
                    (0, Attendance::Attended) => timing.attended_interval,
                    (0, Attendance::Unattended) => timing.unattended_interval,
                };
                (
                    Following {
                        next_request_at: now.after(interval),
                    },
                    false,
                )
            }
            (false, true) => (CatchingUp, true),
            (false, false) => (Filling { remaining_entries }, true),
        },
        (Unreachable { since, attempts, .. }, Input::RequestFailed(condition)) => (
            after_failure(since, attempts.saturating_add(1), condition, now, timing),
            false,
        ),
        (Filling { .. } | Following { .. } | CatchingUp | ArchiveOutdated { .. }, Input::RequestFailed(condition)) => {
            (after_failure(now, 1, condition, now, timing), false)
        }
        (
            Following { .. },
            Input::Woken(ApplicationActivated | SystemResumed | DocumentAccepted | PersonRequested)
            | Input::DeadlineReached,
        ) => (CatchingUp, true),
        (
            state @ (Filling { .. } | CatchingUp),
            Input::Woken(ApplicationActivated | SystemResumed | DocumentAccepted | PersonRequested)
            | Input::DeadlineReached,
        ) => (state, true),
        (
            state @ Unreachable {
                condition: ArchiveCondition::ServiceUnavailable { .. },
                ..
            },
            Input::Woken(ApplicationActivated | SystemResumed | DocumentAccepted),
        ) => (state, false),
        (
            state @ Unreachable { .. },
            Input::Woken(ApplicationActivated | SystemResumed | PersonRequested) | Input::DeadlineReached,
        ) => (state, true),
        (state @ Unreachable { .. }, Input::Woken(DocumentAccepted)) => (state, false),
        (state @ ArchiveOutdated { .. }, Input::Woken(PersonRequested) | Input::DeadlineReached) => (state, true),
        (state @ ArchiveOutdated { .. }, Input::Woken(ApplicationActivated | SystemResumed | DocumentAccepted)) => {
            (state, false)
        }
    };
    let effect = match (requests, &state) {
        (true, _) => Some(SynchronizationEffect::RequestPage),
        (false, Following { next_request_at }) => Some(SynchronizationEffect::AwaitDeadline(*next_request_at)),
        (false, Unreachable { retry_at, .. } | ArchiveOutdated { retry_at }) => {
            Some(SynchronizationEffect::AwaitDeadline(*retry_at))
        }
        (false, Disconnected | Filling { .. } | CatchingUp | Suspended { .. }) => None,
    };
    (state, effect)
}

/// Where a failed request leads, as `notes/client_protocol.md` says under "What a client does on
/// each answer". `since` and `attempts` describe the run of failures this one belongs to.
fn after_failure(
    since: Timestamp,
    attempts: u32,
    condition: ArchiveCondition,
    now: Timestamp,
    timing: &SynchronizationTiming,
) -> SynchronizationState {
    let delay = match &condition {
        ArchiveCondition::CredentialRefused => {
            return SynchronizationState::Suspended {
                reason: SuspensionReason::CredentialRefused,
            };
        }
        ArchiveCondition::CredentialInsufficient => {
            return SynchronizationState::Suspended {
                reason: SuspensionReason::CredentialInsufficient,
            };
        }
        ArchiveCondition::RouteUnknown => {
            return SynchronizationState::ArchiveOutdated {
                retry_at: now.after(timing.outdated_archive_interval),
            };
        }
        // An archive that names no wait is still asked no sooner than after a first failure.
        ArchiveCondition::ServiceUnavailable { retry_after } => (*retry_after).max(timing.first_retry),
        ArchiveCondition::ConnectionFailed
        | ArchiveCondition::TimedOut
        | ArchiveCondition::ServerError
        | ArchiveCondition::ProtocolViolation { .. } => retry_delay(attempts, timing),
    };
    SynchronizationState::Unreachable {
        since,
        attempts,
        retry_at: now.after(delay),
        condition,
    }
}

/// The first retry's delay, tripled per further failed request, up to the longest.
fn retry_delay(attempts: u32, timing: &SynchronizationTiming) -> Duration {
    3u32.checked_pow(attempts.saturating_sub(1))
        .and_then(|factor| timing.first_retry.checked_mul(factor))
        .map_or(timing.longest_retry, |delay| delay.min(timing.longest_retry))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: i64 = 1_000;

    #[test]
    fn a_refused_token_requests_nothing_until_a_new_connection_and_a_persons_wake_retries_an_unreachable_archive_at_once()
     {
        use SynchronizationEffect::{AwaitDeadline, RequestPage};
        use SynchronizationInput::{ConnectionEstablished, DeadlineReached, RequestFailed, Woken};
        use SynchronizationState::{CatchingUp, Suspended, Unreachable};
        let timing = SynchronizationTiming::default();
        let advance = |state, input| {
            advance_synchronization(state, input, Attendance::Unattended, Timestamp(100 * SECOND), &timing)
        };

        let suspended = Suspended {
            reason: SuspensionReason::CredentialRefused,
        };
        assert_eq!(
            advance(CatchingUp, RequestFailed(ArchiveCondition::CredentialRefused)),
            (suspended.clone(), None)
        );
        for input in [
            Woken(WakeReason::PersonRequested),
            Woken(WakeReason::ApplicationActivated),
            Woken(WakeReason::SystemResumed),
            Woken(WakeReason::DocumentAccepted),
            DeadlineReached,
        ] {
            assert_eq!(advance(suspended.clone(), input), (suspended.clone(), None));
        }
        assert_eq!(
            advance(suspended, ConnectionEstablished { fill_complete: true }),
            (CatchingUp, Some(RequestPage))
        );

        let unreachable = Unreachable {
            since: Timestamp(100 * SECOND),
            attempts: 1,
            retry_at: Timestamp(105 * SECOND),
            condition: ArchiveCondition::TimedOut,
        };
        assert_eq!(
            advance(CatchingUp, RequestFailed(ArchiveCondition::TimedOut)),
            (unreachable.clone(), Some(AwaitDeadline(Timestamp(105 * SECOND))))
        );
        assert_eq!(
            advance(unreachable.clone(), Woken(WakeReason::DocumentAccepted)),
            (unreachable.clone(), Some(AwaitDeadline(Timestamp(105 * SECOND))))
        );
        assert_eq!(
            advance(unreachable.clone(), Woken(WakeReason::PersonRequested)),
            (unreachable.clone(), Some(RequestPage))
        );
        assert_eq!(
            advance(unreachable, RequestFailed(ArchiveCondition::ConnectionFailed)),
            (
                Unreachable {
                    since: Timestamp(100 * SECOND),
                    attempts: 2,
                    retry_at: Timestamp(115 * SECOND),
                    condition: ArchiveCondition::ConnectionFailed,
                },
                Some(AwaitDeadline(Timestamp(115 * SECOND)))
            )
        );

        let service_unavailable = Unreachable {
            since: Timestamp(100 * SECOND),
            attempts: 1,
            retry_at: Timestamp(130 * SECOND),
            condition: ArchiveCondition::ServiceUnavailable {
                retry_after: Duration::from_secs(30),
            },
        };
        assert_eq!(
            advance(
                CatchingUp,
                RequestFailed(ArchiveCondition::ServiceUnavailable {
                    retry_after: Duration::from_secs(30),
                })
            ),
            (
                service_unavailable.clone(),
                Some(AwaitDeadline(Timestamp(130 * SECOND)))
            )
        );
        for wake in [
            WakeReason::ApplicationActivated,
            WakeReason::SystemResumed,
            WakeReason::DocumentAccepted,
        ] {
            assert_eq!(
                advance(service_unavailable.clone(), Woken(wake)),
                (
                    service_unavailable.clone(),
                    Some(AwaitDeadline(Timestamp(130 * SECOND)))
                )
            );
        }
        assert_eq!(
            advance(service_unavailable.clone(), Woken(WakeReason::PersonRequested)),
            (service_unavailable.clone(), Some(RequestPage))
        );
        assert_eq!(
            advance(service_unavailable, DeadlineReached),
            (
                Unreachable {
                    since: Timestamp(100 * SECOND),
                    attempts: 1,
                    retry_at: Timestamp(130 * SECOND),
                    condition: ArchiveCondition::ServiceUnavailable {
                        retry_after: Duration::from_secs(30),
                    },
                },
                Some(RequestPage)
            )
        );
    }
}
