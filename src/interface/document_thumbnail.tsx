import { FileIcon } from "@phosphor-icons/react"
import { useState } from "react"

/** A small picture of the document's first page, or a file icon when there is none. */
export function DocumentThumbnail({ documentId, className }: { documentId: string; className: string }) {
	const [unavailable, setUnavailable] = useState(false)
	const frame = `${className} flex-none rounded border border-kumo-hairline`
	if (unavailable) {
		return (
			<span className={`${frame} flex items-center justify-center bg-kumo-tint text-kumo-subtle`}>
				<FileIcon size={16} />
			</span>
		)
	}
	return (
		<img
			src={`/api/documents/${documentId}/thumbnail`}
			alt=""
			loading="lazy"
			className={`${frame} bg-white object-cover object-top`}
			// An image that failed during server rendering has already fired its error before hydration.
			ref={(image) => {
				if (image?.complete && image.naturalWidth === 0) setUnavailable(true)
			}}
			onError={() => setUnavailable(true)}
		/>
	)
}
