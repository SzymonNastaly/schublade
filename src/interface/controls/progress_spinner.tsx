/** A small rotating ring in the current text colour. */
export function ProgressSpinner() {
	return (
		<span
			aria-hidden
			className="inline-block size-4 animate-progress rounded-full border-2 border-current border-r-transparent"
		/>
	)
}
