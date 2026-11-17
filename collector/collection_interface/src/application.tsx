import { useState } from "react"
import { useCollectorStatus } from "./collector_queries"
import { RefusalError } from "./collector_status"
import { FailureMessage } from "./controls/form_fields"
import { failureSentence } from "./failure_sentence"
import { ApplicationHeader } from "./screens/application_header"
import { BacklogConfirmationScreen } from "./screens/backlog_confirmation_screen"
import { FoldersScreen } from "./screens/folders_screen"
import { SettingsScreen } from "./screens/settings_screen"
import { SetupScreen } from "./screens/setup_screen"
import { StartFailureScreen } from "./screens/start_failure_screen"
import { StatusScreen } from "./screens/status_screen"
import type { ApplicationTab } from "./screens/application_header"

/**
 * The screen follows the collector's state: setup until an archive is connected, the confirmation
 * while a surveyed folder awaits its decision, and otherwise the tab the person chose.
 */
export function Application() {
	const status = useCollectorStatus()
	const [tab, setTab] = useState<ApplicationTab>("status")

	if (status.data === undefined) {
		if (!status.isError) return <ApplicationHeader />
		const refusal = status.error instanceof RefusalError ? status.error.refusal : null
		return (
			<>
				<ApplicationHeader />
				{refusal?.kind === "CollectorNotStarted" ? (
					<StartFailureScreen failure={refusal.failure} />
				) : (
					<main className="p-4">
						<FailureMessage>The collector did not answer: {failureSentence(status.error, undefined)}</FailureMessage>
					</main>
				)}
			</>
		)
	}
	// A failed reread keeps the status already shown and says so above it.
	const rereadFailure =
		status.error === null ? null : (
			<FailureMessage>
				The collector did not answer just now: {failureSentence(status.error, status.data)}
			</FailureMessage>
		)
	if (status.data.connection.kind === "Unconfigured") {
		return (
			<>
				<ApplicationHeader />
				{rereadFailure !== null && <div className="mx-auto max-w-[520px] px-6 pt-4">{rereadFailure}</div>}
				<SetupScreen />
			</>
		)
	}
	const awaiting = status.data.folders.find(
		(folder) => folder.admission.kind === "AwaitingDecision" && folder.backlog !== null,
	)
	if (awaiting?.backlog) {
		return (
			<>
				<ApplicationHeader />
				{rereadFailure !== null && <div className="mx-auto max-w-[600px] px-6 pt-4">{rereadFailure}</div>}
				<BacklogConfirmationScreen
					key={awaiting.folder}
					folder={awaiting}
					backlog={awaiting.backlog}
					status={status.data}
				/>
			</>
		)
	}
	return (
		<div className="flex h-full flex-col">
			<ApplicationHeader tab={tab} onTabChange={setTab} />
			<main className="min-h-0 flex-1 overflow-y-auto p-4">
				{rereadFailure !== null && <div className="mx-auto mb-3 max-w-[760px]">{rereadFailure}</div>}
				{tab === "status" && <StatusScreen status={status.data} onOpenTab={setTab} />}
				{tab === "folders" && <FoldersScreen status={status.data} />}
				{tab === "settings" && <SettingsScreen status={status.data} />}
			</main>
		</div>
	)
}
