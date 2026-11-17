import { ArrowSquareOutIcon } from "@phosphor-icons/react"
import { collectorBridge } from "../collector_queries"
import { ActionButton } from "../controls/action_button"
import { PanelRow, SectionPanel } from "../controls/section_panel"
import { StatusBadge } from "../controls/status_badge"
import {
	activitySentence,
	attentionSentence,
	connectionSentence,
	documentStatusLabel,
	progressSentences,
	restingSentence,
} from "../status_sentences"
import { clockTime, receiptTime } from "../time_wording"
import type { CollectorStatus } from "../collector_status"
import type { AttentionAction } from "../status_sentences"
import type { ApplicationTab } from "./application_header"

const actionLabels: Record<Exclude<AttentionAction, null>, { label: string; tab: ApplicationTab }> = {
	replace_token: { label: "Replace token", tab: "settings" },
	decide_backlog: { label: "Show folders", tab: "folders" },
	open_folders: { label: "Show folders", tab: "folders" },
}

interface StatusScreenProperties {
	status: CollectorStatus
	onOpenTab: (tab: ApplicationTab) => void
}

export function StatusScreen({ status, onOpenTab }: StatusScreenProperties) {
	const attention = status.attention.map((item) => attentionSentence(item, status))
	return (
		<div className="mx-auto flex max-w-[760px] flex-col gap-3">
			{attention.length > 0 && (
				<SectionPanel section="attention" heading="Needs your attention">
					{attention.map(({ sentence, action }) => (
						<PanelRow key={sentence}>
							<div className="flex items-center justify-between gap-3">
								<p>{sentence}</p>
								{action !== null && (
									<ActionButton variant="secondary" size="compact" onClick={() => onOpenTab(actionLabels[action].tab)}>
										{actionLabels[action].label}
									</ActionButton>
								)}
							</div>
						</PanelRow>
					))}
				</SectionPanel>
			)}
			<SectionPanel section="documents" heading="Collector">
				<PanelRow>
					<p className="font-bold text-heading">{connectionSentence(status.connection, clockTime)}</p>
					{status.activities.length === 0 ? (
						<p>{restingSentence(status)}</p>
					) : (
						<ul className="flex flex-col gap-0.5">
							{status.activities.map((activity, index) => (
								<li key={index}>{activitySentence(activity, status)}</li>
							))}
						</ul>
					)}
				</PanelRow>
				<PanelRow>
					<p className="text-caption">{progressSentences(status.counts).join(" · ")}</p>
				</PanelRow>
			</SectionPanel>
			<SectionPanel section="documents" heading="Recent uploads">
				{status.recent_receipts.length === 0 ? (
					<PanelRow>
						<p className="text-caption">New uploads appear here.</p>
					</PanelRow>
				) : (
					status.recent_receipts.map((receipt) => {
						const badge = documentStatusLabel(receipt.status)
						return (
							<div key={receipt.document} className="flex items-center gap-3 px-3 py-2">
								<div className="flex min-w-0 flex-1 flex-col">
									<span className="truncate font-bold text-heading">{receipt.file_name}</span>
									<span className="text-fine text-caption">{receiptTime(receipt.received_at)}</span>
								</div>
								<StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>
								<ActionButton
									variant="plain"
									size="compact"
									icon={ArrowSquareOutIcon}
									onClick={() => void collectorBridge.openDocument(receipt.document_link)}
								>
									Open
								</ActionButton>
							</div>
						)
					})
				)}
			</SectionPanel>
		</div>
	)
}
