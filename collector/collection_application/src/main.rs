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
use tauri::{ActivationPolicy, Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

/// Passed by the login item, so a start at login collects without opening the window.
const STARTED_AT_LOGIN_ARGUMENT: &str = "--started-at-login";
/// A debug build is another app: its data directory, Keychain service, login item, and
/// single-instance socket all follow the identifier, so it never shares the installed app's.
const DEVELOPMENT_IDENTIFIER: &str = "org.schublade.collector.development";

fn main() {
    let mut context = tauri::generate_context!();
    if cfg!(debug_assertions) {
        DEVELOPMENT_IDENTIFIER.clone_into(&mut context.config_mut().identifier);
    }
    let identifier = context.config().identifier.clone();
    let started_at_login = std::env::args().any(|argument| argument == STARTED_AT_LOGIN_ARGUMENT);
    let mut application = tauri::Builder::default()
        // First, so a second launch hands over and exits before it starts anything.
        .plugin(tauri_plugin_single_instance::init(
            |application, arguments, _directory| {
                if !arguments.iter().any(|argument| argument == STARTED_AT_LOGIN_ARGUMENT) {
                    let _ = window_presence::show_main_window(application);
                }
            },
        ))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .macos_launcher(MacosLauncher::LaunchAgent)
                .app_name(&identifier)
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
        .setup(move |application| {
            let handle = application.handle().clone();
            // The login item names the executable's path, which goes stale when the app moves.
            if handle.autolaunch().is_enabled().unwrap_or(false) {
                let _ = handle.autolaunch().enable();
            }

            let data_directory = handle.path().app_data_dir().map_err(|error| error.to_string());
            // The command-line program keeps its own service, so connecting one never replaces the
            // other's token.
            let started = collector_presence::start_collector(data_directory, &handle.config().identifier);
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
            if collecting && started_at_login {
                window_presence::hide_main_window(&handle)?;
            } else {
                window_presence::show_main_window(&handle)?;
            }
            Ok(())
        })
        .on_menu_event(|application, event| window_presence::answer_menu_event(application, &event))
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window_presence::hide_main_window(window.app_handle());
            }
        })
        .build(context)
        .expect("the Tauri application could not be built");
    // Set before the event loop launches the app, which applies it while finishing the launch;
    // set in setup, it would follow the launch and the Dock icon would appear first.
    if started_at_login {
        application.set_activation_policy(ActivationPolicy::Accessory);
    }

    application.run(|handle, event| {
        // A click on the Dock icon, or opening the app again from Finder while it runs.
        if let RunEvent::Reopen { .. } = event {
            let _ = window_presence::show_main_window(handle);
        }
    });
}
