import ApplicationBindings
import UIKit

/// The library's pull to refresh. It ends once the copy has read the archive after the pull, at once
/// when the archive is out of reach or withholds its answer, and after ten seconds at the latest.
final class LibraryRefresh {
	private let control: UIRefreshControl
	private let gateway: ApplicationGateway
	private let currentStatus: () -> LibraryStatus?
	private var startedAt: Date?
	/// Counts the pulls, so the fallback of an earlier pull leaves a later one alone.
	private var number: UInt64 = 0

	init(control: UIRefreshControl, gateway: ApplicationGateway, currentStatus: @escaping () -> LibraryStatus?) {
		self.control = control
		self.gateway = gateway
		self.currentStatus = currentStatus
		control.addAction(UIAction { [weak self] _ in self?.begin() }, for: .valueChanged)
	}

	private func begin() {
		startedAt = .now
		number &+= 1
		let pull = number
		gateway.synchronize()
		// An archive out of reach or refusing the token publishes no new status after a pull.
		if let status = currentStatus(), SynchronizationAnswer.resolve(status, requestedAt: .distantFuture) != nil {
			Task { [weak self] in
				try? await Task.sleep(for: .milliseconds(500))
				self?.follow(status)
			}
		}
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(10))
			guard let self, number == pull else {
				return
			}
			end()
		}
	}

	func follow(_ status: LibraryStatus) {
		guard let started = startedAt else {
			return
		}
		if SynchronizationAnswer.resolve(status, requestedAt: started) != nil {
			end()
		}
	}

	private func end() {
		guard startedAt != nil else {
			return
		}
		startedAt = nil
		control.endRefreshing()
	}
}
