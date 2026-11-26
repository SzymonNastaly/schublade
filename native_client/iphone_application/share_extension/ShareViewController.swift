import SubmissionQueue
import UIKit
import UniformTypeIdentifiers

/// Schublade in another application's share sheet: a picture of each file, how many go to which
/// archive, and Send. The files are copied as the sheet appears, so their pictures show before Send.
/// Send makes a submission of each copy, starts its upload in the extension's own background
/// session, and closes once every file is on its way. The application receives the answers that
/// arrive after that, and reads and sends a file whose pages only recognition reads.
final class ShareViewController: UIViewController {
	/// What the sheet shows, from the moment it appears to the moment it closes.
	private enum Phase {
		case unavailable(ShareUnavailability)
		case ready
		/// The upload of the file at `current` is being prepared.
		case sending(current: Int)
		/// Every file is on its way, and the sheet closes a moment later, or `leftToApplication` of them
		/// wait for the application to recognize their pages, and the sheet stays until Done.
		case handedOver(leftToApplication: Int)
		case partlyUnread(unreadNames: [String], sentCount: Int)
	}

	/// One session per process, because a process may create a background session only once per
	/// identifier, and the system can show the extension again in a process that already sent.
	private static let transfer: SubmissionTransfer? = {
		guard let installation = try? SharedInstallation.read(), let container = try? installation.container() else {
			return nil
		}
		let queue = container.submissionQueue
		return SubmissionTransfer(
			configuration: SubmissionTransfer.backgroundConfiguration(
				identifier: installation.shareExtensionTransferSessionIdentifier,
				sharedContainer: installation.applicationGroupIdentifier
			)
		) { attempt, answer in
			_ = try? queue.receive(answer, for: attempt)
		} onProgress: { _, _ in
		} onSessionEvent: { _, _ in
			// The system launches the application, never the extension, for the session's events.
		}
	}()

	private static let handedOverPause = Duration.milliseconds(800)

	private var phase = Phase.ready
	private var destination: ShareDestination?
	private var files: [ShareContents.SharedFile] = []
	/// The copy of each file, made one after another as the sheet appears, which Send awaits.
	private var copies: [Task<URL, any Error>] = []
	/// Where the copies are made, which goes as a whole once nothing needs it: when the sheet ends
	/// without Send, and after Send once the queue has taken every copy it could read.
	private let copiesDirectory = URL.temporaryDirectory.appending(
		path: "imports/\(UUID().uuidString)",
		directoryHint: .isDirectory
	)
	/// The names of the files the archive does not take, nil until a name is known.
	private var leftOutNames: [String?] = []
	private var overLimit = 0

