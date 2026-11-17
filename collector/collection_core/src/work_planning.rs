//! Work is derived, never queued. After each batch the coordinator asks the store for candidates,
//! limited per lane, and `plan_work` turns them into work for the free capacity of each lane,
//! leaving out every key with a reservation. A crash loses only reservations, and the next plan
//! derives the same work again.

use std::collections::{BTreeMap, BTreeSet};

use crate::archive_connection::{ConnectionState, RequestCapacity, request_capacity};
use crate::candidate_classification::ReadableSignature;
use crate::content_synchronization::{
    ContentRecord, SubmissionAuthorization, SubmissionHindrance, authorize_submission,
};
use crate::domain_types::{
    ContentDigest, DirectoryKey, DocumentIdentifier, FolderIdentifier, PathKey, Timestamp, TimingPolicy,
};

/// 1000 digests take 67 KB as compact JSON, under the server's 128 KB limit.
pub const MAXIMUM_LOOKUP_DIGESTS: usize = 1000;
/// The newest documents this collector received that are still followed to a final status.
pub const MAXIMUM_FOLLOWED_DOCUMENTS: usize = 20;

/// One unit of I/O for a worker lane. Each carries what it is based on, and its result comes back
/// as an event through the machine that owns the key.
#[derive(Debug, PartialEq, Eq)]
pub enum Work {
    ListDirectory {
        folder: FolderIdentifier,
        directory: DirectoryKey,
        recursive: bool,
    },
    ComputeDigest {
        path: PathKey,
        signature: ReadableSignature,
    },
    LookUpContents {
        digests: Vec<ContentDigest>,
    },
    SubmitContent {
        authorization: SubmissionAuthorization,
        source: PathKey,
        signature: ReadableSignature,
    },
    ReadDocumentStatus {
        content: ContentDigest,
        document: DocumentIdentifier,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Lane {
    Listing,
    Digest,
    Lookup,
    Submission,
    DocumentStatus,
}

impl Lane {
    pub const ARCHIVE_LANES: [Lane; 3] = [Lane::Lookup, Lane::Submission, Lane::DocumentStatus];
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaneCapacity {
    pub listing: usize,
    pub digest: usize,
    pub lookup: usize,
    /// 1 or 2, from the collector settings.
    pub submission: usize,
    pub document_status: usize,
}

impl LaneCapacity {
    pub fn of(&self, lane: Lane) -> usize {
        match lane {
            Lane::Listing => self.listing,
            Lane::Digest => self.digest,
            Lane::Lookup => self.lookup,
            Lane::Submission => self.submission,
            Lane::DocumentStatus => self.document_status,
        }
    }
}

impl Default for LaneCapacity {
    /// The lane table of the design, with two submissions.
    fn default() -> LaneCapacity {
        LaneCapacity {
            listing: 1,
            digest: 2,
            lookup: 1,
            submission: 2,
            document_status: 1,
        }
    }
}

/// Numbers one lookup request, so the contents of one batch count as one occupant of the lane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LookupBatch(pub u64);

/// What content work is in flight. A content holds at most one reservation, so it is never looked
/// up and submitted at once, and never submitted twice at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContentReservation {
    LookingUp(LookupBatch),
    Submitting,
    FollowingDocument,
}

/// Work in flight. Held only in the coordinator's memory and never stored. A lane's occupancy is
/// the size of its reservation set.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reservations {
    pub directories: BTreeSet<(FolderIdentifier, DirectoryKey)>,
    pub paths: BTreeSet<PathKey>,
    pub contents: BTreeMap<ContentDigest, ContentReservation>,
}

impl Reservations {
    pub fn occupancy(&self, lane: Lane) -> usize {
        match lane {
            Lane::Listing => self.directories.len(),
            Lane::Digest => self.paths.len(),
            Lane::Lookup => self
                .contents
                .values()
                .filter_map(|reservation| match reservation {
                    ContentReservation::LookingUp(batch) => Some(*batch),
                    _ => None,
                })
                .collect::<BTreeSet<_>>()
                .len(),
            Lane::Submission => self.count(ContentReservation::Submitting),
            Lane::DocumentStatus => self.count(ContentReservation::FollowingDocument),
        }
    }

    fn count(&self, reservation: ContentReservation) -> usize {
        self.contents.values().filter(|held| **held == reservation).count()
    }

