import ApplicationBindings
import LibraryPresentation
import QuickLook
import UIKit

final class DocumentFileActions: NSObject, QLPreviewControllerDataSource {
	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private weak var presenter: UIViewController?
	private var previewed: PreviewedDocumentItem?

	var detail: DocumentDetailPresentation? {
		didSet {
			for item in toolbarItems {
				item.isEnabled = detail != nil
			}
		}
	}

	private(set) lazy var toolbarItems: [UIBarButtonItem] = {
		let share = UIBarButtonItem(
			title: "Share",
			image: UIImage(systemName: "square.and.arrow.up"),
			primaryAction: UIAction(title: "Share") { [weak self] _ in self?.share() }
		)
		let preview = UIBarButtonItem(
			title: "Quick Look",
			image: UIImage(systemName: "eye"),
			primaryAction: UIAction(title: "Quick Look") { [weak self] _ in self?.preview() }
		)
		let browser = UIBarButtonItem(
			title: "Open in Browser",
			image: UIImage(systemName: "safari"),
			primaryAction: UIAction(title: "Open in Browser") { [weak self] _ in self?.openInBrowser() }
		)
		share.accessibilityIdentifier = "document.share"
		for item in [share, preview, browser] {
			item.isEnabled = false
		}
		return [share, .flexibleSpace(), preview, .flexibleSpace(), browser]
	}()

	private var shareItem: UIBarButtonItem? {
		toolbarItems.first
	}

	init(gateway: ApplicationGateway, document: DocumentIdentifier, presenter: UIViewController) {
		self.gateway = gateway
		self.document = document
		self.presenter = presenter
	}

	private func share() {
		Task {
			guard let file = await namedCopy() else {
				return
			}
			let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
			sheet.popoverPresentationController?.sourceItem = shareItem
			presenter?.present(sheet, animated: true)
		}
	}

	private func preview() {
		Task {
			guard let file = await namedCopy(), let detail else {
				return
			}
			previewed = PreviewedDocumentItem(url: file, title: detail.title)
			let viewer = QLPreviewController()
			viewer.dataSource = self
			presenter?.present(viewer, animated: true)
		}
	}

	private func openInBrowser() {
		guard let page = detail?.archivePageURL else {
			return
		}
		UIApplication.shared.open(page)
	}

	/// The original under its suggested name in a directory of its own, because the cache names its
	/// files by content and another application shows the name it receives. Says why when the
	/// original cannot be had.
	private func namedCopy() async -> URL? {
		guard let detail else {
			return nil
		}
		do throws(RepresentationRefusal) {
			let original = try await gateway.original(document)
			let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
			let copy = directory.appending(path: detail.suggestedFileName)
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				try FileManager.default.copyItem(at: URL(filePath: original.path), to: copy)
			} catch {
				alert("The Original Could Not Be Copied", error.localizedDescription)
				return nil
			}
			return copy
		} catch {
			let placeholder = LibraryFailureWording.originalRefusalPlaceholder(error, device: IphoneDevice.wording)
			alert(placeholder.title, placeholder.detail)
			return nil
		}
	}

	private func alert(_ title: String, _ message: String) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .default))
		presenter?.present(alert, animated: true)
	}

	func numberOfPreviewItems(in _: QLPreviewController) -> Int {
		previewed == nil ? 0 : 1
	}

	func previewController(_: QLPreviewController, previewItemAt _: Int) -> any QLPreviewItem {
		previewed ?? PreviewedDocumentItem(url: URL.temporaryDirectory, title: "")
	}
}

/// A named copy of an original for Quick Look, which reads its item from its own threads, so the
/// conformance is nonisolated over constants.
final class PreviewedDocumentItem: NSObject {
	nonisolated let previewItemURL: URL?
	nonisolated let previewItemTitle: String?

	init(url: URL, title: String) {
		previewItemURL = url
		previewItemTitle = title
	}
}

extension PreviewedDocumentItem: nonisolated QLPreviewItem {}
