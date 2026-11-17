import { ArrowsClockwiseIcon, FolderIcon } from "@phosphor-icons/react"
import { backlogConfirmationWording } from "../backlog_confirmation_wording"
import { collectorBridge, useCollectorCommand } from "../collector_queries"
import { ActionButton } from "../controls/action_button"
import { FailureMessage } from "../controls/form_fields"
import { failureSentence } from "../failure_sentence"
import type { BacklogSummary, CollectorStatus, FolderStatus } from "../collector_status"

interface BacklogConfirmationScreenProperties {
	folder: FolderStatus
	backlog: BacklogSummary
	status: CollectorStatus
}

/**
 * Asked once per folder, after its survey: what happens to the files already there, and that every
 * later file uploads without asking. The decision names exactly this folder, so a second folder whose
 * survey ends meanwhile is never confirmed unseen.
 */
export function BacklogConfirmationScreen({ folder, backlog, status }: BacklogConfirmationScreenProperties) {
	const wording = backlogConfirmationWording(folder.name, backlog)
	const decision = useCollectorCommand(() => collectorBridge.decideBacklog([folder.folder]))
	const removal = useCollectorCommand(() => collectorBridge.withdrawFolder(folder.folder))
	const failure = decision.error ?? removal.error
	return (
		<main className="mx-auto flex w-full max-w-[600px] flex-col gap-4 p-6">
			<div className="flex flex-col gap-1">
				<h1 className="font-heading text-section-title font-bold text-heading">{wording.heading}</h1>
				<p className="flex items-center gap-1.5 text-caption">
					<FolderIcon size={14} />
					<span className="select-text">{folder.root}</span>
				</p>
			</div>
			<section
				aria-label="The files already there"
				className="flex flex-col gap-3 rounded-tr-panel rounded-b-field border border-documents-border bg-surface p-4"
			>
				<h2 className="font-heading text-[17px] font-bold text-heading">The files already there</h2>
				<ul className="flex flex-col gap-1.5">
					{wording.existingFiles.map((sentence) => (
						<li key={sentence}>{sentence}</li>
					))}
				</ul>
				{wording.skippedSummary !== null && (
					<div className="flex flex-col gap-1.5">
						<p>{wording.skippedSummary}</p>
						<dl className="grid grid-cols-[1fr_auto] gap-x-6 gap-y-0.5 rounded-list border border-table-border px-3 py-2 text-fine">
							{wording.skippedGroups.map((group) => (
								<div key={group.reason} className="contents">
									<dt className="text-caption">{group.reason}</dt>
									<dd className="text-right">{group.count}</dd>
								</div>
							))}
						</dl>
					</div>
				)}
				{wording.examinationNote !== null && <p className="text-caption">{wording.examinationNote}</p>}
			</section>
			<section
				aria-label="New files"
				className="flex gap-3 rounded-list border border-documents-badge-border bg-documents-badge p-4 text-documents-badge-text"
			>
				<ArrowsClockwiseIcon size={22} className="shrink-0" />
				<div className="flex flex-col gap-1">
					<h2 className="font-heading text-[17px] font-bold">New files</h2>
					<p>{wording.futureFiles}</p>
				</div>
			</section>
			{failure !== null && <FailureMessage>{failureSentence(failure, status)}</FailureMessage>}
			<div className="flex flex-wrap justify-end gap-2">
				<ActionButton
					variant="secondaryDestructive"
					pending={removal.isPending}
					disabled={decision.isPending}
					onClick={() => removal.mutate()}
				>
					{wording.removeLabel}
				</ActionButton>
				<ActionButton
					variant="primary"
					pending={decision.isPending}
					disabled={removal.isPending}
					onClick={() => decision.mutate()}
				>
					{wording.uploadLabel}
				</ActionButton>
			</div>
		</main>
	)
}
