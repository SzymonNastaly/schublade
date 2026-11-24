import AppKit
import ApplicationBindings
import ApplicationPresentation

extension FolderPageViewController {
	/// The reassurance first, then what happens to the files there and to later ones, then the
	/// decision, with the upload as the default button.
	func confirmation(_ wording: BacklogConfirmationWording) -> [NSView] {
		let heading = PageText.heading(wording.heading)
		let reassurance = PageText.body(Self.collectionNote)
		let question = NSStackView(views: [heading, reassurance])
		question.orientation = .vertical
		question.alignment = .leading
		question.spacing = 6
		for view in [heading, reassurance] {
			view.widthAnchor.constraint(equalTo: question.widthAnchor).isActive = true
		}

		let existing = PageSectionView(title: wording.existingFilesHeading, symbolName: "doc.on.doc")
		for sentence in wording.existingFiles {
			existing.append(PageText.body(sentence))
		}
		if let summary = wording.skippedSummary {
			existing.append(PageText.body(summary))
			existing.append(skippedGrid(wording.skippedGroups))
		}
		if let note = wording.examinationNote {
			existing.append(PageText.secondary(note))
		}
		let future = PageSectionView(
			title: wording.futureFilesHeading,
			symbolName: "arrow.triangle.2.circlepath",
			symbolColor: InterfacePalette.archive
		)
		future.append(PageText.body(wording.futureFiles))

		let remove = NSButton(title: wording.removeLabel, target: self, action: #selector(removePressed))
		remove.setAccessibilityIdentifier(InterfaceIdentifier.folderPageRemoveButton)
		let upload = NSButton(title: wording.uploadLabel, target: self, action: #selector(uploadPressed))
		upload.keyEquivalent = "\r"
		upload.setAccessibilityIdentifier(InterfaceIdentifier.folderPageUploadButton)
		for button in [remove, upload] {
			button.bezelStyle = .push
			button.controlSize = .large
			button.isEnabled = !commandPending
		}
		let buttons = NSStackView(views: [NSView(), remove, upload])
		buttons.spacing = 12
		return [question, existing, future, buttons]
	}

	func skippedGrid(_ groups: [SkippedGroup]) -> NSView {
		let grid = NSGridView(views: groups.map { group in
			[PageText.secondary(group.reason), PageText.figure(group.count)]
		})
		grid.columnSpacing = 24
		grid.rowSpacing = 3
		grid.column(at: 1).xPlacement = .trailing
		return grid
	}
}
