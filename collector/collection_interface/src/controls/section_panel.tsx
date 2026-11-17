import type { ReactNode } from "react"

/** Blue for the collection itself, orange for what needs attention, green for settings, as in the archive. */
export type PanelSection = "documents" | "attention" | "settings"

const panelPresentations: Record<PanelSection, { frame: string; heading: string; rule: string }> = {
	documents: {
		frame: "border-documents-border bg-surface",
		heading: "bg-documents-heading text-on-header",
		rule: "divide-documents-rule",
	},
	attention: {
		frame: "border-failed-documents-border bg-failed-documents-surface",
		heading: "bg-failed-documents-heading text-on-accent",
		rule: "divide-failed-documents-rule",
	},
	settings: {
		frame: "border-settings-border bg-surface",
		heading: "bg-settings-heading text-on-accent",
		rule: "divide-settings-rule",
	},
}

interface SectionPanelProperties {
	section: PanelSection
	heading: string
	/** Controls at the right of the heading. */
	accessory?: ReactNode
	children: ReactNode
}

/** A box with a coloured heading and one rounded corner. Its direct children are rows divided by rules. */
export function SectionPanel({ section, heading, accessory, children }: SectionPanelProperties) {
	const presentation = panelPresentations[section]
	return (
		<section
			aria-label={heading}
			className={`overflow-hidden rounded-tr-panel rounded-b-field border ${presentation.frame}`}
		>
			<div className={`flex min-h-9 items-center justify-between gap-3 px-3 py-1.5 ${presentation.heading}`}>
				<h2 className="font-bold">{heading}</h2>
				{accessory}
			</div>
			<div className={`divide-y ${presentation.rule}`}>{children}</div>
		</section>
	)
}

export function PanelRow({ children }: { children: ReactNode }) {
	return <div className="flex flex-col gap-1.5 px-3 py-2.5">{children}</div>
}
