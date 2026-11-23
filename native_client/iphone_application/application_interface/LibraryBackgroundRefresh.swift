import BackgroundTasks
import Foundation
import os

/// The time the system grants Schublade while it is not open, so the copy has read the archive when
/// a person next opens it, offline included. The refresh runs in the application's process through
/// its one core, so the copy keeps a single writer, and it reads the token from the Keychain item,
/// which is readable once the phone was unlocked after its start.
final class LibraryBackgroundRefresh {
	/// The copy reads the archive every 15 minutes while no screen attends it, so an earlier refresh
	/// would find little. The system decides when within its own budget.
	private static let interval: TimeInterval = 15 * 60
	private static let logger = Logger(subsystem: "org.schublade.iphone", category: "background-refresh")

	/// `<bundle identifier>.library-refresh`, as `BGTaskSchedulerPermittedIdentifiers` names it.
	let identifier: String
	private let controller: ApplicationController
	/// The task the system launched, until it is completed once, numbered so that a late answer of an
	/// earlier task never completes a later one.
	private var running: (number: UInt64, task: BGAppRefreshTask)?
	private var launches: UInt64 = 0

	init(controller: ApplicationController, bundleIdentifier: String) {
		self.controller = controller
		identifier = "\(bundleIdentifier).library-refresh"
	}

	/// Must run before the launch ends, or the system does not deliver the task to this launch.
	func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
			guard let self, let refresh = task as? BGAppRefreshTask else {
				task.setTaskCompleted(success: false)
				return
			}
			perform(refresh)
		}
	}

	/// Asks for the next refresh, once the person leaves the application and after each refresh,
	/// while an archive is connected.
	func schedule() {
		guard controller.archiveOrigin != nil || controller.situation == .starting else {
			return
		}
		let request = BGAppRefreshTaskRequest(identifier: identifier)
		request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			Self.logger.error("Library refresh not scheduled: \(error.localizedDescription, privacy: .public)")
		}
	}

	private func perform(_ task: BGAppRefreshTask) {
		Self.logger.notice("Library refresh began")
		launches &+= 1
		let number = launches
		running = (number, task)
		schedule()
		let work = Task { [controller] in
			let answer = await controller.refreshLibrary()
			finish(number, answer: answer)
		}
		// The system calls this on a queue of its own, so it only asks the main actor to finish.
		task.expirationHandler = { @Sendable [weak self] in
			work.cancel()
			Task { @MainActor in
				self?.finish(number, answer: nil)
			}
		}
	}

	/// Completes the task once, with its answer or, when its time ran out first, without one. The copy
	/// goes on reading at the next start.
	private func finish(_ number: UInt64, answer: SynchronizationAnswer?) {
		guard let running, running.number == number else {
			return
		}
		self.running = nil
		let outcome = answer.map { "\($0)" } ?? "expired"
		Self.logger.notice("Library refresh ended: \(outcome, privacy: .public)")
		running.task.setTaskCompleted(success: answer == .synchronized)
	}
}
