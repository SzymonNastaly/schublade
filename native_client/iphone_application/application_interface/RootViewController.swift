import ApplicationBindings
import Observation
import UIKit

/// Shows the screen the application's situation calls for: a message while the core starts or
/// when it failed, the connection form while no archive is connected, and the submissions after.
final class RootViewController: UIViewController {
	private enum Screen: Equatable {
		case message(String)
		case connection
		case submissions
	}

	private let controller: ApplicationController
	private var screen: Screen?
	private var shown: UIViewController?

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
		view.backgroundColor = .systemBackground
		follow()
	}

	/// Shows the screen for the situation, and again on its next change.
	private func follow() {
		withObservationTracking {
			show(Self.screen(for: controller.situation))
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private static func screen(for situation: ApplicationController.Situation) -> Screen {
		switch situation {
		case .starting:
			.message("")
		case let .failedToStart(detail):
			.message("Schublade could not start: \(detail)")
		case let .running(status):
			if case .notConfigured = status.archive {
				.connection
			} else {
				.submissions
			}
		}
	}

	private func show(_ next: Screen) {
		guard next != screen else {
			return
		}
		screen = next
		let child: UIViewController = switch next {
		case let .message(text):
			MessageViewController(text: text)
		case .connection:
			UINavigationController(rootViewController: ConnectionViewController(controller: controller))
		case .submissions:
			UINavigationController(rootViewController: SubmissionsViewController(controller: controller))
		}
		shown?.willMove(toParent: nil)
		shown?.view.removeFromSuperview()
		shown?.removeFromParent()
		addChild(child)
		child.view.frame = view.bounds
		child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(child.view)
		child.didMove(toParent: self)
		shown = child
	}
}

/// One sentence in the middle of the screen.
private final class MessageViewController: UIViewController {
	private let text: String

	init(text: String) {
		self.text = text
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		var content = UIContentUnavailableConfiguration.empty()
		content.text = text
		contentUnavailableConfiguration = text.isEmpty ? UIContentUnavailableConfiguration.loading() : content
	}
}
