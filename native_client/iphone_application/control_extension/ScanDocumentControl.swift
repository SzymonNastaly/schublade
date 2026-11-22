import AppIntents
import SwiftUI
import WidgetKit

/// From the Lock Screen, the system asks for Face ID before the application opens.
struct ScanDocumentControl: ControlWidget {
	var body: some ControlWidgetConfiguration {
		StaticControlConfiguration(kind: "scan-document") {
			ControlWidgetButton(action: ScanDocumentIntent()) {
				Label("Scan Document", systemImage: "doc.viewfinder")
			}
		}
		.displayName("Scan Document")
		.description("Opens Schublade with the document camera.")
	}
}
