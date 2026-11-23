import ApplicationBindings
import Foundation

/// How a library status answers a request, made at a given time, that the copy read the archive.
/// Pull to refresh ends on any answer; the background refresh waits out an archive out of reach,
/// because the network may return while the system grants it time.
enum SynchronizationAnswer: Equatable {
	/// The copy read the archive after the request.
	case synchronized
	/// The archive could not be reached. The copy reads it by itself once it can.
	case outOfReach
	/// No archive is connected, it refused the token, or it needs an update, so no read follows until a
	/// person acts. Such a status is not published again after a request.
	case withheld

	/// Nil while the read may still come. The copy records its times in whole milliseconds, so the
	/// two times are compared in whole milliseconds: a read completed in the millisecond of the request
	/// counts, or the request would wait for a read that never comes.
	static func resolve(_ status: LibraryStatus, requestedAt: Date) -> SynchronizationAnswer? {
		let read: Double? = if case let .complete(synchronizedAt) = status.copy {
			wholeMilliseconds(synchronizedAt, .toNearestOrAwayFromZero)
		} else {
			nil
		}
		if let read, read >= wholeMilliseconds(requestedAt, .down) {
			return .synchronized
		}
		switch status.archive {
		case .notConfigured, .configured(_, _, .suspended, _, _), .configured(_, _, .archiveOutdated, _, _):
			return .withheld
		case .configured(_, _, .unreachable, _, _):
			return .outOfReach
		case .configured(_, _, .connected, _, _), .configured(_, _, .checking, _, _),
		     .configured(_, _, .deferred, _, _):
			return nil
		}
	}

	private static func wholeMilliseconds(_ date: Date, _ rounding: FloatingPointRoundingRule) -> Double {
		(date.timeIntervalSince1970 * 1000).rounded(rounding)
	}
}
