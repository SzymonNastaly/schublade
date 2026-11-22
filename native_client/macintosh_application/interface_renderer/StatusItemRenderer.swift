import AppKit
import ApplicationBindings
import ApplicationInterface
import ApplicationPresentation

/// Writes the menu bar item as files: every glyph and upload frame enlarged on a menu bar's
/// background in both appearances, and the menu's rows as text for a resting and a busy Mac.
final class StatusItemRenderer {
	private static let scale: CGFloat = 4
	private static let cell = NSSize(width: 104, height: 104)

	private let outputDirectory: URL
	private let fixtures: RendererFixtures

	init(outputDirectory: URL, fixtures: RendererFixtures) {
		self.outputDirectory = outputDirectory
		self.fixtures = fixtures
	}

	func renderAll() async throws {
		try writeGlyphSheet(name: "status_item_glyphs_light", background: .white, ink: .black)
		try writeGlyphSheet(
			name: "status_item_glyphs_dark",
			background: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1),
			ink: .white
		)
		try await writeMenu()
	}

	/// The glyphs in the order of their precedence, then the eight frames of an upload.
	private func writeGlyphSheet(name: String, background: NSColor, ink: NSColor) throws {
		var images: [NSImage] = StatusItemGlyph.allCases.filter { $0 != .submitting }.map {
			DrawerGlyph.image($0, frame: nil)
		}
		images += (0 ..< StatusItemAnimation.frameCount).map { DrawerGlyph.image(.submitting, frame: $0) }
		let columns = 6
		let rows = (images.count + columns - 1) / columns
		let size = NSSize(width: Self.cell.width * CGFloat(columns), height: Self.cell.height * CGFloat(rows))
		guard let bitmap = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: Int(size.width),
			pixelsHigh: Int(size.height),
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
			throw CocoaError(.fileWriteUnknown)
		}
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = context
		background.setFill()
		NSRect(origin: .zero, size: size).fill()
		for (index, image) in images.enumerated() {
			let column = index % columns
			let row = rows - 1 - index / columns
			let glyphSize = NSSize(
				width: DrawerGlyph.size.width * Self.scale,
				height: DrawerGlyph.size.height * Self.scale
			)
			let origin = NSPoint(
				x: CGFloat(column) * Self.cell.width + (Self.cell.width - glyphSize.width) / 2,
				y: CGFloat(row) * Self.cell.height + (Self.cell.height - glyphSize.height) / 2
			)
			Self.tinted(image, with: ink).draw(in: NSRect(origin: origin, size: glyphSize))
		}
		NSGraphicsContext.restoreGraphicsState()
		guard let png = bitmap.representation(using: .png, properties: [:]) else {
			throw CocoaError(.fileWriteUnknown)
		}
		try png.write(to: outputDirectory.appending(path: "\(name).png"))
	}

	/// A template image as the menu bar draws it: its shape in one colour.
	private static func tinted(_ template: NSImage, with color: NSColor) -> NSImage {
		NSImage(size: template.size, flipped: false) { rect in
			template.draw(in: rect)
			color.set()
			rect.fill(using: .sourceAtop)
			return true
		}
	}

	private func writeMenu() async throws {
		let resting = fixtures.makeStatuses()
		let busy = fixtures.makeStatuses(collector: RendererFixtures.makeCollectorStatus(
			attention: [.backlogAwaitsDecision(folder: RendererFixtures.paperwork)],
			activities: [.submitting(fileName: "Tax assessment 2025.pdf", byteSize: 182_000)]
		))
		var text = ""
		for (title, statuses) in [("A resting Mac", resting), ("An upload and a folder awaiting its decision", busy)] {
			let controller = StatusItemController(queries: fixtures.queries.scene(listing: fixtures.sampleListing))
			controller.render(.running(statuses))
			controller.contentRevisionChanged()
			try await Task.sleep(for: .milliseconds(300))
			text += "\(title)\n\n" + controller.menuTitles.joined(separator: "\n") + "\n\n"
			NSStatusBar.system.removeStatusItem(controller.item)
		}
		try text.write(to: outputDirectory.appending(path: "status_item_menu.txt"), atomically: true, encoding: .utf8)
	}
}
