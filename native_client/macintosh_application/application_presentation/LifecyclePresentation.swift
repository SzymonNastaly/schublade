/// The decisions of the application's lifecycle that follow from its situation alone.
public enum LifecyclePresentation {
	/// What happens to the window after a launch.
	public enum LaunchWindow: Equatable, Sendable {
		case opens
		case staysClosed
		/// The first statuses are still to come.
		case undecided
	}

	/// A start at login keeps the window closed only while the core runs and an archive is
	/// connected; a failed start or a missing archive opens it even then, so nothing fails unseen.
	public static func launchWindow(origin: LaunchOrigin, situation: ApplicationSituation) -> LaunchWindow {
		guard origin == .loginItem else {
			return .opens
		}
		switch situation {
		case .starting:
			return .undecided
		case .failedToStart, .stopped:
			return .opens
		case let .running(statuses):
			guard let library = statuses.library else {
				// A library that faults before its first status needs a person as much as a failed start.
				return statuses.libraryFault == nil ? .undecided : .opens
			}
			switch library.archive {
			case .notConfigured:
				return .opens
			case .configured:
				return .staysClosed
			}
		}
	}

	/// Whether quitting asks first: only while folders are collected, because quitting stops
	/// collecting, and only until a person said not to ask again.
	public static func asksBeforeQuitting(situation: ApplicationSituation, suppressed: Bool) -> Bool {
		guard !suppressed, case let .running(statuses) = situation else {
			return false
		}
		return !(statuses.collector?.folders.isEmpty ?? true)
	}

	/// Whether the login item is registered now: once, at the first status of a connected archive,
	/// and never again after that, because afterwards the person decides in Settings.
	public static func registersLoginItem(situation: ApplicationSituation, alreadyEstablished: Bool) -> Bool {
		guard !alreadyEstablished, case let .running(statuses) = situation,
		      case .configured = statuses.library?.archive
		else {
			return false
		}
		return true
	}
}
