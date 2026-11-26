import { expect, test } from "vitest"
import { isReadableTextLayer } from "./document_text"

test("isReadableTextLayer needs 40 letters or digits and fewer than one replacement character per ten of them", () => {
	const fiftyLettersAndDigits = "Betrag 67,13\n".repeat(5)
	const bulletedList = " Betrag 67,13\n".repeat(4)
	expect({
		fewerThanForty: isReadableTextLayer("Seite 1 von 1\n".repeat(4).slice(1)),
		forty: isReadableTextLayer("Seite 1 von 1\n".repeat(4)),
		unmappedFont: isReadableTextLayer(fiftyLettersAndDigits + "�".repeat(400)),
		controlCharacter: isReadableTextLayer(`${bulletedList}\u0003Betrag 67,13\n`),
		symbolBullets: isReadableTextLayer(`${bulletedList}Betrag 67,13\t\n`),
	}).toEqual({
		fewerThanForty: false,
		forty: true,
		unmappedFont: false,
		controlCharacter: false,
		symbolBullets: true,
	})
})
