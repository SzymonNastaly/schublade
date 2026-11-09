import { Empty, Text } from "@cloudflare/kumo"
import { FileXIcon } from "@phosphor-icons/react"
import { createFileRoute, notFound, useRouter } from "@tanstack/react-router"
import { DocumentDetails } from "../interface/document_details"
import { DocumentOriginal } from "../interface/document_original"
import { listArchiveFacets, retrieveDocument } from "../utilities/server_functions"
import type { ReactNode } from "react"

export const Route = createFileRoute("/documents/$documentId")({
	loader: async ({ params }) => {
		const [document, facets] = await Promise.all([
			retrieveDocument({ data: { documentId: params.documentId } }),
			listArchiveFacets(),
		])
		if (document === null) throw notFound()
		return { document, facets }
	},
	component: DocumentPage,
	notFoundComponent: () => (
		<DocumentPageLayout heading="Document not found">
			<Empty
				icon={<FileXIcon size={32} />}
				title="This document does not exist"
				description="Someone may have deleted it."
			/>
		</DocumentPageLayout>
	),
})

function DocumentPageLayout({
	heading,
	summary = null,
	children,
}: {
	heading: string
	summary?: string | null
	children: ReactNode
}) {
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] md:px-6 md:py-12">
			<header className="flex min-w-0 flex-col gap-2 wrap-break-word">
				<Text variant="heading1" as="h1">
					{heading}
				</Text>
				{summary !== null && <Text>{summary}</Text>}
			</header>
			{children}
		</main>
	)
}

function DocumentPage() {
	const { document, facets } = Route.useLoaderData()
	const router = useRouter()
	const navigate = Route.useNavigate()
	return (
		<DocumentPageLayout heading={document.title ?? "Untitled document"} summary={document.summary}>
			<div key={document.id} className="grid grid-cols-1 gap-6 md:grid-cols-2 md:items-start">
				<DocumentOriginal document={document} />
				<DocumentDetails
					document={document}
					facets={facets}
					onDeleted={() => {
						if (router.history.canGoBack()) router.history.back()
						else void navigate({ to: "/" })
					}}
				/>
			</div>
		</DocumentPageLayout>
	)
}
