import { createServerFn } from "@tanstack/react-start"
import { asc } from "drizzle-orm"
import { database } from "../database/client"
import { householdMembers } from "../database/schema"

export const listHouseholdMembers = createServerFn({ method: "GET" }).handler(() =>
	database
		.select({
			id: householdMembers.id,
			displayName: householdMembers.displayName,
			addresseeNames: householdMembers.addresseeNames,
		})
		.from(householdMembers)
		.orderBy(asc(householdMembers.displayName)),
)
