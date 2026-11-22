import SubmissionQueue
import UIKit
import UniformTypeIdentifiers

/// Schublade in another application's share sheet: how many files go to which archive, with Send
/// and Cancel. Send makes a submission of each file, starts its upload in the extension's own
/// background session, and closes. The application receives the answers that arrive after that.
final class ShareViewController: UIViewController {
	/// Whether the sheet can send, decided once from the record the application keeps.
	private enum Readiness {
		case ready(SharedInstallation, SharedContainer, ConnectedArchive)
		case refused(String)
	}

	/// One shared item the archive takes, and the type to load it as.
	private struct AcceptedItem {
		let provider: NSItemProvider
		let type: UTType
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
		) { identifier, answer in
			_ = try? queue.receive(answer, for: identifier)
		} onProgress: { _, _ in }
	}()

	private let messageLabel = UILabel()
	private let detailLabel = UILabel()
	private let progressIndicator = UIActivityIndicatorView(style: .medium)

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground
		let readiness = Self.readiness()
		let providers = (extensionContext?.inputItems ?? [])
			.compactMap { $0 as? NSExtensionItem }
			.flatMap { $0.attachments ?? [] }
		var accepted: [AcceptedItem] = []
		var refusedNames: [String] = []
		for provider in providers {
			if let type = DocumentImport.preferredType(among: provider.registeredContentTypes) {
				accepted.append(AcceptedItem(provider: provider, type: type))
			} else if !provider.registeredContentTypes.allSatisfy({ $0.conforms(to: .url) }) {
				// Safari shares the page's address beside its PDF, which is no file a person chose.
				refusedNames.append(provider.suggestedName ?? "an unnamed file")
			}
		}
		let sent = Array(accepted.prefix(ShareIntake.fileLimit))
		let leftOver = accepted.count - sent.count

		navigationItem.title = "Schublade"
		navigationItem.leftBarButtonItem = UIBarButtonItem(
			systemItem: .cancel,
			primaryAction: UIAction { [weak self] _ in
				self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
			}
		)
		switch readiness {
		case let .ready(installation, container, archive) where !sent.isEmpty:
			messageLabel.text = Self.offerSentence(count: sent.count, host: archive.host)
			let send = UIBarButtonItem(primaryAction: UIAction(title: "Send") { [weak self] _ in
				self?.send(sent, installation: installation, container: container, archive: archive)
			})
			send.style = .done
			navigationItem.rightBarButtonItem = send
		case .ready:
			messageLabel.text = "Schublade sends PDFs and pictures, and none was shared."
		case let .refused(sentence):
			messageLabel.text = sentence
		}
		detailLabel.text = Self.refusalSentence(refusedNames: refusedNames, leftOver: leftOver)
		buildLayout()
	}

	private func buildLayout() {
		let bar = UINavigationBar()
		bar.items = [navigationItem]
		bar.translatesAutoresizingMaskIntoConstraints = false
		messageLabel.font = .preferredFont(forTextStyle: .body)
		detailLabel.font = .preferredFont(forTextStyle: .footnote)
		detailLabel.textColor = .secondaryLabel
		for label in [messageLabel, detailLabel] {
			label.numberOfLines = 0
			label.adjustsFontForContentSizeCategory = true
		}
		let content = UIStackView(arrangedSubviews: [messageLabel, detailLabel, progressIndicator])
		content.axis = .vertical
		content.alignment = .leading
		content.spacing = 12
		content.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(bar)
		view.addSubview(content)
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			content.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 20),
			content.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
		])
	}

	private static func readiness() -> Readiness {
		guard let installation = try? SharedInstallation.read(), let container = try? installation.container() else {
			return .refused("Schublade cannot reach the documents it shares with this sheet. Reinstall Schublade.")
		}
		guard let archive = container.connectedArchive() else {
			return .refused("Open Schublade and connect your archive, then share again.")
		}
		guard !archive.restricted else {
			return .refused(ConnectedArchive.restrictionSentence)
		}
		return .ready(installation, container, archive)
	}

	private static func offerSentence(count: Int, host: String) -> String {
		count == 1 ? "Send 1 document to \(host)." : "Send \(count) documents to \(host)."
	}

	private static func refusalSentence(refusedNames: [String], leftOver: Int) -> String? {
		var sentences: [String] = []
		if !refusedNames.isEmpty {
			let names = ListFormatter.localizedString(byJoining: refusedNames)
			sentences.append("Schublade sends only PDFs and pictures, so it leaves out \(names).")
		}
		if leftOver > 0 {
			sentences.append("The archive takes \(ShareIntake.fileLimit) files at a time, so \(leftOver) stay here.")
		}
		return sentences.isEmpty ? nil : sentences.joined(separator: " ")
	}

	/// Copies, converts, and enqueues the files one at a time, then starts each upload, because an
	/// extension is ended above about 120 MB.
	private func send(
		_ items: [AcceptedItem],
		installation: SharedInstallation,
		container: SharedContainer,
		archive: ConnectedArchive
	) {
		navigationItem.rightBarButtonItem?.isEnabled = false
		progressIndicator.startAnimating()
		Task {
			var shared: [ShareIntake.SharedFile] = []
			var unreadNames: [String] = []
			for item in items {
				do {
					let copy = try await Self.copy(item)
					shared.append(ShareIntake.SharedFile(file: copy, suggestedName: item.provider.suggestedName))
				} catch {
					unreadNames.append(item.provider.suggestedName ?? "an unnamed file")
				}
			}
			let queue = container.submissionQueue
			let reception = await ShareIntake.receive(shared, into: queue)
			for entry in reception.entries {
				switch await queue.prepare(
					entry,
					archiveOrigin: archive.origin,
					credentials: installation.credentialStorage
				) {
				case let .prepared(request, body):
					Self.transfer?.send(entry.id, request: request, body: body)
				case let .answered(answer):
					try? queue.record(answer, for: entry.id)
				}
			}
			progressIndicator.stopAnimating()
			let unsent = unreadNames + reception.refusedNames
			guard !unsent.isEmpty else {
				extensionContext?.completeRequest(returningItems: nil)
				return
			}
			showUnsent(unsent, sentCount: reception.entries.count)
		}
	}

	/// Says which files could not be read, and lets the person close the sheet.
	private func showUnsent(_ names: [String], sentCount: Int) {
		messageLabel.text = "Schublade could not read \(ListFormatter.localizedString(byJoining: names))."
		detailLabel.text = sentCount == 0 ? nil : "The other files are on their way to your archive."
		navigationItem.leftBarButtonItem = nil
		navigationItem.rightBarButtonItem = UIBarButtonItem(
			systemItem: .done,
			primaryAction: UIAction { [weak self] _ in
				self?.extensionContext?.completeRequest(returningItems: nil)
			}
		)
	}

	/// Copies the file a provider offers into a directory the extension owns, because the provider's
	/// file exists only during its callback.
	private static func copy(_ item: AcceptedItem) async throws -> URL {
		let directory = try DocumentImport.workingDirectory()
		return try await withCheckedThrowingContinuation { continuation in
			_ = item.provider.loadFileRepresentation(for: item.type, openInPlace: false) { url, _, error in
				guard let url else {
					continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
					return
				}
				let copy = directory.appending(path: url.lastPathComponent)
				do {
					try FileManager.default.copyItem(at: url, to: copy)
					continuation.resume(returning: copy)
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}
