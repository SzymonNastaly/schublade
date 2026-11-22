import AppKit

/// The application has a Dock icon and a main menu while one of its windows shows, and is an
/// accessory in the menu bar otherwise, so a start at login puts no icon into the Dock.
enum ActivationPolicy {
	static func becomeRegular() {
		if NSApp.activationPolicy() != .regular {
			NSApp.setActivationPolicy(.regular)
		}
	}

	/// Called as a window closes: another window, such as Settings, keeps the Dock icon.
	static func becomeAccessoryUnlessAnotherWindowShows(besides closing: NSWindow?) {
		if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.canBecomeMain }) {
			NSApp.setActivationPolicy(.accessory)
		}
	}
}
