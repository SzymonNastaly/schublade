import { Badge } from "@cloudflare/kumo"
import { MagnifyingGlassIcon, SealCheckIcon, UploadSimpleIcon } from "@phosphor-icons/react"
import { Link, useLoaderData, useRouter } from "@tanstack/react-router"
import { DocumentFilePicker } from "./document_file_picker"

export const ARCHIVE_SEARCH_INPUT_IDENTIFIER = "archive-search"

const action =
	"relative flex h-14 min-w-0 flex-1 flex-col items-center justify-center gap-0.5 text-xs text-kumo-subtle aria-[current=page]:text-kumo-default"

/** The actions a phone needs most, within reach of a thumb. It sets no z-index, so a dialog covers it. */
export function PhoneActionBar() {
	const router = useRouter()
	const pendingVerificationCount = useLoaderData({ from: "__root__" })
	const focusSearch = () => document.getElementById(ARCHIVE_SEARCH_INPUT_IDENTIFIER)?.focus()
	return (
		<nav
			aria-label="Quick actions"
			className="fixed inset-x-0 bottom-0 flex border-t border-kumo-hairline bg-kumo-elevated pb-[env(safe-area-inset-bottom)] md:hidden"
		>
			<button
				type="button"
				className={action}
				onClick={() => {
					// iOS opens the keyboard only for a focus that happens inside the tap.
					if (router.state.location.pathname === "/") focusSearch()
					else void router.navigate({ to: "/" }).then(focusSearch)
				}}
			>
				<MagnifyingGlassIcon size={22} />
				Search
			</button>
			<Link to="/verification" activeOptions={{ exact: true, includeSearch: false }} className={action}>
				<span className="relative">
					<SealCheckIcon size={22} />
					{pendingVerificationCount > 0 && (
						<span className="absolute -top-2 left-4">
							<Badge variant="warning">{pendingVerificationCount}</Badge>
						</span>
					)}
				</span>
				Pending verification
			</Link>
			<DocumentFilePicker>
				{(open) => (
					<button type="button" className={action} onClick={open}>
						<UploadSimpleIcon size={22} />
						Upload document
					</button>
				)}
			</DocumentFilePicker>
		</nav>
	)
}
