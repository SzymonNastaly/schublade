import AppKit

/// The Mac's settings form: a grid of 480 points with 20 points of margin, its labels at the
/// trailing edge of the first column and its controls in the second.
enum SettingsPaneLayout {
	private static let paneWidth: CGFloat = 480
	private static let margin: CGFloat = 20
	private static let columnSpacing: CGFloat = 8

	/// One row: a label such as "Startup:", or nil to continue the row above, and its control.
	struct PaneRow {
		let label: String?
		let content: NSView
		/// Space above the row, beyond the grid's row spacing.
		var spacingAbove: CGFloat = 0
	}

	/// Builds the pane. A wrapping label in the second column wraps at the column's width, so the
	/// pane's fitting size is its height before any window lays it out.
	static func pane(_ rows: [PaneRow]) -> NSView {
		let labels = rows.map { row in
			row.label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
		}
		let grid = NSGridView(views: zip(labels, rows).map { [$0, $1.content] })
		grid.rowSpacing = 8
		grid.columnSpacing = columnSpacing
		grid.rowAlignment = .firstBaseline
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).xPlacement = .leading
		for (index, row) in rows.enumerated() {
			grid.row(at: index).topPadding = row.spacingAbove
		}

		let labelWidth = labels.map(\.fittingSize.width).max() ?? 0
		let contentWidth = paneWidth - 2 * margin - labelWidth - columnSpacing
		for row in rows {
			for label in wrappingLabels(in: row.content) {
				label.preferredMaxLayoutWidth = contentWidth
			}
		}

		let pane = NSView()
		grid.translatesAutoresizingMaskIntoConstraints = false
		pane.addSubview(grid)
		NSLayoutConstraint.activate([
			pane.widthAnchor.constraint(equalToConstant: paneWidth),
			grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: margin),
			grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: margin),
			grid.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -margin),
			grid.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -margin),
		])
		return pane
	}

	private static func wrappingLabels(in view: NSView) -> [NSTextField] {
		if let label = view as? NSTextField, !label.isEditable, label.cell?.wraps == true {
			return [label]
		}
		return view.subviews.flatMap(wrappingLabels)
	}
}
