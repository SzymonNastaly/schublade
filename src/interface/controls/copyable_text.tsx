import { useState } from "react"
import { ActionButton } from "./action_button"

/** Text to carry elsewhere, such as a token or an address, with a button that copies it. */
export function CopyableText({ text }: { text: string }) {
	const [copied, setCopied] = useState(false)
	return (
		<div className="flex flex-wrap items-center gap-2">
			<code className="min-w-0 flex-[1_1_280px] rounded-field border border-table-border bg-surface px-2.5 py-2 font-mono text-fine wrap-anywhere">
				{text}
			</code>
			<ActionButton
				variant="secondary"
				stretchOnPhone
				onClick={() => void navigator.clipboard.writeText(text).then(() => setCopied(true))}
			>
				{copied ? "Copied" : "Copy"}
			</ActionButton>
		</div>
	)
}
