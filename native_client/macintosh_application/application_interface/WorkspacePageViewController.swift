import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The pages that take the place of the list, the reader, and the inspector together: a folder,
/// Needs Attention, an empty archive, and the notices for an archive the library cannot read.
final class WorkspacePageViewController: NSViewController {
	private enum Page {
		case notice
		case folder
		case attention
	}

	private let container = WindowContainerViewController()
	private let notice = NSViewController()
	private let noticeView: EmptyStateView
	private let folderPage: FolderPageViewController
	private let attentionPage: NeedsAttentionViewController
	private var page: Page?

	init(
		commands: any CollectorCommands,
		renderMode: InterfaceRenderMode,
		onNavigate: @escaping (NavigationDestination, DocumentIdentifier?) -> Void,
		onAddFolder: @escaping () -> Void,
		onReplaceToken: @escaping () -> Void
	) {
		noticeView = EmptyStateView { action in
			switch action {
			case .addFolder: onAddFolder()
			case .replaceToken: onReplaceToken()
			case .searchAllDocuments: onNavigate(.library(.allDocuments, title: nil), nil)
			}
		}
		notice.view = noticeView
		folderPage = FolderPageViewController(
			commands: commands,
			renderMode: renderMode,
			onSelectDocument: { onNavigate(.library(.allDocuments, title: nil), $0) },
			onFolderWithdrawn: { onNavigate(.library(.allDocuments, title: nil), nil) }
		)
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
	func render(_ mode: WorkspaceDetailMode, statuses: ApplicationStatuses, context: ApplicationWordingContext) {
		switch mode {
		case .documents:
			break
		case .emptyArchive, .archiveOutdated, .tokenCannotRead:
			show(.notice)
			if let page = EmptyStatePresentation.page(mode) {
				noticeView.render(page, defaultAction: true)
			}
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

	/// Asks to remove the folder whose page shows, as its Remove Folder… button does.
	func requestFolderRemoval() {
		guard page == .folder else {
			return
		}
		folderPage.requestRemoval()
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
