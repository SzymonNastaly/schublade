import { useState } from "react"
import { useCollectorEvents, useCollectorStatus } from "./collector_queries"
import { FailureMessage } from "./controls/form_fields"
import { ApplicationHeader } from "./screens/application_header"
import { BacklogConfirmationScreen } from "./screens/backlog_confirmation_screen"
import { FoldersScreen } from "./screens/folders_screen"
import { SettingsScreen } from "./screens/settings_screen"
import { SetupScreen } from "./screens/setup_screen"
import { StatusScreen } from "./screens/status_screen"
import type { ApplicationTab } from "./screens/application_header"

/**
 * The screen follows the collector's state: setup until an archive is connected, the confirmation
 * while a surveyed folder awaits its decision, and otherwise the tab the person chose.
 */
export function Application() {
	useCollectorEvents()
	const status = useCollectorStatus()
	const [tab, setTab] = useState<ApplicationTab>("status")

	if (status.isPending) return <ApplicationHeader />
	if (status.isError) {
		return (
			<>
				<ApplicationHeader />
				<main className="p-4">
					<FailureMessage>The collector did not answer: {status.error.message}</FailureMessage>
				</main>
			</>
		)
	}
	if (status.data.connection.kind === "Unconfigured") {
		return (
			<>
				<ApplicationHeader />
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
				<BacklogConfirmationScreen folder={awaiting} backlog={awaiting.backlog} status={status.data} />
			</>
		)
	}
	return (
		<div className="flex h-full flex-col">
			<ApplicationHeader tab={tab} onTabChange={setTab} />
			<main className="min-h-0 flex-1 overflow-y-auto p-4">
				{tab === "status" && <StatusScreen status={status.data} onOpenTab={setTab} />}
				{tab === "folders" && <FoldersScreen status={status.data} />}
				{tab === "settings" && <SettingsScreen status={status.data} />}
			</main>
		</div>
	)
}
