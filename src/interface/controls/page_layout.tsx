import { Link } from "@tanstack/react-router"
import { Children, Fragment } from "react"
import { textLinkClasses } from "./text_link"
import type { ReactNode } from "react"

export function PageContent({ children }: { children: ReactNode }) {
	return <main className="flex flex-col gap-4 px-3 pt-3.5 pb-10 md:px-5">{children}</main>
}

/** Where the member is, from the archive down. Earlier steps are router links passed as children. */
export function BreadcrumbTrail({ current, children }: { current: string; children?: ReactNode }) {
	const separator = <span aria-hidden>›</span>
	return (
		<nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-1.5 text-fine text-caption max-md:hidden">
			<span>You are here:</span>
			<Link to="/" className={`font-bold ${textLinkClasses}`}>
				Schublade
			</Link>
			{separator}
			{Children.toArray(children).map((step, position) => (
				<Fragment key={position}>
					{step}
					{separator}
				</Fragment>
			))}
			<span className="text-foreground">{current}</span>
		</nav>
	)
}

export function PageHeading({ title, subtitle }: { title: string; subtitle: string | null }) {
	return (
		<div className="min-w-0 font-heading wrap-break-word">
			<h1 className="text-phone-title leading-tight font-bold text-heading md:text-page-title">{title}</h1>
			{subtitle !== null && (
				<p className="mt-0.5 text-phone-subtitle leading-snug text-subheading md:text-page-subtitle">{subtitle}</p>
			)}
		</div>
	)
}

export function SectionHeading({ children }: { children: ReactNode }) {
	return <h2 className="font-heading text-section-title font-bold text-heading">{children}</h2>
}

interface PageColumnsProperties {
	/** The panels beside the content from the lg breakpoint upward. */
	panels: ReactNode
	/** Keeps narrower windows showing the panels below the content rather than hiding them. */
	panelsFollowContent?: boolean
	children: ReactNode
}

/** A narrow column of panels beside the content on a wide window, and one column on a narrower one. */
export function PageColumns({ panels, panelsFollowContent = false, children }: PageColumnsProperties) {
	const panelColumn = (
		<aside
			className={`flex min-w-0 flex-col gap-3.5 lg:w-60 lg:flex-none ${panelsFollowContent ? "md:max-lg:grid md:max-lg:grid-cols-2 md:max-lg:items-start" : "max-lg:hidden"}`}
		>
			{panels}
		</aside>
	)
	const content = <div className="flex min-w-0 flex-1 flex-col gap-4">{children}</div>
	return panelsFollowContent ? (
		<div className="flex flex-col gap-6 lg:flex-row-reverse lg:items-start">
			{content}
			{panelColumn}
		</div>
	) : (
		<div className="flex flex-col gap-6 lg:flex-row lg:items-start">
			{panelColumn}
			{content}
		</div>
	)
}

export function ListFrame({ children }: { children: ReactNode }) {
	return <div className="@container overflow-hidden rounded-list border border-outline bg-surface">{children}</div>
}

/** The way back to the page above, where a phone has no breadcrumb. */
export function PhoneReturnBar({
	to,
	trailing,
	children,
}: {
	to: "/" | "/verification"
	trailing?: ReactNode
	children: string
}) {
	return (
		<div className="flex items-center justify-between gap-2 border-b border-toolbar-border bg-toolbar pr-1.5 md:hidden">
			<Link to={to} className="inline-flex min-h-11 items-center px-3 font-bold text-link">
				‹ {children}
			</Link>
			{trailing !== undefined && <span className="flex items-center gap-1">{trailing}</span>}
		</div>
	)
}
