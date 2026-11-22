/// Controls view replacements needed when capturing offscreen bitmaps without a display server.
public enum InterfaceRenderMode: Equatable, Sendable {
	case interactive
	case offscreenSnapshot
}
