import { useEffect, useRef, useState } from "react"

const TYPING_PAUSE_MILLISECONDS = 350

/**
 * Text that commits after a pause in typing, so each keystroke does not start a search. A
 * committed value that changes elsewhere, such as through Clear, replaces the text.
 */
export function useCommittedText(committed: string, onCommit: (text: string) => void) {
	const [text, setText] = useState(committed)
	const [previousCommitted, setPreviousCommitted] = useState(committed)
	if (committed !== previousCommitted) {
		setPreviousCommitted(committed)
		if (committed !== text.trim()) setText(committed)
	}
	const commit = useRef(onCommit)
	commit.current = onCommit
	useEffect(() => {
		if (text.trim() === committed) return
		const timer = setTimeout(() => commit.current(text.trim()), TYPING_PAUSE_MILLISECONDS)
		return () => clearTimeout(timer)
	}, [text, committed])
	return [text, setText] as const
}
