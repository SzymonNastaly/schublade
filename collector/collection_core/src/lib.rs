//! The core of the Schublade collector: the state machines, their persistence, and the archive
//! client, as `notes/collector_design.md` describes them. The modules arrive in the order of the
//! design's module map.

pub mod archive_client;
pub mod archive_connection;
pub mod candidate_classification;
pub mod clock;
pub mod content_synchronization;
pub mod directory_reconciliation;
pub mod domain_types;
pub mod file_system_observation;
pub mod folder_admission;
pub mod path_lifecycle;
pub mod scripted_archive;
pub mod state_store;
pub mod status_report;
pub mod work_planning;
