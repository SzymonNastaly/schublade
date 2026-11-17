//! The core of the Schublade collector: the state machines, their persistence, and the archive
//! client, as `notes/collector_design.md` describes them. The modules arrive in the order of the
//! design's module map.

pub mod candidate_classification;
pub mod directory_reconciliation;
pub mod domain_types;
pub mod path_lifecycle;
