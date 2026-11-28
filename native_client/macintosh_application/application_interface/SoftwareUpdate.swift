/// Checks for a newer release of the application and installs it. The application target supplies
/// one only to a Release build, so a Debug build, the renderer, and the tests never replace
/// themselves with a release and show no Check for Updates.
public protocol SoftwareUpdate: AnyObject {
	func checkForUpdates()
}
