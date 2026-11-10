import type { ReactNode } from "react"

export type BadgeTone = "processing" | "failure" | "success" | "neutral"

const toneClasses: Record<BadgeTone, string> = {
	processing: "border-documents-badge-border bg-documents-badge text-documents-badge-text",
	failure: "border-failure-badge-border bg-failure-badge text-failure-text",
	success: "border-success-badge-border bg-success-badge text-success-badge-text",
	neutral: "border-neutral-badge-border bg-neutral-badge text-neutral-badge-text",
}

export function StatusBadge({ tone, children }: { tone: BadgeTone; children: ReactNode }) {
	return (
		<span
			className={`inline-block rounded-badge border px-2 text-[11.5px] font-bold whitespace-nowrap ${toneClasses[tone]}`}
		>
			{children}
		</span>
	)
}
