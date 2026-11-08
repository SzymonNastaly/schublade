import { Banner, Button, ClipboardText, Empty, Input, LayerCard, Select, Table, Text } from "@cloudflare/kumo"
import { KeyIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { createFileRoute, useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { formatTimestamp } from "../interface/document_formatting"
import { issueApiTokenRecord, listApiTokenRecords, revokeApiTokenRecord } from "../utilities/server_functions"
import type { ApiTokenListing } from "../authentication/api_tokens"

export const Route = createFileRoute("/settings")({
	loader: () => listApiTokenRecords(),
	component: SettingsPage,
})

const levelLabels: Record<ApiTokenListing["level"], string> = {
	read: "Read",
	ingest: "Ingest documents",
	modify: "Modify",
	administer: "Administer",
}

function formatTime(time: Date | null): string {
	return time === null ? "Never" : formatTimestamp(time)
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
			className="flex flex-col gap-4"
			onSubmit={(event) => {
				event.preventDefault()
				if (description.trim() !== "") issuance.mutate(description.trim())
			}}
		>
			<div className="grid grid-cols-1 gap-4 md:grid-cols-[1fr_16rem_auto] md:items-end">
				<Input
					label="Description"
					placeholder="QuickScan on Jonas's phone"
					value={description}
					onChange={(event) => setDescription(event.target.value)}
				/>
				<Select<string> label="Permission" value="ingest" items={[{ value: "ingest", label: levelLabels.ingest }]} />
				<Button type="submit" variant="primary" icon={KeyIcon} loading={issuance.isPending}>
					Issue token
				</Button>
			</div>
			{issuance.isError && <Text variant="error">{issuance.error.message}</Text>}
			{issuance.data && (
				<Banner
					variant="alert"
					title="Copy this token now"
					description={
						<div className="flex flex-col gap-2">
							<span>Schublade stores only a digest of the token and cannot show it again.</span>
							<ClipboardText text={issuance.data.token} />
						</div>
					}
				/>
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
		return <Empty icon={<KeyIcon size={32} />} title="No tokens" description="Issue a token for a scanner or script." />
	}
	return (
		<div className="overflow-x-auto">
			<Table>
				<Table.Header>
					<Table.Row>
						<Table.Head>Description</Table.Head>
						<Table.Head>Permission</Table.Head>
						<Table.Head>Issued</Table.Head>
						<Table.Head>Last used</Table.Head>
						<Table.Head />
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{tokens.map((token) => (
						<Table.Row key={token.id}>
							<Table.Cell className="break-words">{token.description}</Table.Cell>
							<Table.Cell className="whitespace-nowrap">{levelLabels[token.level]}</Table.Cell>
							<Table.Cell className="whitespace-nowrap tabular-nums">{formatTime(token.createdAt)}</Table.Cell>
							<Table.Cell className="whitespace-nowrap tabular-nums">{formatTime(token.lastUsedAt)}</Table.Cell>
							<Table.Cell className="text-right">
								<Button
									variant="secondary-destructive"
									size="sm"
									icon={TrashIcon}
									loading={revocation.isPending && revocation.variables === token.id}
									onClick={() => revocation.mutate(token.id)}
								>
									Revoke
								</Button>
							</Table.Cell>
						</Table.Row>
					))}
				</Table.Body>
			</Table>
		</div>
	)
}

function SettingsPage() {
	const tokens = Route.useLoaderData()
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:px-6 md:py-12">
			<div className="flex flex-wrap items-center justify-between gap-4">
				<Text variant="heading1" as="h1">
					Settings
				</Text>
				<ArchiveNavigation />
			</div>
			<LayerCard>
				<LayerCard.Secondary>API tokens</LayerCard.Secondary>
				<LayerCard.Primary className="flex flex-col gap-6">
					<Text variant="secondary">
						A scanner, a script, or an Apple Shortcut uploads documents to POST /api/documents/ingest with the header
						Authorization: Bearer followed by the token.
					</Text>
					<TokenIssuance />
					<TokenTable tokens={tokens} />
				</LayerCard.Primary>
			</LayerCard>
		</main>
	)
}
