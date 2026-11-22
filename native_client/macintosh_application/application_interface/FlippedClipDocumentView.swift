import AppKit

/// Top-aligned document view used inside vertical inspector scroll views.
final class FlippedClipDocumentView: NSView {
	override var isFlipped: Bool {
		true
	}
}
