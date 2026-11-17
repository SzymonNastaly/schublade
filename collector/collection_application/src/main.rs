//! Schublade Collector: one `Collector` from the core behind a Tauri window, a menu bar item, and
//! start at login. The app holds no collection logic; its commands map one to one to the core's
//! methods, and the core's events reach the window as `collector_event`.

#[cfg(not(target_os = "macos"))]
compile_error!("collection_application is a macOS app; build collection_command on other systems.");

mod application_commands;
mod application_preferences;
mod collector_presence;
mod window_presence;

use std::sync::Arc;

use collector_presence::CollectorPresence;
use tauri::{Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_autostart::MacosLauncher;

/// Passed by the login item, so a start at login collects without opening the window.
const STARTED_AT_LOGIN_ARGUMENT: &str = "--started-at-login";
/// The Keychain service of the command-line program as well, so both read one token.
const KEYCHAIN_SERVICE: &str = "Schublade collector";

fn main() {
    let application = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .macos_launcher(MacosLauncher::LaunchAgent)
                .args([STARTED_AT_LOGIN_ARGUMENT])
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            application_commands::read_collector_status,
            application_commands::connect_archive,
            application_commands::enroll_folder,
            application_commands::withdraw_folder,
            application_commands::decide_backlog,
            application_commands::read_application_preferences,
            application_commands::change_application_preferences,
            application_commands::quit_application,
        ])
        .setup(|application| {
            let handle = application.handle().clone();
            let data_directory = handle.path().app_data_dir().map_err(|error| error.to_string());
            let started = collector_presence::start_collector(data_directory, KEYCHAIN_SERVICE);
            let collecting = started.is_ok();
            match started {
                Ok((collector, events)) => {
                    application.manage(CollectorPresence::Running(Arc::new(collector)));
                    let emitter = handle.clone();
                    std::thread::Builder::new()
                        .name("collector-events".to_owned())
                        .spawn(move || {
                            for event in events {
                                let _ = emitter.emit("collector_event", &event);
                            }
                        })?;
                }
                Err(failure) => {
                    application.manage(CollectorPresence::NotStarted(failure));
                }
            }

            let preferences = application_preferences::read(&handle);
            window_presence::show_menu_bar_item(&handle, preferences.menu_bar_item_shown)?;
            // A failure shows the window even at login, so the collector never stops unseen.
            if collecting && std::env::args().any(|argument| argument == STARTED_AT_LOGIN_ARGUMENT) {
                window_presence::hide_main_window(&handle)?;
            } else {
                window_presence::show_main_window(&handle)?;
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window_presence::hide_main_window(window.app_handle());
            }
        })
        .build(tauri::generate_context!())
        .expect("the Tauri application could not be built");

    application.run(|handle, event| {
        // A click on the Dock icon, or opening the app again from Finder while it runs.
        if let RunEvent::Reopen { .. } = event {
            let _ = window_presence::show_main_window(handle);
        }
    });
}
