/// How a collector state or a receipt is coloured: something for a person, which includes what went
/// wrong, something done, or nothing to say.
public enum CollectorTone: Equatable, Sendable {
	case attention
	case success
	case neutral
}
