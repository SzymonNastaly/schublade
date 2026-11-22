import AppKit
import QuickLookUI

/// Three-pane library detail split holding the document list, reader, and collapsible inspector.
final class LibraryDetailSplitViewController: NSSplitViewController {
	private let listController: DocumentListViewController
	private let readerController: DocumentReaderViewController
	private let inspectorController: DocumentInspectorViewController
	private let persistsSplitPositions: Bool
	private let inspectorItem: NSSplitViewItem
	var onToggleSidebar: ((Any?) -> Void)?
	/// Called when the window's width, not a person, collapsed or expanded the inspector.
	var onInspectorVisibilityChanged: ((Bool) -> Void)?
	private var requestedInspectorVisible = true
	private var dividersPlaced = false
	private var hasAppeared = false

	init(
		listController: DocumentListViewController,
		readerController: DocumentReaderViewController,
		inspectorController: DocumentInspectorViewController,
		persistsSplitPositions: Bool
	) {
		self.listController = listController
		self.readerController = readerController
		self.inspectorController = inspectorController
		self.persistsSplitPositions = persistsSplitPositions
		inspectorItem = NSSplitViewItem(viewController: inspectorController)
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		splitView.dividerStyle = .thin
		if persistsSplitPositions {
			splitView.autosaveName = "org.schublade.detailSplit"
		}

		let listItem = NSSplitViewItem(viewController: listController)
		listItem.minimumThickness = 270
		listItem.maximumThickness = 440
		listItem.holdingPriority = NSLayoutConstraint.Priority(260)

		let readerItem = NSSplitViewItem(viewController: readerController)
		readerItem.minimumThickness = 360
		readerItem.holdingPriority = NSLayoutConstraint.Priority(240)

		inspectorItem.minimumThickness = 220
		inspectorItem.maximumThickness = 320
		inspectorItem.canCollapse = true
		// The inspector gives way first when the window narrows below what the four parts need.
		inspectorItem.canCollapseFromWindowResize = true
		inspectorItem.collapseBehavior = .useConstraints
		inspectorItem.holdingPriority = NSLayoutConstraint.Priority(270)

		addSplitViewItem(listItem)
		addSplitViewItem(readerItem)
		addSplitViewItem(inspectorItem)
	}

	override func viewDidAppear() {
		super.viewDidAppear()
		hasAppeared = true
		view.needsLayout = true
	}

	/// The layouts before the window appears are narrower than the window and collapse the
	/// inspector, so the dividers are placed, and the inspector restored, at the first layout after.
	override func viewDidLayout() {
		super.viewDidLayout()
		guard hasAppeared, !dividersPlaced, splitView.bounds.width > 0 else {
			return
		}
		dividersPlaced = true
		if requestedInspectorVisible, inspectorItem.isCollapsed {
			inspectorItem.isCollapsed = false
		}
		InitialDividerPlacement.place(in: splitView, at: [330, splitView.bounds.width - 250])
	}

	override func splitViewDidResizeSubviews(_ notification: Notification) {
		super.splitViewDidResizeSubviews(notification)
		guard dividersPlaced else {
			return
		}
		let visible = !inspectorItem.isCollapsed
		if visible != requestedInspectorVisible {
			requestedInspectorVisible = visible
			onInspectorVisibilityChanged?(visible)
		}
	}

	func setInspectorVisible(_ visible: Bool, animated: Bool) {
		requestedInspectorVisible = visible
		let shouldCollapse = !visible
		guard inspectorItem.isCollapsed != shouldCollapse else {
			return
		}
		if animated {
			inspectorItem.animator().isCollapsed = shouldCollapse
		} else {
			inspectorItem.isCollapsed = shouldCollapse
		}
	}

	@objc override func toggleSidebar(_ sender: Any?) {
		onToggleSidebar?(sender)
	}

	// The Quick Look panel takes a data source only from a responder that controls it. The split
	// is in the responder chain whether the list, the reader, or the inspector has the keyboard.

	override nonisolated func acceptsPreviewPanelControl(_: QLPreviewPanel?) -> Bool {
		true
	}

	override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
		MainActor.assumeIsolated {
			panel.map { QuickLookCoordinator.shared.beginControl(of: $0) }
		}
	}

	override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
		MainActor.assumeIsolated {
			panel.map { QuickLookCoordinator.shared.endControl(of: $0) }
		}
	}
}
