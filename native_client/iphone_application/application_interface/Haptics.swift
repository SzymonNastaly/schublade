import UIKit

/// One function per moment that a person feels, so no screen picks a generator of its own.
enum Haptics {
	/// A scan or an import landed as a row on top of the library.
	static func arrivalLanded() {
		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
	}

	/// An arrival became its filed document.
	static func arrivalFiled() {
		UINotificationFeedbackGenerator().notificationOccurred(.success)
	}

	/// The archive did not accept an arrival, or refused the token.
	static func arrivalRefused() {
		UINotificationFeedbackGenerator().notificationOccurred(.error)
	}

	/// A person copied a fact of a document's details.
	static func factCopied() {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	/// The archive refused a connection, or its address or token was missing.
	static func connectionRefused() {
		UINotificationFeedbackGenerator().notificationOccurred(.error)
	}

	/// The share sheet has handed every file to its upload.
	static func shareHandedOver() {
		UINotificationFeedbackGenerator().notificationOccurred(.success)
	}

	/// The share sheet could not read a file a person shared.
	static func shareUnread() {
		UINotificationFeedbackGenerator().notificationOccurred(.warning)
	}
}
