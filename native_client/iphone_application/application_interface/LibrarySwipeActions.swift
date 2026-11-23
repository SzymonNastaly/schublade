import ApplicationBindings
import UIKit

/// The swipe actions of the library's rows: Share on a document, and on an arrival what
/// `ArrivalPresentation` permits. A full swipe does nothing, because a sheet that opened from one
/// would surprise.
final class LibrarySwipeActions {
	private let gateway: ApplicationGateway
	private let submissions: SubmissionCoordinator
	private weak var presenter: UIViewController?

	init(gateway: ApplicationGateway, submissions: SubmissionCoordinator, presenter: UIViewController) {
		self.gateway = gateway
		self.submissions = submissions
		self.presenter = presenter
	}

	func configuration(document row: DocumentRow) -> UISwipeActionsConfiguration {
		let share = Self.share { [weak self] view in
			guard let self else {
				return
			}
			OriginalCopies.share(
				row.document,
				fileName: row.suggestedFileName,
				gateway: gateway,
				presenter: presenter,
				source: view
			)
		}
		return Self.configuration([share])
	}

	func configuration(arrival: Arrival) -> UISwipeActionsConfiguration? {
		guard ArrivalPresentation.removable(arrival) else {
			return nil
		}
		let identifier = arrival.id
		let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
			self?.submissions.remove(identifier)
			done(true)
		}
		remove.image = UIImage(systemName: "trash")
		guard ArrivalPresentation.fileShareable(arrival) else {
			return Self.configuration([remove])
		}
		let share = Self.share { [weak self] view in
			self?.shareFile(of: identifier, from: view)
		}
		return Self.configuration([remove, share])
	}

	private static func share(_ perform: @escaping (UIView) -> Void) -> UIContextualAction {
		let share = UIContextualAction(style: .normal, title: "Share") { _, view, done in
			perform(view)
			done(true)
		}
		share.image = UIImage(systemName: "square.and.arrow.up")
		share.backgroundColor = .tintColor
		return share
	}

	private static func configuration(_ actions: [UIContextualAction]) -> UISwipeActionsConfiguration {
		let configuration = UISwipeActionsConfiguration(actions: actions)
		configuration.performsFirstActionWithFullSwipe = false
		return configuration
	}

	private func shareFile(of identifier: UUID, from view: UIView) {
		guard let entry = submissions.entries.first(where: { $0.id == identifier }),
		      let file = submissions.documentFile(of: entry)
		else {
			return
		}
		OriginalCopies.share(file: file, fileName: entry.manifest.fileName, presenter: presenter, source: view)
	}
}
