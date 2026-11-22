import ApplicationBindings
import Observation
import UIKit

/// The first screen until scanning and reading arrive: whether the core runs, and what the copy
/// of the archive holds.
final class LibraryStateViewController: UIViewController {
	private let controller: ApplicationController
	private let stateLabel = UILabel()

	init(controller: ApplicationController) {
		self.controller = controller
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = "Schublade"
		navigationItem.largeTitleDisplayMode = .always
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemBackground
		stateLabel.font = .preferredFont(forTextStyle: .body)
		stateLabel.adjustsFontForContentSizeCategory = true
		stateLabel.textColor = .secondaryLabel
		stateLabel.numberOfLines = 0
		stateLabel.textAlignment = .center
		stateLabel.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stateLabel)
		NSLayoutConstraint.activate([
			stateLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
			stateLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			stateLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
		])
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		showSituation()
	}

	/// Shows the situation and shows it again on its next change.
	private func showSituation() {
		withObservationTracking {
			stateLabel.text = Self.sentence(controller.situation)
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.showSituation()
			}
		}
	}

	private static func sentence(_ situation: ApplicationController.Situation) -> String {
		switch situation {
		case .starting:
			"Starting"
		case let .failedToStart(detail):
			"Schublade could not start: \(detail)"
		case let .running(status):
			switch status.archive {
			case .notConfigured:
				"No archive is connected"
			case .configured:
				"\(status.counts.documents) documents"
			}
		}
	}
}
