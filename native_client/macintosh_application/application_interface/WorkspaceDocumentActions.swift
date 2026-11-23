import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Executes user-initiated document actions (Open, Quick Look, Export, Copy, Share, Open in
/// Browser, and Add Folder) and presents refusal sheets in interactive mode.
@MainActor
final class WorkspaceDocumentActions {
	private let queries: any LibraryQueries
	private let collectorCommands: any CollectorCommands
	private let quickLookCoordinator = QuickLookCoordinator.shared
	private let renderMode: InterfaceRenderMode
	private var newestPreviewRequest: UInt64 = 0

	init(
		queries: any LibraryQueries,
		collectorCommands: any CollectorCommands,
		renderMode: InterfaceRenderMode
	) {
		self.queries = queries
		self.collectorCommands = collectorCommands
		self.renderMode = renderMode
	}

	/// Follows the selection while the Quick Look panel shows, and downloads nothing while it does not.
	func updateQuickLookSelection(_ document: DocumentIdentifier?, detail: DocumentDetail?) {
		newestPreviewRequest &+= 1
		guard quickLookCoordinator.isPreviewVisible else {
			return
		}
		guard let document else {
			quickLookCoordinator.updatePreviewIfVisible(item: nil)
			return
		}
		let request = newestPreviewRequest
		Task {
			guard let localFile = try? await queries.original(document), request == newestPreviewRequest else {
				return
			}
			let title = detail?.title ?? "Document"
			let item = PreviewedDocumentItem(url: URL(fileURLWithPath: localFile.path), title: title)
			quickLookCoordinator.updatePreviewIfVisible(item: item)
		}
	}

	func openInDefaultApplication(_ document: DocumentIdentifier, window: NSWindow?) {
		Task {
			do throws(RepresentationRefusal) {
				let localFile = try await queries.original(document)
				NSWorkspace.shared.open(URL(fileURLWithPath: localFile.path))
			} catch {
				presentRepresentationAlert(error, in: window)
			}
		}
	}

	func toggleQuickLook(for document: DocumentIdentifier, title: String?, window: NSWindow?) {
		Task {
			do throws(RepresentationRefusal) {
				let localFile = try await queries.original(document)
				let item = PreviewedDocumentItem(
					url: URL(fileURLWithPath: localFile.path),
					title: title ?? "Document"
				)
				quickLookCoordinator.togglePreview(for: item)
			} catch {
				presentRepresentationAlert(error, in: window)
			}
		}
	}

	/// Puts a copy of the original on the pasteboard under its suggested name, writable, as a drag
	/// gives it, and apart from the cache, whose file may be evicted before the paste.
	func copyFile(_ document: DocumentIdentifier, suggestedFileName: String?, window: NSWindow?) {
		Task {
			do {
				let localFile = try await queries.original(document)
				let copy = try namedCopy(
					of: URL(fileURLWithPath: localFile.path),
					suggestedFileName: suggestedFileName ?? "\(document.value).pdf"
				)
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setData(copy.dataRepresentation, forType: .fileURL)
			} catch let refusal as RepresentationRefusal {
				presentRepresentationAlert(refusal, in: window)
			} catch {
				presentAlert(title: "Copy Failed", message: error.localizedDescription, in: window)
			}
		}
	}

	/// A copy of a cached original under its suggested name, in a folder of its own, for a paste or
	/// a share that may outlive the cache's file.
	func namedCopy(of original: URL, suggestedFileName: String) throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "Schublade Copies/\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let copy = folder.appending(path: suggestedFileName)
		try OriginalFileCopy.write(from: original, to: copy)
		return copy
	}

	func export(_ document: DocumentIdentifier, suggestedFileName: String?, window: NSWindow?) {
		guard let window else {
			return
		}
		let panel = NSSavePanel()
		panel.nameFieldStringValue = suggestedFileName ?? "\(document.value).pdf"
		panel.canCreateDirectories = true
		panel.beginSheetModal(for: window) { [weak self] response in
			guard response == .OK, let destination = panel.url else {
				return
			}
			Task {
				await self?.writeExportedOriginal(document: document, to: destination, window: window)
			}
		}
	}

	func presentAddFolderPanel(in window: NSWindow?, onEnrolled: @escaping (FolderReference) -> Void) {
		guard let window else {
			return
		}
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = "Add Folder"
		panel.beginSheetModal(for: window) { [weak self] response in
			guard response == .OK, let selectedURL = panel.url else {
				return
			}
			Task {
				await self?.enrollFolder(at: selectedURL, window: window, onEnrolled: onEnrolled)
			}
		}
	}

	func presentRepresentationAlert(_ refusal: RepresentationRefusal, in window: NSWindow?) {
		let placeholder = LibraryFailureWording.originalRefusalPlaceholder(refusal, device: MacintoshDevice.wording)
		presentAlert(title: placeholder.title, message: placeholder.detail, in: window)
	}

	private func writeExportedOriginal(
		document: DocumentIdentifier,
		to destination: URL,
		window: NSWindow?
	) async {
		do {
			let localFile = try await queries.original(document)
			try OriginalFileCopy.write(from: URL(fileURLWithPath: localFile.path), to: destination)
		} catch let refusal as RepresentationRefusal {
			presentRepresentationAlert(refusal, in: window)
		} catch {
			presentAlert(title: "Export Failed", message: error.localizedDescription, in: window)
		}
	}

	private func enrollFolder(
		at url: URL,
		window: NSWindow?,
		onEnrolled: @escaping (FolderReference) -> Void
	) async {
		do {
			let folder = try await collectorCommands.enrollFolder(root: url.path(percentEncoded: false))
			onEnrolled(folder)
		} catch {
			presentAlert(title: "Could Not Add Folder", message: String(describing: error), in: window)
		}
	}

	private func presentAlert(title: String, message: String, in window: NSWindow?) {
		guard let window, renderMode == .interactive else {
			return
		}
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.addButton(withTitle: "OK")
		alert.beginSheetModal(for: window)
	}
}
