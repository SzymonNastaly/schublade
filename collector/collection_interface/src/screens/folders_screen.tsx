import { FolderPlusIcon } from "@phosphor-icons/react"
import { useState } from "react"
import { collectorBridge, useCollectorCommand } from "../collector_queries"
import { ActionButton } from "../controls/action_button"
import { FailureMessage } from "../controls/form_fields"
import { SectionPanel } from "../controls/section_panel"
import { StatusBadge } from "../controls/status_badge"
import { failureSentence } from "../failure_sentence"
import { folderState } from "../status_sentences"
import type { CollectorStatus, FolderStatus } from "../collector_status"

export function FoldersScreen({ status }: { status: CollectorStatus }) {
	const enrollment = useCollectorCommand(async () => {
		const root = await collectorBridge.chooseFolder()
		if (root !== null) await collectorBridge.enrollFolder(root)
	})
	return (
		<div className="mx-auto flex max-w-[760px] flex-col gap-3">
			<SectionPanel
				section="documents"
				heading="Folders"
				accessory={
					<ActionButton
						variant="secondary"
						size="compact"
						icon={FolderPlusIcon}
						pending={enrollment.isPending}
						onClick={() => enrollment.mutate()}
					>
						Add folder
					</ActionButton>
				}
			>
				{status.folders.length === 0 ? (
					<div className="flex flex-col gap-1 px-3 py-4">
						<p className="font-bold text-heading">No folders yet</p>
						<p className="text-caption">
							Add Downloads or another folder where your PDFs and scans land. You see what it holds before anything
							uploads.
						</p>
					</div>
				) : (
					status.folders.map((folder) => <FolderRow key={folder.folder} folder={folder} status={status} />)
				)}
			</SectionPanel>
			{enrollment.isError && <FailureMessage>{failureSentence(enrollment.error, status)}</FailureMessage>}
			<p className="px-1 text-fine text-caption">
				The collector reads the PDF, JPEG, PNG, and WebP files in these folders and their subfolders. It never changes,
				moves, or deletes your files, and removing a folder here keeps what Schublade received.
			</p>
		</div>
	)
}

function FolderRow({ folder, status }: { folder: FolderStatus; status: CollectorStatus }) {
	const [confirming, setConfirming] = useState(false)
	const withdrawal = useCollectorCommand(() => collectorBridge.withdrawFolder(folder.folder))
	const state = folderState(folder)
	return (
		<div className="flex flex-col gap-1.5 px-3 py-2.5">
			<div className="flex items-center gap-3">
				<div className="flex min-w-0 flex-1 flex-col">
					<span className="flex items-center gap-2">
						<span className="truncate font-bold text-heading">{folder.name}</span>
						<StatusBadge tone={state.tone}>{state.label}</StatusBadge>
					</span>
					<span className="truncate text-fine text-caption select-text">{folder.root}</span>
				</div>
				{!confirming && (
					<ActionButton variant="secondaryDestructive" size="compact" onClick={() => setConfirming(true)}>
						Remove
					</ActionButton>
				)}
			</div>
			{state.detail !== null && <p className="text-fine">{state.detail}</p>}
			{confirming && (
				<div className="flex items-center justify-between gap-3 rounded-field border border-destructive-border bg-failure-badge px-3 py-2">
					<p className="text-fine">
						Stop collecting from {folder.name}? Your files stay where they are, and Schublade keeps what it received.
					</p>
					<div className="flex shrink-0 gap-2">
						<ActionButton variant="secondary" size="compact" onClick={() => setConfirming(false)}>
							Keep
						</ActionButton>
						<ActionButton
							variant="secondaryDestructive"
							size="compact"
							pending={withdrawal.isPending}
							onClick={() => withdrawal.mutate()}
						>
							Remove folder
						</ActionButton>
					</div>
				</div>
			)}
			{withdrawal.isError && <FailureMessage>{failureSentence(withdrawal.error, status)}</FailureMessage>}
		</div>
	)
}
