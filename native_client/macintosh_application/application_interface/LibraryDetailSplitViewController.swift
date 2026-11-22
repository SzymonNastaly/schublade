import AppKit

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

		splitView.setPosition(330, ofDividerAt: 0)
		splitView.setPosition(876, ofDividerAt: 1)
	}

	override func splitViewDidResizeSubviews(_ notification: Notification) {
		super.splitViewDidResizeSubviews(notification)
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
}
