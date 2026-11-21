import CollectionBindings

/// The only type that calls the bindings. Every call into the core waits on a thread of the Rust
/// side, so the main actor never waits on the coordinator, the network, or the Keychain.
final class CollectorGateway: CollectorCommands {
	/// Nil until `start` succeeds. A command before then answers that the collector is stopped.
	private var collector: Collector?

	func start(configuration: CollectorConfiguration) async throws(CollectorStartFailure) {
		collector = try await narrowing {
			try await startCollector(configuration: configuration)
		} otherwise: { detail -> CollectorStartFailure in
			// The start declares no failure outside the core, so this is a panic of the Rust side.
			preconditionFailure("The collector failed to start outside its declared failures: \(detail)")
		}
	}

	/// The first status whose revision exceeds `revision`, or the current status for nil. A read
	/// that waits ends with a newer status, or with `CollectorFault.Stopped` after `shutdown`.
	func statusAfter(_ revision: UInt64?) async throws(CollectorFault) -> CollectorStatus {
		guard let collector else {
			throw .Stopped
		}
		return try await narrowing {
			try await collector.statusAfter(revision: revision)
		} otherwise: { detail in
			CollectorFault.Unexpected(detail: detail)
		}
	}

	func connectArchive(address: String, token: String) async throws(ConnectionRefusal) {
		try await command(ConnectionRefusal.Collector) { collector in
			try await collector.connectArchive(address: address, token: token)
		}
	}

	func enrollFolder(root: String) async throws(EnrollmentRefusal) -> FolderReference {
		try await command(EnrollmentRefusal.Collector) { collector in try await collector.enrollFolder(root: root) }
	}

	func withdrawFolder(_ folder: FolderIdentifier) async throws(WithdrawalRefusal) {
		try await command(WithdrawalRefusal.Collector) { collector in
			try await collector.withdrawFolder(folder: folder)
		}
	}

	func decideBacklog(_ folder: FolderIdentifier) async throws(DecisionRefusal) {
		try await command(DecisionRefusal.Collector) { collector in try await collector.decideBacklog(folder: folder) }
	}

	/// The system woke from sleep: the collector probes the archive and walks every folder.
	func systemResumed() {
		collector?.systemResumed()
	}

	/// Stops the coordinator after its current batch, which ends every waiting read.
	func shutdown() async {
		await collector?.shutdown()
	}

	private func command<Answer, Refusal: Error>(
		_ refusal: (CollectorFault) -> Refusal,
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
