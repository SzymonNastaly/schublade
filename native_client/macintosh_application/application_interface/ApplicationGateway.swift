import ApplicationBindings
import ApplicationPresentation

/// The only type that calls the bindings. Every asynchronous call into the core runs on a Rust
/// worker pool, so the main actor never waits on a coordinator, SQLite, the network, or the
/// Keychain.
final class ApplicationGateway: ApplicationCommands, LibraryQueries, CollectorCommands, StorageCommands {
	/// Nil until `start` succeeds. A command before then answers that the application is stopped.
	private var core: ApplicationCore?
	private var library: Library?
	private var collector: Collector?

	func start(configuration: ApplicationConfiguration) async throws(ApplicationStartFailure) {
		var configuration = configuration
		configuration.documentReader = CollectedDocumentReader()
		let started = try await narrowing { [configuration] in
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
		try await libraryQuery { library in
			try await library.statusAfter(revision: revision)
		}
	}

	/// The first collector status whose revision exceeds `revision`, or the current status for nil.
	/// A read that waits ends with a newer status, or with `ApplicationFault.Stopped` after
	/// `shutdown`.
	func collectorStatusAfter(_ revision: UInt64?) async throws(ApplicationFault) -> CollectorStatus {
		try await collectorQuery { collector in
			try await collector.statusAfter(revision: revision)
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

	func listDocuments(
		request: ListingRequest,
		preceding: (any DocumentListingSnapshot)?
	) async throws(ApplicationFault) -> DocumentListingReply {
		let concretePreceding = preceding as? DocumentListing
		let answer = try await libraryQuery { library in
			try await library.listDocuments(request: request, preceding: concretePreceding)
		}
		return DocumentListingReply(listing: answer.listing, difference: answer.difference)
	}

	func facets() async throws(ApplicationFault) -> LibraryFacets {
		try await libraryQuery { library in
			try await library.facets()
		}
	}

	func document(_ document: DocumentIdentifier) async throws(ApplicationFault) -> DocumentDetail? {
		try await libraryQuery { library in
			try await library.document(document: document)
		}
	}

	func original(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile {
		try await representationQuery { library in
			try await library.original(document: document)
		}
	}

	func thumbnail(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile? {
		try await representationQuery { library in
			try await library.thumbnail(document: document)
		}
	}

	func extractedText(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> String {
		try await representationQuery { library in
			try await library.extractedText(document: document)
		}
	}

	func synchronize() {
		library?.synchronize()
	}

	func originalStorage() async throws(ApplicationFault) -> OriginalStorage {
		try await libraryQuery { library in
			try await library.originalStorage()
		}
	}

	func setOriginalStorageLimit(_ bytes: UInt64?) async throws(ApplicationFault) {
		try await libraryQuery { library in
			try await library.setOriginalStorageLimit(limitBytes: bytes)
		}
	}

	func removeDownloadedOriginals() async throws(ApplicationFault) {
		try await libraryQuery { library in
			try await library.removeDownloadedOriginals()
		}
	}

	func enrollFolder(root: String) async throws(EnrollmentRefusal) -> FolderReference {
		try await collectorCommand(EnrollmentRefusal.Application) { collector in
			try await collector.enrollFolder(root: root)
		}
	}

	func withdrawFolder(_ folder: FolderIdentifier) async throws(WithdrawalRefusal) {
		try await collectorCommand(WithdrawalRefusal.Application) { collector in
			try await collector.withdrawFolder(folder: folder)
		}
	}

	func decideBacklog(_ folder: FolderIdentifier) async throws(DecisionRefusal) {
		try await collectorCommand(DecisionRefusal.Application) { collector in
			try await collector.decideBacklog(folder: folder)
		}
	}

	/// Reports whether a window currently shows the library.
	func interfaceAttended(_ attended: Bool) {
		core?.interfaceAttended(attended: attended)
	}

	/// The system woke from sleep: both cores probe and synchronize.
	func systemResumed() {
		core?.systemResumed()
	}

	/// Stops both coordinators after their current work, which ends every waiting read.
	func shutdown() async {
		await core?.shutdown()
	}

	private func libraryQuery<Answer>(
		_ call: (Library) async throws -> Answer
	) async throws(ApplicationFault) -> Answer {
		guard let library else {
			throw .Stopped
		}
		return try await narrowing {
			try await call(library)
		} otherwise: { detail in
			ApplicationFault.Unexpected(detail: detail)
		}
	}

	private func representationQuery<Answer>(
		_ call: (Library) async throws -> Answer
	) async throws(RepresentationRefusal) -> Answer {
		guard let library else {
			throw .Application(fault: .Stopped)
		}
		return try await narrowing {
			try await call(library)
		} otherwise: { detail in
			RepresentationRefusal.Application(fault: .Unexpected(detail: detail))
		}
	}

	private func collectorQuery<Answer>(
		_ call: (Collector) async throws -> Answer
	) async throws(ApplicationFault) -> Answer {
		guard let collector else {
			throw .Stopped
		}
		return try await narrowing {
			try await call(collector)
		} otherwise: { detail in
			ApplicationFault.Unexpected(detail: detail)
		}
	}

	private func collectorCommand<Answer, Refusal: Error>(
		_ refusal: (ApplicationFault) -> Refusal,
		_ call: (Collector) async throws -> Answer
	) async throws(Refusal) -> Answer {
		guard let collector else {
			throw refusal(.Stopped)
		}
		return try await narrowing {
			try await call(collector)
		} otherwise: { detail in
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