	private let bar = UINavigationBar()
	private lazy var sheet = ShareSheetView(
		tiles: files.map { ShareTile(name: nil, isPicture: !$0.type.conforms(to: .pdf)) }
	)
	private let unavailableView = UIContentUnavailableView(configuration: .empty())

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground
		// The sheet lives in the host's window, which carries the host's tint, not the extension's.
		view.tintColor = UIColor(resource: .accent)
		let shared = ShareContents(items: extensionContext?.inputItems ?? [])
		files = shared.files
		overLimit = shared.overLimit
		leftOutNames = shared.leftOut.map { _ in nil }
		switch ShareDestination.resolve() {
		case let .success(found) where !files.isEmpty:
			destination = found
			phase = .ready
		case .success:
			phase = .unavailable(.nothingToSend)
		case let .failure(unavailability):
			phase = .unavailable(unavailability)
		}
		buildLayout()
		show()
		Task {
			for (index, file) in files.enumerated() {
				// A file sent keeps no extension, because the archive names it by its kind, while the name of
				// a file left out keeps the extension that says why.
				let name = await ShareContents.name(of: file.provider)
					.map(DocumentImport.nameWithoutRecognizedExtension)
				sheet.update(index) { $0.name = name }
			}
			for (index, provider) in shared.leftOut.enumerated() {
				leftOutNames[index] = await ShareContents.name(of: provider)
			}
			if case .ready = phase {
				show()
			}
		}
	}

	override func viewIsAppearing(_ animated: Bool) {
		super.viewIsAppearing(animated)
		guard case .ready = phase, copies.isEmpty else {
			return
		}
		copyFiles()
	}

	/// A swipe down ends the sheet as Cancel does, without calling it.
	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		if case .ready = phase {
			discardCopies()
		}
	}

	private func buildLayout() {
		navigationItem.title = "Schublade"
		bar.items = [navigationItem]
		for subview in [sheet, unavailableView, bar] as [UIView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			sheet.topAnchor.constraint(equalTo: bar.bottomAnchor),
			sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			sheet.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
			unavailableView.topAnchor.constraint(equalTo: bar.bottomAnchor),
			unavailableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			unavailableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			unavailableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	private func show() {
		sheet.isHidden = false
		unavailableView.isHidden = true
		switch phase {
		case let .unavailable(unavailability):
			sheet.isHidden = true
			unavailableView.isHidden = false
			unavailableView.configuration = unavailability.configuration
			navigationItem.leftBarButtonItem = cancelItem()
			navigationItem.rightBarButtonItem = nil
		case .ready:
			sheet.show(ShareSheetView.Words(
				headline: files.count == 1 ? "1 document" : "\(files.count) documents",
				destination: destination.map { "to your archive at \($0.archive.host)" },
				footnote: leftOutSentence
			))
			navigationItem.leftBarButtonItem = cancelItem()
			navigationItem.rightBarButtonItem = sendItem()
		case let .sending(current):
			sheet.show(ShareSheetView.Words(
				headline: files.count == 1 ? "Sending…" : "Sending \(current + 1) of \(files.count)…",
				destination: destination.map { "to your archive at \($0.archive.host)" },
				footnote: leftOutSentence
			))
			if !(navigationItem.rightBarButtonItem?.customView is UIActivityIndicatorView) {
				let indicator = UIActivityIndicatorView(style: .medium)
				indicator.startAnimating()
				let item = UIBarButtonItem(customView: indicator)
				if #available(iOS 26, *) {
					item.hidesSharedBackground = true
				}
				navigationItem.rightBarButtonItem = item
			}
			navigationItem.leftBarButtonItem?.isEnabled = false
		case let .handedOver(leftToApplication):
			sheet.show(handedOverWords(leftToApplication: leftToApplication))
			navigationItem.leftBarButtonItem?.isEnabled = false
			navigationItem.rightBarButtonItem = leftToApplication == 0 ? nil : doneItem()
		case let .partlyUnread(unreadNames, sentCount):
			sheet.show(ShareSheetView.Words(
				headline: "Schublade could not read \(ListFormatter.localizedString(byJoining: unreadNames)).",
				destination: sentCount == 0 ? nil : "The other files are on their way to your archive."
			))
			navigationItem.leftBarButtonItem = nil
			navigationItem.rightBarButtonItem = doneItem()
		}
	}

	/// Copies each file before the next, because an extension is ended above about 120 MB, and asks
	/// Quick Look for its picture once its copy exists, which its tile shows.
	private func copyFiles() {
		let size = ShareTileSize.of(count: files.count)
		let scale = traitCollection.displayScale
		var previous: Task<URL, any Error>?
		try? FileManager.default.createDirectory(at: copiesDirectory, withIntermediateDirectories: true)
		copies = files.map { [copiesDirectory] file in
			let before = previous
			let copy = Task {
				_ = await before?.result
				return try await ShareContents.copy(file, into: copiesDirectory)
			}
			previous = copy
			return copy
		}
		for (index, copy) in copies.enumerated() {
			Task { [weak self] in
				guard let file = try? await copy.value,
				      let rendering = await ShareTileSize.rendering(of: file, size: size, scale: scale)
				else {
					return
				}
				self?.sheet.update(index) { $0.picture = ShareTileSize.framed(rendering, size: size, scale: scale) }
			}
		}
	}

	private func cancel() {
		discardCopies()
		extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
	}

	/// Removes every copy at once, because the process may end right after the sheet, and again once
	/// every copy has ended, because one still being written can keep the directory from going. A copy
	/// that starts later finds its directory gone and makes none.
	private func discardCopies() {
		copies.forEach { $0.cancel() }
		try? FileManager.default.removeItem(at: copiesDirectory)
		Task { [copies, copiesDirectory] in
			for copy in copies {
				_ = await copy.result
			}
			try? FileManager.default.removeItem(at: copiesDirectory)
		}
	}

	/// Enqueues and starts each copy before the next, so a submission the application sees already
	/// carries the claim of the upload that this extension starts at once.
	private func send() {
		guard let destination else {
			return
		}
		// Cancel or a swipe down would end the extension between two files, after some were already
		// on their way.
		isModalInPresentation = true
		Task {
			var unreadNames: [String] = []
			var leftToApplication = 0
			for (index, file) in files.enumerated() {
				phase = .sending(current: index)
				show()
				sheet.reveal(index)
				do {
					let copy = try await copies[index].value
					if try await hand(copy, of: file, to: destination) {
						leftToApplication += 1
					}
					sheet.update(index) { $0.mark = .started }
				} catch {
					unreadNames.append(sheet.tiles[index].name ?? "an unnamed file")
					sheet.update(index) { $0.mark = .unread }
				}
			}
			// Every copy has ended, and the queue moved each one it took, so what remains is empty
			// directories and the copies it could not read.
			try? FileManager.default.removeItem(at: copiesDirectory)
			guard unreadNames.isEmpty else {
				phase = .partlyUnread(unreadNames: unreadNames, sentCount: files.count - unreadNames.count)
				show()
				Haptics.shareUnread()
				return
			}
			phase = .handedOver(leftToApplication: leftToApplication)
			show()
			Haptics.shareHandedOver()
			guard leftToApplication == 0 else {
				return
			}
			try? await Task.sleep(for: Self.handedOverPause)
			extensionContext?.completeRequest(returningItems: nil)
		}
	}
}