    pub fn free(&self, lane: Lane, capacity: &LaneCapacity) -> usize {
        capacity.of(lane).saturating_sub(self.occupancy(lane))
    }

    /// True when no work is in flight. `wait_until_idle` combines it with an empty plan.
    pub fn is_empty(&self) -> bool {
        self.directories.is_empty() && self.paths.is_empty() && self.contents.is_empty()
    }

    fn archive_requests_in_flight(&self) -> usize {
        Lane::ARCHIVE_LANES.iter().map(|lane| self.occupancy(*lane)).sum()
    }
}

/// Rows the store returned for planning, each query limited to the free capacity plus the
/// reserved count of its lane, ordered arrivals first (first observed after the folder's
/// decision), then backlog by `first_observed_at`.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct WorkCandidates {
    /// Directories with a Stabilizing or Unreadable row whose next observation is due, in
    /// available folders. The coordinator adds the listings it schedules itself.
    pub due_directories: Vec<(FolderIdentifier, DirectoryKey, bool)>,
    pub stable_paths: Vec<(PathKey, ReadableSignature)>,
    /// Unresolved contents with any Digested path in an available folder (survey or not), and
    /// Absent contents whose answer is stale and that have an admitted source.
    pub contents_to_look_up: Vec<ContentDigest>,
    /// Absent contents with at least one admitted source, each with its sources in order.
    pub contents_to_submit: Vec<(ContentRecord, Vec<(PathKey, ReadableSignature)>)>,
    pub documents_to_follow: Vec<(ContentDigest, DocumentIdentifier)>,
}

