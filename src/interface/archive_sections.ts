export type ArchiveSection = "documents" | "verification" | "settings"

/** The section a path belongs to. A document page belongs to the archive that lists it. */
export function archiveSectionOfPath(pathname: string): ArchiveSection {
	if (pathname.startsWith("/verification")) return "verification"
	if (pathname.startsWith("/settings")) return "settings"
	return "documents"
}
