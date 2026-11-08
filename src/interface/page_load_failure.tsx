import { Button, Empty } from "@cloudflare/kumo"
import { CloudSlashIcon } from "@phosphor-icons/react"
import { useRouter } from "@tanstack/react-router"
import { useArchiveChanges } from "./document_status_updates"

/**
 * Replaces a page whose loader failed, which a background reload can cause while the socket is
 * still open. A full page load is the retry, because an expired Access session needs the redirect
 * to its sign-in that a server function call cannot follow.
 */
export function PageLoadFailure() {
	const router = useRouter()
	useArchiveChanges(() => void router.invalidate())
	return (
		<main className="mx-auto flex max-w-6xl flex-col items-center gap-4 px-4 py-12">
			<Empty
				icon={<CloudSlashIcon size={32} />}
				title="This page could not be loaded"
				description="Your documents are safe. Check your connection and try again."
			/>
			<Button variant="primary" onClick={() => window.location.reload()}>
				Try again
			</Button>
		</main>
	)
}
