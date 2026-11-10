import { MagnifyingGlassIcon, UploadSimpleIcon } from "@phosphor-icons/react"
import { Link, useLoaderData, useNavigate, useRouterState, useSearch } from "@tanstack/react-router"
import { useEffect, useRef } from "react"
import { ApplicationLogo } from "./application_logo"
import { archiveSectionOfPath } from "./archive_sections"
import { useCommittedText } from "./committed_text"
import { ActionButton } from "./controls/action_button"
import { ProgressSpinner } from "./controls/progress_spinner"
import { DocumentFilePicker } from "./document_file_picker"
import type { ArchiveSection } from "./archive_sections"
import type { ReactNode } from "react"

const TAB_HEIGHT = 42

const sectionTabs = [
	{
		section: "documents",
		to: "/",
		label: "All documents",
		compactLabel: "All documents",
		width: 184,
		compactWidth: 150,
		widthClasses: "w-[150px] lg:w-[184px]",
		highlight: "#a6d3fa",
		colour: "var(--color-documents)",
	},
	{
		section: "failed_documents",
		to: "/failed_documents",
		label: "Failed documents",
		compactLabel: "Failed documents",
		width: 240,
		compactWidth: 204,
		widthClasses: "w-[204px] lg:w-[240px]",
		highlight: "#ffc878",
		colour: "var(--color-failed-documents)",
	},
	{
		section: "settings",
		to: "/settings",
		label: "Settings",
		compactLabel: "Settings",
		width: 130,
		compactWidth: 116,
		widthClasses: "w-[116px] lg:w-[130px]",
		highlight: "#cde582",
		colour: "var(--color-settings)",
	},
] as const satisfies ReadonlyArray<{
	section: ArchiveSection
	to: string
	label: string
	compactLabel: string
	width: number
	compactWidth: number
	widthClasses: string
	highlight: string
	colour: string
}>

const sectionRules: Record<ArchiveSection, string> = {
	documents: "bg-documents",
	failed_documents: "bg-failed-documents",
	settings: "bg-settings",
}

/** The open outline of a tab whose sides curve out to meet the bottom of the header. */
function tabOutline(width: number): string {
	const height = TAB_HEIGHT
	return `M0 ${height} C9 ${height} 13 36 17 24 C21 10 27 2 40 2 H${width - 40} C${width - 27} 2 ${width - 21} 10 ${width - 17} 24 C${width - 13} 36 ${width - 9} ${height} ${width} ${height}`
}

function TabShape({
	tab,
	width,
	active,
	visibility,
}: {
	tab: (typeof sectionTabs)[number]
	width: number
	active: boolean
	visibility: string
}) {
	const gradientIdentifier = `section-tab-${tab.section}-${width}`
	return (
		<svg
			aria-hidden
			width={width}
			height={TAB_HEIGHT}
			viewBox={`0 0 ${width} ${TAB_HEIGHT}`}
			className={`absolute inset-0 ${visibility}`}
		>
			<defs>
				<linearGradient id={gradientIdentifier} x1="0" y1="0" x2="0" y2="1">
					<stop offset="0" stopColor={tab.highlight} />
					<stop offset="1" stopColor={tab.colour} />
				</linearGradient>
			</defs>
			<path
				d={tabOutline(width)}
				fill={`url(#${gradientIdentifier})`}
				stroke={active ? "#ffffff" : "#0e2a52"}
				strokeOpacity={active ? 0.9 : 0.35}
				strokeWidth={1.4}
			/>
		</svg>
	)
}

function SectionTab({ tab, active }: { tab: (typeof sectionTabs)[number]; active: boolean }) {
	const failedDocumentCount = useLoaderData({ from: "__root__" })
	return (
		<Link
			to={tab.to}
			aria-current={active ? "page" : undefined}
			activeOptions={{ exact: true, includeSearch: false }}
			style={{ height: TAB_HEIGHT }}
			className={`relative flex items-center justify-center gap-2 font-bold text-on-accent ${tab.widthClasses} ${active ? "" : "translate-y-1.5"}`}
		>
			<TabShape tab={tab} width={tab.compactWidth} active={active} visibility="lg:hidden" />
			<TabShape tab={tab} width={tab.width} active={active} visibility="max-lg:hidden" />
			<span className="relative lg:hidden">{tab.compactLabel}</span>
			<span className="relative max-lg:hidden">{tab.label}</span>
			{tab.section === "failed_documents" && failedDocumentCount > 0 && (
				<span className="relative inline-flex h-5 min-w-[22px] items-center justify-center rounded-badge bg-surface px-1.5 text-fine font-bold text-failed-documents-badge-text">
					{failedDocumentCount}
				</span>
			)}
		</Link>
	)
}

