import { useRef } from "react"
import { acceptedMediaTypes } from "../ingestion/source_file"
import { useDocumentUploads } from "./upload_tray"
import type { ReactNode } from "react"

/**
 * A hidden file input and the control that opens it. On a phone the system's own picker offers the
 * camera, the photo library, and the files, and it converts a HEIC photograph to an accepted type.
 */
export function DocumentFilePicker({ children }: { children: (open: () => void) => ReactNode }) {
	const { start } = useDocumentUploads()
	const fileInput = useRef<HTMLInputElement>(null)
	return (
		<>
			<input
				ref={fileInput}
				type="file"
				multiple
				hidden
				aria-label="Choose documents"
				accept={acceptedMediaTypes.join(",")}
				onChange={(event) => {
					// Clearing the input empties its live FileList, so the files are copied first.
					const files = [...(event.target.files ?? [])]
					event.target.value = ""
					if (files.length > 0) start(files)
				}}
			/>
			{children(() => fileInput.current?.click())}
		</>
	)
}
