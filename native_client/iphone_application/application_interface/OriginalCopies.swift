import ApplicationBindings
import LibraryPresentation
import UIKit

/// Copies of an original under the name a person reads, for the share sheet.
enum OriginalCopies {
	/// Every copy lives under this directory, which each share empties first, so a copy whose sheet
	/// never closed, because the application ended, goes with the next share.
	private static let directory = URL.temporaryDirectory.appending(
		path: "original_copies",
		directoryHint: .isDirectory
	)
	/// Whether a share is between its tap and its sheet. Another tap meanwhile does nothing, so a
	/// person who taps twice during a download gets one download and one sheet.
	private static var sharing = false

	/// The share sheet with a named copy, whose directory goes once the sheet closes.
	static func share(
		_ document: DocumentIdentifier,
		fileName: String,
		gateway: ApplicationGateway,
		presenter: UIViewController?,
		source: (any UIPopoverPresentationControllerSourceItem)?
	) {
		guard !sharing else {
			return
		}
		sharing = true
		Task {
			defer { sharing = false }
			try? FileManager.default.removeItem(at: directory)
			guard let copy = await namedCopy(of: document, fileName: fileName, gateway: gateway, presenter: presenter)
			else {
				return
			}
			guard let presenter else {
				try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
				return
			}
			let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
			sheet.popoverPresentationController?.sourceItem = source
			sheet.completionWithItemsHandler = { _, _, _, _ in
				try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
			}
			presenter.present(sheet, animated: true)
		}
	}

	/// The original under its suggested name in a directory of its own, because the cache names its
	/// files by content and another application shows the name it receives. Says why when the
	/// original cannot be had.
	private static func namedCopy(
		of document: DocumentIdentifier,
		fileName: String,
		gateway: ApplicationGateway,
		presenter: UIViewController?
	) async -> URL? {
		do throws(RepresentationRefusal) {
			let original = try await gateway.original(document)
			let copyDirectory = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
			let copy = copyDirectory.appending(path: fileName)
			do {
				try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
				try FileManager.default.copyItem(at: URL(filePath: original.path), to: copy)
			} catch {
				alert("The Original Could Not Be Copied", error.localizedDescription, on: presenter)
				return nil
			}
			return copy
		} catch {
			let placeholder = LibraryFailureWording.originalRefusalPlaceholder(error, device: IphoneDevice.wording)
			alert(placeholder.title, placeholder.detail, on: presenter)
			return nil
		}
	}

	private static func alert(_ title: String, _ message: String, on presenter: UIViewController?) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .default))
		presenter?.present(alert, animated: true)
	}
}
