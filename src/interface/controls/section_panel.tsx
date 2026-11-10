import type { ArchiveSection } from "../archive_sections"
import type { ButtonHTMLAttributes, ReactNode } from "react"

const panelPresentations: Record<
	ArchiveSection,
	{ frame: string; heading: string; rule: string; selected: string; hover: string; tint: string }
> = {
	documents: {
		frame: "border-documents-border",
		heading: "bg-documents-heading text-on-header",
		rule: "border-documents-rule",
		selected: "bg-documents-selected",
		hover: "hover:bg-documents-hover",
		tint: "bg-surface",
	},
	failed_documents: {
		frame: "border-failed-documents-border",
		heading: "bg-failed-documents-heading text-on-accent",
		rule: "border-failed-documents-rule",
		selected: "bg-failed-documents-selected",
		hover: "hover:bg-failed-documents-hover",
		tint: "bg-failed-documents-surface",
	},
	settings: {
		frame: "border-settings-border",
		heading: "bg-settings-heading text-on-accent",
		rule: "border-settings-rule",
		selected: "bg-settings-selected",
		hover: "hover:bg-settings-hover",
		tint: "bg-settings-surface",
	},
}

/** The heading colours of a section, shared with the dialogs of that section. */
export function panelHeadingClasses(section: ArchiveSection): string {
	return panelPresentations[section].heading
}

interface SectionPanelProperties {
	section: ArchiveSection
	heading: string
	/** Colours the body with the section, for a notice rather than a menu. */
	tinted?: boolean
	children: ReactNode
}

/** A box with a coloured heading and one rounded corner, in the colour of the section it belongs to. */
export function SectionPanel({ section, heading, tinted = false, children }: SectionPanelProperties) {
	const presentation = panelPresentations[section]
	return (
		<section
			aria-label={heading}
			className={`overflow-hidden rounded-tr-panel rounded-b-field border ${presentation.frame} ${tinted ? presentation.tint : "bg-surface"}`}
		>
			<h2 className={`px-3 py-2 font-bold wrap-anywhere ${presentation.heading}`}>{heading}</h2>
			{children}
		</section>
	)
}

interface PanelRowAppearance {
	section: ArchiveSection
	selected?: boolean
	destructive?: boolean
}

/** The classes of a row in a panel menu, for a router link as well as a button. */
export function panelRowClasses({ section, selected = false, destructive = false }: PanelRowAppearance): string {
	const presentation = panelPresentations[section]
	const fill = selected ? `${presentation.selected} font-bold text-on-accent` : "bg-menu-row"
	const text = destructive ? "text-destructive-text" : selected ? "" : "text-link"
	return `flex min-h-11 w-full cursor-pointer items-center gap-2.5 border-b px-3 py-1.5 text-left last:border-b-0 md:min-h-9 ${presentation.rule} ${presentation.hover} ${fill} ${text}`
}

interface PanelRowButtonProperties
	extends PanelRowAppearance, Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className" | "style"> {}

export function PanelRowButton({ section, selected, destructive, children, ...button }: PanelRowButtonProperties) {
	return (
		<button
			type="button"
			aria-pressed={selected}
			className={panelRowClasses({ section, selected, destructive })}
			{...button}
		>
			{children}
		</button>
	)
}
