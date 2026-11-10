import { FilesIcon, UploadSimpleIcon, WarningCircleIcon } from "@phosphor-icons/react"
import { Link, useLoaderData, useRouterState } from "@tanstack/react-router"
import { archiveSectionOfPath } from "./archive_sections"
import { DocumentFilePicker } from "./document_file_picker"

const destination =
	"flex h-[62px] min-w-0 flex-1 flex-col items-center justify-center gap-0.5 border-t-4 text-[11px] text-on-accent"

/** The sections and the upload, within reach of a thumb. It sets no z-index, so a dialog covers it. */
export function PhoneNavigationBar() {
	const failedDocumentCount = useLoaderData({ from: "__root__" })
	const section = useRouterState({ select: (state) => archiveSectionOfPath(state.location.pathname) })
	return (
		<nav
			aria-label="Archive sections"
			className="fixed inset-x-0 bottom-0 flex border-t border-toolbar-border bg-toolbar pb-[env(safe-area-inset-bottom)] md:hidden"
		>
			<Link
				to="/"
				aria-current={section === "documents" ? "page" : undefined}
				activeOptions={{ exact: true, includeSearch: false }}
				className={`${destination} ${section === "documents" ? "border-documents font-bold" : "border-transparent"}`}
			>
				<FilesIcon size={22} className="text-primary" />
				Documents
			</Link>
			<Link
				to="/failed_documents"
				aria-current={section === "failed_documents" ? "page" : undefined}
				className={`${destination} ${section === "failed_documents" ? "border-failed-documents font-bold" : "border-transparent"}`}
			>
				<span className="relative">
					<WarningCircleIcon size={22} className="text-failed-documents-badge-text" />
					{failedDocumentCount > 0 && (
						<span className="absolute -top-1.5 left-4 flex h-[18px] min-w-[18px] items-center justify-center rounded-badge bg-failed-documents px-1 text-[11px] font-bold">
							{failedDocumentCount}
						</span>
					)}
				</span>
				Failed documents
			</Link>
			<DocumentFilePicker>
				{(open) => (
					<button type="button" onClick={open} className={`${destination} border-transparent`}>
						<UploadSimpleIcon size={22} className="text-primary" />
						Upload
					</button>
				)}
			</DocumentFilePicker>
		</nav>
	)
}
