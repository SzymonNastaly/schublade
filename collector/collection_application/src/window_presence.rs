//! The window and the menu bar item. The app keeps running when the window closes, and its Dock
//! icon shows only while the window is open: the activation policy is Regular with the window and
//! Accessory without it.

use tauri::image::Image;
use tauri::menu::{MenuBuilder, MenuEvent, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{ActivationPolicy, AppHandle, Manager};

const MAIN_WINDOW: &str = "main";
const MENU_BAR_ITEM: &str = "menu_bar_item";
const OPEN_WINDOW_ITEM: &str = "open_window";
const QUIT_ITEM: &str = "quit";

pub fn show_main_window(application: &AppHandle) -> tauri::Result<()> {
    application.set_activation_policy(ActivationPolicy::Regular)?;
    if let Some(window) = application.get_webview_window(MAIN_WINDOW) {
        window.show()?;
        window.unminimize()?;
        window.set_focus()?;
    }
    Ok(())
}

pub fn hide_main_window(application: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = application.get_webview_window(MAIN_WINDOW) {
        window.hide()?;
    }
    application.set_activation_policy(ActivationPolicy::Accessory)
}

/// The menu bar item's menu. Registered once on the builder, because a handler given to each new
/// tray icon is added to the app's global listeners and never removed.
pub fn answer_menu_event(application: &AppHandle, event: &MenuEvent) {
    match event.id().as_ref() {
        OPEN_WINDOW_ITEM => {
            let _ = show_main_window(application);
        }
        QUIT_ITEM => application.exit(0),
        _ => {}
    }
}

/// Adds or removes the menu bar item. AppKit owns the item, so call this on the main thread only. Its icon is a template image, so macOS draws it in the
/// menu bar's own colour in light and dark mode.
pub fn show_menu_bar_item(application: &AppHandle, shown: bool) -> tauri::Result<()> {
    if !shown {
        application.remove_tray_by_id(MENU_BAR_ITEM);
        return Ok(());
    }
    if application.tray_by_id(MENU_BAR_ITEM).is_some() {
        return Ok(());
    }
    let menu = MenuBuilder::new(application)
        .item(&MenuItem::with_id(
            application,
            OPEN_WINDOW_ITEM,
            "Open Schublade Collector",
            true,
            None::<&str>,
        )?)
        .separator()
        .item(&MenuItem::with_id(application, QUIT_ITEM, "Quit", true, None::<&str>)?)
        .build()?;
    TrayIconBuilder::with_id(MENU_BAR_ITEM)
        .icon(Image::from_bytes(include_bytes!("../icons/menu_bar_template.png"))?)
        .icon_as_template(true)
        .tooltip("Schublade Collector")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = show_main_window(tray.app_handle());
            }
        })
        .build(application)?;
    Ok(())
}
