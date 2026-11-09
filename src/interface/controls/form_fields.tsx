import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from "react"

const fieldLabelClasses = "flex min-w-0 flex-col gap-1 text-fine text-field-label"
const fieldControlClasses =
	"h-11 w-full min-w-0 rounded-field border border-field-border bg-surface px-2 text-body text-foreground md:h-9"

interface TextFieldProperties extends Omit<InputHTMLAttributes<HTMLInputElement>, "className" | "style"> {
	label: ReactNode
}

export function TextField({ label, ...input }: TextFieldProperties) {
	return (
		<label className={fieldLabelClasses}>
			{label}
			<input className={fieldControlClasses} {...input} />
		</label>
	)
}

interface SelectionFieldProperties extends Omit<SelectHTMLAttributes<HTMLSelectElement>, "className" | "style"> {
	label: ReactNode
	options: ReadonlyArray<{ value: string; label: string }>
	/** An entry without a value, shown until the member chooses one. */
	placeholder?: string
}

/** A native select, so a phone offers its own picker and a keyboard can type ahead. */
export function SelectionField({ label, options, placeholder, ...select }: SelectionFieldProperties) {
	return (
		<label className={fieldLabelClasses}>
			{label}
			<select className={fieldControlClasses} {...select}>
				{placeholder !== undefined && <option value="">{placeholder}</option>}
				{options.map((option) => (
					<option key={option.value} value={option.value}>
						{option.label}
					</option>
				))}
			</select>
		</label>
	)
}

export function FailureMessage({ children }: { children: ReactNode }) {
	return (
		<p role="alert" className="text-failure-text">
			{children}
		</p>
	)
}