/// The bar's items and the footnote, apart from the states that choose them.
private extension ShareViewController {
	/// Enqueues one copy and starts its upload, unless its pages wait for the application, which
	/// recognizes them. Answers whether the copy was left to the application.
	func hand(_ copy: URL, of file: ShareContents.SharedFile, to destination: ShareDestination) async throws -> Bool {
		let queue = destination.container.submissionQueue
		let entry = try await ShareIntake.receive(
			ShareIntake.SharedFile(file: copy, type: file.type, suggestedName: file.provider.suggestedName),
			into: queue
		)
		guard entry.manifest.uploadClaimedAt != nil else {
			return true
		}
		switch await queue.prepare(
			entry,
			archiveOrigin: destination.archive.origin,
			credentials: destination.installation.credentialStorage
		) {
		case let .prepared(request, attempt, body):
			Self.transfer?.send(attempt, request: request, body: body)
		case let .answered(answer):
			_ = try? queue.record(answer, for: entry.id)
		}
		return false
	}

	func handedOverWords(leftToApplication: Int) -> ShareSheetView.Words {
		guard leftToApplication > 0 else {
			return ShareSheetView.Words(headline: "On its way to your archive.", handedOver: true)
		}
		return ShareSheetView.Words(
			headline: leftToApplication == files.count ? "Ready to send." : "Partly on its way.",
			destination: "Open Schublade to read the scanned pages and send "
				+ (leftToApplication == 1 ? "the document." : "the \(leftToApplication) documents."),
			handedOver: true
		)
	}

	func doneItem() -> UIBarButtonItem {
		UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
			self?.extensionContext?.completeRequest(returningItems: nil)
		})
	}

	func cancelItem() -> UIBarButtonItem {
		UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
			self?.cancel()
		})
	}

	func sendItem() -> UIBarButtonItem {
		let item = UIBarButtonItem(primaryAction: UIAction(title: "Send") { [weak self] _ in
			self?.send()
		})
		if #available(iOS 26, *) {
			item.style = .prominent
			// A prominent item in the extension's bar takes the item's tint and ignores the view's.
			item.tintColor = UIColor(resource: .accent)
		} else {
			item.style = .done
		}
		return item
	}

	var leftOutSentence: String? {
		var sentences: [String] = []
		if !leftOutNames.isEmpty {
			let joined = ListFormatter.localizedString(byJoining: leftOutNames.map { $0 ?? "an unnamed file" })
			sentences.append("Schublade sends only PDFs and pictures, so it leaves out \(joined).")
		}
		if overLimit > 0 {
			sentences.append("The archive takes \(ShareIntake.fileLimit) files at a time, so \(overLimit) stay here.")
		}
		return sentences.isEmpty ? nil : sentences.joined(separator: " ")
	}
}
