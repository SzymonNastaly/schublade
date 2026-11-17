import { SectionPanel } from "../controls/section_panel"
import { ConnectionForm } from "./connection_form"

export function SetupScreen() {
	return (
		<main className="mx-auto flex w-full max-w-[520px] flex-col gap-4 p-6">
			<div className="flex flex-col gap-1.5">
				<h1 className="font-heading text-section-title font-bold text-heading">Connect your archive</h1>
				<p>
					Schublade Collector uploads the PDFs and scans that land in folders you choose, such as Downloads. It never
					changes or deletes your files.
				</p>
			</div>
			<SectionPanel section="documents" heading="Your Schublade">
				<div className="p-3.5">
					<ConnectionForm initialAddress="" submitLabel="Connect" />
				</div>
			</SectionPanel>
		</main>
	)
}
