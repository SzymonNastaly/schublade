import { Lifecycle } from "agents/lifecycle"
import { WebSockets } from "agents/websockets"
import { DurableObject } from "cloudflare:workers"

const ARCHIVE_CHANGED_MESSAGE = "archive_changed"

/** It stores nothing, because D1 holds the documents and a browser reads them again on each signal. */
export class ArchiveCoordinator extends DurableObject<Env> {
	readonly webSockets = new WebSockets({ protocol: false })
	readonly lifecycle = Lifecycle.install(this).use(this.webSockets)

	async announceArchiveChange(): Promise<void> {
		await this.lifecycle.start()
		for (const connection of this.webSockets.getConnections()) connection.send(ARCHIVE_CHANGED_MESSAGE)
	}
}
