import { expect, test } from "vitest"
import { parseMoondreamEventStream } from "./text_recognizer"

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
	expect(parseMoondreamEventStream(`${recordedEventStream}\n\n`)).toBe(
		"Stadtwerke Talbrück GmbH\nIBAN DE12 9701 1320 0300 4182 25",
	)
})
