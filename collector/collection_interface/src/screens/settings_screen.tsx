import { useApplicationPreferences, useChangePreferences } from "../collector_queries"
import { FailureMessage, ToggleField } from "../controls/form_fields"
import { PanelRow, SectionPanel } from "../controls/section_panel"
import { failureSentence } from "../failure_sentence"
import { startingOverInstructions } from "../status_sentences"
import { ConnectionForm } from "./connection_form"
import type { CollectorStatus } from "../collector_status"

export function SettingsScreen({ status }: { status: CollectorStatus }) {
	const preferences = useApplicationPreferences()
	const change = useChangePreferences()
	return (
		<div className="mx-auto flex max-w-[760px] flex-col gap-3">
			<SectionPanel section="settings" heading="This Mac">
				{preferences.data === undefined ? (
					<PanelRow>
						<p className="text-caption">Reading the settings.</p>
					</PanelRow>
				) : (
					<>
						<PanelRow>
							<ToggleField
								label="Start at login"
								description="Collects in the background from the moment you log in, without opening this window."
								checked={preferences.data.start_at_login}
								disabled={change.isPending}
								onChange={(checked) => change.mutate({ ...preferences.data, start_at_login: checked })}
							/>
						</PanelRow>
						<PanelRow>
							<ToggleField
								label="Show in the menu bar"
								description="A drawer in the menu bar opens this window. Without it, open Schublade Collector from Applications."
								checked={preferences.data.menu_bar_item_shown}
								disabled={change.isPending}
								onChange={(checked) => change.mutate({ ...preferences.data, menu_bar_item_shown: checked })}
							/>
						</PanelRow>
					</>
				)}
			</SectionPanel>
			{change.isError && <FailureMessage>{failureSentence(change.error, status)}</FailureMessage>}
			<SectionPanel section="settings" heading="Archive">
				<div className="p-3.5">
					<p className="mb-3 text-caption">
						Replace the token after you revoke it in Schublade. The token is kept in your Keychain.{" "}
						{startingOverInstructions}
					</p>
					<ConnectionForm initialAddress={status.archive_origin ?? ""} submitLabel="Save and connect" />
				</div>
			</SectionPanel>
		</div>
	)
}
