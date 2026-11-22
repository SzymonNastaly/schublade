import AppKit

/// Places a split view's dividers where the design puts them. A caller does this once, after the
/// first layout that gives the split view its real width, because a split view without a width
/// keeps no divider; and it sets its own "placed" flag first, because moving a divider lays the
/// split view out again and calls back into the same layout method.
enum InitialDividerPlacement {
	/// Moves the dividers unless a person's own positions were saved under the autosave name.
	static func place(in splitView: NSSplitView, at positions: [CGFloat]) {
		let saved = splitView.autosaveName.map { name in
			UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil
		} ?? false
		guard !saved else {
			return
		}
		for (index, position) in positions.enumerated() {
			splitView.setPosition(position, ofDividerAt: index)
		}
	}
}
