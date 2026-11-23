import ApplicationBindings
import Observation
import ScanRequest
import UIKit

final class RootViewController: UIViewController {
	private enum Screen: Equatable {
		case starting
		case failure(String)
		case connection
		case library
	}

	private let controller: ApplicationController
	private var screen: Screen?
	private var shown: UIViewController?
	private var library: LibraryViewController?

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

	/// Shows the screen for the situation and answers a scan request, and again on the next change.
	private func follow() {
		withObservationTracking {
			show(screen(for: controller.situation))
			if ScanRequestCenter.shared.isPending {
				answerScanRequest()
			}
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	/// A request waits while the core starts, so a request that started the application opens the
	/// camera. The library screen answers it. Any other screen drops it, because a camera that
	/// opened once a person had connected would answer a request made long before.
	private func answerScanRequest() {
		switch screen {
		case .starting?, nil:
			break
		case .failure?, .connection?:
			_ = ScanRequestCenter.shared.take()
		case .library?:
			library?.answerScanRequest()
		}
	}

	/// While the core starts, a scan requested from outside the application installs the library at
	/// once when the last connected archive permits sending, so the camera opens without waiting for
	/// the core: a submission needs only the queue, and is sent once the core knows the archive.
	private func screen(for situation: ApplicationController.Situation) -> Screen {
		switch situation {
		case .starting:
			screen == .library || ScanRequestCenter.shared.isPending && controller.sendingPermitted
				? .library : .starting
		case let .failedToStart(detail):
			.failure("Schublade could not start: \(detail)")
		case let .running(status):
			if case .notConfigured = status.archive {
				.connection
			} else {
				.library
			}
		}
	}

	private func show(_ next: Screen) {
		guard next != screen else {
			return
		}
		screen = next
		shown?.presentedViewController?.dismiss(animated: false)
		library = nil
		let child: UIViewController
		switch next {
		case .starting:
			child = MessageViewController(text: "")
		case let .failure(text):
			child = MessageViewController(text: text)
		case .connection:
			child = UINavigationController(rootViewController: ConnectionViewController(controller: controller))
		case .library:
			let screen = LibraryViewController(controller: controller)
			library = screen
			child = UINavigationController(rootViewController: screen)
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
