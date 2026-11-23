import ApplicationBindings

/// The only type that calls the bindings. Every asynchronous call into the core runs on a Rust
/// worker pool, so the main actor never waits on a coordinator, SQLite, the network, or the
/// Keychain.
final class ApplicationGateway {
	/// Nil until `start` succeeds. A command before then answers that the application is stopped.
	private var core: ApplicationCore?
	private var library: Library?

	func start(configuration: ApplicationConfiguration) async throws(ApplicationStartFailure) {
		let started = try await narrowing {
			try await startApplicationCore(configuration: configuration)
		} otherwise: { detail in
			ApplicationStartFailure.Unexpected(detail: detail)
		}
		core = started
		library = started.library()
	}

	/// The first library status whose revision exceeds `revision`, or the current status for nil.
	func libraryStatusAfter(_ revision: UInt64?) async throws(ApplicationFault) -> LibraryStatus {
		try await libraryQuery { library in
			try await library.statusAfter(revision: revision)
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

	func listDocuments(request: ListingRequest) async throws(ApplicationFault) -> DocumentListing {
		try await libraryQuery { library in
			try await library.listDocuments(request: request, preceding: nil).listing
		}
	}

	func facets() async throws(ApplicationFault) -> LibraryFacets {
		try await libraryQuery { library in
			try await library.facets()
		}
	}

	/// The document's detail, or nil while the copy does not hold it.
	func document(_ document: DocumentIdentifier) async throws(ApplicationFault) -> DocumentDetail? {
		try await libraryQuery { library in
			try await library.document(document: document)
		}
	}

	/// The original as a file on this iPhone, downloaded first when the cache lacks it.
	func original(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile {
		try await representationQuery { library in
			try await library.original(document: document)
		}
	}

	/// The first page as a picture, or nil for a document that has none.
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

	/// Whether a screen shows the library. While attended, the copy reads the archive every minute.
	func interfaceAttended(_ attended: Bool) {
		core?.interfaceAttended(attended: attended)
	}

	/// Asks the copy to read the archive's changes now, as after a sent document was archived,
	/// instead of at its next scheduled time.
	func synchronize() {
		library?.synchronize()
	}

	/// Stops the coordinator after its current work, which ends every waiting read.
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
