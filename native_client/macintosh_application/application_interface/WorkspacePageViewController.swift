import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The pages that take the place of the list, the reader, and the inspector together: a folder,
/// Needs Attention, and the notices for an archive the library cannot read.
final class WorkspacePageViewController: NSViewController {
	private enum Page {
		case notice
		case folder
		case attention
	}

	private let container = WindowContainerViewController()
	private let notice = WorkspaceNoticeViewController()
	private let folderPage: FolderPageViewController
	private let attentionPage: NeedsAttentionViewController
	private let onReplaceToken: () -> Void
	private var page: Page?

	init(
		commands: any CollectorCommands,
		renderMode: InterfaceRenderMode,
		onNavigate: @escaping (NavigationDestination, DocumentIdentifier?) -> Void,
		onReplaceToken: @escaping () -> Void
	) {
		self.onReplaceToken = onReplaceToken
		folderPage = FolderPageViewController(commands: commands, renderMode: renderMode) { document in
			onNavigate(.library(.allDocuments, title: nil), document)
		}
		attentionPage = NeedsAttentionViewController(
			onAction: { action in
				switch action {
				case .replaceToken:
					onReplaceToken()
				case let .decideBacklog(folder), let .openFolder(folder):
					onNavigate(.folder(folder), nil)
				}
			},
			onShowFailedDocuments: { onNavigate(.library(.failed, title: nil), nil) }
		)
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		addChild(container)
		view = container.view
	}

	/// Shows the page of a detail mode other than `documents`, which the document split shows.
	func render(_ mode: WorkspaceDetailMode, statuses: ApplicationStatuses, context: WordingContext) {
		switch mode {
		case .documents:
			break
		case let .archiveOutdated(message):
			show(.notice)
			notice.render(title: "Update Required", detail: message, actionTitle: nil, onAction: nil)
		case let .tokenCannotRead(message):
			show(.notice)
			notice.render(
				title: "Token Cannot Read Archive",
				detail: message,
				actionTitle: "Replace Token…",
				onAction: onReplaceToken
			)
		case .needsAttention:
			show(.attention)
			attentionPage.render(
				items: statuses.attentionItems,
				failedDocuments: statuses.library?.counts.documentsFailed ?? 0,
				context: context
			)
		case let .folder(identifier, _):
			show(.folder)
			folderPage.render(
				folder: statuses.collector?.folders.first { $0.folder.identifier == identifier },
				receipts: statuses.collector?.recentReceipts ?? [],
				context: context
			)
		}
	}

	private func show(_ next: Page) {
		guard next != page else {
			return
		}
		page = next
		switch next {
		case .notice:
			container.display(notice)
		case .folder:
			container.display(folderPage)
		case .attention:
			container.display(attentionPage)
		}
	}
}
