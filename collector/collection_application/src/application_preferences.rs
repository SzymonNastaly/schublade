//! What the person chose about this Mac, apart from the collector's own state: whether the menu bar
//! item shows, and whether start at login was ever set. Start at login itself lives with the login
//! item, so it is read from there.

use std::path::PathBuf;
use std::sync::Mutex;

use tauri::{AppHandle, Manager};

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct StoredPreferences {
    pub menu_bar_item_shown: bool,
    /// Set by the first successful connection, which turns start at login on, or by the person's
    /// own choice, so a later connection never overrides what the person chose.
    pub start_at_login_established: bool,
}

impl Default for StoredPreferences {
    fn default() -> StoredPreferences {
        StoredPreferences {
            menu_bar_item_shown: true,
            start_at_login_established: false,
        }
    }
}

/// Serializes each read and write of the file, since the window's commands run on several threads.
static PREFERENCES_FILE: Mutex<()> = Mutex::new(());

fn preferences_path(application: &AppHandle) -> tauri::Result<PathBuf> {
    Ok(application
        .path()
        .app_config_dir()?
        .join("application_preferences.json"))
}

fn read_unguarded(application: &AppHandle) -> StoredPreferences {
    preferences_path(application)
        .ok()
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// The stored preferences, or the defaults when none were stored or the file does not parse.
pub fn read(application: &AppHandle) -> StoredPreferences {
    let _file = PREFERENCES_FILE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    read_unguarded(application)
}

/// Reads, changes, and writes the preferences as one step, and answers what was written.
pub fn update(
    application: &AppHandle,
    change: impl FnOnce(&mut StoredPreferences),
) -> Result<StoredPreferences, String> {
    let _file = PREFERENCES_FILE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut preferences = read_unguarded(application);
    change(&mut preferences);
    let path = preferences_path(application).map_err(|error| error.to_string())?;
    if let Some(directory) = path.parent() {
        std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(&preferences).map_err(|error| error.to_string())?;
    std::fs::write(path, bytes).map_err(|error| error.to_string())?;
    Ok(preferences)
}
