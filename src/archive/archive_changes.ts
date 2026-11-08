import type { ArchiveCoordinator } from "../durable_objects/archive_coordinator"

type CoordinatorEnvironment = Pick<Env, "ARCHIVE_COORDINATOR">

export const ARCHIVE_CHANGES_PATH = "/api/archive_changes"

// The Worker names the coordinator, so no request can address another object.
const HOUSEHOLD_COORDINATOR_NAME = "household"

function householdCoordinator(environment: CoordinatorEnvironment) {
	// The generated Env does not carry the class of a Durable Object binding.
	const namespace = environment.ARCHIVE_COORDINATOR as unknown as DurableObjectNamespace<ArchiveCoordinator>
	return namespace.getByName(HOUSEHOLD_COORDINATOR_NAME)
}

export function connectToArchiveChanges(environment: CoordinatorEnvironment, request: Request): Promise<Response> {
	return householdCoordinator(environment).fetch(request)
}

/**
 * D1 holds the truth, so a lost announcement leaves a browser behind only until the next one, a
 * reconnection, or a reload. It must not fail the write it follows.
 */
export async function announceArchiveChange(environment: CoordinatorEnvironment): Promise<void> {
	try {
		await householdCoordinator(environment).announceArchiveChange()
	} catch (error) {
		console.warn("The archive change could not be announced", error)
	}
}
