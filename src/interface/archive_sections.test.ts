import { expect, test } from "vitest"
import { archiveSectionOfPath } from "./archive_sections"

test("a path belongs to the section whose tab stays active on it", () => {
	expect(archiveSectionOfPath("/")).toBe("documents")
	expect(archiveSectionOfPath("/documents/af0cf412-70e7-45d6-9957-62f2a522d882")).toBe("documents")
	expect(archiveSectionOfPath("/verification")).toBe("verification")
	expect(archiveSectionOfPath("/verification/review")).toBe("verification")
	expect(archiveSectionOfPath("/settings")).toBe("settings")
})
