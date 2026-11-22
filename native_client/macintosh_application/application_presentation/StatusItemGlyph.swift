/// The menu bar item's drawing, in the order of precedence in which the item shows them. The glyph
/// speaks only for this Mac: a document the archive failed to read never turns it to attention.
public enum StatusItemGlyph: Equatable, Sendable, CaseIterable {
	/// The start failed, the token is refused, a folder awaits its decision, or one cannot be read.
	case attentionRequired
	case archiveNotConnected
	/// The archive does not answer, defers, or is being checked.
	case archiveUnreachable
	/// An upload is in flight; the drawer takes a sheet in, one frame of `StatusItemAnimation` at a time.
	case submitting
	case resting
	/// Before the first status.
	case starting
}
