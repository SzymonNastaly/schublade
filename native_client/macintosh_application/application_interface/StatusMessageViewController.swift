import AppKit
import ApplicationPresentation

/// The window's page while Schublade starts, after it failed to start, while its library is
/// unavailable, or once it stopped.
public final class StatusMessageViewController: NSViewController {
	private let presentation: EmptyStatePresentation

	public init(presentation: EmptyStatePresentation) {
		self.presentation = presentation
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func loadView() {
		let stateView = EmptyStateView { _ in }
		stateView.render(presentation)
		view = stateView
	}
}
