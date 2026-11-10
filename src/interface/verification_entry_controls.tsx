import { SectionPanel } from "./controls/section_panel"
import { FailedDocumentActions } from "./upload_tray"
import type { VerificationItem } from "../archive/verification_items"

export function VerificationEntryControls({ item }: { item: VerificationItem }) {
	return (
		<SectionPanel section="verification" heading="Your answer">
			<div className="flex flex-col gap-3 p-3.5">
				<FailedDocumentActions documentId={item.document.id} title={item.document.title} />
			</div>
		</SectionPanel>
	)
}
