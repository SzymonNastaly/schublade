import ApplicationBindings

/// The only type that calls the bindings. Every call into the core waits on a thread of the Rust
/// side, so the main actor never waits on the coordinator, the network, or the Keychain.
final class CollectorGateway: CollectorCommands {
	/// Nil until `start` succeeds. A command before then answers that the application is stopped.
	private var core: ApplicationCore?
	private var library: Library?
	private var collector: Collector?

	func start(configuration: ApplicationConfiguration) async throws(ApplicationStartFailure) {
		let started = try await narrowing {
			try await startApplicationCore(configuration: configuration)
		} otherwise: { detail in
			ApplicationStartFailure.Unexpected(detail: detail)
		}
		core = started
		library = started.library()
		collector = started.collector()
	}

	/// The first library status whose revision exceeds `revision`, or the current status for nil.
	/// A read that waits ends with a newer status, or with `ApplicationFault.Stopped` after
	/// `shutdown`.
	func libraryStatusAfter(_ revision: UInt64?) async throws(ApplicationFault) -> LibraryStatus {
		guard let library else {
			throw .Stopped
		}
		return try await narrowing {
			try await library.statusAfter(revision: revision)
		} otherwise: { detail in
			ApplicationFault.Unexpected(detail: detail)
		}
	}

	/// The first status whose revision exceeds `revision`, or the current status for nil. A read
	/// that waits ends with a newer status, or with `ApplicationFault.Stopped` after `shutdown`.
	func statusAfter(_ revision: UInt64?) async throws(ApplicationFault) -> CollectorStatus {
		guard let collector else {
			throw .Stopped
		}
		return try await narrowing {
			try await collector.statusAfter(revision: revision)
		} otherwise: { detail in
			ApplicationFault.Unexpected(detail: detail)
		}
	}

	func connectArchive(address: String, token: String) async throws(ConnectionRefusal) -> ConnectionGrant {
		guard let core else {
			throw .Application(fault: .Stopped)
		}
		return try await narrowing {
			try await core.connectArchive(address: address, token: token)
		} otherwise: { detail in
			ConnectionRefusal.Application(fault: .Unexpected(detail: detail))
		}
	}

	func enrollFolder(root: String) async throws(EnrollmentRefusal) -> FolderReference {
		try await command(EnrollmentRefusal.Application) { collector in
			try await collector.enrollFolder(root: root)
		}
	}

	func withdrawFolder(_ folder: FolderIdentifier) async throws(WithdrawalRefusal) {
		try await command(WithdrawalRefusal.Application) { collector in
			try await collector.withdrawFolder(folder: folder)
		}
	}

	func decideBacklog(_ folder: FolderIdentifier) async throws(DecisionRefusal) {
		try await command(DecisionRefusal.Application) { collector in
			try await collector.decideBacklog(folder: folder)
		}
	}

	/// The system woke from sleep: both cores probe and synchronize.
	func systemResumed() {
		core?.systemResumed()
	}

	/// Stops both coordinators after their current work, which ends every waiting read.
	func shutdown() async {
		await core?.shutdown()
	}

	private func command<Answer, Refusal: Error>(
		_ refusal: (ApplicationFault) -> Refusal,
		_ call: (Collector) async throws -> Answer
	) async throws(Refusal) -> Answer {
		guard let collector else {
			throw refusal(.Stopped)
		}
		return try await narrowing { try await call(collector) } otherwise: { detail in
			refusal(.Unexpected(detail: detail))
		}
	}

	/// The one place where the untyped `throws` of a generated call becomes the error its Rust
	/// signature names. Any other error is UniFFI's own, such as a panic of the Rust side.
	private func narrowing<Answer, Refusal: Error>(
		_ call: () async throws -> Answer,
		otherwise unexpected: (String) -> Refusal
	) async throws(Refusal) -> Answer {
		do {
			return try await call()
		} catch let refusal as Refusal {
			throw refusal
		} catch {
			throw unexpected(String(describing: error))
		}
	}
}
