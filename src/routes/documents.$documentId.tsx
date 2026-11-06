import { Empty, Text } from "@cloudflare/kumo"
import { FileXIcon } from "@phosphor-icons/react"
import { createFileRoute, notFound, useRouter } from "@tanstack/react-router"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { DocumentInspection } from "../interface/document_inspection"
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

function DocumentPageLayout({ heading, children }: { heading: string; children: ReactNode }) {
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] md:px-6 md:py-12">
			<div className="flex flex-wrap items-center justify-between gap-4">
				<div className="min-w-0 wrap-break-word">
					<Text variant="heading1" as="h1">
						{heading}
					</Text>
				</div>
				<ArchiveNavigation />
			</div>
			{children}
		</main>
	)
}

function DocumentPage() {
	const { document, facets } = Route.useLoaderData()
	const router = useRouter()
	const navigate = Route.useNavigate()
	return (
		<DocumentPageLayout heading={document.title ?? "Untitled document"}>
			<DocumentInspection
				key={document.id}
				document={document}
				facets={facets}
				onDeleted={() => {
					if (router.history.canGoBack()) router.history.back()
					else void navigate({ to: "/" })
				}}
			/>
		</DocumentPageLayout>
	)
}
