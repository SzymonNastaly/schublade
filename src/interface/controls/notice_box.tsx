import type { ReactNode } from "react"

const toneClasses = {
	documents: "border-documents-badge-border bg-documents-badge",
	verification: "border-verification-border bg-verification-surface",
	settings: "border-settings-border bg-settings-surface",
}

interface NoticeBoxProperties {
	tone: keyof typeof toneClasses
	title: string
	children: ReactNode
}

export function NoticeBox({ tone, title, children }: NoticeBoxProperties) {
	return (
		<div role="status" className={`flex flex-col gap-2 rounded-list border px-3.5 py-3 ${toneClasses[tone]}`}>
			<strong className="wrap-anywhere">{title}</strong>
			{children}
		</div>
	)
}
