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

	/// Nil while the read may still come.
	static func resolve(_ status: LibraryStatus, requestedAt: Date) -> SynchronizationAnswer? {
		status.copy.hasRead(since: requestedAt) ? .synchronized : withoutRead(status.archive)
	}

	/// The answer of a connection that publishes no read after a request, nil while one may come.
	static func withoutRead(_ archive: ArchiveConnection) -> SynchronizationAnswer? {
		switch archive.configuration?.condition {
		case nil, .suspended, .archiveOutdated:
			.withheld
		case .unreachable:
			.outOfReach
		case .connected, .checking, .deferred:
			nil
		}
	}
}

extension LibraryCopy {
	/// Whether the copy completed a read of the archive at or after a time. The copy records its times
	/// in whole milliseconds, so the two times are compared in whole milliseconds: a read completed in
	/// the millisecond of the time counts, or a request would wait for a read that never comes.
	func hasRead(since time: Date) -> Bool {
		guard case let .complete(synchronizedAt) = self else {
			return false
		}
		return Self.wholeMilliseconds(synchronizedAt, .toNearestOrAwayFromZero) >= Self.wholeMilliseconds(time, .down)
	}

	private static func wholeMilliseconds(_ date: Date, _ rounding: FloatingPointRoundingRule) -> Double {
		(date.timeIntervalSince1970 * 1000).rounded(rounding)
	}
}
