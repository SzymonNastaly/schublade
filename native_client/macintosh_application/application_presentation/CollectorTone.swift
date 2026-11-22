/// How a collector state, an attention item, or a receipt is coloured: work in progress, something
/// for the person to decide, something that went wrong, something done, or nothing to say.
public enum CollectorTone: Equatable, Sendable {
	case processing
	case attention
	case failure
	case success
	case neutral
}
