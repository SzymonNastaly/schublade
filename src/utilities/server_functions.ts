import { createServerFn } from "@tanstack/react-start"
import { env } from "cloudflare:workers"
import { z } from "zod"
import { queryArchiveFacets } from "../archive/document_listing"
import { deleteDocument, documentRevisionSchema, reviseDocument } from "../archive/document_revision"
import {
	confirmTaxonomyRecord,
	deleteTaxonomyRecord,
	mergeTaxonomyRecords,
	renameTaxonomyRecord,
	taxonomyMergeSchema,
	taxonomyRecordSchema,
	taxonomyRenameSchema,
} from "../archive/taxonomy_maintenance"
import { countVerificationItems, listVerificationItems } from "../archive/verification_items"
import { apiTokenIssuanceSchema, issueApiToken, listApiTokens, revokeApiToken } from "../authentication/api_tokens"
import { authorizeOperation } from "../authorization/caller_authorization"
import { database } from "../database/client"
import { searchCriteriaSchema } from "../search/search_criteria"
import { searchDocuments } from "../search/document_search"

export const retrieveDocuments = createServerFn({ method: "GET" })
	.validator(searchCriteriaSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "readArchive")
		return searchDocuments(database, env.SEARCH_INDEX, data)
	})

export const listArchiveFacets = createServerFn({ method: "GET" }).handler(({ context }) => {
	authorizeOperation(context, "readArchive")
	return queryArchiveFacets(database)
})

export const listApiTokenRecords = createServerFn({ method: "GET" }).handler(({ context }) => {
	authorizeOperation(context, "administerApiTokens")
	return listApiTokens(database)
})

export const issueApiTokenRecord = createServerFn({ method: "POST" })
	.validator(apiTokenIssuanceSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "administerApiTokens")
		return issueApiToken(database, data)
	})

export const revokeApiTokenRecord = createServerFn({ method: "POST" })
	.validator(z.strictObject({ tokenId: z.uuid() }))
	.handler(({ context, data }) => {
		authorizeOperation(context, "administerApiTokens")
		return revokeApiToken(database, data.tokenId)
	})

/** @public */
export const retrieveVerificationItems = createServerFn({ method: "GET" }).handler(({ context }) => {
	authorizeOperation(context, "readArchive")
	return listVerificationItems(database)
})

/** @public */
export const countPendingVerificationItems = createServerFn({ method: "GET" }).handler(({ context }) => {
	authorizeOperation(context, "readArchive")
	return countVerificationItems(database)
})

const archiveEnvironment = () => ({ database, storage: env.DOCUMENT_STORAGE, searchIndex: env.SEARCH_INDEX })

/** @public */
export const submitDocumentRevision = createServerFn({ method: "POST" })
	.validator(documentRevisionSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "reviseDocument")
		return reviseDocument(archiveEnvironment(), data)
	})

/** @public */
export const submitDocumentDeletion = createServerFn({ method: "POST" })
	.validator(z.strictObject({ documentId: z.uuid() }))
	.handler(({ context, data }) => {
		authorizeOperation(context, "deleteDocument")
		return deleteDocument(archiveEnvironment(), data.documentId)
	})

/** @public */
export const submitTaxonomyConfirmation = createServerFn({ method: "POST" })
	.validator(taxonomyRecordSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "confirmTaxonomyRecord")
		return confirmTaxonomyRecord(database, data)
	})

/** @public */
export const submitTaxonomyRename = createServerFn({ method: "POST" })
	.validator(taxonomyRenameSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "renameTaxonomyRecord")
		return renameTaxonomyRecord(database, data)
	})

/** @public */
export const submitTaxonomyMerge = createServerFn({ method: "POST" })
	.validator(taxonomyMergeSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "mergeTaxonomyRecords")
		return mergeTaxonomyRecords(database, data)
	})

/** @public */
export const submitTaxonomyDeletion = createServerFn({ method: "POST" })
	.validator(taxonomyRecordSchema)
	.handler(({ context, data }) => {
		authorizeOperation(context, "deleteTaxonomyRecord")
		return deleteTaxonomyRecord(database, data)
	})
