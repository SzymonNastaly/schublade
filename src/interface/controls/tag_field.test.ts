import { expect, test } from "vitest"
import { appendTag } from "./tag_field"

test("typed text becomes a trimmed tag", () => {
	expect(appendTag(["Internet"], "  Monthly ", 5)).toEqual(["Internet", "Monthly"])
})

test("blank text, a repeated tag, and a tag over the limit leave the tags alone", () => {
	expect(appendTag(["Internet"], "   ", 5)).toEqual(["Internet"])
	expect(appendTag(["Internet"], "internet", 5)).toEqual(["Internet"])
	expect(appendTag(["Internet"], "Monthly", 1)).toEqual(["Internet"])
})
