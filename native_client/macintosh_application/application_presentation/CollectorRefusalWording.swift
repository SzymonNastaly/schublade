import ApplicationBindings
import LibraryPresentation

/// Why the collector refused to add a folder, remove one, or take a folder's decision.
public enum CollectorRefusalWording {
	public static func enrollmentRefusalSentence(
		_ refusal: EnrollmentRefusal,
		context: ApplicationWordingContext
	) -> String {
		switch refusal {
		case let .NotADirectory(root):
			"\(root) is not a folder."
		case let .AlreadyEnrolled(folder):
			"\(context.folderName(folder.root)) is collected already."
		case let .OverlapsEnrolledFolder(folder):
			"This folder is inside \(context.folderName(folder.root)) or contains it. "
				+ "Each file can be collected from one folder only."
		case let .Application(fault):
			LibraryFailureWording.faultSentence(fault)
		}
	}

	public static func withdrawalRefusalSentence(_ refusal: WithdrawalRefusal) -> String {
		switch refusal {
		case .FolderUnknown:
			"This folder is no longer collected."
		case let .Application(fault):
			LibraryFailureWording.faultSentence(fault)
		}
	}

	public static func decisionRefusalSentence(
		_ refusal: DecisionRefusal,
		context: ApplicationWordingContext
	) -> String {
		switch refusal {
		case .FolderUnknown:
			"This folder is no longer collected."
		case let .SurveyIncomplete(folder):
			"\(context.folderName(folder.root)) is still being surveyed."
		case let .AlreadyDecided(folder):
			"\(context.folderName(folder.root)) is collecting already."
		case let .Application(fault):
			LibraryFailureWording.faultSentence(fault)
		}
	}
}
