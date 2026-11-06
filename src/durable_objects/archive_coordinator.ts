import { DurableObject } from "cloudflare:workers"

// Phase 5 broadcasts workflow state transitions to connected clients from here.
export class ArchiveCoordinator extends DurableObject<Env> {}
