//! The collector the app runs, or why it could not start. A failed start keeps the app running, so
//! the window can say what happened instead of the app vanishing.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::Receiver;

use collection_core::state_store::StoreOpenFailure;
use collection_core::{Collector, CollectorEvent, CollectorSettings, KeychainCredentialStore, StartFailure};

use crate::application_commands::ApplicationRefusal;

pub enum CollectorPresence {
    Running(Arc<Collector>),
    NotStarted(CollectorStartFailure),
}

impl CollectorPresence {
    /// The running collector, or the refusal that carries why it did not start.
    pub fn collector(&self) -> Result<Arc<Collector>, ApplicationRefusal> {
        match self {
            CollectorPresence::Running(collector) => Ok(Arc::clone(collector)),
            CollectorPresence::NotStarted(failure) => Err(ApplicationRefusal::CollectorNotStarted {
                failure: failure.clone(),
            }),
        }
    }
}

/// Why the collector did not start, serialized with serde's external tagging for the window.
#[derive(Clone, Debug, serde::Serialize)]
pub enum CollectorStartFailure {
    DataDirectoryUnavailable { detail: String },
    DatabaseInUse,
    DatabaseNewerThanApplication,
    DatabaseUnusable { detail: String },
    WatcherUnavailable { detail: String },
}

impl From<StartFailure> for CollectorStartFailure {
    fn from(failure: StartFailure) -> CollectorStartFailure {
        let detail = failure.to_string();
        match failure {
            StartFailure::Store(StoreOpenFailure::InUse { .. }) => CollectorStartFailure::DatabaseInUse,
            StartFailure::Store(StoreOpenFailure::NewerSchema { .. }) => {
                CollectorStartFailure::DatabaseNewerThanApplication
            }
            StartFailure::Store(_) => CollectorStartFailure::DatabaseUnusable { detail },
            StartFailure::Watcher(_) => CollectorStartFailure::WatcherUnavailable { detail },
        }
    }
}

/// Starts the collector on `collector.sqlite` in the data directory. A database that fails its
/// check is renamed aside by the core, which then refuses to start; the second start opens a
/// fresh one, and the window returns to setup.
pub fn start_collector(
    data_directory: Result<PathBuf, String>,
    keychain_service: &str,
) -> Result<(Collector, Receiver<CollectorEvent>), CollectorStartFailure> {
    let data_directory = data_directory.map_err(|detail| CollectorStartFailure::DataDirectoryUnavailable { detail })?;
    std::fs::create_dir_all(&data_directory).map_err(|error| CollectorStartFailure::DataDirectoryUnavailable {
        detail: error.to_string(),
    })?;
    let database_path = data_directory.join("collector.sqlite");
    let settings = || {
        CollectorSettings::new(
            database_path.clone(),
            Box::new(KeychainCredentialStore::new(keychain_service)),
        )
    };
    let started = match Collector::start(settings()) {
        Err(StartFailure::Store(StoreOpenFailure::Unreadable { .. })) => Collector::start(settings()),
        started => started,
    };
    started.map_err(CollectorStartFailure::from)
}
