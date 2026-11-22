import AppKit

/// A document row's background: the website's light blue selection with a blue edge on the
/// leading side, which keeps the row's text and its link-blue title legible, unlike AppKit's
/// solid accent fill.
final class DocumentListRowView: NSTableRowView {
	static let identifier = NSUserInterfaceItemIdentifier("schublade.documentList.rowView")

	override var interiorBackgroundStyle: NSView.BackgroundStyle {
		.normal
	}

	override func drawSelection(in _: NSRect) {
		let area = bounds.insetBy(dx: 6, dy: 2)
		(isEmphasized ? InterfacePalette.selectionFill : InterfacePalette.inactiveSelectionFill).setFill()
		NSBezierPath(roundedRect: area, xRadius: 6, yRadius: 6).fill()
		let edge = NSRect(x: area.minX + 3, y: area.minY + 8, width: 3, height: area.height - 16)
		(isEmphasized ? InterfacePalette.selectionEdge : InterfacePalette.inactiveSelectionEdge).setFill()
		NSBezierPath(roundedRect: edge, xRadius: 1.5, yRadius: 1.5).fill()
	}
}
