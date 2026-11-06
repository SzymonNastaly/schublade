import { Badge } from "@cloudflare/kumo"
import { FilesIcon, GearIcon, SealCheckIcon } from "@phosphor-icons/react"
import { Link, useLoaderData } from "@tanstack/react-router"
import type { Icon } from "@phosphor-icons/react"

const views = [
	{ to: "/", label: "All documents", icon: FilesIcon },
	{ to: "/verification", label: "Pending verification", icon: SealCheckIcon },
	{ to: "/settings", label: "Settings", icon: GearIcon },
] as const satisfies ReadonlyArray<{ to: string; label: string; icon: Icon }>

/** The archive views, with the number of entries that await verification. Labels fold into icons below md. */
export function ArchiveNavigation() {
	const pendingVerificationCount = useLoaderData({ from: "__root__" })
	return (
		<nav aria-label="Archive views" className="flex items-center gap-1">
			{views.map(({ to, label, icon: ViewIcon }) => (
				<Link
					key={to}
					to={to}
					aria-label={label}
					activeOptions={{ exact: true, includeSearch: false }}
					className="inline-flex h-11 items-center gap-2 rounded-lg px-3 text-kumo-subtle hover:bg-kumo-tint hover:text-kumo-default aria-[current=page]:bg-kumo-tint aria-[current=page]:text-kumo-default md:h-9"
				>
					<ViewIcon size={18} />
					<span className="hidden md:inline">{label}</span>
					{to === "/verification" && pendingVerificationCount > 0 && (
						<Badge variant="warning">{pendingVerificationCount}</Badge>
					)}
				</Link>
			))}
		</nav>
	)
}