function ApplicationHeader({ section }: { section: ArchiveSection }) {
	return (
		<header className="overflow-hidden bg-application-header">
			<div className="flex min-h-15 flex-wrap items-center justify-between gap-x-4 gap-y-1.5 px-3 py-2 md:min-h-[76px] md:items-end md:justify-start md:px-5 md:pt-2.5 md:pb-0 lg:min-h-[98px] lg:gap-x-9">
				<ApplicationLogo />
				<nav aria-label="Archive sections" className="flex flex-wrap items-end gap-0.5 max-md:hidden">
					{sectionTabs.map((tab) => (
						<SectionTab key={tab.section} tab={tab} active={tab.section === section} />
					))}
				</nav>
				<Link
					to="/settings"
					aria-label="Settings"
					aria-current={section === "settings" ? "page" : undefined}
					className={`flex size-11 items-center justify-center rounded-list text-on-header md:hidden ${section === "settings" ? "bg-on-header/18" : ""}`}
				>
					<SettingsGlyph />
				</Link>
			</div>
		</header>
	)
}

function SettingsGlyph() {
	return (
		<svg
			aria-hidden
			width="22"
			height="22"
			viewBox="0 0 24 24"
			fill="none"
			stroke="currentColor"
			strokeWidth="2"
			strokeLinecap="round"
		>
			<circle cx="12" cy="12" r="3" />
			<path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1" />
		</svg>
	)
}

/**
 * The one search field of the application. On the archive it searches as the member types, as
 * the archive's other filters apply at once. Anywhere else it waits for Enter, so that typing a
 * word does not take the member away from the page.
 */
function ArchiveSearchField({ onArchive }: { onArchive: boolean }) {
	const input = useRef<HTMLInputElement>(null)
	const navigate = useNavigate()
	const committedQuery = useSearch({ strict: false, select: (search) => search.query ?? "" })
	const searching = useRouterState({ select: (state) => state.location.href !== state.resolvedLocation?.href })
	const searchArchive = (query: string) =>
		void navigate({
			to: "/",
			search: (previous) => {
				const { query: _replaced, ...others } = onArchive ? previous : { query: undefined }
				return query === "" ? others : { ...others, query }
			},
			replace: onArchive,
		})
	const [text, setText] = useCommittedText(committedQuery, (committed) => {
		if (onArchive) searchArchive(committed)
	})
	useEffect(() => {
		const focusSearch = (event: KeyboardEvent) => {
			const target = event.target instanceof HTMLElement ? event.target : null
			const editing =
				target !== null && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
			const shortcut = (event.key === "k" && (event.metaKey || event.ctrlKey)) || (event.key === "/" && !editing)
			if (!shortcut) return
			event.preventDefault()
			input.current?.focus()
			input.current?.select()
		}
		window.addEventListener("keydown", focusSearch)
		return () => window.removeEventListener("keydown", focusSearch)
	}, [])
	return (
		<form
			role="search"
			className="flex min-w-0 flex-1 basis-[420px] items-center gap-2.5 px-3 py-2 md:px-5 md:py-2.5"
			onSubmit={(event) => {
				event.preventDefault()
				searchArchive(text.trim())
			}}
		>
			<span className="text-field-label max-md:hidden">
				{searching ? <ProgressSpinner /> : <MagnifyingGlassIcon size={20} />}
			</span>
			<input
				ref={input}
				type="search"
				aria-label="Search documents"
				placeholder="Search documents"
				value={text}
				onChange={(event) => setText(event.target.value)}
				className="h-11 min-w-0 flex-1 rounded-field border border-control-border bg-surface px-2.5 text-sm text-foreground md:h-10"
			/>
			<ActionButton type="submit" variant="secondary">
				Search
			</ActionButton>
		</form>
	)
}

function ApplicationToolbar({ onArchive }: { onArchive: boolean }) {
	return (
		<div
			className={`flex flex-wrap items-stretch border-b border-toolbar-border bg-toolbar ${onArchive ? "" : "max-md:hidden"}`}
		>
			<ArchiveSearchField onArchive={onArchive} />
			<div className="flex items-center border-l border-toolbar-divider px-5 py-2.5 max-md:hidden">
				<DocumentFilePicker>
					{(open) => (
						<ActionButton variant="primary" icon={UploadSimpleIcon} onClick={open}>
							Upload documents
						</ActionButton>
					)}
				</DocumentFilePicker>
			</div>
		</div>
	)
}

/** The header, tabs, and search that every page sits inside. */
export function ApplicationShell({ children }: { children: ReactNode }) {
	const pathname = useRouterState({ select: (state) => state.location.pathname })
	const section = archiveSectionOfPath(pathname)
	return (
		<div className="mx-auto flex min-h-dvh w-full max-w-[1280px] flex-col bg-surface shadow-application">
			<ApplicationHeader section={section} />
			<div className={`h-1 md:h-[5px] ${sectionRules[section]}`} />
			<ApplicationToolbar onArchive={pathname === "/"} />
			<div className="min-w-0 flex-1">{children}</div>
		</div>
	)
}
