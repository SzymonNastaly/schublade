/// Who started the application: a person, or the system at login.
public enum LaunchOrigin: Equatable, Sendable {
	case person
	case loginItem
}
