import type { ReactNode } from "react"

interface EmptyStateProperties {
	icon: ReactNode
	title: string
	description: ReactNode
	children?: ReactNode
}

/** What a page or list shows when it has nothing to show. */
export function EmptyState({ icon, title, description, children }: EmptyStateProperties) {
	return (
		<div className="flex flex-col items-center gap-2.5 px-5 py-12 text-center">
			<span className="text-primary">{icon}</span>
			<p className="font-heading text-section-title font-bold text-heading">{title}</p>
			<p className="max-w-[480px] text-caption">{description}</p>
			{children}
		</div>
	)
}
