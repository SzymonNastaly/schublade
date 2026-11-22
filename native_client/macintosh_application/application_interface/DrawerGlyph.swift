import AppKit
import ApplicationPresentation

/// The menu bar item's glyphs, drawn as template images from the drawer of
/// `application/menu_bar_template.svg`, so the system tints them for the menu bar in both
/// appearances. Core Animation is not used, because layer contents bypass the template tint.
public enum DrawerGlyph {
	/// The menu bar's glyph size, in points.
	public static let size = NSSize(width: 18, height: 18)
	/// The drawing's coordinates are those of the SVG's view box, 64 units from the top.
	private static let unitsPerPoint: CGFloat = 64 / 18
	private static let strokeWidth: CGFloat = 3.6

	/// The image of a glyph, or of an upload's frame when `frame` is given.
	public static func image(_ glyph: StatusItemGlyph, frame: Int?) -> NSImage {
		let image = NSImage(size: size, flipped: true) { _ in
			guard let context = NSGraphicsContext.current else {
				return false
			}
			context.cgContext.scaleBy(x: 1 / unitsPerPoint, y: 1 / unitsPerPoint)
			context.cgContext.translateBy(x: -2, y: 0)
			NSColor.black.set()
			draw(glyph, frame: frame, in: context)
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = NSRunningApplication.current.localizedName
		return image
	}

	private static func draw(_ glyph: StatusItemGlyph, frame: Int?, in context: NSGraphicsContext) {
		switch glyph {
		case .resting:
			drawSheets(sinkingBy: nil, dashed: false, in: context)
		case .submitting:
			drawSheets(sinkingBy: frame.map(sinking(atFrame:)) ?? 0, dashed: false, in: context)
		case .archiveUnreachable:
			drawSheets(sinkingBy: nil, dashed: true, in: context)
		case .attentionRequired:
			drawSheets(sinkingBy: nil, dashed: false, in: context)
			drawBadge(in: context)
		case .archiveNotConnected:
			drawSlash(in: context)
		case .starting:
			break
		}
		drawer().fill()
	}

	/// How far the front sheet has sunk at a frame: from well above the drawer to inside it.
	private static func sinking(atFrame frame: Int) -> CGFloat {
		let progress = CGFloat(frame) / CGFloat(StatusItemAnimation.frameCount - 1)
		return -14 + progress * 30
	}

	/// The back sheet, then the front sheet over it, or sinking into the drawer by an offset.
	private static func drawSheets(sinkingBy offset: CGFloat?, dashed: Bool, in context: NSGraphicsContext) {
		let back = sheet([(21, 40), (24, 12), (50, 15), (47, 40)])
		var front = sheet([(13, 40), (12, 20), (34, 17.5), (38, 40)])
		if let offset {
			front = sheet([(13, 40 + offset), (12, 20 + offset), (34, 17.5 + offset), (38, 40 + offset)])
		}
		for path in [back, front] {
			path.lineWidth = strokeWidth
			path.lineJoinStyle = .round
			if dashed {
				path.setLineDash([5, 4], count: 2, phase: 0)
			}
		}
		context.saveGraphicsState()
		// Above the drawer only, so a sinking sheet disappears into it.
		NSBezierPath(rect: NSRect(x: 0, y: 0, width: 72, height: 39)).addClip()
		back.stroke()
		clear(front, widenedBy: strokeWidth, in: context)
		front.stroke()
		context.restoreGraphicsState()
	}

	/// A slash across the empty drawer: no archive to put a sheet into.
	private static func drawSlash(in context: NSGraphicsContext) {
		let slash = NSBezierPath()
		slash.move(to: NSPoint(x: 14, y: 8))
		slash.line(to: NSPoint(x: 52, y: 36))
		slash.lineWidth = strokeWidth
		slash.lineCapStyle = .round
		slash.stroke()
	}

	/// A filled circle with an exclamation mark cut out of it, at the top right.
	private static func drawBadge(in context: NSGraphicsContext) {
		let circle = NSBezierPath(ovalIn: NSRect(x: 42, y: 2, width: 22, height: 22))
		clear(circle, widenedBy: 6, in: context)
		circle.fill()
		context.saveGraphicsState()
		context.compositingOperation = .destinationOut
		NSBezierPath(roundedRect: NSRect(x: 51.2, y: 6, width: 3.6, height: 9), xRadius: 1.8, yRadius: 1.8).fill()
		NSBezierPath(ovalIn: NSRect(x: 51.2, y: 16.4, width: 3.6, height: 3.6)).fill()
		context.restoreGraphicsState()
	}

	/// The drawer's body with its handle cut out.
	private static func drawer() -> NSBezierPath {
		let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 38, width: 54, height: 24), xRadius: 3, yRadius: 3)
		body.append(NSBezierPath(roundedRect: NSRect(x: 23, y: 47, width: 20, height: 7), xRadius: 3.5, yRadius: 3.5))
		body.windingRule = .evenOdd
		return body
	}

	private static func sheet(_ corners: [(CGFloat, CGFloat)]) -> NSBezierPath {
		let path = NSBezierPath()
		for (index, corner) in corners.enumerated() {
			let point = NSPoint(x: corner.0, y: corner.1)
			if index == 0 {
				path.move(to: point)
			} else {
				path.line(to: point)
			}
		}
		return path
	}

	/// Erases a shape and a margin around it, so what is drawn next stands apart from what lies behind.
	private static func clear(_ path: NSBezierPath, widenedBy margin: CGFloat, in context: NSGraphicsContext) {
		context.saveGraphicsState()
		context.compositingOperation = .destinationOut
		path.fill()
		guard let copy = path.copy() as? NSBezierPath else {
			context.restoreGraphicsState()
			return
		}
		copy.lineWidth = margin
		copy.stroke()
		context.restoreGraphicsState()
	}
}
