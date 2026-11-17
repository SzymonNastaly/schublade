import type { InputHTMLAttributes, ReactNode } from "react"

interface TextFieldProperties extends Omit<InputHTMLAttributes<HTMLInputElement>, "className" | "style"> {
	label: ReactNode
	hint?: ReactNode
}

export function TextField({ label, hint, ...input }: TextFieldProperties) {
	return (
		<label className="flex min-w-0 flex-col gap-1 text-fine text-field-label">
			<span className="font-bold">{label}</span>
			<input
				className="h-9 w-full min-w-0 rounded-field border border-field-border bg-surface px-2 text-body text-foreground focus:border-primary focus:outline-2 focus:outline-documents-badge-border"
				{...input}
			/>
			{hint !== undefined && <span className="text-caption">{hint}</span>}
		</label>
	)
}

export function FailureMessage({ children }: { children: ReactNode }) {
	return (
		<p
			role="alert"
			className="rounded-field border border-failure-badge-border bg-failure-badge px-3 py-2 text-failure-text"
		>
			{children}
		</p>
	)
}

interface ToggleFieldProperties {
	label: string
	description: string
	checked: boolean
	disabled?: boolean
	onChange: (checked: boolean) => void
}

/** A switch, as macOS presents a setting that applies at once. */
export function ToggleField({ label, description, checked, disabled = false, onChange }: ToggleFieldProperties) {
	return (
		<label className="flex cursor-pointer items-start justify-between gap-4">
			<span className="flex flex-col gap-0.5">
				<span className="font-bold text-heading">{label}</span>
				<span className="text-fine text-caption">{description}</span>
			</span>
			<input
				type="checkbox"
				role="switch"
				checked={checked}
				disabled={disabled}
				onChange={(event) => onChange(event.target.checked)}
				className="peer sr-only"
			/>
			<span
				aria-hidden
				className="relative mt-0.5 inline-flex h-5.5 w-9.5 shrink-0 items-center rounded-full border border-control-border bg-neutral-badge transition-colors peer-checked:border-primary peer-checked:bg-primary peer-focus-visible:outline-2 peer-focus-visible:outline-documents-badge-border peer-disabled:opacity-55 after:absolute after:left-0.5 after:size-4 after:rounded-full after:bg-surface after:shadow-application after:transition-transform peer-checked:after:translate-x-4"
			/>
		</label>
	)
}