/// Pure. Never returns work for a reserved key or beyond a lane's capacity or the connection's
/// capacity. Calls `authorize_submission` for each submission; a stale content goes into the
/// lookup batch instead. Returns the same plan for the same inputs.
pub fn plan_work(
    candidates: WorkCandidates,
    reservations: &Reservations,
    capacity: &LaneCapacity,
    connection: &ConnectionState,
    now: Timestamp,
    timing: &TimingPolicy,
) -> Vec<Work> {
    let mut work = Vec::new();
    work.extend(
        candidates
            .due_directories
            .into_iter()
            .filter(|(folder, directory, _)| !reservations.directories.contains(&(*folder, directory.clone())))
            .take(reservations.free(Lane::Listing, capacity))
            .map(|(folder, directory, recursive)| Work::ListDirectory {
                folder,
                directory,
                recursive,
            }),
    );
    work.extend(
        candidates
            .stable_paths
            .into_iter()
            .filter(|(path, _)| !reservations.paths.contains(path))
            .take(reservations.free(Lane::Digest, capacity))
            .map(|(path, signature)| Work::ComputeDigest { path, signature }),
    );

    let archive_requests = match request_capacity(connection) {
        RequestCapacity::None => 0,
        RequestCapacity::Single => 1usize.saturating_sub(reservations.archive_requests_in_flight()),
        RequestCapacity::Unlimited => usize::MAX,
    };
    let unreserved = |digest: &ContentDigest| !reservations.contents.contains_key(digest);
    let mut lookups: Vec<ContentDigest> = candidates.contents_to_look_up.into_iter().filter(unreserved).collect();
    let mut submissions = Vec::new();
    for (record, sources) in candidates.contents_to_submit {
        if !unreserved(&record.digest) {
            continue;
        }
        match authorize_submission(&record, now, timing) {
            Ok(authorization) => {
                if let Some((source, signature)) = sources.into_iter().next() {
                    submissions.push(Work::SubmitContent {
                        authorization,
                        source,
                        signature,
                    });
                }
            }
            Err(SubmissionHindrance::LookupStale) => lookups.push(record.digest),
            Err(SubmissionHindrance::BackingOff { .. } | SubmissionHindrance::NotAbsent) => {}
        }
    }
    let mut seen = BTreeSet::new();
    lookups.retain(|digest| seen.insert(*digest));
    let lookups = lookups
        .chunks(MAXIMUM_LOOKUP_DIGESTS)
        .take(reservations.free(Lane::Lookup, capacity))
        .map(|digests| Work::LookUpContents {
            digests: digests.to_vec(),
        });
    let submissions = submissions
        .into_iter()
        .take(reservations.free(Lane::Submission, capacity));
    let status_reads = candidates
        .documents_to_follow
        .into_iter()
        .filter(|(content, _)| unreserved(content))
        .take(reservations.free(Lane::DocumentStatus, capacity))
        .map(|(content, document)| Work::ReadDocumentStatus { content, document });
    work.extend(lookups.chain(submissions).chain(status_reads).take(archive_requests));
    work
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate_classification::classify_signature;
    use crate::content_synchronization::{ArchiveStanding, SubmissionFailures};
    use crate::domain_types::{EntryName, FileSignature};

    const MINUTE: i64 = 60_000;
    const NOW: Timestamp = Timestamp(100 * MINUTE);

    fn digest(byte: u8) -> ContentDigest {
        ContentDigest::from_bytes([byte; 32])
    }

    fn signature(inode: u64) -> ReadableSignature {
        classify_signature(FileSignature {
            device: 1,
            inode,
            byte_size: 10,
            modification_nanoseconds: 0,
            status_change_nanoseconds: 0,
            dataless: false,
        })
        .unwrap()
    }

    fn path(name: &str) -> PathKey {
        PathKey {
            folder: FolderIdentifier::new(1),
            directory: DirectoryKey::root(),
            name: EntryName::new(name),
        }
    }

    fn absent(byte: u8, looked_up_at: Timestamp, retry_not_before: Option<Timestamp>) -> ContentRecord {
        ContentRecord {
            digest: digest(byte),
            standing: ArchiveStanding::Absent {
                looked_up_at,
                failures: SubmissionFailures {
                    count: 0,
                    retry_not_before,
                },
            },
        }
    }

    fn document(last: char) -> DocumentIdentifier {
        DocumentIdentifier::parse(&format!("4c5d6e7f-8091-4a2b-9c3d-4e5f6071829{last}")).unwrap()
    }

    fn candidates() -> WorkCandidates {
        WorkCandidates {
            due_directories: vec![
                (FolderIdentifier::new(1), DirectoryKey::root(), false),
                (
                    FolderIdentifier::new(1),
                    DirectoryKey::from_stored_text("Scans".to_owned()),
                    false,
                ),
            ],
            stable_paths: vec![
                (path("a.pdf"), signature(1)),
                (path("b.pdf"), signature(2)),
                (path("c.pdf"), signature(3)),
            ],
            contents_to_look_up: vec![digest(1), digest(2)],
            contents_to_submit: vec![
                (
                    absent(3, Timestamp(95 * MINUTE), None),
                    vec![(path("d.pdf"), signature(4)), (path("e.pdf"), signature(5))],
                ),
                (
                    absent(4, Timestamp(80 * MINUTE), None),
                    vec![(path("f.pdf"), signature(6))],
                ),
                (
                    absent(5, Timestamp(95 * MINUTE), Some(Timestamp(101 * MINUTE))),
                    vec![(path("g.pdf"), signature(7))],
                ),
                (
                    absent(6, Timestamp(95 * MINUTE), None),
                    vec![(path("h.pdf"), signature(8))],
                ),
            ],
            documents_to_follow: vec![(digest(7), document('3')), (digest(8), document('4'))],
        }
    }

    fn digests_of(work: &Work) -> Vec<ContentDigest> {
        match work {
            Work::LookUpContents { digests } => digests.clone(),
            _ => panic!("not a lookup: {work:?}"),
        }
    }

    #[test]
    fn a_plan_fills_each_free_lane_and_moves_a_stale_answer_into_the_lookup() {
        let timing = TimingPolicy::default();
        let capacity = LaneCapacity {
            document_status: 2,
            ..LaneCapacity::default()
        };
        let mut reservations = Reservations::default();
        reservations.paths.insert(path("a.pdf"));
        reservations.contents.insert(digest(6), ContentReservation::Submitting);
        reservations
            .contents
            .insert(digest(8), ContentReservation::FollowingDocument);

        let work = plan_work(
            candidates(),
            &reservations,
            &capacity,
            &ConnectionState::Available,
            NOW,
            &timing,
        );

        let authorization = match &work[3] {
            Work::SubmitContent {
                authorization,
                source,
                signature: submitted,
            } => {
                assert_eq!((source, submitted), (&path("d.pdf"), &signature(4)));
                authorization
            }
            other => panic!("expected a submission, found {other:?}"),
        };
        assert_eq!(authorization.digest(), digest(3));
        assert_eq!(work.len(), 5, "{work:?}");
        assert_eq!(
            work[0],
            Work::ListDirectory {
                folder: FolderIdentifier::new(1),
                directory: DirectoryKey::root(),
                recursive: false
            }
        );
        assert_eq!(
            work[1],
            Work::ComputeDigest {
                path: path("b.pdf"),
                signature: signature(2)
            }
        );
        assert_eq!(digests_of(&work[2]), vec![digest(1), digest(2), digest(4)]);
        assert_eq!(
            work[4],
            Work::ReadDocumentStatus {
                content: digest(7),
                document: document('3')
            }
        );
    }

    #[test]
    fn the_connection_limits_the_archive_lanes_together() {
        let timing = TimingPolicy::default();
        let capacity = LaneCapacity::default();
        let probing = ConnectionState::Probing {
            since: Timestamp(0),
            attempt: 1,
        };
        let deferred = ConnectionState::Deferred {
            until: Timestamp(200 * MINUTE),
        };

        let none = plan_work(
            candidates(),
            &Reservations::default(),
            &capacity,
            &deferred,
            NOW,
            &timing,
        );
        assert!(
            none.iter()
                .all(|work| matches!(work, Work::ListDirectory { .. } | Work::ComputeDigest { .. })),
            "{none:?}"
        );

        let single = plan_work(
            candidates(),
            &Reservations::default(),
            &capacity,
            &probing,
            NOW,
            &timing,
        );
        assert_eq!(single.len(), 4);
        assert_eq!(digests_of(&single[3]), vec![digest(1), digest(2), digest(4)]);

        let mut in_flight = Reservations::default();
        in_flight
            .contents
            .insert(digest(9), ContentReservation::LookingUp(LookupBatch(1)));
        let occupied = plan_work(candidates(), &in_flight, &capacity, &probing, NOW, &timing);
        assert_eq!(occupied.len(), 3);
    }

    #[test]
    fn a_lookup_holds_at_most_a_thousand_digests_and_each_digest_once() {
        let timing = TimingPolicy::default();
        let capacity = LaneCapacity {
            lookup: 2,
            ..LaneCapacity::default()
        };
        let digests: Vec<ContentDigest> = (0..1200u16)
            .map(|index| ContentDigest::from_bytes(index.to_be_bytes().repeat(16).try_into().unwrap()))
            .collect();
        let candidates = WorkCandidates {
            contents_to_look_up: [digests.clone(), digests[..5].to_vec()].concat(),
            ..WorkCandidates::default()
        };

        let work = plan_work(
            candidates,
            &Reservations::default(),
            &capacity,
            &ConnectionState::Available,
            NOW,
            &timing,
        );

        assert_eq!(work.len(), 2);
        assert_eq!(digests_of(&work[0]).len(), MAXIMUM_LOOKUP_DIGESTS);
        assert_eq!(digests_of(&work[1]), digests[1000..].to_vec());
    }

    #[test]
    fn occupancy_counts_lookup_batches_once_and_idleness_needs_no_reservation() {
        let mut reservations = Reservations::default();
        assert!(reservations.is_empty());
        reservations
            .contents
            .insert(digest(1), ContentReservation::LookingUp(LookupBatch(4)));
        reservations
            .contents
            .insert(digest(2), ContentReservation::LookingUp(LookupBatch(4)));
        reservations
            .contents
            .insert(digest(3), ContentReservation::LookingUp(LookupBatch(5)));
        reservations.contents.insert(digest(4), ContentReservation::Submitting);
        reservations
            .directories
            .insert((FolderIdentifier::new(1), DirectoryKey::root()));
        assert_eq!(reservations.occupancy(Lane::Lookup), 2);
        assert_eq!(reservations.occupancy(Lane::Submission), 1);
        assert_eq!(reservations.occupancy(Lane::DocumentStatus), 0);
        assert_eq!(reservations.occupancy(Lane::Listing), 1);
        assert_eq!(reservations.free(Lane::Submission, &LaneCapacity::default()), 1);
        assert_eq!(reservations.free(Lane::Lookup, &LaneCapacity::default()), 0);
        assert!(!reservations.is_empty());
    }
}
