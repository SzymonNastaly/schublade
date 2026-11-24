/// What the connection form asks for: the first archive, on the welcome, or a new token for the
/// connected one.
public enum ConnectionFormPurpose: Equatable, Sendable {
	case welcome
	/// `reason` says why the archive needs a new token, and is nil when a person chose to replace it.
	case replaceToken(origin: String, reason: String?, cancellable: Bool)

	public static let tokenNote = "In your archive's Settings in the browser, issue a token for the Schublade app."

	public var title: String {
		switch self {
		case .welcome: "Connect Your Archive"
		case .replaceToken: "Replace Token"
		}
	}

	/// The sentence under the title.
	public var sentence: String? {
		switch self {
		case .welcome:
			"Schublade keeps every document of your archive at hand on this Mac, even offline, "
				+ "and archives the papers in the folders you add."
		case let .replaceToken(_, reason, _):
			reason
		}
	}

	public var address: String? {
		switch self {
		case .welcome: nil
		case let .replaceToken(origin, _, _): origin
		}
	}

	public var cancellable: Bool {
		switch self {
		case .welcome: false
		case let .replaceToken(_, _, cancellable): cancellable
		}
	}
}
