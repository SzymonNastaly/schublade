//! The commands the window invokes. Each maps to one method of the core's `Collector`, runs off the
//! main thread, and answers a refusal the window words in plain sentences.

use std::path::PathBuf;
use std::sync::Arc;

use collection_core::archive_connection::ArchiveCondition;
use collection_core::{
    ArchiveAddress, Collector, CollectorStatus, CommandRefusal, ConnectionStatus, FolderIdentifier, HttpArchiveClient,
    IngestToken,
};
use tauri::{AppHandle, State};
use tauri_plugin_autostart::ManagerExt;

use crate::application_preferences::{self, StoredPreferences};
use crate::window_presence;

/// Every way a command can fail, serialized with serde's external tagging like the core's types.
#[derive(Debug, serde::Serialize)]
pub enum ApplicationRefusal {
    AddressInvalid { detail: String },
    TokenRefused,
    TokenInsufficient,
    ArchiveUnreachable,
    ArchiveUnavailable { retry_after_seconds: u64 },
    ArchiveFailed,
    NotAnArchive { detail: String },
    PreferenceNotApplied { detail: String },
    CommandRefused { refusal: CommandRefusal },
}

impl From<CommandRefusal> for ApplicationRefusal {
    fn from(refusal: CommandRefusal) -> ApplicationRefusal {
        ApplicationRefusal::CommandRefused { refusal }
    }
}

impl From<ArchiveCondition> for ApplicationRefusal {
    fn from(condition: ArchiveCondition) -> ApplicationRefusal {
        match condition {
            ArchiveCondition::CredentialRefused => ApplicationRefusal::TokenRefused,
            ArchiveCondition::CredentialInsufficient => ApplicationRefusal::TokenInsufficient,
            ArchiveCondition::ServiceUnavailable { retry_after } => ApplicationRefusal::ArchiveUnavailable {
                retry_after_seconds: retry_after.as_secs(),
            },
            ArchiveCondition::ConnectionFailed | ArchiveCondition::TimedOut => ApplicationRefusal::ArchiveUnreachable,
            ArchiveCondition::ServerError | ArchiveCondition::DigestDisagreement => ApplicationRefusal::ArchiveFailed,
            ArchiveCondition::ProtocolViolation { detail } => ApplicationRefusal::NotAnArchive { detail },
        }
    }
}

type SharedCollector = Arc<Collector>;

/// Runs blocking work on Tauri's blocking pool, so neither the main thread nor an async worker waits
/// on the coordinator or the network.
async fn off_main_thread<Answer: Send + 'static>(
    work: impl FnOnce() -> Result<Answer, ApplicationRefusal> + Send + 'static,
) -> Result<Answer, ApplicationRefusal> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .unwrap_or(Err(ApplicationRefusal::CommandRefused {
            refusal: CommandRefusal::CollectorStopped,
        }))
}

#[tauri::command]
pub async fn read_collector_status(
    collector: State<'_, SharedCollector>,
) -> Result<CollectorStatus, ApplicationRefusal> {
    let collector = Arc::clone(&collector);
    off_main_thread(move || Ok(collector.status()?)).await
}

/// Tries the address and token against the archive before the core stores either, so a wrong token
/// is refused on the setup screen instead of suspending the collector later. The first connection
/// also turns on start at login.
#[tauri::command]
pub async fn connect_archive(
    application: AppHandle,
    collector: State<'_, SharedCollector>,
    address: String,
    token: String,
) -> Result<(), ApplicationRefusal> {
    let collector = Arc::clone(&collector);
    off_main_thread(move || {
        let address = ArchiveAddress::parse(&address)
            .map_err(|refusal| ApplicationRefusal::AddressInvalid { detail: refusal.detail })?;
        let token = IngestToken::new(token);
        HttpArchiveClient::new(&address, &token).verify_credential()?;
        let first_connection = collector.status()?.connection == ConnectionStatus::Unconfigured;
        collector.connect_archive(address, token)?;
        if first_connection {
            let _ = application.autolaunch().enable();
        }
        Ok(())
    })
    .await
}

#[tauri::command]
pub async fn enroll_folder(collector: State<'_, SharedCollector>, root: PathBuf) -> Result<(), ApplicationRefusal> {
    let collector = Arc::clone(&collector);
    off_main_thread(move || Ok(collector.enroll_folder(root).map(|_| ())?)).await
}

#[tauri::command]
pub async fn withdraw_folder(collector: State<'_, SharedCollector>, folder: i64) -> Result<(), ApplicationRefusal> {
    let collector = Arc::clone(&collector);
    off_main_thread(move || Ok(collector.withdraw_folder(FolderIdentifier::new(folder))?)).await
}

/// The window names exactly the folders whose counts it showed.
#[tauri::command]
pub async fn decide_backlog(
    collector: State<'_, SharedCollector>,
    folders: Vec<i64>,
) -> Result<(), ApplicationRefusal> {
    let collector = Arc::clone(&collector);
    let folders: Vec<FolderIdentifier> = folders.into_iter().map(FolderIdentifier::new).collect();
    off_main_thread(move || Ok(collector.decide_backlog(&folders)?)).await
}

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
pub struct ApplicationPreferences {
    menu_bar_item_shown: bool,
    start_at_login: bool,
}

fn current_preferences(application: &AppHandle) -> Result<ApplicationPreferences, ApplicationRefusal> {
    let start_at_login =
        application
            .autolaunch()
            .is_enabled()
            .map_err(|error| ApplicationRefusal::PreferenceNotApplied {
                detail: error.to_string(),
            })?;
    Ok(ApplicationPreferences {
        menu_bar_item_shown: application_preferences::read(application).menu_bar_item_shown,
        start_at_login,
    })
}

#[tauri::command]
pub async fn read_application_preferences(
    application: AppHandle,
) -> Result<ApplicationPreferences, ApplicationRefusal> {
    current_preferences(&application)
}

/// Applies each preference that changed and answers what now holds.
#[tauri::command]
pub async fn change_application_preferences(
    application: AppHandle,
    preferences: ApplicationPreferences,
) -> Result<ApplicationPreferences, ApplicationRefusal> {
    let not_applied = |detail: String| ApplicationRefusal::PreferenceNotApplied { detail };
    let current = current_preferences(&application)?;
    if preferences.start_at_login != current.start_at_login {
        let launcher = application.autolaunch();
        let changed = if preferences.start_at_login {
            launcher.enable()
        } else {
            launcher.disable()
        };
        changed.map_err(|error| not_applied(error.to_string()))?;
    }
    if preferences.menu_bar_item_shown != current.menu_bar_item_shown {
        window_presence::show_menu_bar_item(&application, preferences.menu_bar_item_shown)
            .map_err(|error| not_applied(error.to_string()))?;
        application_preferences::write(
            &application,
            StoredPreferences {
                menu_bar_item_shown: preferences.menu_bar_item_shown,
            },
        )
        .map_err(not_applied)?;
    }
    current_preferences(&application)
}
