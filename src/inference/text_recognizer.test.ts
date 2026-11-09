import { expect, test } from "vitest"
import { parseMoondreamEventStream, restoreEuroSigns } from "./text_recognizer"

// Shape recorded from the Workers AI binding: every chunk repeats the full answer so far.
const recordedEventStream = [
	'data: {"id":"9558cb3f-9c60-4593-b0f3-f67123f053cb","status":"processing","usage":{"prompt_tokens":0}}',
	'data: {"mode":"replace","name":"task","value":"query"}',
	'data: {"chunk":{"answer":"Stadt","caption":null,"finish_reason":""},"index":0}',
	'data: {"chunk":{"answer":"Stadtwerke Talbrück","caption":null,"finish_reason":""},"index":1}',
	'data: {"chunk":{"answer":"Stadtwerke Talbrück GmbH\\nIBAN DE12 9701 1320 0300 4182 25\\n","caption":null,"finish_reason":"stop"},"index":2}',
	'data: {"id":"9558cb3f-9c60-4593-b0f3-f67123f053cb","output":[{"answer":"Stadt"}],"status":"succeeded"}',
	'data: {"response":""}',
	"data: [DONE]",
].join("\n\n")

test("parseMoondreamEventStream returns the answer of the last chunk", () => {
	expect(parseMoondreamEventStream(`${recordedEventStream}\n\n`)).toEqual({
		kind: "transcribed",
		text: "Stadtwerke Talbrück GmbH\nIBAN DE12 9701 1320 0300 4182 25",
	})
})

test("parseMoondreamEventStream reports a reading that stopped at the token limit", () => {
	const eventStream = [
		'data: {"chunk":{"answer":"Seite Seite","caption":null,"finish_reason":""},"index":0}',
		'data: {"chunk":{"answer":"Seite Seite Seite","caption":null,"finish_reason":"length"},"index":1}',
		"data: [DONE]",
	].join("\n\n")

	expect(parseMoondreamEventStream(eventStream)).toEqual({ kind: "token_limit_reached" })
})

test("restoreEuroSigns turns a replacement character beside a monetary amount into a euro sign", () => {
	expect(
		[
			"91,84 �",
			"� 12,94",
			"Preis 3,99�",
			"Abschlag -1.104,00 �",
			"| 845.51 � |",
			"01.09.2025 � 31.08.2026",
			"21 �C",
			"Z�hlerstand 12 � 4",
			"Stra�e 7, Talbr�ck",
			"Summe in �",
		].map(restoreEuroSigns),
	).toEqual([
		"91,84 €",
		"€ 12,94",
		"Preis 3,99€",
		"Abschlag -1.104,00 €",
		"| 845.51 € |",
		"01.09.2025 � 31.08.2026",
		"21 �C",
		"Z�hlerstand 12 � 4",
		"Stra�e 7, Talbr�ck",
		"Summe in �",
	])
})
