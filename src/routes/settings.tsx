import { KeyIcon, PlugsConnectedIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { createFileRoute, useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { ActionButton } from "../interface/controls/action_button"
import { CopyableText } from "../interface/controls/copyable_text"
import { EmptyState } from "../interface/controls/empty_state"
import { FilterTab, FilterTabs } from "../interface/controls/filter_tabs"
import { FailureMessage, SelectionField, TextField } from "../interface/controls/form_fields"
import { NoticeBox } from "../interface/controls/notice_box"
import {
	BreadcrumbTrail,
	ListFrame,
	PageColumns,
	PageContent,
	PageHeading,
	SectionHeading,
} from "../interface/controls/page_layout"
import { SectionPanel, panelRowClasses } from "../interface/controls/section_panel"
import { formatTimestamp } from "../interface/document_formatting"
import {
	issueApiTokenRecord,
	listApiTokenRecords,
	listAuthorizedClientRecords,
	revokeApiTokenRecord,
	revokeAuthorizedClientRecord,
} from "../utilities/server_functions"
import { MODEL_CONTEXT_PROTOCOL_PATH } from "../model_context_protocol/authorization_server_paths"
import type { ApiTokenListing } from "../authentication/api_tokens"
import type { AuthorizedClientListing } from "../model_context_protocol/authorization_grants"
import type { ReactNode } from "react"

export const Route = createFileRoute("/settings")({
	loader: async () => {
		const [tokens, authorizedClients] = await Promise.all([listApiTokenRecords(), listAuthorizedClientRecords()])
		return { tokens, authorizedClients }
	},
	component: SettingsPage,
})

const levelLabels: Record<ApiTokenListing["level"], string> = {
	read: "Read",
	ingest: "Ingest documents",
	modify: "Modify",
	administer: "Administer",
}

const headerCell = "py-2 pr-3 text-left font-bold first:pl-3.5"
const bodyCell = "py-1.5 pr-3 first:pl-3.5 max-md:py-0.5 max-md:pl-3.5 max-md:text-fine max-md:text-caption"
const primaryBodyCell =
	"py-1.5 pr-3 font-bold wrap-anywhere first:pl-3.5 max-md:py-0.5 max-md:pl-3.5 max-md:text-body max-md:text-foreground"
const bodyRow = "border-b border-dotted border-row-rule max-md:flex max-md:flex-col max-md:py-2.5"
const actionCell = "py-1.5 pr-3.5 md:text-right max-md:pt-2 max-md:pl-3.5"

function formatTime(time: Date | null): string {
	return time === null ? "Never" : formatTimestamp(time)
}

/** A table from the md breakpoint upward, and a stack of rows below it. */
function RecordTable({ headings, children }: { headings: Array<string>; children: ReactNode }) {
	return (
		<ListFrame>
			<table className="w-full border-collapse max-md:block">
				<thead className="max-md:hidden">
					<tr className="border-b border-table-rule text-fine text-caption">
						{headings.map((heading) => (
							<th key={heading} className={headerCell}>
								{heading}
							</th>
						))}
						<th />
					</tr>
				</thead>
				<tbody className="max-md:block">{children}</tbody>
			</table>
		</ListFrame>
	)
}

function PhoneCaption({ children }: { children: string }) {
	return <span className="md:hidden">{children} </span>
}

function TokenIssuance() {
	const router = useRouter()
	const [description, setDescription] = useState("")
	const issuance = useMutation({
		mutationFn: (issuedDescription: string) =>
			issueApiTokenRecord({ data: { description: issuedDescription, level: "ingest" } }),
		onSuccess: () => {
			setDescription("")
			void router.invalidate()
		},
	})
	return (
		<form
			className="flex flex-col gap-3"
			onSubmit={(event) => {
				event.preventDefault()
				if (description.trim() !== "") issuance.mutate(description.trim())
			}}
		>
			<div className="grid grid-cols-1 gap-3 rounded-list border border-table-border bg-menu-row p-3.5 md:grid-cols-[1fr_16rem_auto] md:items-end">
				<TextField
					label="Description"
					placeholder="QuickScan on Jonas's phone"
					value={description}
					onChange={(event) => setDescription(event.target.value)}
				/>
				<SelectionField label="Permission" options={[{ value: "ingest", label: levelLabels.ingest }]} />
				<ActionButton type="submit" variant="primary" icon={KeyIcon} stretchOnPhone pending={issuance.isPending}>
					Issue token
				</ActionButton>
			</div>
			{issuance.isError && <FailureMessage>{issuance.error.message}</FailureMessage>}
			{issuance.data && (
				<NoticeBox tone="settings" title="Copy this token now">
					<span className="text-field-label">
						Schublade stores only a digest of the token and cannot show it again.
					</span>
					<CopyableText text={issuance.data.token} />
				</NoticeBox>
			)}
		</form>
	)
}

function TokenTable({ tokens }: { tokens: Array<ApiTokenListing> }) {
	const router = useRouter()
	const revocation = useMutation({
		mutationFn: (tokenId: string) => revokeApiTokenRecord({ data: { tokenId } }),
		onSettled: () => router.invalidate(),
	})
	if (tokens.length === 0) {
		return (
			<ListFrame>
				<EmptyState
					icon={<KeyIcon size={32} />}
					title="No tokens"
					description="Issue a token for a scanner or script."
				/>
			</ListFrame>
		)
	}
	return (
		<RecordTable headings={["Description", "Permission", "Issued", "Last used"]}>
			{tokens.map((token) => (
				<tr key={token.id} className={bodyRow}>
					<td className={primaryBodyCell}>{token.description}</td>
					<td className={`${bodyCell} whitespace-nowrap`}>{levelLabels[token.level]}</td>
					<td className={`${bodyCell} whitespace-nowrap tabular-nums`}>
						<PhoneCaption>Issued</PhoneCaption>
						{formatTime(token.createdAt)}
					</td>
					<td className={`${bodyCell} whitespace-nowrap tabular-nums`}>
						<PhoneCaption>Last used:</PhoneCaption>
						{formatTime(token.lastUsedAt)}
					</td>
					<td className={actionCell}>
						<ActionButton
							variant="secondaryDestructive"
							size="compact"
							icon={TrashIcon}
							pending={revocation.isPending && revocation.variables === token.id}
							onClick={() => revocation.mutate(token.id)}
						>
							Revoke
						</ActionButton>
					</td>
				</tr>
			))}
		</RecordTable>
	)
}

function AuthorizedClientTable({ clients }: { clients: Array<AuthorizedClientListing> }) {
	const router = useRouter()
	const revocation = useMutation({
		mutationFn: (grantId: string) => revokeAuthorizedClientRecord({ data: { grantId } }),
		onSettled: () => router.invalidate(),
	})
	if (clients.length === 0) {
		return (
			<ListFrame>
				<EmptyState
					icon={<PlugsConnectedIcon size={32} />}
					title="No connected clients"
					description="Add the address above to Claude or another client, and Schublade asks what it may read."
				/>
			</ListFrame>
		)
	}
	return (
		<RecordTable headings={["Client", "May read", "Connected", "Expires"]}>
			{clients.map((client) => (
				<tr key={client.grantId} className={bodyRow}>
					<td className={primaryBodyCell}>{client.clientName}</td>
					<td className={`${bodyCell} wrap-anywhere`}>
						<PhoneCaption>May read:</PhoneCaption>
						{client.accessSummary}
					</td>
					<td className={`${bodyCell} whitespace-nowrap tabular-nums`}>
						<PhoneCaption>Connected</PhoneCaption>
						{formatTime(client.authorizedAt)}
					</td>
					<td className={`${bodyCell} whitespace-nowrap tabular-nums`}>
						<PhoneCaption>Expires</PhoneCaption>
						{formatTime(client.expiresAt)}
					</td>
					<td className={actionCell}>
						<ActionButton
							variant="secondaryDestructive"
							size="compact"
							icon={TrashIcon}
							pending={revocation.isPending && revocation.variables === client.grantId}
							onClick={() => revocation.mutate(client.grantId)}
						>
							Disconnect
						</ActionButton>
					</td>
				</tr>
			))}
		</RecordTable>
	)
}

const sections = [
	{ key: "tokens", identifier: "api-tokens", title: "API tokens" },
	{ key: "clients", identifier: "connected-clients", title: "Connected clients" },
] as const

function SettingsPage() {
	const { tokens, authorizedClients } = Route.useLoaderData()
	const { origin } = useRouter()
	const [phoneSection, setPhoneSection] = useState<(typeof sections)[number]["key"]>("tokens")
	const sectionVisibility = (key: typeof phoneSection) => (key === phoneSection ? "" : "max-md:hidden")
	return (
		<PageContent>
			<BreadcrumbTrail current="Settings" />
			<PageColumns
				panels={
					<SectionPanel section="settings" heading="Settings">
						{sections.map(({ identifier, title }) => (
							<a key={identifier} href={`#${identifier}`} className={panelRowClasses({ section: "settings" })}>
								<span aria-hidden>›</span>
								{title}
							</a>
						))}
					</SectionPanel>
				}
			>
				<PageHeading title="Settings" subtitle="Connect scanners, scripts, and assistants to your archive." />
				<div className="md:hidden">
					<FilterTabs label="Settings sections">
						{sections.map(({ key, title }) => (
							<FilterTab key={key} selected={key === phoneSection} onSelect={() => setPhoneSection(key)}>
								{title}
							</FilterTab>
						))}
					</FilterTabs>
					<div className="border-t border-outline" />
				</div>
				<section id="api-tokens" className={`flex flex-col gap-3 md:mb-3 ${sectionVisibility("tokens")}`}>
					<div className="max-md:hidden">
						<SectionHeading>API tokens</SectionHeading>
					</div>
					<p className="max-w-[760px] text-field-label">
						A scanner, a script, or an Apple Shortcut uploads documents to POST /api/documents/ingest with the header
						Authorization: Bearer followed by the token.
					</p>
					<TokenIssuance />
					<TokenTable tokens={tokens} />
				</section>
				<section id="connected-clients" className={`flex flex-col gap-3 ${sectionVisibility("clients")}`}>
					<div className="max-md:hidden">
						<SectionHeading>Connected clients</SectionHeading>
					</div>
					<p className="max-w-[760px] text-field-label">
						Claude and other Model Context Protocol clients read the archive through this address. Each client asks you
						once what it may read.
					</p>
					<CopyableText text={`${origin}${MODEL_CONTEXT_PROTOCOL_PATH}`} />
					<AuthorizedClientTable clients={authorizedClients} />
				</section>
			</PageColumns>
		</PageContent>
	)
}
