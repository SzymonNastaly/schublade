export type ArchiveSection = "documents" | "failed_documents" | "settings"

/** The section a path belongs to. A document page belongs to the archive that lists it. */
export function archiveSectionOfPath(pathname: string): ArchiveSection {
	if (pathname.startsWith("/failed_documents")) return "failed_documents"
	if (pathname.startsWith("/settings")) return "settings"
	return "documents"
}
