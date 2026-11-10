import { TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { submitDocumentDeletion, submitDocumentRevision } from "../utilities/server_functions"
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { ActionButton } from "./controls/action_button"
import { FailureMessage } from "./controls/form_fields"
import { SectionPanel } from "./controls/section_panel"
import { FailedDocumentActions } from "./upload_tray"
import type { VerificationItem } from "../archive/verification_items"
import type { ReactNode } from "react"

/** Runs an action, then reloads the entries and the navigation count, which drops the resolved entry. */
function useVerificationAction<TInput, TResult = unknown>(action: (input: TInput) => Promise<TResult>) {
	const router = useRouter()
	return useMutation({ mutationFn: action, onSuccess: () => router.invalidate() })
}

function AnswerPanel({ children, error }: { children: ReactNode; error: Error | null }) {
	return (
		<SectionPanel section="verification" heading="Your answer">
			<div className="flex flex-col gap-3 p-3.5">
				{children}
				{error && <FailureMessage>{error.message}</FailureMessage>}
			</div>
		</SectionPanel>
	)
}

function NonArchivalEntry({ item }: { item: Extract<VerificationItem, { reason: "non_archival_attachment" }> }) {
	const router = useRouter()
	const retention = useVerificationAction(() =>
		submitDocumentRevision({ data: { documentId: item.document.id, nonArchival: false } }),
	)
	return (
		<AnswerPanel error={retention.error}>
			<div className="flex flex-col gap-2 md:flex-row md:flex-wrap">
				<ActionButton
					variant="secondary"
					stretchOnPhone
					pending={retention.isPending}
					onClick={() => retention.mutate()}
				>
					Keep document
				</ActionButton>
				<ActionConfirmation
					trigger={(open) => (
						<ActionButton variant="destructive" icon={TrashIcon} stretchOnPhone onClick={open}>
							Delete attachment
						</ActionButton>
					)}
					section="verification"
					title="Delete this attachment?"
					description={documentDeletionDescription(item.document.title)}
					confirmationLabel="Delete"
					confirmationVariant="destructive"
					action={() => submitDocumentDeletion({ data: { documentId: item.document.id } })}
					onCompleted={() => router.invalidate()}
				/>
			</div>
		</AnswerPanel>
	)
}

function FailedIngestionEntry({ item }: { item: Extract<VerificationItem, { reason: "failed_ingestion" }> }) {
	return (
		<AnswerPanel error={null}>
			<FailedDocumentActions documentId={item.document.id} title={item.document.title} />
		</AnswerPanel>
	)
}

export function VerificationEntryControls({ item }: { item: VerificationItem }) {
	switch (item.reason) {
		case "non_archival_attachment":
			return <NonArchivalEntry item={item} />
		case "failed_ingestion":
			return <FailedIngestionEntry item={item} />
	}
}
