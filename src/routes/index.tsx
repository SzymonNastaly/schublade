import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/")({ component: ArchiveOverview })

function ArchiveOverview() {
	return (
		<main className="mx-auto max-w-3xl px-6 py-12">
			<h1 className="text-2xl font-semibold">Schublade</h1>
		</main>
	)
}
