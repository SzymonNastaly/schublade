import { env } from "cloudflare:test"
import { expect, test, vi } from "vitest"
import { announceArchiveChange, connectToArchiveChanges } from "./archive_changes"

async function openBrowserSocket() {
	const response = await connectToArchiveChanges(
		env,
		new Request("https://archive.test/api/archive_changes", { headers: { Upgrade: "websocket" } }),
	)
	const socket = response.webSocket
	if (socket === null) throw new Error(`The coordinator answered ${response.status} instead of a WebSocket`)
	socket.accept()
	const messages: Array<unknown> = []
	socket.addEventListener("message", (event) => {
		messages.push(event.data)
	})
	return { socket, messages }
}

test("every open browser hears that the archive changed", async () => {
	const first = await openBrowserSocket()
	const second = await openBrowserSocket()

	await announceArchiveChange(env)

	await vi.waitFor(() =>
		expect({ first: first.messages, second: second.messages }).toEqual({
			first: ["archive_changed"],
			second: ["archive_changed"],
		}),
	)
	first.socket.close()
	second.socket.close()
})

test("an announcement that cannot reach the coordinator does not fail the write it follows", async () => {
	const unreachable = {
		getByName: () => ({ announceArchiveChange: () => Promise.reject(new Error("The coordinator is unavailable")) }),
	}
	const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined)

	await expect(
		announceArchiveChange({ ARCHIVE_COORDINATOR: unreachable as unknown as Env["ARCHIVE_COORDINATOR"] }),
	).resolves.toBeUndefined()

	expect(warning).toHaveBeenCalledOnce()
})
