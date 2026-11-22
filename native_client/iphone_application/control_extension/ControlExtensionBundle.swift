import SwiftUI
import WidgetKit

/// The controls extension, which holds only the Scan Document control. It is the one SwiftUI target,
/// because a control exists only as a SwiftUI widget.
@main
struct ControlExtensionBundle: WidgetBundle {
	var body: some Widget {
		ScanDocumentControl()
	}
}
