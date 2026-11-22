//! The path machine. A path is one entry of one directory in one folder; its state says what the
//! collector knows about the bytes at that name. Every variant is a resting state. "Digesting" is
//! a Stable path plus a reservation the coordinator holds in memory.

use crate::candidate_classification::{ExclusionReason, ReadableSignature, classify_signature};
use crate::domain_types::{ContentDigest, FileSignature, Timestamp, TimingPolicy};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathState {
    /// The signature last seen and when it was first seen. Stable once the same signature is
    /// listed again `stabilization_interval` later.
    Stabilizing {
        signature: FileSignature,
        observed_at: Timestamp,
    },
    /// Unchanged long enough and admissible by metadata; awaits its digest.
    Stable { signature: ReadableSignature },
    /// The path held these bytes when it had this signature. The content row exists.
    Digested {
        signature: ReadableSignature,
        content: ContentDigest,
    },
    /// No candidate while the signature holds.
    Excluded {
        signature: FileSignature,
        reason: ExclusionReason,
    },
    /// The read was refused (permission, I/O error). Read again on a change or after
    /// `unreadable_retry_interval`.
    Unreadable {
        signature: ReadableSignature,
        since: Timestamp,
        cause: String,
    },
}

impl PathState {
    pub fn signature(&self) -> &FileSignature {
        match self {
            PathState::Stabilizing { signature, .. } | PathState::Excluded { signature, .. } => signature,
            PathState::Stable { signature }
            | PathState::Digested { signature, .. }
            | PathState::Unreadable { signature, .. } => signature.signature(),
        }
    }
}

