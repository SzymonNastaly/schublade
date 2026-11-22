/// The upload animation of the menu bar item: eight frames in which a sheet sinks into the drawer.
/// A cycle that began is finished, so a short upload shows one whole motion, and with Reduce Motion
/// the item shows one still frame and no timer runs.
public struct StatusItemAnimation: Equatable, Sendable {
	public static let frameCount = 8
	/// The frame shown with Reduce Motion: the sheet half inside the drawer.
	public static let stillFrame = 4

	/// The frame on screen, or nil while no cycle runs.
	public private(set) var frame: Int?

	public init() {}

	/// Whether a timer must tick: only while a cycle runs.
	public var needsTimer: Bool {
		frame != nil
	}

	/// Follows a new glyph: an upload starts a cycle unless one runs or motion is reduced, and a
	/// glyph that outranks the upload stops the cycle at once.
	public mutating func follow(_ glyph: StatusItemGlyph, reduceMotion: Bool) {
		switch glyph {
		case .submitting:
			if frame == nil, !reduceMotion {
				frame = 0
			}
		case .attentionRequired, .archiveNotConnected, .archiveUnreachable, .starting:
			frame = nil
		case .resting:
			break
		}
	}

	/// Moves to the next frame. At the end of a cycle another begins only while still uploading.
	public mutating func tick(stillSubmitting: Bool) {
		guard let current = frame else {
			return
		}
		let next = current + 1
		frame = next < Self.frameCount ? next : (stillSubmitting ? 0 : nil)
	}

	/// The frame to draw for a glyph: the running cycle's, the still frame of a reduced upload, or
	/// none for a glyph without motion.
	public func frame(for glyph: StatusItemGlyph, reduceMotion: Bool) -> Int? {
		if let frame {
			return frame
		}
		return glyph == .submitting && reduceMotion ? Self.stillFrame : nil
	}
}
