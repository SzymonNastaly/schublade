//! The folder machine: the admission region carries the user's consent for a folder's backlog, and
//! the orthogonal availability region says whether the folder's root can be listed. No path of a
//! folder is a submission source until the folder is Collecting and Available.

use crate::directory_reconciliation::ListingOutcome;
use crate::domain_types::Timestamp;

/// The consent region of a folder. Stored in `watched_folders.admission`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum FolderAdmission {
    /// Walking, digesting, and looking up; nothing is submitted from this folder.
    Surveying,
    /// The counts are complete; new arrivals still join the backlog.
    AwaitingDecision,
    /// The user chose to upload the backlog. Paths of this folder are submission sources.
    Collecting { decided_at: Timestamp },
}

/// The availability region. Never stored; every walk probes the root again.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum FolderAvailability {
    Available,
    Missing,
    AccessDenied,
}

/// A listing of a folder's root decides its availability and nothing else: a root that vanished
/// or could not be read never removes rows.
pub fn availability_after_root_listing(outcome: &ListingOutcome) -> FolderAvailability {
    match outcome {
        ListingOutcome::Listed { .. } => FolderAvailability::Available,
        ListingOutcome::Vanished => FolderAvailability::Missing,
        ListingOutcome::Unreadable { .. } => FolderAvailability::AccessDenied,
    }
}

/// What the store reports about one folder's survey.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SurveyProgress {
    /// Set by the coordinator when this process finished its first recursive walk.
    pub initial_walk_completed: bool,
    pub paths_stabilizing_or_stable: u64,
    pub contents_unresolved: u64,
}

/// Unreadable and Excluded paths never hold the survey back.
pub fn survey_complete(progress: &SurveyProgress) -> bool {
    progress.initial_walk_completed && progress.paths_stabilizing_or_stable == 0 && progress.contents_unresolved == 0
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionRefusal {
    SurveyIncomplete,
    AlreadyDecided,
}

/// Surveying to AwaitingDecision, once `survey_complete` holds. Never back.
pub fn conclude_survey(current: FolderAdmission, progress: &SurveyProgress) -> FolderAdmission {
    match current {
        FolderAdmission::Surveying if survey_complete(progress) => FolderAdmission::AwaitingDecision,
        other => other,
    }
}

/// AwaitingDecision to Collecting. Every other state refuses.
pub fn decide(current: FolderAdmission, at: Timestamp) -> Result<FolderAdmission, AdmissionRefusal> {
    match current {
        FolderAdmission::Surveying => Err(AdmissionRefusal::SurveyIncomplete),
        FolderAdmission::AwaitingDecision => Ok(FolderAdmission::Collecting { decided_at: at }),
        FolderAdmission::Collecting { .. } => Err(AdmissionRefusal::AlreadyDecided),
    }
}

/// Whether a path in this folder may be a submission source.
pub fn admits_submission(admission: FolderAdmission, availability: FolderAvailability) -> bool {
    matches!(admission, FolderAdmission::Collecting { .. }) && availability == FolderAvailability::Available
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMPLETE: SurveyProgress = SurveyProgress {
        initial_walk_completed: true,
        paths_stabilizing_or_stable: 0,
        contents_unresolved: 0,
    };

    #[test]
    fn a_survey_concludes_once_the_walk_finished_and_nothing_is_being_examined() {
        let incomplete = [
            SurveyProgress {
                initial_walk_completed: false,
                ..COMPLETE
            },
            SurveyProgress {
                paths_stabilizing_or_stable: 1,
                ..COMPLETE
            },
            SurveyProgress {
                contents_unresolved: 1,
                ..COMPLETE
            },
        ];
        for progress in incomplete {
            assert_eq!(
                conclude_survey(FolderAdmission::Surveying, &progress),
                FolderAdmission::Surveying,
                "{progress:?}"
            );
        }
        assert_eq!(
            conclude_survey(FolderAdmission::Surveying, &COMPLETE),
            FolderAdmission::AwaitingDecision
        );
        let collecting = FolderAdmission::Collecting {
            decided_at: Timestamp(5),
        };
        assert_eq!(conclude_survey(collecting, &COMPLETE), collecting);
    }

    #[test]
    fn only_a_folder_awaiting_its_decision_accepts_one() {
        assert_eq!(
            decide(FolderAdmission::Surveying, Timestamp(9)),
            Err(AdmissionRefusal::SurveyIncomplete)
        );
        assert_eq!(
            decide(FolderAdmission::AwaitingDecision, Timestamp(9)),
            Ok(FolderAdmission::Collecting {
                decided_at: Timestamp(9)
            })
        );
        assert_eq!(
            decide(
                FolderAdmission::Collecting {
                    decided_at: Timestamp(5)
                },
                Timestamp(9)
            ),
            Err(AdmissionRefusal::AlreadyDecided)
        );
    }

    #[test]
    fn only_a_collecting_and_available_folder_admits_submissions() {
        let collecting = FolderAdmission::Collecting {
            decided_at: Timestamp(5),
        };
        assert!(admits_submission(collecting, FolderAvailability::Available));
        assert!(!admits_submission(collecting, FolderAvailability::Missing));
        assert!(!admits_submission(collecting, FolderAvailability::AccessDenied));
        assert!(!admits_submission(
            FolderAdmission::AwaitingDecision,
            FolderAvailability::Available
        ));
        assert!(!admits_submission(
            FolderAdmission::Surveying,
            FolderAvailability::Available
        ));
    }

    #[test]
    fn a_root_listing_maps_to_availability() {
        let listed = ListingOutcome::Listed {
            files: vec![],
            subdirectories: vec![],
        };
        assert_eq!(availability_after_root_listing(&listed), FolderAvailability::Available);
        assert_eq!(
            availability_after_root_listing(&ListingOutcome::Vanished),
            FolderAvailability::Missing
        );
        assert_eq!(
            availability_after_root_listing(&ListingOutcome::Unreadable {
                cause: "permission denied".to_owned()
            }),
            FolderAvailability::AccessDenied
        );
    }
}