/// What a digest worker found. It always carries the signature its read was based on, so a
/// result for a signature the path no longer has is recognized as stale.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DigestFinding {
    /// `lstat` before and after the read equalled the reserved signature.
    Digested {
        content: ContentDigest,
    },
    /// The leading bytes are no accepted kind; the rest was not read.
    Unrecognized,
    /// The signature differed before the read or after it. `None` means the file vanished, which
    /// only the next listing of its directory proves.
    Changed {
        current: Option<FileSignature>,
    },
    ReadRefused {
        cause: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathEvent {
    /// The parent's successful listing contains this entry with this signature.
    Listed { signature: FileSignature, at: Timestamp },
    /// The parent's successful listing lacks this entry. Never produced by a failed listing.
    NotListed,
    DigestFinished {
        based_on: ReadableSignature,
        finding: DigestFinding,
        at: Timestamp,
    },
    /// A submission worker could not read this path back as the digested bytes. `None` means the
    /// file vanished.
    SourceVerificationFailed {
        based_on: ReadableSignature,
        current: Option<FileSignature>,
        at: Timestamp,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathTransition {
    /// Nothing is written.
    Unchanged,
    /// The row is inserted or replaced with this state.
    Store(PathState),
    /// The row is deleted. Its content row stays.
    Remove,
}

/// The whole path machine. `current` is None when no row exists.
///
/// Invariants:
/// - Any signature change from any state leads to Stabilizing with `observed_at = at`.
/// - A `DigestFinished` or `SourceVerificationFailed` whose `based_on` differs from the stored
///   signature is `Unchanged`: the path already moved on.
/// - An event for a missing row is `Unchanged`, except `Listed`, which creates the row.
/// - Running the same `Listed` twice yields `Unchanged` the second time unless the stabilization
///   interval elapsed in between.
pub fn advance_path(current: Option<&PathState>, event: PathEvent, timing: &TimingPolicy) -> PathTransition {
    use PathTransition::{Remove, Store, Unchanged};
    let Some(state) = current else {
        return match event {
            PathEvent::Listed { signature, at } => Store(stabilizing(signature, at)),
            _ => Unchanged,
        };
    };
    match event {
        PathEvent::Listed { signature, at } if signature != *state.signature() => Store(stabilizing(signature, at)),
        PathEvent::Listed { signature, at } => match state {
            PathState::Stabilizing { observed_at, .. }
                if at.elapsed_since(*observed_at) >= timing.stabilization_interval =>
            {
                Store(settled(signature))
            }
            PathState::Unreadable { signature, since, .. }
                if at.elapsed_since(*since) >= timing.unreadable_retry_interval =>
            {
                Store(PathState::Stable { signature: *signature })
            }
            _ => Unchanged,
        },
        PathEvent::NotListed => Remove,
        PathEvent::DigestFinished { based_on, finding, at } => match state {
            PathState::Stable { signature } if signature == &based_on => match finding {
                DigestFinding::Digested { content } => Store(PathState::Digested {
                    signature: based_on,
                    content,
                }),
                DigestFinding::Unrecognized => Store(PathState::Excluded {
                    signature: *based_on.signature(),
                    reason: ExclusionReason::UnrecognizedContent,
                }),
                DigestFinding::Changed { current: Some(current) } => Store(stabilizing(current, at)),
                DigestFinding::Changed { current: None } => Unchanged,
                DigestFinding::ReadRefused { cause } => Store(PathState::Unreadable {
                    signature: based_on,
                    since: at,
                    cause,
                }),
            },
            _ => Unchanged,
        },
        PathEvent::SourceVerificationFailed { based_on, current, at } => match (state, current) {
            (PathState::Digested { signature, .. }, Some(current)) if signature == &based_on => {
                Store(stabilizing(current, at))
            }
            _ => Unchanged,
        },
    }
}

fn stabilizing(signature: FileSignature, at: Timestamp) -> PathState {
    PathState::Stabilizing {
        signature,
        observed_at: at,
    }
}

fn settled(signature: FileSignature) -> PathState {
    match classify_signature(signature) {
        Ok(readable) => PathState::Stable { signature: readable },
        Err(reason) => PathState::Excluded { signature, reason },
    }
}

/// When a path should be listed again: a Stabilizing path at the end of its interval, an
/// Unreadable path at its retry. The coordinator lists the directory then, so the second
/// observation never depends on a file-system event.
pub fn next_observation_due(state: &PathState, timing: &TimingPolicy) -> Option<Timestamp> {
    match state {
        PathState::Stabilizing { observed_at, .. } => Some(observed_at.after(timing.stabilization_interval)),
        PathState::Unreadable { since, .. } => Some(since.after(timing.unreadable_retry_interval)),
        PathState::Stable { .. } | PathState::Digested { .. } | PathState::Excluded { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const SECOND: i64 = 1_000;

    fn timing() -> TimingPolicy {
        TimingPolicy {
            stabilization_interval: Duration::from_secs(5),
            unreadable_retry_interval: Duration::from_secs(60),
            ..TimingPolicy::default()
        }
    }

    fn signature(inode: u64, byte_size: u64) -> FileSignature {
        FileSignature {
            device: 7,
            inode,
            byte_size,
            modification_nanoseconds: 1_700_000_000_000_000_000,
            status_change_nanoseconds: 1_700_000_000_000_000_000,
            dataless: false,
        }
    }

    fn readable(inode: u64) -> ReadableSignature {
        classify_signature(signature(inode, 4_096)).unwrap()
    }

    fn digest(byte: u8) -> ContentDigest {
        ContentDigest::from_bytes([byte; 32])
    }

    fn listed(signature: FileSignature, at: i64) -> PathEvent {
        PathEvent::Listed {
            signature,
            at: Timestamp(at),
        }
    }

    fn finished(based_on: ReadableSignature, finding: DigestFinding, at: i64) -> PathEvent {
        PathEvent::DigestFinished {
            based_on,
            finding,
            at: Timestamp(at),
        }
    }

    fn stabilizing(signature: FileSignature, at: i64) -> PathState {
        PathState::Stabilizing {
            signature,
            observed_at: Timestamp(at),
        }
    }

    #[test]
    fn the_path_machine_follows_the_transition_table() {
        use PathTransition::{Remove, Store, Unchanged};
        let regular = signature(1, 4_096);
        let rewritten = signature(1, 8_192);
        let stable = PathState::Stable { signature: readable(1) };
        let digested = PathState::Digested {
            signature: readable(1),
            content: digest(0xAB),
        };
        let excluded = PathState::Excluded {
            signature: regular,
            reason: ExclusionReason::EmptyFile,
        };
        let unreadable = PathState::Unreadable {
            signature: readable(1),
            since: Timestamp(100 * SECOND),
            cause: "permission denied".to_owned(),
        };
        let dataless = FileSignature {
            dataless: true,
            ..regular
        };
        let stabilizing_regular = stabilizing(regular, 0);
        let stabilizing_empty = stabilizing(signature(1, 0), 0);
        let stabilizing_oversized = stabilizing(signature(1, 25_000_001), 0);
        let stabilizing_dataless = stabilizing(dataless, 0);
        let cases: Vec<(&str, Option<&PathState>, PathEvent, PathTransition)> = vec![
            (
                "a new entry starts stabilizing",
                None,
                listed(regular, 0),
                Store(stabilizing(regular, 0)),
            ),
            (
                "no row ignores every other event",
                None,
                PathEvent::NotListed,
                Unchanged,
            ),
            (
                "the same signature before the interval changes nothing",
                Some(&stabilizing_regular),
                listed(regular, 4 * SECOND),
                Unchanged,
            ),
            (
                "the same signature after the interval settles",
                Some(&stabilizing_regular),
                listed(regular, 5 * SECOND),
                Store(stable.clone()),
            ),
            (
                "an empty file settles as excluded",
                Some(&stabilizing_empty),
                listed(signature(1, 0), 5 * SECOND),
                Store(PathState::Excluded {
                    signature: signature(1, 0),
                    reason: ExclusionReason::EmptyFile,
                }),
            ),
            (
                "an oversized file settles as excluded",
                Some(&stabilizing_oversized),
                listed(signature(1, 25_000_001), 5 * SECOND),
                Store(PathState::Excluded {
                    signature: signature(1, 25_000_001),
                    reason: ExclusionReason::ExceedsSizeLimit,
                }),
            ),
            (
                "a placeholder settles as excluded",
                Some(&stabilizing_dataless),
                listed(dataless, 5 * SECOND),
                Store(PathState::Excluded {
                    signature: dataless,
                    reason: ExclusionReason::CloudPlaceholder,
                }),
            ),
            (
                "a changed signature resets the observation",
                Some(&stabilizing_regular),
                listed(rewritten, 3 * SECOND),
                Store(stabilizing(rewritten, 3 * SECOND)),
            ),
            (
                "a stable path keeps its state",
                Some(&stable),
                listed(regular, 9 * SECOND),
                Unchanged,
            ),
            (
                "a stable path that changed stabilizes again",
                Some(&stable),
                listed(rewritten, 9 * SECOND),
                Store(stabilizing(rewritten, 9 * SECOND)),
            ),
            (
                "a digested path keeps its state",
                Some(&digested),
                listed(regular, 9 * SECOND),
                Unchanged,
            ),
            (
                "a digested path that changed stabilizes again",
                Some(&digested),
                listed(rewritten, 9 * SECOND),
                Store(stabilizing(rewritten, 9 * SECOND)),
            ),
            (
                "an excluded path keeps its state",
                Some(&excluded),
                listed(regular, 9 * SECOND),
                Unchanged,
            ),
            (
                "an excluded path that changed stabilizes again",
                Some(&excluded),
                listed(rewritten, 9 * SECOND),
                Store(stabilizing(rewritten, 9 * SECOND)),
            ),
            (
                "an unreadable path waits for its retry interval",
                Some(&unreadable),
                listed(regular, 159 * SECOND),
                Unchanged,
            ),
            (
                "an unreadable path is read again after the retry interval",
                Some(&unreadable),
                listed(regular, 160 * SECOND),
                Store(stable.clone()),
            ),
            (
                "an unreadable path that changed stabilizes again",
                Some(&unreadable),
                listed(rewritten, 101 * SECOND),
                Store(stabilizing(rewritten, 101 * SECOND)),
            ),
            (
                "a stabilizing path not listed is removed",
                Some(&stabilizing_regular),
                PathEvent::NotListed,
                Remove,
            ),
            (
                "a digested path not listed is removed",
                Some(&digested),
                PathEvent::NotListed,
                Remove,
            ),
            (
                "an unreadable path not listed is removed",
                Some(&unreadable),
                PathEvent::NotListed,
                Remove,
            ),
            (
                "a digest of the reserved signature is recorded",
                Some(&stable),
                finished(
                    readable(1),
                    DigestFinding::Digested { content: digest(0xAB) },
                    10 * SECOND,
                ),
                Store(digested.clone()),
            ),
            (
                "a digest based on an older signature is stale",
                Some(&stable),
                finished(
                    readable(2),
                    DigestFinding::Digested { content: digest(0xAB) },
                    10 * SECOND,
                ),
                Unchanged,
            ),
            (
                "unrecognized leading bytes exclude the path",
                Some(&stable),
                finished(readable(1), DigestFinding::Unrecognized, 10 * SECOND),
                Store(PathState::Excluded {
                    signature: regular,
                    reason: ExclusionReason::UnrecognizedContent,
                }),
            ),
            (
                "a file that changed during the read stabilizes with the new signature",
                Some(&stable),
                finished(
                    readable(1),
                    DigestFinding::Changed {
                        current: Some(rewritten),
                    },
                    10 * SECOND,
                ),
                Store(stabilizing(rewritten, 10 * SECOND)),
            ),
            (
                "a file that vanished during the read waits for the listing",
                Some(&stable),
                finished(readable(1), DigestFinding::Changed { current: None }, 10 * SECOND),
                Unchanged,
            ),
            (
                "a refused read makes the path unreadable",
                Some(&stable),
                finished(
                    readable(1),
                    DigestFinding::ReadRefused {
                        cause: "permission denied".to_owned(),
                    },
                    10 * SECOND,
                ),
                Store(PathState::Unreadable {
                    signature: readable(1),
                    since: Timestamp(10 * SECOND),
                    cause: "permission denied".to_owned(),
                }),
            ),
            (
                "a repeated digest result for a digested path changes nothing",
                Some(&digested),
                finished(
                    readable(1),
                    DigestFinding::Digested { content: digest(0xAB) },
                    10 * SECOND,
                ),
                Unchanged,
            ),
            (
                "a digest result for a stabilizing path changes nothing",
                Some(&stabilizing_regular),
                finished(
                    readable(1),
                    DigestFinding::Digested { content: digest(0xAB) },
                    10 * SECOND,
                ),
                Unchanged,
            ),
            (
                "a source that could not be verified stabilizes again",
                Some(&digested),
                PathEvent::SourceVerificationFailed {
                    based_on: readable(1),
                    current: Some(rewritten),
                    at: Timestamp(20 * SECOND),
                },
                Store(stabilizing(rewritten, 20 * SECOND)),
            ),
            (
                "a source with the same signature but other bytes stabilizes again",
                Some(&digested),
                PathEvent::SourceVerificationFailed {
                    based_on: readable(1),
                    current: Some(regular),
                    at: Timestamp(20 * SECOND),
                },
                Store(stabilizing(regular, 20 * SECOND)),
            ),
            (
                "a source that vanished waits for the listing",
                Some(&digested),
                PathEvent::SourceVerificationFailed {
                    based_on: readable(1),
                    current: None,
                    at: Timestamp(20 * SECOND),
                },
                Unchanged,
            ),
            (
                "a source failure based on an older signature is stale",
                Some(&digested),
                PathEvent::SourceVerificationFailed {
                    based_on: readable(2),
                    current: Some(rewritten),
                    at: Timestamp(20 * SECOND),
                },
                Unchanged,
            ),
            (
                "a source failure for a stable path changes nothing",
                Some(&stable),
                PathEvent::SourceVerificationFailed {
                    based_on: readable(1),
                    current: Some(rewritten),
                    at: Timestamp(20 * SECOND),
                },
                Unchanged,
            ),
        ];
        for (name, current, event, expected) in cases {
            assert_eq!(advance_path(current, event, &timing()), expected, "{name}");
        }
    }

    #[test]
    fn listing_twice_yields_no_transition_until_the_interval_elapses() {
        let regular = signature(1, 4_096);
        let PathTransition::Store(first) = advance_path(None, listed(regular, 0), &timing()) else {
            panic!("the first listing stores a row")
        };
        assert_eq!(
            advance_path(Some(&first), listed(regular, 0), &timing()),
            PathTransition::Unchanged
        );
        assert_eq!(
            advance_path(Some(&first), listed(regular, 5 * SECOND), &timing()),
            PathTransition::Store(PathState::Stable { signature: readable(1) })
        );
    }

    #[test]
    fn only_stabilizing_and_unreadable_paths_ask_for_another_observation() {
        let regular = signature(1, 4_096);
        assert_eq!(
            next_observation_due(&stabilizing(regular, 2 * SECOND), &timing()),
            Some(Timestamp(7 * SECOND))
        );
        let unreadable = PathState::Unreadable {
            signature: readable(1),
            since: Timestamp(0),
            cause: String::new(),
        };
        assert_eq!(
            next_observation_due(&unreadable, &timing()),
            Some(Timestamp(60 * SECOND))
        );
        assert_eq!(
            next_observation_due(&PathState::Stable { signature: readable(1) }, &timing()),
            None
        );
        assert_eq!(
            next_observation_due(
                &PathState::Excluded {
                    signature: regular,
                    reason: ExclusionReason::EmptyFile
                },
                &timing()
            ),
            None
        );
    }
}
