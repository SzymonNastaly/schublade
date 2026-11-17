import { DrawerEmblem } from "../controls/drawer_emblem"

export type ApplicationTab = "status" | "folders" | "settings"

const tabs: Array<{ tab: ApplicationTab; label: string }> = [
	{ tab: "status", label: "Status" },
	{ tab: "folders", label: "Folders" },
	{ tab: "settings", label: "Settings" },
]

interface ApplicationHeaderProperties {
	tab?: ApplicationTab
	onTabChange?: (tab: ApplicationTab) => void
}

/** The archive's blue header with the drawer, and the tabs once the collector is set up. */
export function ApplicationHeader({ tab, onTabChange }: ApplicationHeaderProperties) {
	return (
		<header className="shrink-0 bg-application-header px-4 pt-3">
			<div className="flex items-center gap-2.5 pb-3">
				<DrawerEmblem className="h-[34px] w-[38px]" />
				<span className="flex flex-col">
					<span className="font-heading text-[22px] leading-6 font-bold text-on-header">Schublade Collector</span>
					<span className="text-[10px] font-bold tracking-[1.4px] text-header-caption">
						FILLS YOUR ARCHIVE FROM THIS MAC
					</span>
				</span>
			</div>
			{tab !== undefined && onTabChange !== undefined && (
				<nav aria-label="Sections" className="flex gap-1">
					{tabs.map((entry) => (
						<button
							key={entry.tab}
							type="button"
							aria-current={entry.tab === tab ? "page" : undefined}
							onClick={() => onTabChange(entry.tab)}
							className={`h-8.5 cursor-pointer rounded-t-tab px-5 font-bold ${entry.tab === tab ? "bg-page-background text-on-accent" : "bg-inactive-tab text-control-foreground opacity-85 hover:opacity-100"}`}
						>
							{entry.label}
						</button>
					))}
				</nav>
			)}
		</header>
	)
}
