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
const TAB_WIDTH = 170

const sectionRules: Record<ArchiveSection, string> = {
	documents: "bg-documents",
	failed_documents: "bg-failed-documents",
	settings: "bg-settings",
}

/** The open outline of a tab whose sides curve out to meet the bottom of the header. */
const tabOutline = `M0 ${TAB_HEIGHT} C9 ${TAB_HEIGHT} 13 36 17 24 C21 10 27 2 40 2 H${TAB_WIDTH - 40} C${TAB_WIDTH - 27} 2 ${TAB_WIDTH - 21} 10 ${TAB_WIDTH - 17} 24 C${TAB_WIDTH - 13} 36 ${TAB_WIDTH - 9} ${TAB_HEIGHT} ${TAB_WIDTH} ${TAB_HEIGHT}`

/** The one tab of the header, because the archive is what members come for. */
function DocumentsTab({ active }: { active: boolean }) {
	return (
		<Link
			to="/"
			aria-current={active ? "page" : undefined}
			activeOptions={{ exact: true, includeSearch: false }}
			style={{ height: TAB_HEIGHT, width: TAB_WIDTH }}
			className={`relative flex items-center justify-center font-bold text-on-accent ${active ? "" : "translate-y-1.5"}`}
		>
			<svg
				aria-hidden
				width={TAB_WIDTH}
				height={TAB_HEIGHT}
				viewBox={`0 0 ${TAB_WIDTH} ${TAB_HEIGHT}`}
				className="absolute inset-0"
			>
				<defs>
					<linearGradient id="documents-tab-gradient" x1="0" y1="0" x2="0" y2="1">
						<stop offset="0" stopColor="#a6d3fa" />
						<stop offset="1" stopColor="var(--color-documents)" />
					</linearGradient>
				</defs>
				<path
					d={tabOutline}
					fill="url(#documents-tab-gradient)"
					stroke={active ? "#ffffff" : "#0e2a52"}
					strokeOpacity={active ? 0.9 : 0.35}
					strokeWidth={1.4}
				/>
			</svg>
			<span className="relative">Documents</span>
		</Link>
	)
}

function UtilityLink({
	to,
	current,
	children,
}: {
	to: "/failed_documents" | "/settings"
	current: boolean
	children: ReactNode
}) {
	return (
		<Link
			to={to}
			aria-current={current ? "page" : undefined}
			className={`flex items-center gap-1.5 rounded-list px-2 py-1 hover:underline ${current ? "bg-on-header/18 font-bold" : ""}`}
		>
			{children}
		</Link>
	)
}

/** Failed documents and Settings, small at the top right, as the archive matters more than either. */
function UtilityLinks({ section }: { section: ArchiveSection }) {
	const failedDocumentCount = useLoaderData({ from: "__root__" })
	return (
		<nav
			aria-label="Failed documents and settings"
			className="ml-auto flex items-center gap-1 self-start text-body text-on-header max-md:hidden"
		>
			{(failedDocumentCount > 0 || section === "failed_documents") && (
				<>
					<UtilityLink to="/failed_documents" current={section === "failed_documents"}>
						Failed documents
						{failedDocumentCount > 0 && (
							<span className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-badge bg-failed-documents px-1 text-fine font-bold text-on-accent">
								{failedDocumentCount}
							</span>
						)}
					</UtilityLink>
					<span aria-hidden className="text-on-header/60">
						|
					</span>
				</>
			)}
			<UtilityLink to="/settings" current={section === "settings"}>
				Settings
			</UtilityLink>
		</nav>
	)
}

function ApplicationHeader({ section }: { section: ArchiveSection }) {
	return (
		<header className="overflow-hidden bg-application-header">
			<div className="flex min-h-15 flex-wrap items-center justify-between gap-x-4 gap-y-1.5 px-3 py-2 md:min-h-[76px] md:items-end md:justify-start md:px-5 md:pt-2.5 md:pb-0 lg:min-h-[98px] lg:gap-x-9">
				<ApplicationLogo />
				<nav aria-label="Archive" className="flex items-end max-md:hidden">
					<DocumentsTab active={section === "documents"} />
				</nav>
				<UtilityLinks section={section} />
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
