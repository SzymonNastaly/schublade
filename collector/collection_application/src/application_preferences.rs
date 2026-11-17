//! What the person chose about this Mac, apart from the collector's own state: whether the menu bar
//! item shows. Start at login lives with the login item itself, so it is read from there.

use std::path::PathBuf;

use tauri::{AppHandle, Manager};

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
pub struct StoredPreferences {
    pub menu_bar_item_shown: bool,
}

impl Default for StoredPreferences {
    fn default() -> StoredPreferences {
        StoredPreferences {
            menu_bar_item_shown: true,
        }
    }
}

fn preferences_path(application: &AppHandle) -> tauri::Result<PathBuf> {
    Ok(application
        .path()
        .app_config_dir()?
        .join("application_preferences.json"))
}

/// The stored preferences, or the defaults when none were stored or the file does not parse.
pub fn read(application: &AppHandle) -> StoredPreferences {
    preferences_path(application)
        .ok()
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn write(application: &AppHandle, preferences: StoredPreferences) -> Result<(), String> {
    let path = preferences_path(application).map_err(|error| error.to_string())?;
    if let Some(directory) = path.parent() {
        std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(&preferences).map_err(|error| error.to_string())?;
    std::fs::write(path, bytes).map_err(|error| error.to_string())
}
