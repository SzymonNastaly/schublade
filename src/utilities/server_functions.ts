import { createServerFn } from "@tanstack/react-start"
import { env } from "cloudflare:workers"
import { queryArchiveFacets } from "../archive/document_listing"
import { database } from "../database/client"
import { searchCriteriaSchema } from "../search/search_criteria"
import { searchDocuments } from "../search/document_search"

export const retrieveDocuments = createServerFn({ method: "GET" })
	.validator(searchCriteriaSchema)
	.handler(({ data }) => searchDocuments(database, env.SEARCH_INDEX, data))

export const listArchiveFacets = createServerFn({ method: "GET" }).handler(() => queryArchiveFacets(database))
